import Foundation
import Network

/// Loopback-only HTTP + WebSocket server that streams mirror frames and accepts control input.
public final class RelayServer {
    public struct Options {
        public var port: UInt16 = 8765
        public var host: String = "127.0.0.1"
        /// nil disables token checking.
        public var token: String?
        public var viewOnly = false
        /// Lets viewers end the session (the viewer's Stop button). The launcher enables it.
        public var allowShutdown = false
        /// Called when a viewer asks to stop; defaults to exiting the process.
        public var onShutdown: () -> Void = { exit(0) }
        public init() {}
    }

    let options: Options
    let backend: RelayBackend
    let log: (String) -> Void

    private let queue = DispatchQueue(label: "ios-remote-screen.server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: WSClient] = [:]

    public init(options: Options, backend: RelayBackend, log: @escaping (String) -> Void) {
        self.options = options
        self.backend = backend
        self.log = log
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: options.port) else { throw NWError.posix(.EINVAL) }
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(options.host), port: port)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.log("Listening on http://\(self?.options.host ?? ""):\(self?.options.port ?? 0)")
            case let .failed(error):
                self?.log("Listener failed: \(error)")
                exit(1)
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Fans a frame out to every viewer that is not still sending the previous one (drops, never queues).
    public func broadcast(_ frame: RelayFrame) {
        queue.async {
            let header = Self.frameHeader(frame)
            for client in self.clients.values { client.offer(header: header, jpeg: frame.jpeg) }
        }
    }

    static func frameHeader(_ frame: RelayFrame) -> String {
        "{\"t\":\"frame\",\"w\":\(Int(frame.pixelSize.width)),\"h\":\(Int(frame.pixelSize.height))}"
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHead(conn, buffer: [])
    }

    private func readHead(_ conn: NWConnection, buffer: [UInt8]) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(contentsOf: data) }
            if let headLen = HTTPRequest.headLength(in: buffer) {
                let rest = Array(buffer[headLen...])
                guard let req = HTTPRequest.parse(Array(buffer[..<headLen])) else {
                    return self.respond(conn, HTTPResponse.text(400, "Bad Request", "bad request"))
                }
                self.route(conn, req, leftover: rest)
            } else if buffer.count > 32 * 1024 {
                self.respond(conn, HTTPResponse.text(431, "Request Header Fields Too Large", "headers too large"))
            } else if error != nil || done {
                conn.cancel()
            } else {
                self.readHead(conn, buffer: buffer)
            }
        }
    }

    private func authorized(_ req: HTTPRequest) -> Bool {
        guard let token = options.token else { return true }
        let given = Array((req.query["token"] ?? "").utf8), expected = Array(token.utf8)
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func route(_ conn: NWConnection, _ req: HTTPRequest, leftover: [UInt8]) {
        guard req.method == "GET" else { return respond(conn, HTTPResponse.text(405, "Method Not Allowed", "GET only")) }
        if req.path == "/healthz" { return respond(conn, HTTPResponse.text(200, "OK", "ok")) }
        guard authorized(req) else { return respond(conn, HTTPResponse.text(401, "Unauthorized", "missing or wrong ?token=")) }
        switch req.path {
        case "/":
            respond(conn, HTTPResponse.make(status: 200, reason: "OK", contentType: "text/html; charset=utf-8", body: Data(WebAssets.indexHTML.utf8)))
        case "/status":
            respond(conn, HTTPResponse.make(status: 200, reason: "OK", contentType: "application/json", body: statusJSON()))
        case "/snapshot.jpg":
            if let frame = backend.latestFrame {
                respond(conn, HTTPResponse.make(status: 200, reason: "OK", contentType: "image/jpeg", body: frame.jpeg))
            } else {
                respond(conn, HTTPResponse.text(503, "Service Unavailable", "no frame yet: is the device screen source running?"))
            }
        case "/ws":
            guard req.isWebSocketUpgrade, let key = req.headers["sec-websocket-key"] else {
                return respond(conn, HTTPResponse.text(426, "Upgrade Required", "websocket required"))
            }
            conn.send(content: WebSocketCodec.handshakeResponse(clientKey: key), completion: .contentProcessed { _ in })
            let client = WSClient(conn: conn, queue: queue, onMessage: { [weak self] text in self?.control(text) },
                                  onClose: { [weak self] c in self?.drop(c) })
            clients[ObjectIdentifier(client)] = client
            log("Viewer connected (\(clients.count) total)")
            client.sendText(statusString())
            if let frame = backend.latestFrame { client.offer(header: Self.frameHeader(frame), jpeg: frame.jpeg) }
            client.run(initial: leftover)
        default:
            respond(conn, HTTPResponse.text(404, "Not Found", "not found"))
        }
    }

    private func drop(_ client: WSClient) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        log("Viewer disconnected (\(clients.count) remaining)")
        backend.releaseAll()
    }

    private func control(_ text: String) {
        if options.allowShutdown, ControlMessage.isShutdown(text) {
            log("Stop requested by a viewer; shutting down")
            for client in clients.values { client.sendText("{\"t\":\"stopped\"}") }
            let onShutdown = options.onShutdown
            queue.asyncAfter(deadline: .now() + 0.3) { onShutdown() }
            return
        }
        guard !options.viewOnly, let message = ControlMessage.parse(text) else { return }
        backend.handle(message)
    }

    private func statusString() -> String {
        String(decoding: statusJSON(), as: UTF8.self)
    }

    private func statusJSON() -> Data {
        var obj = backend.status
        obj["t"] = "status"
        obj["inputAvailable"] = backend.inputAvailable
        obj["viewOnly"] = options.viewOnly
        obj["allowShutdown"] = options.allowShutdown
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private func respond(_ conn: NWConnection, _ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// One WebSocket viewer. All methods run on the server queue.
final class WSClient {
    let conn: NWConnection
    let queue: DispatchQueue
    let onMessage: (String) -> Void
    let onClose: (WSClient) -> Void
    private var buffer: [UInt8] = []
    private var assembler = WSMessageAssembler(maxMessage: 64 * 1024)
    private var sending = false
    private var closed = false

    init(conn: NWConnection, queue: DispatchQueue, onMessage: @escaping (String) -> Void, onClose: @escaping (WSClient) -> Void) {
        self.conn = conn
        self.queue = queue
        self.onMessage = onMessage
        self.onClose = onClose
    }

    func run(initial: [UInt8]) {
        buffer = initial
        drain()
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(contentsOf: data) }
            self.drain()
            if error != nil || done { return self.close() }
            if !self.closed { self.receive() }
        }
    }

    private func drain() {
        do {
            while let frame = try WebSocketCodec.decode(&buffer, maxPayload: 64 * 1024) {
                switch try assembler.accept(frame) {
                case let .text(s)?: onMessage(s)
                case let .ping(p)?: write(WebSocketCodec.encode(.pong, p))
                case .close?: return close(sendingCloseFrame: true)
                case .binary?, .pong?, nil: break
                }
            }
        } catch {
            close()
        }
    }

    func sendText(_ s: String) { write(WebSocketCodec.encode(.text, Array(s.utf8))) }

    /// Sends the frame only if the previous one has been handed to the kernel; slow viewers skip frames.
    func offer(header: String, jpeg: Data) {
        guard !closed, !sending else { return }
        sending = true
        var data = Data(WebSocketCodec.encode(.text, Array(header.utf8)))
        data.append(contentsOf: WebSocketCodec.encode(.binary, [UInt8](jpeg)))
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.sending = false
                if error != nil { self.close() }
            }
        })
    }

    private func write(_ bytes: [UInt8]) {
        guard !closed else { return }
        conn.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    private func close(sendingCloseFrame: Bool = false) {
        guard !closed else { return }
        closed = true
        onClose(self)
        guard sendingCloseFrame else { return conn.cancel() }
        let conn = self.conn
        conn.send(content: Data(WebSocketCodec.encode(.close, [])), completion: .contentProcessed { _ in conn.cancel() })
    }
}
