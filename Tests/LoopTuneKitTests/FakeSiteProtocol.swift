import Foundation

/// Serves synthetic sites inside a `URLSession` so HTTPS redirects can be
/// tested through the real session and redirect delegate without TLS
/// certificates or network access. Each test registers its own hostnames.
/// A redirect copies the request, headers included, as `URLSession` does for
/// HTTP, so the redirect delegate decides what reaches the next site.
final class FakeSiteProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case redirect(status: Int, location: String)
        case json(String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: @Sendable (URLRequest) -> Reply] = [:]
    nonisolated(unsafe) private static var received: [String: [URLRequest]] = [:]

    /// A session whose requests are all answered by registered fake sites.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeSiteProtocol.self]
        return URLSession(configuration: configuration)
    }

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
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .json(let text):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
