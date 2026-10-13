import Testing
import Foundation
@testable import LoopTuneKit

/// URL user information is removed from entered site addresses and refused by
/// the transport. All credentials are synthetic.
@Suite("URL user information")
struct URLUserInfoTests {
    /// Spellings of user information, each on a site whose base URL is
    /// `expected`. None of the synthetic values may survive normalization.
    private let cases: [(raw: String, expected: String)] = [
        ("https://audit-user:audit-password@example.com/path?token=audit-token#fragment", "https://example.com"),
        ("https://audit-user@example.com", "https://example.com"),
        ("https://:audit-password@example.com", "https://example.com"),
        ("https://@example.com", "https://example.com"),
        ("https://%61udit-user:%61udit-password@example.com", "https://example.com"),
        ("https://audit%40user:audit-pass@word@example.com:8443", "https://example.com:8443"),
        ("audit-user:audit-password@Example.com", "https://example.com"),
        ("http://audit-user:audit-password@[::1]:1337", "http://[::1]:1337"),
    ]

    private func assertNoUserInfo(_ url: URL?, _ context: String) {
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        #expect(components?.percentEncodedUser == nil, "\(context)")
        #expect(components?.percentEncodedPassword == nil, "\(context)")
        let string = url?.absoluteString ?? ""
        #expect(!string.contains("audit"), "\(context)")
        #expect(!string.contains("%61"), "\(context)")
    }

    @Test("the base URL normalizer removes every form of user information")
    func normalizer() {
        for (raw, expected) in cases {
            let normalized = NightscoutClient.normalizeBaseURL(raw)
            #expect(normalized?.absoluteString == expected, "\(raw)")
            assertNoUserInfo(normalized, raw)
        }
    }

    @Test("both initializers build requests without user information")
    func initializers() async throws {
        for (raw, _) in cases {
            let stub = StubTransport()
            let fromString = try NightscoutClient(rawURLString: raw, credentials: .token("synthetic-token"), transport: stub)
            assertNoUserInfo(fromString.baseURL, raw)
            _ = try await fromString.fetchEntries(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 300))
            let sent = try #require(stub.lastRequest?.url)
            assertNoUserInfo(sent, raw)
            #expect(sent.absoluteString.contains("token=synthetic-token"))

            guard raw.contains("://") else { continue }
            let url = try #require(URL(string: raw))
            let fromURL = try NightscoutClient(baseURL: url, credentials: .apiSecret("synthetic-secret"), transport: stub)
            #expect(fromURL.baseURL == fromString.baseURL, "\(raw)")
            _ = try await fromURL.fetchEntries(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 300))
            assertNoUserInfo(stub.lastRequest?.url, raw)
            #expect(stub.lastRequest?.value(forHTTPHeaderField: "api-secret") != nil)
        }
    }

    @Test("the transport policy refuses URLs with user information")
    func policy() throws {
        let origin = try #require(SiteOrigin(url: URL(string: "https://site.example")!))
        for target in [
            "https://audit-user:audit-password@site.example/api",
            "https://audit-user@site.example/api",
            "https://:audit-password@site.example/api",
            "https://@site.example/api",
        ] {
            let url = try #require(URL(string: target))
            #expect(!TransportPolicy.permits(url), "\(target)")
            #expect(!TransportPolicy.permitsRedirect(to: url, from: origin), "\(target)")
        }
        #expect(TransportPolicy.permits(URL(string: "https://site.example/api")!))
    }
}

/// The real `URLSession` transport against a plain-HTTP server on 127.0.0.1.
@Suite("URLSessionTransport and URL user information")
struct URLSessionTransportUserInfoTests {
    private let statusJSON = #"{"version":"15.0.0","settings":{"units":"mg/dL"}}"#

    @Test("a client created from a URL with user information sends none of it")
    func clientSendsNoUserInfo() async throws {
        let json = statusJSON
        let site = try await LocalHTTPServer.start { _ in .json(json) }
        let raw = "http://audit-user:audit-password@127.0.0.1:\(site.port)"
        let client = try NightscoutClient(rawURLString: raw, transport: URLSessionTransport())

        #expect(try await client.fetchStatus().version == "15.0.0")
        let request = try #require(site.requests.first)
        #expect(request.headers["authorization"] == nil)
        #expect(!request.target.contains("audit"))
    }

    @Test("a request URL with user information is refused before it is sent")
    func requestRefused() async throws {
        let json = statusJSON
        let site = try await LocalHTTPServer.start { _ in .json(json) }
        let url = try #require(URL(string: "http://audit-user:audit-password@127.0.0.1:\(site.port)/api/v1/status.json"))

        await #expect(throws: NightscoutError.invalidURL) {
            _ = try await URLSessionTransport().data(for: URLRequest(url: url))
        }
        #expect(site.requests.isEmpty)
    }

    @Test("a same-origin redirect that adds user information is refused")
    func redirectRefused() async throws {
        let site = try await LocalHTTPServer.start { request in
            .redirect(to: "http://audit-user:audit-password@\(request.headers["host"] ?? "")/moved")
        }
        let client = try NightscoutClient(rawURLString: site.baseURL, transport: URLSessionTransport())

        await #expect(throws: NightscoutError.disallowedRedirect) {
            _ = try await client.fetchStatus()
        }
        #expect(site.requests.map(\.target) == ["/api/v1/status.json"])
    }
}
