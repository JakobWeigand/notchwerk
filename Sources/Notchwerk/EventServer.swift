import Foundation
import Network
import Security

/// Kleiner HTTP-Server, der ausschließlich auf 127.0.0.1 lauscht.
/// Jede Anfrage muss den geheimen Token aus ~/.claude-notch/ mitschicken.
final class EventServer {
    typealias Reply = (Data?) -> Void
    /// Wird auf dem Main-Thread aufgerufen. `reply` darf später (z.B. nach einem Klick) aufgerufen werden.
    /// `onClose` meldet, dass der Hook die Verbindung beendet hat.
    var onEvent: ((_ json: [String: Any], _ reply: @escaping Reply, _ onClose: @escaping (@escaping () -> Void) -> Void) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "claude-notch.server")
    private let token: String
    private let maxBody = 16 * 1024 * 1024

    init(token: String) {
        self.token = token
    }

    func start(onReady: @escaping (UInt16) -> Void) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state, let port = listener?.port?.rawValue {
                DispatchQueue.main.async { onReady(port) }
            }
            if case .failed(let error) = state {
                NSLog("Notchwerk: Server-Fehler \(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Verbindungen

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > self.maxBody {
                self.respond(conn, status: "413 Payload Too Large", body: nil)
                return
            }
            if let request = HTTPRequest.parse(buffer) {
                self.handle(request, conn: conn)
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buffer)
        }
    }

    private func handle(_ request: HTTPRequest, conn: NWConnection) {
        guard request.method == "POST", request.path == "/event" else {
            respond(conn, status: "404 Not Found", body: nil)
            return
        }
        guard let given = request.headers["x-claude-notch-token"], constantTimeEqual(given, token) else {
            respond(conn, status: "401 Unauthorized", body: nil)
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            respond(conn, status: "400 Bad Request", body: nil)
            return
        }
        // hook.sh schickt die Prozesskette (Base64) mit, damit die App die Herkunft der Sitzung kennt.
        var event = obj
        if let encoded = request.headers["x-claude-notch-origin"], !encoded.isEmpty,
           let data = Data(base64Encoded: encoded), let text = String(data: data, encoding: .utf8) {
            event["_notch_origin"] = text
        }

        let once = OnceFlag()
        let reply: Reply = { [weak self] data in
            guard once.set() else { return }
            self?.queue.async { self?.respond(conn, status: "200 OK", body: data) }
        }
        // Erkennen, wenn der Hook vorzeitig abbricht (z.B. Esc in Claude Code).
        let onClose: (@escaping () -> Void) -> Void = { [weak self] handler in
            self?.watchClose(conn, once: once, handler: handler)
        }
        DispatchQueue.main.async { [weak self] in
            if let cb = self?.onEvent {
                cb(event, reply, onClose)
            } else {
                reply(nil)
            }
        }
    }

    private func watchClose(_ conn: NWConnection, once: OnceFlag, handler: @escaping () -> Void) {
        queue.async {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
                if (isComplete || error != nil), once.set() {
                    conn.cancel()
                    DispatchQueue.main.async(execute: handler)
                }
            }
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: Data?) {
        let body = body ?? Data()
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// Sorgt dafür, dass eine Antwort genau einmal gesendet wird.
final class OnceFlag {
    private var done = false
    private let lock = NSLock()

    /// Gibt beim ersten Aufruf true zurück, danach immer false.
    func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Liefert nil solange die Anfrage noch nicht vollständig ist.
    static func parse(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }
        guard let headText = String(data: data[data.startIndex..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = headText.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = range.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
    }
}

enum Secrets {
    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
