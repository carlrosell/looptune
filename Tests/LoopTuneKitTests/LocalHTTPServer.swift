import Foundation
import Network

/// A minimal HTTP/1.1 server bound to 127.0.0.1 on an ephemeral port, for
/// exercising the real `URLSession` transport without leaving the machine.
/// Each connection serves one request and is then closed.
final class LocalHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let target: String
        /// Header names lowercased.
        let headers: [String: String]
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func redirect(_ status: Int = 302, to location: String) -> Response {
            Response(status: status, headers: ["Location": location])
        }

        static func json(_ text: String) -> Response {
            Response(status: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalHTTPServer")
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private let handler: @Sendable (Request) -> Response

    /// Start a server that answers every request with `handler`.
    static func start(handler: @escaping @Sendable (Request) -> Response) async throws -> LocalHTTPServer {
        let server = try LocalHTTPServer(handler: handler)
        try await server.waitUntilReady()
        return server
    }

    private init(handler: @escaping @Sendable (Request) -> Response) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            readyContinuation = continuation
            lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.resumeReady(with: nil)
                case .failed(let error): self?.resumeReady(with: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func resumeReady(with error: Error?) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    /// The ephemeral port the server listens on.
    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    /// `http://127.0.0.1:<port>`.
    var baseURL: String {
        "http://127.0.0.1:\(port)"
    }

    deinit {
        listener.cancel()
    }

    /// Requests received so far, in arrival order.
    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let request = Request(
            target: requestLine.count > 1 ? requestLine[1] : "",
            headers: headers
        )
        lock.lock()
        recorded.append(request)
        lock.unlock()

        let response = handler(request)
        var text = "HTTP/1.1 \(response.status) Status\r\n"
        var fields = response.headers
        fields["Content-Length"] = String(response.body.count)
        fields["Connection"] = "close"
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        var payload = Data(text.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
