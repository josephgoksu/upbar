import Network
import ServiceManagement
import Charts
import SwiftUI
import UserNotifications

// MARK: - Checking

struct Endpoint: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var url = "https://"
    var expected = 200
}

enum Health: Equatable {
    case unknown, up(code: Int, ms: Int), down(String)
    var isDown: Bool { if case .down = self { true } else { false } }
}

/// Failed checks in a row before an endpoint counts as down, so one dropped request doesn't alert.
let failureThreshold = 2

/// Folds one probe result into the shown health and the failure streak.
func step(_ shown: Health, streak: Int, probe: Health) -> (Health, Int) {
    guard probe.isDown else { return (probe, 0) }
    return (streak + 1 >= failureThreshold ? probe : shown, streak + 1)
}

/// Redirects aren't followed, so the status code is exactly what the URL returns.
final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest) async -> URLRequest? { nil }
}

let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 15
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.urlCache = nil
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
}()

/// Where one request spent its time, from URLSessionTaskMetrics. The editor draws it as a waterfall.
struct Trace: Equatable {
    var dns = 0, connect = 0, tls = 0, server = 0  // milliseconds
    var reused = false
    var proto: String?  // h2, h3, http/1.1
    var tlsVersion: String?
    var address: String?
    var certExpires: Date?
}

/// Records one task's metrics and the expiry of the server certificate. One per task, so parallel probes never mix.
final class Recorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: Trace?
    private var expires: Date?

    var trace: Trace? { lock.withLock { metrics } }
    var certExpires: Date? { lock.withLock { expires } }

    /// Only a new TLS connection asks for trust, so a reused connection has no expiry date.
    func urlSession(_: URLSession, task _: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if let trust = challenge.protectionSpace.serverTrust,
           let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first {
            let date = notAfter(leaf)
            lock.withLock { expires = date }
        }
        return (.performDefaultHandling, nil)  // macOS still validates the certificate
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let m = metrics.transactionMetrics.last else { return }
        func ms(_ from: Date?, _ to: Date?) -> Int {
            guard let from, let to else { return 0 }
            return max(0, Int(to.timeIntervalSince(from) * 1000))
        }
        let trace = Trace(dns: ms(m.domainLookupStartDate, m.domainLookupEndDate),
                          connect: ms(m.connectStartDate, m.secureConnectionStartDate ?? m.connectEndDate),  // connectEnd includes TLS
                          tls: ms(m.secureConnectionStartDate, m.secureConnectionEndDate),
                          server: ms(m.requestStartDate, m.responseStartDate),
                          reused: m.isReusedConnection, proto: m.networkProtocolName,
                          tlsVersion: m.negotiatedTLSProtocolVersion.map { $0 == .TLSv13 ? "TLS 1.3" : $0 == .TLSv12 ? "TLS 1.2" : "TLS" },
                          address: m.remoteAddress)
        lock.withLock { self.metrics = trace }
    }
}

/// The "not valid after" date of a certificate.
func notAfter(_ certificate: SecCertificate) -> Date? {
    let key = kSecOIDX509V1ValidityNotAfter
    guard let values = SecCertificateCopyValues(certificate, [key] as CFArray, nil) as? [CFString: Any],
          let entry = values[key] as? [CFString: Any], let seconds = entry[kSecPropertyKeyValue] as? NSNumber else { return nil }
    return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
}

func probe(_ endpoint: Endpoint) async -> (Health, Trace?) {
    guard let url = URL(string: endpoint.url), url.host() != nil else { return (.down("Invalid URL"), nil) }
    var start = ContinuousClock.now
    let head = Recorder()
    var deciding = head
    do {
        // HEAD first: same status, no body. Some servers answer HEAD differently (405, or even 400), so any
        // unexpected status is confirmed with a GET that stops after the headers. A down verdict is always a real GET.
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        var code = try await (session.data(for: request, delegate: head).1 as? HTTPURLResponse)?.statusCode ?? 0
        if code != endpoint.expected {
            start = .now
            deciding = Recorder()
            let (body, response) = try await session.bytes(from: url, delegate: deciding)
            body.task.cancel()
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
        var trace = deciding.trace ?? head.trace  // a cancelled GET can report its metrics after we return
        trace?.certExpires = deciding.certExpires ?? head.certExpires
        return (code == endpoint.expected ? .up(code: code, ms: ms) : .down("HTTP \(code)"), trace)
    } catch {
        return (.down(error.localizedDescription), nil)
    }
}

/// A run of failed checks long enough to count as down. `end` is nil while it lasts.
struct Incident: Equatable {
    var start: UInt32
    var end: UInt32?
}

/// Outages in the history, by the same rule as the alerts: `failureThreshold` failed checks in a row.
func incidents(_ samples: [Sample]) -> [Incident] {
    var out: [Incident] = [], run = 0, first: UInt32 = 0
    for sample in samples {
        if sample.ms < 0 {
            if run == 0 { first = sample.t }
            run += 1
            if run == failureThreshold { out.append(Incident(start: first)) }
        } else {
            if run >= failureThreshold { out[out.count - 1].end = sample.t }
            run = 0
        }
    }
    return out
}

/// Days until a certificate expires at which Upbar warns.
let certWarningDays = 14

/// Trims whitespace and adds https:// when the scheme is missing, so pasted URLs just work.
func normalizeURL(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed.contains("://") ? trimmed : "https://" + trimmed
}

/// One check result. 8 bytes of data: seconds since 1970 and the response time, -1 for a failed check.
struct Sample: Codable, Equatable {
    var t: UInt32
    var ms: Int32
}

struct Stats: Equatable {
    var uptime: Double  // share of successful checks, 0...1
    var checks: Int
    var p50: Int?, p90: Int?, p95: Int?, p99: Int?
    var mean: Int?, min: Int?, max: Int?  // of successful checks
    var failed: Int { checks - Int((uptime * Double(checks)).rounded()) }
}

/// Nearest-rank percentile of an ascending array.
func percentile(_ sorted: [Int], _ p: Double) -> Int? {
    guard !sorted.isEmpty else { return nil }
    return sorted[max(0, Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1)]
}

func summarize(_ samples: [Sample]) -> Stats? {
    guard !samples.isEmpty else { return nil }
    let times = samples.filter { $0.ms >= 0 }.map { Int($0.ms) }.sorted()
    return Stats(uptime: Double(times.count) / Double(samples.count), checks: samples.count,
                 p50: percentile(times, 50), p90: percentile(times, 90), p95: percentile(times, 95), p99: percentile(times, 99),
                 mean: times.isEmpty ? nil : times.reduce(0, +) / times.count, min: times.first, max: times.last)
}

/// The website an endpoint belongs to: `api.markwise.app` becomes `markwise.app`.
/// ponytail: last two labels, three for short country suffixes like `co.uk`; use the Public Suffix List if this guesses wrong.
func site(_ url: String) -> String {
    guard let host = URL(string: normalizeURL(url))?.host()?.lowercased() else { return url }
    let labels = host.split(separator: ".")
    guard labels.count > 2, !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return host }
    let keep = labels[labels.count - 1].count == 2 && labels[labels.count - 2].count <= 3 ? 3 : 2
    return labels.suffix(keep).joined(separator: ".")
}

/// `swift run` has no app bundle, and notifications and login items need one.
let isApp = Bundle.main.bundleURL.pathExtension == "app"

/// CPU seconds this process has used since launch.
func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

/// Memory as Activity Monitor counts it.
func memoryFootprint() -> Int64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    } == KERN_SUCCESS
    return ok ? Int64(info.phys_footprint) : nil
}

@MainActor @Observable
final class Store {
    var endpoints: [Endpoint] { didSet { UserDefaults.standard.set(try? JSONEncoder().encode(endpoints), forKey: "endpoints") } }
    private(set) var health: [UUID: Health] = [:]
    private(set) var lastCheck: Date?
    /// Raw check results of the last 24 hours, oldest first. Drives the sparkline and the stats. Saved to disk.
    private(set) var samples: [UUID: [Sample]] = [:]
    private var savedAt = Date.now
    static let window: TimeInterval = 24 * 60 * 60
    /// The dev build (`swift run`, tests) keeps its own file, so it never touches the real history.
    static let historyFile = (isApp ? URL.applicationSupportDirectory : URL.temporaryDirectory).appending(path: "Upbar/history.plist")
    private(set) var downSince: [UUID: Date] = [:]
    /// The last request of each endpoint, for the waterfall. In memory; the next check refreshes it.
    private(set) var traces: [UUID: Trace] = [:]
    /// Known only after a new TLS connection, so it is kept across checks that reuse a connection.
    private(set) var certExpiry: [UUID: Date] = [:]
    private var certWarned: Set<UUID> = []
    /// One entry per check round, newest last. Drives the menu bar icon.
    private(set) var rounds: [Round] = []
    private var streak: [UUID: Int] = [:]
    private(set) var checking = false
    /// Offline, every check would fail and alert. Checks pause instead and resume on reconnect.
    private(set) var online = true
    private let path = NWPathMonitor()
    /// Upbar's own CPU use between the last two checks, 0...1. Includes the checks and any redraw while the window was open.
    private(set) var cpu: Double?
    private var lastCPU = (seconds: cpuSeconds(), at: ContinuousClock.now)

    init() {
        let saved = UserDefaults.standard.data(forKey: "endpoints")
        endpoints = saved.flatMap { try? JSONDecoder().decode([Endpoint].self, from: $0) } ?? []
        let ids = Set(endpoints.map(\.id))
        samples = ((try? Data(contentsOf: Self.historyFile)).flatMap { try? PropertyListDecoder().decode([UUID: [Sample]].self, from: $0) } ?? [:])
            .filter { ids.contains($0.key) }
            .mapValues { list in list.filter { Double($0.t) >= Date.now.timeIntervalSince1970 - Self.window } }
        // Quit saves the history; queue .main keeps the callback on the main thread.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveHistory() }
        }
        if isApp { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) } }
        // @Sendable: macOS calls this on a background queue, so it must not inherit the main actor.
        path.pathUpdateHandler = { @Sendable [weak self] path in
            Task { @MainActor in
                guard let self, self.online != (path.status == .satisfied) else { return }
                self.online = path.status == .satisfied
                if self.online { await self.check() }
            }
        }
        path.start(queue: .global(qos: .utility))
        Task {
            while true {
                await check()
                try? await Task.sleep(for: .seconds(60), tolerance: .seconds(10))  // lets macOS batch the wake-up
            }
        }
    }

    var downCount: Int { endpoints.count { health[$0.id]?.isDown == true } }
    var sorted: [Endpoint] { endpoints.filter { health[$0.id]?.isDown == true } + endpoints.filter { health[$0.id]?.isDown != true } }

    /// Endpoints grouped by website. Groups with a down endpoint come first, then your order.
    var groups: [(site: String, endpoints: [Endpoint])] {
        var order: [String] = [], members: [String: [Endpoint]] = [:]
        for endpoint in sorted {
            let key = site(endpoint.url)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(endpoint)
        }
        let all = order.map { (site: $0, endpoints: members[$0]!) }
        return all.filter { $0.endpoints.contains { health[$0.id]?.isDown == true } } + all.filter { !$0.endpoints.contains { health[$0.id]?.isDown == true } }
    }

    func check() async {
        guard !checking, online else { return }
        checking = true
        defer { checking = false }
        let snapshot = endpoints
        // ponytail: all probes at once; fine for tens of endpoints, cap concurrency if someone watches hundreds.
        let probes = await withTaskGroup(of: (UUID, (Health, Trace?)).self) { group in
            for endpoint in snapshot { group.addTask { (endpoint.id, await probe(endpoint)) } }
            var out: [UUID: (Health, Trace?)] = [:]
            for await (id, result) in group { out[id] = result }
            return out
        }
        let results = probes.mapValues(\.0)
        for endpoint in snapshot {
            guard let result = results[endpoint.id], endpoints.contains(endpoint) else { continue }
            observe(endpoint, probes[endpoint.id]?.1)
            record(endpoint.id, result)
            let before = health[endpoint.id] ?? .unknown
            let (after, count) = step(before, streak: streak[endpoint.id, default: 0], probe: result)
            (health[endpoint.id], streak[endpoint.id]) = (after, count)
            if case .down(let reason) = after, !before.isDown { downSince[endpoint.id] = .now; notify("\(endpoint.name) is down", reason) }
            if before.isDown, case .up = after { downSince[endpoint.id] = nil; notify("\(endpoint.name) is back up", endpoint.url) }
        }
        let times = results.values.compactMap { if case .up(_, let ms) = $0 { ms } else { nil } }.sorted()
        rounds = (rounds + [Round(ms: times.isEmpty ? nil : times[times.count / 2], failed: results.values.contains { $0.isDown })]).suffix(7)
        lastCheck = .now
        let now = (seconds: cpuSeconds(), at: ContinuousClock.now)
        cpu = (now.seconds - lastCPU.seconds) / max(1, (now.at - lastCPU.at) / .seconds(1))
        lastCPU = now
        if Date.now.timeIntervalSince(savedAt) > 600 { saveHistory() }  // every 10 minutes, not every check
    }

    func save(_ endpoint: Endpoint) {
        let old = endpoints.first { $0.id == endpoint.id }
        if let i = endpoints.firstIndex(where: { $0.id == endpoint.id }) { endpoints[i] = endpoint } else { endpoints.append(endpoint) }
        guard old?.url != endpoint.url || old?.expected != endpoint.expected else { return }  // a rename keeps its history
        forget(endpoint.id)
        Task {  // show it right away, without waiting for the next round
            let (result, trace) = await probe(endpoint)
            guard endpoints.contains(endpoint) else { return }
            health[endpoint.id] = result
            observe(endpoint, trace)
            record(endpoint.id, result)
        }
    }

    func delete(_ endpoint: Endpoint) {
        endpoints.removeAll { $0.id == endpoint.id }
        forget(endpoint.id)
    }

    /// The last 30 response times for the sparkline, nil = failed check.
    func history(_ id: UUID) -> [Int?] { (samples[id] ?? []).suffix(30).map { $0.ms >= 0 ? Int($0.ms) : nil } }

    func stats(_ id: UUID) -> Stats? { summarize(samples[id] ?? []) }

    private func record(_ id: UUID, _ result: Health) {
        let now = UInt32(Date.now.timeIntervalSince1970)
        let ms: Int32 = if case .up(_, let ms) = result { Int32(clamping: ms) } else { -1 }
        var list = samples[id, default: []]
        list.append(Sample(t: now, ms: ms))
        // Drop what is older than 24 hours. The count cap also bounds manual checks.
        let cutoff = now - UInt32(Self.window)
        list.removeFirst(list.firstIndex { $0.t >= cutoff } ?? 0)
        samples[id] = list.suffix(2 * 1440)
    }

    func saveHistory() {
        savedAt = .now
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(samples) else { return }
        try? FileManager.default.createDirectory(at: Self.historyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.historyFile, options: .atomic)
    }

    /// Keeps the trace and the certificate date, and warns once per launch when the certificate expires soon.
    private func observe(_ endpoint: Endpoint, _ trace: Trace?) {
        guard let trace else { return }
        traces[endpoint.id] = trace
        guard let expires = trace.certExpires else { return }
        certExpiry[endpoint.id] = expires
        let days = Int(expires.timeIntervalSinceNow / 86400)
        if days < certWarningDays, certWarned.insert(endpoint.id).inserted {
            notify("\(endpoint.name): " + (days < 0 ? "certificate expired" : "certificate expires in \(days) days"), site(endpoint.url))
        }
    }

    private func forget(_ id: UUID) {
        (health[id], streak[id], samples[id], downSince[id], traces[id], certExpiry[id]) = (nil, nil, nil, nil, nil, nil)
        certWarned.remove(id)
    }

    var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do { try launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch { launchAtLogin = !launchAtLogin }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    private func notify(_ title: String, _ body: String) {
        guard isApp else { return print("\(title): \(body)") }
        let content = UNMutableNotificationContent()
        (content.title, content.body, content.sound) = (title, body, .default)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - UI

@main
struct Upbar: App {
    @State private var store = Store()
    @State private var receiver = Receiver()

    var body: some Scene {
        MenuBarExtra {
            Popover().environment(store).environment(receiver)
        } label: {
            Image(nsImage: menuBarIcon(store.rounds, down: store.downCount))
            if store.downCount > 0 { Text("\(store.downCount)") }
        }
        .menuBarExtraStyle(.window)
    }
}

struct Round: Equatable {
    var ms: Int?  // median response time of the round's successful checks
    var failed: Bool
}

/// The menu bar icon: a 7-bar sparkline of recent check rounds.
/// Healthy, it's a template image that follows the menu bar tint. A failed round draws a full bar,
/// orange for a past blip and red while something is down, which needs a non-template image.
@MainActor func menuBarIcon(_ rounds: [Round], down: Int) -> NSImage {
    let bars = 7, width: CGFloat = 2.5, gap: CGFloat = 1.5, height: CGFloat = 14
    let recent = Array(repeating: nil, count: max(0, bars - rounds.count)) + rounds.suffix(bars).map(Optional.some)
    let times = rounds.compactMap(\.ms).sorted()
    let peak = CGFloat(max(2 * (times.isEmpty ? 1 : times[times.count / 2]), 1))
    let anyFailed = rounds.suffix(bars).contains(where: \.failed)
    let image = NSImage(size: NSSize(width: CGFloat(bars) * (width + gap) - gap, height: 16), flipped: false) { _ in
        for (i, round) in recent.enumerated() {
            let barHeight: CGFloat
            switch round {
            case nil:
                NSColor.labelColor.withAlphaComponent(0.3).setFill()
                barHeight = 3
            case let round? where round.failed:
                (down > 0 ? NSColor.systemRed : .systemOrange).setFill()
                barHeight = height
            case let round?:
                NSColor.labelColor.setFill()
                barHeight = round.ms.map { max(3, height * min(1, CGFloat($0) / peak)) } ?? 3
            }
            NSBezierPath(roundedRect: NSRect(x: CGFloat(i) * (width + gap), y: 1, width: width, height: barHeight),
                         xRadius: width / 2, yRadius: width / 2).fill()
        }
        return true
    }
    image.isTemplate = !anyFailed
    image.accessibilityDescription = down > 0 ? "\(down) down" : "All up"
    return image
}

/// The popover's accent: green when all is well, red when something is down.
enum Mood {
    case calm, alarm, offline, empty

    var tint: Color {
        switch self {
        case .calm: .green
        case .alarm: .red
        case .offline: .gray
        case .empty: .indigo
        }
    }
    var symbol: String {
        switch self {
        case .calm: "checkmark"
        case .alarm: "exclamationmark"
        case .offline: "wifi.slash"
        case .empty: "plus"
        }
    }
}

struct Popover: View {
    @Environment(Store.self) private var store
    @Environment(Receiver.self) private var receiver
    @State private var editing: Endpoint?
    @State private var detail: UUID?
    @State private var tab = Tab.endpoints
    @State private var collapsed: Set<String> = []

    enum Tab { case endpoints, events }

    private var mood: Mood {
        !store.online ? .offline : store.downCount > 0 ? .alarm : store.endpoints.isEmpty ? .empty : .calm
    }

    var body: some View {
        Group {
            if let endpoint = editing {
                let isNew = !store.endpoints.contains { $0.id == endpoint.id }
                Editor(endpoint: endpoint, isNew: isNew) { action in
                    switch action {
                    case .save(let saved): store.save(saved)
                    case .delete: store.delete(endpoint); detail = nil
                    case .cancel: break
                    }
                    editing = nil
                }
                .id(endpoint.id)
            } else if let id = detail, let endpoint = store.endpoints.first(where: { $0.id == id }) {
                Detail(endpoint: endpoint, health: store.health[id] ?? .unknown, downSince: store.downSince[id],
                       samples: store.samples[id] ?? [], trace: store.traces[id], certExpires: store.certExpiry[id],
                       back: { detail = nil }, edit: { editing = endpoint })
            } else {
                VStack(spacing: 0) {
                    hero
                    TabBar(tab: $tab, unread: receiver.unread).padding(.horizontal, 14).padding(.bottom, 10)
                    Group { if tab == .endpoints { list } else { EventList() } }
                        .frame(maxHeight: .infinity, alignment: .top)
                    footer
                }
                .onChange(of: tab) { if tab == .events { receiver.unread = 0 } }
                .onChange(of: receiver.unread) { if tab == .events { receiver.unread = 0 } }
            }
        }
        // One fixed size for every view. macOS grows a menu bar window but never shrinks it,
        // so a size that follows the content leaves the popover floating in an oversized window.
        .frame(width: 360, height: 560)
        .background {
            // A solid material keeps text readable over anything; the tint wash carries the status.
            ZStack(alignment: .top) {
                Rectangle().fill(.thickMaterial)
                LinearGradient(colors: [mood.tint.opacity(0.28), mood.tint.opacity(0)], startPoint: .top, endPoint: .center)
            }
            .animation(.smooth, value: mood)
        }
    }

    private var hero: some View {
        let up = store.endpoints.count { if case .up = store.health[$0.id] { true } else { false } }
        let title = switch mood {
        case .offline: "Offline"
        case .alarm: "\(store.downCount) of \(store.endpoints.count) down"
        case .empty: "Welcome to Upbar"
        case .calm: store.lastCheck == nil ? "Checking…" : "All systems up"
        }
        return HStack(spacing: 14) {
            StatusRing(progress: store.endpoints.isEmpty ? 1 : Double(up) / Double(store.endpoints.count), mood: mood)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(.title3, design: .rounded, weight: .bold))
                Group {
                    if mood == .offline {
                        Text("Checks pause until you're back online")
                    } else if mood == .empty {
                        Text("Uptime checks in your menu bar")
                    } else if let last = store.lastCheck {
                        // Not Text(style: .relative): that re-lays out the popover every second, even while hidden (5% CPU idle).
                        TimelineView(.everyMinute) { _ in Text("\(up) up · checked \(last.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))") }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if mood != .empty { refresh }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var refresh: some View {
        Button { Task { await store.check() } } label: {
            Group {
                if store.checking { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)) }
            }
            .frame(width: 30, height: 30)
            .background(.regularMaterial, in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(store.checking)
        .keyboardShortcut("r")
        .help("Check now (⌘R)")
        .accessibilityLabel("Check now")
    }

    @ViewBuilder private var list: some View {
        if store.endpoints.isEmpty {
            ContentUnavailableView {
                Label("Nothing to Watch", systemImage: "waveform.path.ecg")
            } description: {
                Text("Paste a URL and Upbar checks it every minute.")
            } actions: {
                Button("Add Endpoint") { editing = Endpoint() }.buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.groups, id: \.site) { group in
                        let down = group.endpoints.count { store.health[$0.id]?.isDown == true }
                        VStack(spacing: 0) {
                            GroupHeader(site: group.site, total: group.endpoints.count, down: down,
                                        up: group.endpoints.count { if case .up = store.health[$0.id] { true } else { false } },
                                        collapsed: collapsed.contains(group.site)) {
                                withAnimation(.snappy) { collapsed.formSymmetricDifference([group.site]) }
                            }
                            if !collapsed.contains(group.site) {
                                ForEach(group.endpoints) { endpoint in
                                    Row(endpoint: endpoint, health: store.health[endpoint.id] ?? .unknown,
                                        history: store.history(endpoint.id), downSince: store.downSince[endpoint.id],
                                        certExpires: store.certExpiry[endpoint.id], show: { detail = endpoint.id }) { editing = endpoint }
                                        .padding(.leading, 24)  // indent under the website header
                                        .contextMenu {
                                            Button("Open in Browser") { if let url = URL(string: endpoint.url) { NSWorkspace.shared.open(url) } }
                                            Button("Edit…") { editing = endpoint }
                                            Button("Delete", role: .destructive) { store.delete(endpoint) }
                                        }
                                }
                            }
                        }
                        .padding(4)
                        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(down > 0 ? Color.red.opacity(0.35) : Color.primary.opacity(0.06)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
        }
    }

    private var cpuText: String {
        guard let cpu = store.cpu else { return "CPU: measuring…" }
        return String(format: "CPU: %.2f%% (last minute)", cpu * 100)
    }

    private var memoryText: String {
        guard let bytes = memoryFootprint() else { return "Memory: –" }
        return "Memory: " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private var footer: some View {
        @Bindable var store = store
        @Bindable var receiver = receiver
        return HStack {
            if tab == .endpoints, !store.endpoints.isEmpty {
                Button { editing = Endpoint() } label: {
                    Label("Add Endpoint", systemImage: "plus").font(.callout.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: .capsule)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n")
                .help("Add endpoint (⌘N)")
            } else if tab == .events, receiver.enabled {
                // The off switch sits where you see the receiver, not only in the ⋯ menu.
                Toggle("Receiving", isOn: $receiver.enabled).toggleStyle(.switch).controlSize(.mini).font(.callout)
                if !receiver.events.isEmpty {
                    Button("Clear", systemImage: "trash") { receiver.clear() }.buttonStyle(.borderless).padding(.leading, 8)
                }
            }
            Spacer()
            Menu {
                // Read when the footer redraws, about once a check. No timer.
                // Upbar's own use, not the Mac's.
                Section("Upbar uses") {
                    Text(cpuText)
                    Text(memoryText)
                }
                Divider()
                Toggle("Open at Login", isOn: $store.launchAtLogin).disabled(!isApp)
                Section("Events") {
                    Toggle("Receive Events", isOn: $receiver.enabled)
                    Button("Copy Test Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(receiver.curlExample(token: receiver.token), forType: .string)
                    }
                    .disabled(!receiver.enabled)
                    Button("New Token") { receiver.newToken() }.disabled(!receiver.enabled)
                }
                Divider()
                Button("Quit Upbar") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 26)
                    .background(.regularMaterial, in: .circle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// A ring that fills with the share of endpoints that are up, with the status glyph inside.
struct StatusRing: View {
    let progress: Double
    let mood: Mood
    private var arc: Color { mood == .alarm ? .green : mood.tint }

    var body: some View {
        ZStack {
            // The arc is the share that is up; in an outage the red track shows the rest.
            Circle().stroke(mood.tint.opacity(mood == .alarm ? 0.55 : 0.18), lineWidth: 5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(AngularGradient(colors: [arc.opacity(0.6), arc], center: .center),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: mood.symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(mood.tint)
        }
        .frame(width: 46, height: 46)
        .animation(.smooth, value: progress)
        .accessibilityHidden(true)
    }
}

/// Two pill tabs with a sliding selection, like an iOS segmented control.
struct TabBar: View {
    @Binding var tab: Popover.Tab
    let unread: Int
    @Namespace private var pill
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            item("Endpoints", .endpoints, badge: 0)
            item("Events", .events, badge: unread)
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: .capsule)
    }

    private func item(_ title: String, _ value: Popover.Tab, badge: Int) -> some View {
        Button { withAnimation(.snappy(duration: 0.25)) { tab = value } } label: {
            HStack(spacing: 5) {
                Text(title)
                if badge > 0 {
                    Text("\(badge)").font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 5).background(.red, in: .capsule)
                }
            }
            .font(.callout.weight(tab == value ? .semibold : .regular))
            .foregroundStyle(tab == value ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background {
                if tab == value {
                    Capsule().fill(scheme == .dark ? Color.white.opacity(0.16) : .white).shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }
}

/// A colored letter tile for a website. ponytail: no favicons, they would call the site or a third party.
struct Monogram: View {
    let site: String

    var body: some View {
        // A stable hue per name; String.hashValue changes every launch.
        let hue = Double(site.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        RoundedRectangle(cornerRadius: 6)
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.95),
                                          Color(hue: hue, saturation: 0.75, brightness: 0.7)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Text(site.prefix(1).uppercased()).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white))
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}

/// A website header: click to fold or unfold its endpoints.
struct GroupHeader: View {
    let site: String
    let total: Int
    let down: Int
    let up: Int
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Monogram(site: site)
                Text(site).font(.callout.weight(.semibold))
                Spacer()
                // Green only when every endpoint is up; one still checking keeps it grey.
                let tint = down > 0 ? Color.red : up == total ? .green : .secondary
                Text(down > 0 ? "\(down) down" : "\(up)/\(total) up")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.14), in: .capsule)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(site), \(down > 0 ? "\(down) down" : "all up"), \(collapsed ? "collapsed" : "expanded")")
    }
}

struct Row: View {
    let endpoint: Endpoint
    let health: Health
    let history: [Int?]
    let downSince: Date?
    let certExpires: Date?
    let show: () -> Void
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        // Two sibling buttons, never nested, so the pencil can't also open the details.
        HStack(spacing: 4) {
            Button(action: show) {
                HStack(spacing: 10) {
                    Circle().fill(color).frame(width: 8, height: 8)
                        .shadow(color: color.opacity(health.isDown ? 0.9 : 0.5), radius: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(endpoint.name).lineLimit(1)
                        detail.font(.caption).foregroundStyle(health.isDown ? .red : certDays != nil ? .orange : .secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Sparkline(history: history)
                        if case .up(let code, let ms) = health {
                            Text((code == 200 ? "" : "\(code) · ") + (ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(ms > 1000 ? .orange : .secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show details")

            // Always in the layout, shown on hover, so nothing shifts when the pointer moves.
            Button("Edit \(endpoint.name)", systemImage: "pencil.circle.fill", action: edit)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title3)
                .foregroundStyle(.secondary)
                .help("Edit")
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 8))
        .onHover { hovering = $0 }
    }

    /// Days left on the certificate, only when it is close to expiry.
    private var certDays: Int? {
        guard let certExpires else { return nil }
        let days = Int(certExpires.timeIntervalSinceNow / 86400)
        return days < certWarningDays ? days : nil
    }

    private var detail: Text {
        guard case .down(let reason) = health else { 
            if let certDays { return Text(certDays < 0 ? "Certificate expired" : "Certificate expires in \(certDays) days") }
            return Text(endpoint.url.replacing(/^https?:\/\//, with: ""))
        }
        guard let downSince else { return Text(reason) }
        let minutes = Int(-downSince.timeIntervalSinceNow / 60)
        return Text("\(reason) · " + (minutes < 1 ? "just now" : minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"))
    }

    private var color: Color {
        switch health {
        case .unknown: .secondary.opacity(0.5)
        case .up: .green
        case .down: .red
        }
    }
}

/// Response times of the last 30 checks, newest on the right. Failed checks are full-height red bars.
struct Sparkline: View {
    let history: [Int?]

    var body: some View {
        // Scale to 2x the median: a steady endpoint shows half-height bars, spikes stand out, outliers clip.
        let times = history.compactMap { $0 }.sorted()
        let peak = CGFloat(max(2 * (times.isEmpty ? 1 : times[times.count / 2]), 1))
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(history.enumerated()), id: \.offset) { _, ms in
                Capsule()
                    .fill(ms == nil ? Color.red : ms! > 1000 ? .orange : .green.opacity(0.55))
                    .frame(width: 2, height: ms.map { min(14, max(2, 14 * CGFloat($0) / peak)) } ?? 14)
            }
        }
        .frame(width: 90, height: 14, alignment: .bottomTrailing)
    }
}

struct Editor: View {
    enum Action { case save(Endpoint), delete, cancel }

    @State var endpoint: Endpoint
    let isNew: Bool
    let done: (Action) -> Void
    @FocusState private var urlFocused: Bool
    @State private var confirmDelete = false
    @State private var testResult: Health?
    @State private var testing = false

    private var url: URL? {
        URL(string: normalizeURL(endpoint.url)).flatMap { ["http", "https"].contains($0.scheme) && $0.host() != nil ? $0 : nil }
    }
    private var valid: Bool { url != nil && (100...599).contains(endpoint.expected) }
    /// Live String binding: a formatted number field only commits on Return, so clicking Save would drop the edit.
    private var expected: Binding<String> {
        Binding { endpoint.expected == 0 ? "" : String(endpoint.expected) } set: { endpoint.expected = Int($0.filter(\.isNumber).prefix(3)) ?? 0 }
    }
    private var saved: Endpoint {
        var saved = endpoint
        saved.url = normalizeURL(saved.url)
        if saved.name.trimmingCharacters(in: .whitespaces).isEmpty { saved.name = url?.host() ?? saved.url }
        return saved
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { done(.cancel) }.keyboardShortcut(.cancelAction)
                Spacer()
                Text(isNew ? "Add Endpoint" : "Edit Endpoint").font(.headline)
                Spacer()
                Button("Save") { done(.save(saved)) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!valid)
            }
            .padding(12)
            Divider()
            Form {
                Section {
                    TextField("URL", text: $endpoint.url, prompt: Text(verbatim: "https://api.example.com/health"))
                        .focused($urlFocused)
                    TextField("Name", text: $endpoint.name, prompt: Text(url?.host() ?? "Optional"))
                } footer: {
                    if url == nil, !["", "https://"].contains(endpoint.url) {
                        Text(verbatim: "Enter a full URL, like https://example.com/health").foregroundStyle(.red)
                    }
                }
                Section {
                    TextField("Expected status", text: expected, prompt: Text("200"))
                    LabeledContent("Test") {
                        HStack(spacing: 8) {
                            testLabel
                            Button("Test now") { Task { await test() } }.disabled(url == nil || testing)
                        }
                    }
                } footer: {
                    Text(!(100...599).contains(endpoint.expected) ? "Expect an HTTP status code between 100 and 599."
                         : "Down after \(failureThreshold) failed checks in a row. Redirects aren't followed.")
                        .foregroundStyle(!(100...599).contains(endpoint.expected) ? .red : .secondary)
                }
                if !isNew {
                    Section {
                        // Two clicks: the first arms it, so a stray click can't delete.
                        Button(confirmDelete ? "Click Again to Delete" : "Delete Endpoint", role: .destructive) {
                            if confirmDelete { done(.delete) } else { confirmDelete = true }
                        }
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { urlFocused = true }
        .onChange(of: endpoint.url) { testResult = nil }
        .onChange(of: endpoint.expected) { testResult = nil }
    }

    @ViewBuilder private var testLabel: some View {
        if testing {
            ProgressView().controlSize(.small)
        } else if case .up(let code, let ms) = testResult {
            Label("\(code) · \(ms) ms", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if case .down(let reason) = testResult {
            Label(reason, systemImage: "xmark.circle.fill").foregroundStyle(.red).lineLimit(1)
        }
    }

    private func test() async {
        testing = true
        testResult = await probe(saved).0
        testing = false
    }
}

/// Everything Upbar knows about one endpoint: its state now, 24 hours of latency and uptime, outages and the last request.
struct Detail: View {
    let endpoint: Endpoint
    let health: Health
    let downSince: Date?
    let samples: [Sample]
    let trace: Trace?
    let certExpires: Date?
    let back: () -> Void
    let edit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button("Back", systemImage: "chevron.left", action: back).keyboardShortcut(.cancelAction)
                Spacer()
                Text(endpoint.name).font(.headline).lineLimit(1)
                Spacer()
                Button("Open in Browser", systemImage: "safari") { if let url = URL(string: endpoint.url) { NSWorkspace.shared.open(url) } }
                    .labelStyle(.iconOnly).help("Open in browser")
                Button("Edit", systemImage: "pencil", action: edit).labelStyle(.iconOnly).help("Edit")
            }
            .buttonStyle(.borderless)
            .padding(12)
            Divider()
            Form {
                Section("Now") {
                    LabeledContent("Status") { status }
                    LabeledContent("URL") { Text(verbatim: endpoint.url).textSelection(.enabled).lineLimit(2) }
                    LabeledContent("Expects", value: "HTTP \(endpoint.expected)")
                }
                if let stats = summarize(samples) { last24(stats) }
                if let trace { lastRequest(trace) }
            }
            .formStyle(.grouped)
        }
    }

    private var status: some View {
        switch health {
        case .unknown: Text("Checking…").foregroundStyle(.secondary)
        case .up(let code, let ms): Text("Up · \(code) · \(ms) ms").foregroundStyle(.green)
        case .down(let reason):
            Text(reason + (downSince.map { " · since " + $0.formatted(date: .omitted, time: .shortened) } ?? "")).foregroundStyle(.red)
        }
    }

    @ViewBuilder private func last24(_ stats: Stats) -> some View {
        let ms = { (value: Int?) in value.map { "\($0) ms" } ?? "–" }
        Section {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Tile(label: "Uptime", value: String(format: "%.2f%%", stats.uptime * 100), tint: stats.uptime < 0.99 ? .orange : .green)
                    Tile(label: "Checks", value: "\(stats.checks)")
                    Tile(label: "Failed", value: "\(stats.failed)", tint: stats.failed > 0 ? .red : .primary)
                    Tile(label: "Mean", value: ms(stats.mean))
                }
                GridRow {
                    Tile(label: "p50", value: ms(stats.p50))
                    Tile(label: "p90", value: ms(stats.p90))
                    Tile(label: "p95", value: ms(stats.p95))
                    Tile(label: "p99", value: ms(stats.p99), tint: (stats.p99 ?? 0) > 1000 ? .orange : .primary)
                }
            }
            ResponseChart(buckets: buckets(samples))
            LabeledContent("Fastest · slowest", value: "\(ms(stats.min)) · \(ms(stats.max))").monospacedDigit()
            let outages = incidents(samples)
            LabeledContent("Incidents") {
                Text(incidentSummary(outages)).monospacedDigit().foregroundStyle(outages.isEmpty ? Color.secondary : .orange)
            }
            ForEach(outages.suffix(5).reversed(), id: \.start) { incident in
                let start = Date(timeIntervalSince1970: TimeInterval(incident.start))
                LabeledContent(start.formatted(date: .omitted, time: .shortened)) {
                    Text(incident.end.map { duration(Int($0 - incident.start)) } ?? "ongoing")
                        .foregroundStyle(incident.end == nil ? .red : .secondary).monospacedDigit()
                }
                .font(.callout)
            }
        } header: {
            Text("Last 24 hours")
        } footer: {
            Text("Percentiles use successful checks only. Red marks on the chart show failed checks.")
        }
    }

    private func lastRequest(_ trace: Trace) -> some View {
        Section("Last request") {
            if trace.reused {
                LabeledContent("Server", value: "\(trace.server) ms").monospacedDigit()
            } else {
                Waterfall(trace: trace)
            }
            LabeledContent("Connection") {
                Text([trace.proto, trace.tlsVersion, trace.address, trace.reused ? "reused" : nil].compactMap { $0 }.joined(separator: " · "))
                    .textSelection(.enabled)
            }
            if let expires = trace.certExpires ?? certExpires {
                let days = Int(expires.timeIntervalSinceNow / 86400)
                LabeledContent("Certificate") {
                    Text("\(expires.formatted(date: .abbreviated, time: .omitted)) · \(days) days")
                        .foregroundStyle(days < 0 ? .red : days < certWarningDays ? .orange : .secondary)
                }
            }
        }
    }
}

struct Bucket: Equatable {
    var start: Date
    var ms: Int?  // median of the successful checks
    var failures: Int
}

/// Folds samples into 15-minute buckets, so the chart draws at most 96 points for 24 hours.
func buckets(_ samples: [Sample], minutes: UInt32 = 15) -> [Bucket] {
    let width = minutes * 60
    return Dictionary(grouping: samples) { $0.t / width }.map { key, group in
        let times = group.filter { $0.ms >= 0 }.map { Int($0.ms) }.sorted()
        return Bucket(start: Date(timeIntervalSince1970: TimeInterval(key * width)),
                      ms: times.isEmpty ? nil : times[times.count / 2], failures: group.count - times.count)
    }
    .sorted { $0.start < $1.start }
}

struct Tile: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
    }
}

struct ResponseChart: View {
    let buckets: [Bucket]

    var body: some View {
        Chart {
            ForEach(buckets, id: \.start) { bucket in
                if let ms = bucket.ms {
                    AreaMark(x: .value("Time", bucket.start), y: .value("ms", ms))
                        .foregroundStyle(LinearGradient(colors: [.green.opacity(0.35), .green.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", bucket.start), y: .value("ms", ms))
                        .foregroundStyle(.green)
                        .interpolationMethod(.monotone)
                }
                if bucket.failures > 0 {
                    RuleMark(x: .value("Time", bucket.start)).foregroundStyle(.red.opacity(0.6))
                }
            }
        }
        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
        .frame(height: 90)
        .accessibilityLabel("Response times over the last 24 hours")
    }
}

/// "None", or the count, the mean time to recovery and when the last one started.
func incidentSummary(_ outages: [Incident]) -> String {
    guard let last = outages.last else { return "None" }
    let resolved = outages.compactMap { incident in incident.end.map { Int($0 - incident.start) } }
    let mttr = resolved.isEmpty ? nil : resolved.reduce(0, +) / resolved.count
    let ago = Date(timeIntervalSince1970: TimeInterval(last.start)).formatted(.relative(presentation: .named))
    return "\(outages.count) · " + (last.end == nil ? "ongoing" : "MTTR \(duration(mttr ?? 0))") + " · \(ago)"
}

/// 45s, 4m, 1h 5m.
func duration(_ seconds: Int) -> String {
    seconds < 60 ? "\(seconds)s" : seconds < 3600 ? "\(seconds / 60)m" : "\(seconds / 3600)h \(seconds % 3600 / 60)m"
}

/// DNS, connect, TLS and server time of one request as stacked bars, like a browser's network waterfall.
struct Waterfall: View {
    let trace: Trace

    var body: some View {
        let phases = [("DNS", trace.dns, Color.teal), ("Connect", trace.connect, .blue),
                      ("TLS", trace.tls, .purple), ("Server", trace.server, .green)]
        let total = max(phases.map(\.1).reduce(0, +), 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(phases, id: \.0) { name, ms, color in
                        Rectangle().fill(color.gradient).frame(width: geometry.size.width * CGFloat(ms) / CGFloat(total))
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 8)
            HStack(spacing: 10) {
                ForEach(phases, id: \.0) { name, ms, color in
                    HStack(spacing: 4) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text("\(name) \(ms)")
                    }
                }
                Spacer(minLength: 0)
                Text("\(total) ms").fontWeight(.semibold)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
