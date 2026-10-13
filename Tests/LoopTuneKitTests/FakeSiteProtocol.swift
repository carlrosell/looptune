import Foundation

/// Serves synthetic sites inside a `URLSession` so HTTPS redirects can be
/// tested through the real session and redirect delegate without TLS
/// certificates or network access. Each test registers its own hostnames.
/// A redirect copies the request, headers included, as `URLSession` does for
/// HTTP, so the redirect delegate decides what reaches the next site.
///
/// `URLSession` tells a protocol that its redirect was followed by stopping
/// it, but says nothing when the delegate refuses one: it waits for the
/// protocol to deliver the redirect response itself. A protocol that reports a
/// redirect and then finishes the load races the delegate's decision. The task
/// can then complete with neither a response nor an error, which traps in
/// `URLSession.data(for:delegate:)` (#41), or return the redirect response
/// for a redirect the delegate followed. This protocol asks the delegate
/// first and then either reports the redirect or finishes with the redirect
/// response, never both.
final class FakeSiteProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case redirect(status: Int, location: String)
        case json(String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: @Sendable (URLRequest) -> Reply] = [:]
    nonisolated(unsafe) private static var received: [String: [URLRequest]] = [:]
    /// Set and read only on the thread that loads this request.
    private var stopped = false

    /// A session whose requests are all answered by registered fake sites.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeSiteProtocol.self]
        return URLSession(configuration: configuration)
    }()

    /// Answer requests for `host` with `reply`. Hosts are unique per test.
    static func register(host: String, reply: @escaping @Sendable (URLRequest) -> Reply) {
        lock.lock()
        defer { lock.unlock() }
        routes[host.lowercased()] = reply
        received[host.lowercased()] = []
    }

    /// Requests that reached `host`, in arrival order.
    static func requests(to host: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return received[host.lowercased()] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(percentEncoded: false)?.lowercased() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        let route = Self.routes[host]
        if route != nil { Self.received[host, default: []].append(request) }
        Self.lock.unlock()
        guard let route else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch route(request) {
        case .redirect(let status, let location):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            var next = request
            next.url = URL(string: location, relativeTo: url)?.absoluteURL
            redirect(to: next, after: response)
        case .json(let text):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped = true
    }

    /// Asks the task's delegate about the redirect without blocking the
    /// loading thread, then reports the redirect if the delegate follows it or
    /// finishes with the redirect response if it refuses. The answer arrives on
    /// another thread, so the result is delivered on the thread and run loop
    /// mode that started the load.
    private func redirect(to next: URLRequest, after response: HTTPURLResponse) {
        guard let task,
              let ask = task.delegate?.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:) else {
            // Without a redirect delegate, the session follows the redirect.
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        nonisolated(unsafe) let loader = CFRunLoopGetCurrent()
        let mode = RunLoop.current.currentMode ?? .default
        ask(Self.session, task, response, next) { [self] request in
            CFRunLoopPerformBlock(loader, mode.rawValue as CFString) { [self] in
                guard !stopped else { return }
                if request != nil {
                    // The session asks the delegate again, stops this load,
                    // and starts one for `next`.
                    client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
                } else {
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
            CFRunLoopWakeUp(loader)
        }
    }
}
