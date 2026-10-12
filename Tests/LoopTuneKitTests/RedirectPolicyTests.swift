import Testing
import Foundation
@testable import LoopTuneKit

private let statusJSON = #"{"version":"15.0.0","settings":{"units":"mg/dL"}}"#
private let secretHeader = NightscoutCredentials.apiSecret("synthetic-secret").apiSecretHeader!

/// Redirects through the real `URLSession` transport against plain-HTTP
/// servers on 127.0.0.1. Credentials are synthetic.
@Suite("URLSessionTransport redirects between loopback servers")
struct LoopbackRedirectTests {
    @Test("a redirect to another host is refused before the api-secret is sent")
    func crossHostAPISecret() async throws {
        let target = try await LocalHTTPServer.start { _ in .json(statusJSON) }
        let site = try await LocalHTTPServer.start { _ in
            .redirect(to: "http://localhost:\(target.port)/other-origin")
        }
        let client = try NightscoutClient(
            rawURLString: site.baseURL,
            credentials: .apiSecret("synthetic-secret"),
            transport: URLSessionTransport()
        )

        await #expect(throws: NightscoutError.disallowedRedirect) {
            _ = try await client.fetchStatus()
        }
        #expect(site.requests.first?.headers["api-secret"] == secretHeader)
        #expect(target.requests.isEmpty)
    }

    @Test("a redirect to another port is refused even when it carries the token")
    func crossPortToken() async throws {
        let target = try await LocalHTTPServer.start { _ in .json(statusJSON) }
        let site = try await LocalHTTPServer.start { request in
            let query = request.target.split(separator: "?", maxSplits: 1).last ?? ""
            return .redirect(307, to: "http://127.0.0.1:\(target.port)/api/v1/status.json?\(query)")
        }
        let client = try NightscoutClient(
            rawURLString: site.baseURL,
            credentials: .token("synthetic-token"),
            transport: URLSessionTransport()
        )

        await #expect(throws: NightscoutError.disallowedRedirect) {
            _ = try await client.fetchStatus()
        }
        #expect(site.requests.first?.target.contains("token=synthetic-token") == true)
        #expect(target.requests.isEmpty)
    }

    @Test("same-origin redirects are followed and keep both kinds of credentials")
    func sameOrigin() async throws {
        let site = try await LocalHTTPServer.start { request in
            if request.target.hasPrefix("/moved") { return .json(statusJSON) }
            let query = request.target.split(separator: "?", maxSplits: 1).dropFirst().first
            return .redirect(301, to: "/moved" + (query.map { "?\($0)" } ?? ""))
        }

        let secretClient = try NightscoutClient(
            rawURLString: site.baseURL,
            credentials: .apiSecret("synthetic-secret"),
            transport: URLSessionTransport()
        )
        #expect(try await secretClient.fetchStatus().version == "15.0.0")

        let tokenClient = try NightscoutClient(
            rawURLString: site.baseURL,
            credentials: .token("synthetic-token"),
            transport: URLSessionTransport()
        )
        #expect(try await tokenClient.fetchStatus().version == "15.0.0")

        let moved = site.requests.filter { $0.target.hasPrefix("/moved") }
        #expect(moved.count == 2)
        #expect(moved.first?.headers["api-secret"] == secretHeader)
        #expect(moved.last?.target.contains("token=synthetic-token") == true)
    }

    @Test("a safe first hop does not exempt a later hop")
    func chain() async throws {
        let target = try await LocalHTTPServer.start { _ in .json(statusJSON) }
        let site = try await LocalHTTPServer.start { request in
            if request.target.hasPrefix("/step") {
                return .redirect(to: "http://localhost:\(target.port)/other-origin")
            }
            return .redirect(to: "/step")
        }
        let client = try NightscoutClient(
            rawURLString: site.baseURL,
            credentials: .apiSecret("synthetic-secret"),
            transport: URLSessionTransport()
        )

        await #expect(throws: NightscoutError.disallowedRedirect) {
            _ = try await client.fetchStatus()
        }
        #expect(site.requests.map(\.target) == ["/api/v1/status.json", "/step"])
        #expect(site.requests.last?.headers["api-secret"] == secretHeader)
        #expect(target.requests.isEmpty)
    }

    @Test("an upgrade from http to https on the same host is refused")
    func httpToHTTPS() async throws {
        let defaultPort = try await LocalHTTPServer.start { _ in
            .redirect(to: "https://127.0.0.1/api/v1/status.json")
        }
        let samePort = try await LocalHTTPServer.start { request in
            .redirect(to: "https://\(request.headers["host"] ?? "")/api/v1/status.json")
        }
        for server in [defaultPort, samePort] {
            let client = try NightscoutClient(
                rawURLString: server.baseURL,
                credentials: .apiSecret("synthetic-secret"),
                transport: URLSessionTransport()
            )
            await #expect(throws: NightscoutError.disallowedRedirect) {
                _ = try await client.fetchStatus()
            }
            // A followed redirect to the same port would open a TLS handshake
            // that the server never records as a request.
            #expect(server.requests.count == 1)
        }
    }
}

/// Redirects from HTTPS sites through a real `URLSession` whose requests are
/// answered in-process, so no certificate or network access is needed.
@Suite("URLSessionTransport redirects from HTTPS sites")
struct HTTPSRedirectTests {
    private func client(_ host: String, _ credentials: NightscoutCredentials) throws -> NightscoutClient {
        try NightscoutClient(
            rawURLString: "https://\(host)",
            credentials: credentials,
            transport: URLSessionTransport(session: FakeSiteProtocol.session())
        )
    }

    @Test("a downgrade to http on the same host is refused before it is sent")
    func downgrade() async throws {
        FakeSiteProtocol.register(host: "downgrade.site.example") { request in
            request.url?.scheme == "https"
                ? .redirect(status: 302, location: "http://downgrade.site.example/api/v1/status.json")
                : .json(statusJSON)
        }
        await #expect(throws: NightscoutError.disallowedRedirect) {
            _ = try await client("downgrade.site.example", .apiSecret("synthetic-secret")).fetchStatus()
        }
        let schemes = FakeSiteProtocol.requests(to: "downgrade.site.example").map { $0.url?.scheme }
        #expect(schemes == ["https"])
    }

    @Test("a redirect to a remote plain-http host is refused")
    func remoteHTTP() async throws {
        FakeSiteProtocol.register(host: "http-hop.site.example") { _ in
            .redirect(status: 302, location: "http://remote.other.example/api/v1/status.json")
        }
        FakeSiteProtocol.register(host: "remote.other.example") { _ in .json(statusJSON) }
        await #expect(throws: NightscoutError.disallowedRedirect) {
            _ = try await client("http-hop.site.example", .token("synthetic-token")).fetchStatus()
        }
        #expect(FakeSiteProtocol.requests(to: "remote.other.example").isEmpty)
    }

    @Test("a redirect to another HTTPS host is refused")
    func crossHostHTTPS() async throws {
        FakeSiteProtocol.register(host: "cross.site.example") { _ in
            .redirect(status: 302, location: "https://cross.other.example/api/v1/status.json")
        }
        FakeSiteProtocol.register(host: "cross.other.example") { _ in .json(statusJSON) }
        await #expect(throws: NightscoutError.disallowedRedirect) {
            _ = try await client("cross.site.example", .apiSecret("synthetic-secret")).fetchStatus()
        }
        #expect(FakeSiteProtocol.requests(to: "cross.other.example").isEmpty)
    }

    @Test("an equivalent spelling of the same origin is followed")
    func sameOriginSpelling() async throws {
        FakeSiteProtocol.register(host: "same.site.example") { request in
            request.url?.path == "/moved"
                ? .json(statusJSON)
                : .redirect(status: 308, location: "https://SAME.site.example:443/moved")
        }
        let status = try await client("same.site.example", .apiSecret("synthetic-secret")).fetchStatus()
        #expect(status.version == "15.0.0")
        let moved = FakeSiteProtocol.requests(to: "same.site.example").last
        #expect(moved?.url?.path == "/moved")
        #expect(moved?.value(forHTTPHeaderField: "api-secret") == secretHeader)
    }

    @Test("a request outside the transport policy is not sent")
    func initialRequest() async throws {
        FakeSiteProtocol.register(host: "plain.site.example") { _ in .json(statusJSON) }
        let transport = URLSessionTransport(session: FakeSiteProtocol.session())
        let request = URLRequest(url: try #require(URL(string: "http://plain.site.example/api/v1/status.json")))
        await #expect(throws: NightscoutError.invalidURL) {
            _ = try await transport.data(for: request)
        }
        #expect(FakeSiteProtocol.requests(to: "plain.site.example").isEmpty)
    }
}

@Suite("Redirect target policy")
struct RedirectTargetPolicyTests {
    @Test("only targets with exactly the request's origin are permitted")
    func targets() throws {
        let https = try #require(SiteOrigin(url: URL(string: "https://site.example")!))
        let loopback = try #require(SiteOrigin(url: URL(string: "http://127.0.0.1:1337")!))
        let cases: [(SiteOrigin, String, Bool)] = [
            (https, "https://site.example/api", true),
            (https, "https://Site.Example:443/api", true),
            (https, "https://site.example:8443/api", false),
            (https, "https://other.example/api", false),
            (https, "http://site.example/api", false),
            (https, "https://%73ite.example/api", false),
            (https, "ftp://site.example/api", false),
            (loopback, "http://127.0.0.1:1337/api", true),
            (loopback, "http://localhost:1337/api", false),
            (loopback, "https://127.0.0.1:1337/api", false),
            (loopback, "http://127.0.0.1:1338/api", false),
        ]
        for (origin, target, permitted) in cases {
            let url = try #require(URL(string: target))
            #expect(TransportPolicy.permitsRedirect(to: url, from: origin) == permitted, "\(origin) → \(target)")
        }
    }
}
