import Network
import Security
import SwiftUI
import SystemConfiguration
import UserNotifications

// Events: Upbar listens on a port of this Mac. Anything that can send an HTTP POST on your network
// (a deploy hook, a CI step, a cron job, curl) sends events straight to it. No other server is involved.

struct Event: Identifiable, Equatable {
    var id = UUID()
    var time = Date.now
    var title: String?
    var message: String?
    var tags: [String] = []
    var priority: Int?
    var click: String?

    enum Severity { case failure, success, info }

    /// The sender sets the severity with tags or a priority. README section "Events" lists them.
    var severity: Severity {
        let tags = Set(tags.map { $0.lowercased() })
        if !tags.isDisjoint(with: ["x", "rotating_light", "warning", "failure", "failed", "error", "red_circle"]) || (priority ?? 3) >= 4 { return .failure }
        if !tags.isDisjoint(with: ["white_check_mark", "heavy_check_mark", "tada", "success", "ok", "green_circle"]) { return .success }
        return .info
    }
}

struct Request: Equatable {
    var method: String
    var target: String
    var headers: [String: String]  // lowercased names
    var body: Data
}

/// Largest request Upbar accepts. Events are short; this caps memory per connection.
let maxRequestSize = 64 * 1024

/// Parses one HTTP/1.1 request. Returns nil while the request is incomplete.
func parseRequest(_ data: Data) -> Request? {
    guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)),
          let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
    let lines = head.components(separatedBy: "\r\n")
    let start = lines[0].split(separator: " ")
    guard start.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let length = Int(headers["content-length"] ?? "0") ?? 0
    let body = data[end.upperBound...]
    guard body.count >= length else { return nil }
    return Request(method: String(start[0]), target: String(start[1]), headers: headers, body: Data(body.prefix(length)))
}

/// Builds an event from headers (ntfy style: Title, Tags, Priority, Click) and a plain-text or JSON body.
func makeEvent(_ request: Request) -> Event {
    var event = Event(title: request.headers["title"] ?? request.headers["x-title"],
                      tags: (request.headers["tags"] ?? request.headers["x-tags"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                      priority: (request.headers["priority"] ?? request.headers["x-priority"]).flatMap { Int($0) },
                      click: request.headers["click"] ?? request.headers["x-click"])
    if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
        event.title = event.title ?? json["title"] as? String
        event.message = (json["message"] ?? json["text"] ?? json["body"] ?? json["description"]) as? String
        event.tags += (json["tags"] as? [String]) ?? []
        event.priority = event.priority ?? json["priority"] as? Int
        event.click = event.click ?? (json["click"] ?? json["url"]) as? String
        if event.title == nil && event.message == nil { event.message = String(data: request.body, encoding: .utf8) }
    } else {
        event.message = String(data: request.body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return event
}

/// The receiver token lives in the Keychain, never in the preferences file.
enum Keychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "Upbar", kSecAttrAccount as String: "receiver-token"] }

    static var token: String? {
        var item: CFTypeRef?
        var q = query
        (q[kSecReturnData as String], q[kSecMatchLimit as String]) = (true, kSecMatchLimitOne)
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func newToken() -> String {
        let token = (0..<4).map { _ in String(UInt64.random(in: .min ... .max), radix: 36) }.joined()
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(q as CFDictionary, nil)
        return token
    }
}

@MainActor @Observable
final class Receiver {
    private(set) var events: [Event] = []  // newest first, at most 100
    private(set) var listening = false
    private(set) var error: String?
    private(set) var token = Keychain.token ?? ""
    var unread = 0
    let port: UInt16 = 4747
    private var listener: NWListener?

    var enabled = UserDefaults.standard.bool(forKey: "receiverOn") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "receiverOn")
            enabled ? start() : stop()
        }
    }

    /// The Bonjour name of this Mac, for example `josephs-macbook.local`.
    var url: String { "http://\((SCDynamicStoreCopyLocalHostName(nil) as String?)?.lowercased() ?? "localhost").local:\(port)" }
    /// The command to copy. On screen Upbar shows `$UPBAR_TOKEN` instead, so the token never shows in a screen share.
    func curlExample(token: String) -> String {
        "curl -H \"Authorization: Bearer \(token)\" -H \"Title: Deploy finished\" -H \"Tags: white_check_mark\" -d \"API is live\" \(url)"
    }

    init() { if enabled { start() } }

    func newToken() { token = Keychain.newToken() }
    func clear() { (events, unread) = ([], 0) }

    private func start() {
        if token.isEmpty { newToken() }
        guard listener == nil, let listener = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) else { return }
        // Callbacks run on a background queue; @Sendable keeps them off the main actor, and each hops back explicitly.
        listener.stateUpdateHandler = { @Sendable [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: (self.listening, self.error) = (true, nil)
                case .failed(let failure): (self.listening, self.error) = (false, "Port \(self.port): \(failure.localizedDescription)")
                case .cancelled: self.listening = false
                default: break
                }
            }
        }
        listener.newConnectionHandler = { @Sendable [weak self] connection in
            let receiver = self  // a let, so the @Sendable request handler can capture it
            connection.start(queue: .global(qos: .utility))
            Receiver.read(connection, Data()) { request in
                await receiver?.handle(request) ?? (503, "Service Unavailable")
            }
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        listening = false
    }

    /// Reads until one complete request or the size limit, answers, then closes the connection.
    nonisolated private static func read(_ connection: NWConnection, _ buffer: Data,
                                         _ handle: @escaping @Sendable (Request) async -> (Int, String)) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { @Sendable data, _, complete, error in
            let buffer = buffer + (data ?? Data())
            if buffer.count > maxRequestSize { return respond(connection, 413, "Payload Too Large") }
            if let request = parseRequest(buffer) {
                Task { let (code, reason) = await handle(request); respond(connection, code, reason) }
            } else if complete || error != nil {
                respond(connection, 400, "Bad Request")
            } else {
                read(connection, buffer, handle)
            }
        }
    }

    nonisolated private static func respond(_ connection: NWConnection, _ code: Int, _ reason: String) {
        let response = "HTTP/1.1 \(code) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { @Sendable _ in connection.cancel() })
    }

    private func handle(_ request: Request) -> (Int, String) {
        guard ["POST", "PUT"].contains(request.method) else { return (405, "Method Not Allowed") }
        let query = URLComponents(string: request.target)?.queryItems?.first { $0.name == "token" }?.value
        let bearer = request.headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "")
        guard !token.isEmpty, [query, bearer].contains(token) else { return (401, "Unauthorized") }
        let event = makeEvent(request)
        events = Array(([event] + events).prefix(100))
        unread += 1
        announce(event)
        return (200, "OK")
    }

    private func announce(_ event: Event) {
        guard isApp else { return print("[event] \(event.title ?? "") \(event.message ?? "")") }
        let content = UNMutableNotificationContent()
        content.title = event.title ?? "Event"
        content.body = event.message ?? ""
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
    }
}

// MARK: - UI

struct EventList: View {
    @Environment(Receiver.self) private var receiver

    var body: some View {
        if !receiver.enabled {
            ContentUnavailableView {
                Label("Deploy Alerts", systemImage: "bell.badge")
            } description: {
                Text("Get notified when a deploy, CI job or script finishes. Events go straight to this Mac.")
            } actions: {
                Button("Turn On Events") { receiver.enabled = true }.buttonStyle(.borderedProminent)
            }
        } else if receiver.events.isEmpty, let error = receiver.error {
            ContentUnavailableView("Can't Receive Events", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if receiver.events.isEmpty {
            ContentUnavailableView {
                Label("Waiting for Events", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text(verbatim: receiver.url).textSelection(.enabled)
            } actions: { VStack(spacing: 8) {
                // On screen the token stays a variable; the copy has the real one.
                Text(verbatim: receiver.curlExample(token: "$UPBAR_TOKEN"))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                Button("Copy Test Command", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(receiver.curlExample(token: receiver.token), forType: .string)
                }
            } }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(receiver.events) { EventRow(event: $0) }
                }
                .padding(6)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EventRow: View {
    let event: Event
    @State private var hovering = false

    var body: some View {
        Button { if let click = event.click, let url = URL(string: click) { NSWorkspace.shared.open(url) } } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title ?? event.message ?? "Event").lineLimit(1)
                    if event.title != nil, let message = event.message, !message.isEmpty {
                        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Text(event.time, style: .relative).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering && event.click != nil ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var symbol: String {
        switch event.severity {
        case .failure: "xmark.circle.fill"
        case .success: "checkmark.circle.fill"
        case .info: "bell.circle.fill"
        }
    }

    private var color: Color {
        switch event.severity {
        case .failure: .red
        case .success: .green
        case .info: .blue
        }
    }
}
