import Network
import ServiceManagement
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

func probe(_ endpoint: Endpoint) async -> Health {
    guard let url = URL(string: endpoint.url), url.host() != nil else { return .down("Invalid URL") }
    var start = ContinuousClock.now
    do {
        // HEAD first: same status, no body. Some servers answer HEAD differently (405, or even 400), so any
        // unexpected status is confirmed with a GET that stops after the headers. A down verdict is always a real GET.
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        var code = try await (session.data(for: request).1 as? HTTPURLResponse)?.statusCode ?? 0
        if code != endpoint.expected {
            start = .now
            let (body, response) = try await session.bytes(from: url)
            body.task.cancel()
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
        return code == endpoint.expected ? .up(code: code, ms: ms) : .down("HTTP \(code)")
    } catch {
        return .down(error.localizedDescription)
    }
}

/// Trims whitespace and adds https:// when the scheme is missing, so pasted URLs just work.
func normalizeURL(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed.contains("://") ? trimmed : "https://" + trimmed
}

/// `swift run` has no app bundle, and notifications and login items need one.
let isApp = Bundle.main.bundleURL.pathExtension == "app"

@MainActor @Observable
final class Store {
    var endpoints: [Endpoint] { didSet { UserDefaults.standard.set(try? JSONEncoder().encode(endpoints), forKey: "endpoints") } }
    private(set) var health: [UUID: Health] = [:]
    private(set) var lastCheck: Date?
    /// Last 30 raw response times, nil = failed check. Drives the sparkline.
    private(set) var history: [UUID: [Int?]] = [:]
    private(set) var downSince: [UUID: Date] = [:]
    /// One entry per check round, newest last. Drives the menu bar icon.
    private(set) var rounds: [Round] = []
    private var streak: [UUID: Int] = [:]
    private(set) var checking = false
    /// Offline, every check would fail and alert. Checks pause instead and resume on reconnect.
    private(set) var online = true
    private let path = NWPathMonitor()

    init() {
        let saved = UserDefaults.standard.data(forKey: "endpoints")
        endpoints = saved.flatMap { try? JSONDecoder().decode([Endpoint].self, from: $0) } ?? []
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

    func check() async {
        guard !checking, online else { return }
        checking = true
        defer { checking = false }
        let snapshot = endpoints
        // ponytail: all probes at once; fine for tens of endpoints, cap concurrency if someone watches hundreds.
        let results = await withTaskGroup(of: (UUID, Health).self) { group in
            for endpoint in snapshot { group.addTask { (endpoint.id, await probe(endpoint)) } }
            var out: [UUID: Health] = [:]
            for await (id, result) in group { out[id] = result }
            return out
        }
        for endpoint in snapshot {
            guard let result = results[endpoint.id], endpoints.contains(endpoint) else { continue }
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
    }

    func save(_ endpoint: Endpoint) {
        let old = endpoints.first { $0.id == endpoint.id }
        if let i = endpoints.firstIndex(where: { $0.id == endpoint.id }) { endpoints[i] = endpoint } else { endpoints.append(endpoint) }
        guard old?.url != endpoint.url || old?.expected != endpoint.expected else { return }  // a rename keeps its history
        forget(endpoint.id)
        Task {  // show it right away, without waiting for the next round
            let result = await probe(endpoint)
            guard endpoints.contains(endpoint) else { return }
            health[endpoint.id] = result
            record(endpoint.id, result)
        }
    }

    func delete(_ endpoint: Endpoint) {
        endpoints.removeAll { $0.id == endpoint.id }
        forget(endpoint.id)
    }

    private func record(_ id: UUID, _ result: Health) {
        let ms: Int? = if case .up(_, let ms) = result { ms } else { nil }
        history[id, default: []] = (history[id, default: []] + [ms]).suffix(30)
    }

    private func forget(_ id: UUID) {
        (health[id], streak[id], history[id], downSince[id]) = (nil, nil, nil, nil)
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

    var body: some Scene {
        MenuBarExtra {
            Popover().environment(store)
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

struct Popover: View {
    @Environment(Store.self) private var store
    @State private var editing: Endpoint?

    var body: some View {
        Group {
            if let endpoint = editing {
                let isNew = !store.endpoints.contains { $0.id == endpoint.id }
                Editor(endpoint: endpoint, isNew: isNew) { action in
                    switch action {
                    case .save(let saved): store.save(saved)
                    case .delete: store.delete(endpoint)
                    case .cancel: break
                    }
                    editing = nil
                }
                .id(endpoint.id)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    list
                    Divider()
                    footer
                }
            }
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)  // the window fits its content, list or editor
        .background(.thickMaterial)  // readable over any wallpaper or window behind the glass
    }

    private var header: some View {
        let down = store.downCount > 0
        let title = !store.online ? "Offline" : down ? "\(store.downCount) of \(store.endpoints.count) down"
            : store.endpoints.isEmpty ? "Upbar" : store.lastCheck == nil ? "Checking…" : "All systems operational"
        return HStack(spacing: 10) {
            Image(systemName: !store.online ? "wifi.slash" : down ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(!store.online ? Color.secondary : down ? .red : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if !store.online {
                    Text("Checks paused until you're back online").font(.caption).foregroundStyle(.secondary)
                } else if let last = store.lastCheck {
                    Text("Checked \(last, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.checking {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
            } else {
                Button("Check now", systemImage: "arrow.clockwise") { Task { await store.check() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .keyboardShortcut("r")
                    .help("Check now (⌘R)")
            }
        }
        .padding(12)
    }

    @ViewBuilder private var list: some View {
        if store.endpoints.isEmpty {
            Text("Nothing to watch yet.\nPaste a URL and Upbar checks it every minute.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(24)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.sorted) { endpoint in
                        Row(endpoint: endpoint, health: store.health[endpoint.id] ?? .unknown,
                            history: store.history[endpoint.id] ?? [], downSince: store.downSince[endpoint.id]) { editing = endpoint }
                            .contextMenu {
                                Button("Edit…") { editing = endpoint }
                                Button("Delete", role: .destructive) { store.delete(endpoint) }
                            }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        @Bindable var store = store
        return HStack {
            Button("Add", systemImage: "plus") { editing = Endpoint() }
                .keyboardShortcut("n")
                .help("Add endpoint (⌘N)")
            Spacer()
            Menu {
                Toggle("Open at Login", isOn: $store.launchAtLogin).disabled(!isApp)
                Divider()
                Button("Quit Upbar") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct Row: View {
    let endpoint: Endpoint
    let health: Health
    let history: [Int?]
    let downSince: Date?
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        // Two sibling buttons, never nested, so the pencil can't also open the URL.
        HStack(spacing: 4) {
            Button { if let url = URL(string: endpoint.url) { NSWorkspace.shared.open(url) } } label: {
                HStack(spacing: 10) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(endpoint.name).lineLimit(1)
                        detail.font(.caption).foregroundStyle(health.isDown ? .red : .secondary).lineLimit(1)
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
            .help("Open \(endpoint.url)")

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
        .background(hovering ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 6))
        .onHover { hovering = $0 }
    }

    private var detail: Text {
        guard case .down(let reason) = health else { return Text(endpoint.url.replacing(/^https?:\/\//, with: "")) }
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
                    .fill(ms == nil ? Color.red : ms! > 1000 ? .orange : .secondary.opacity(0.5))
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
            .scrollDisabled(true)
        }
        .onAppear { urlFocused = true }
        .task { if !isNew { await test() } }  // show the current state of an existing endpoint right away
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
        testResult = await probe(saved)
        testing = false
    }
}
