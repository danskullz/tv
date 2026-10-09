import Foundation
import Network
import Synchronization

/// Tiny loopback-only HTTP/1.1 server for the demo harness: GET requests, one response per
/// connection. Not a general server; the real streaming server is `StreamServer`.
final class LoopbackHTTPServer: Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var query: [String: String]
    }

    struct Response: Sendable {
        var status: Int
        var contentType: String
        var body: Data

        static func xml(_ text: String, status: Int = 200) -> Response {
            Response(status: status, contentType: "application/xml; charset=utf-8", body: Data(text.utf8))
        }
    }

    enum ServerError: Error { case failedToStart(String) }

    private let handler: @Sendable (Request) -> Response
    private let queue = DispatchQueue(label: "marquee.demo.http")
    private let listener = Mutex<NWListener?>(nil)

    init(handler: @escaping @Sendable (Request) -> Response) {
        self.handler = handler
    }

    /// Binds 127.0.0.1 on an ephemeral port and returns it.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        let handler = self.handler
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            Connection(connection, handler: handler).run(on: queue)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Mutex(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.withLock({ let was = $0; $0 = true; return !was }) {
                        if let p = listener.port?.rawValue { continuation.resume(returning: p) }
                        else { continuation.resume(throwing: ServerError.failedToStart("no port")) }
                    }
                case .failed(let error):
                    if once.withLock({ let was = $0; $0 = true; return !was }) {
                        continuation.resume(throwing: ServerError.failedToStart("\(error)"))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.listener.withLock { $0 = listener }
        return port
    }

    func stop() {
        listener.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    private final class Connection: @unchecked Sendable {
        private let connection: NWConnection
        private let handler: @Sendable (Request) -> Response
        private var buffer = Data()

        init(_ connection: NWConnection, handler: @escaping @Sendable (Request) -> Response) {
            self.connection = connection
            self.handler = handler
        }

        func run(on queue: DispatchQueue) {
            connection.start(queue: queue)
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
                if let data { buffer.append(data) }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    respond(to: buffer[..<end.lowerBound])
                } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                    connection.cancel()
                } else {
                    receive()
                }
            }
        }

        private func respond(to head: Data) {
            let text = String(decoding: head, as: UTF8.self)
            let line = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            let response: Response
            if parts.count >= 2 {
                let target = String(parts[1])
                let components = URLComponents(string: "http://localhost" + target)
                var query: [String: String] = [:]
                for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
                response = handler(Request(method: String(parts[0]), path: components?.path ?? target, query: query))
            } else {
                response = Response(status: 400, contentType: "text/plain", body: Data("bad request".utf8))
            }
            let reason = response.status == 200 ? "OK" : "Error"
            var out = Data(
                ("HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\n"
                    + "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n").utf8)
            out.append(response.body)
            connection.send(content: out, isComplete: true, completion: .contentProcessed { [self] _ in connection.cancel() })
        }
    }
}
