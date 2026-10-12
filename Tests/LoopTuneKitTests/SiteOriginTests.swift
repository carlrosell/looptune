import Testing
import Foundation
@testable import LoopTuneKit

@Suite("SiteOrigin")
struct SiteOriginTests {
    private func origin(_ string: String) -> SiteOrigin? {
        URL(string: string).flatMap(SiteOrigin.init(url:))
    }

    @Test("default ports, host case, path, and user information do not change the origin")
    func equivalentSpellings() throws {
        let expected = try #require(origin("https://example.com"))
        #expect(expected.scheme == "https")
        #expect(expected.host == "example.com")
        #expect(expected.port == 443)
        for spelling in [
            "HTTPS://Example.COM",
            "https://example.com:443",
            "https://example.com/api/v1/entries.json?token=synthetic#top",
            "https://user:synthetic@example.com",
        ] {
            #expect(origin(spelling) == expected, "\(spelling)")
        }
        #expect(origin("http://localhost") == origin("http://LOCALHOST:80"))
        #expect(origin("http://[::1]:1337") == origin("http://[0:0:0:0:0:0:0:1]:1337"))
        #expect(origin("https://bücher.example")?.host == "xn--bcher-kva.example")
    }

    @Test("scheme, port, and host distinguish origins")
    func distinctOrigins() {
        let origins = [
            "http://localhost:1337",
            "http://localhost:8080",
            "http://localhost",
            "https://localhost",
            "http://127.0.0.1:1337",
            "https://example.com:8443",
        ].map(origin)
        #expect(origins.allSatisfy { $0 != nil })
        #expect(Set(origins).count == origins.count)
        #expect(origin("http://example.com:443") != origin("https://example.com"))
    }

    @Test("only absolute http and https URLs with a host and valid port have an origin")
    func rejectsUnsupportedURLs() {
        for string in ["ftp://example.com", "file:///tmp/site", "https://example.com:0", "https://example.com:65536", "/relative/path", "http://[fe80::1%25en0]:1337"] {
            #expect(origin(string) == nil, "\(string)")
        }
    }

    @Test("hosts that are not names or IP literals have no origin")
    func rejectsMalformedHosts() {
        let longLabel = String(repeating: "a", count: 64)
        for string in [
            "https://exa%20mple.com",
            "https://ex%2Fample.com",
            "https://a%00b.com",
            "https://a%0Ab.com",
            "https://a%40b.com",
            "https://a%23b.com",
            "https://a%3Fb.com",
            "https://a%25b.com",
            "https://a..b.com",
            "https://.example.com",
            "https://example.com..",
            "https://-example.com",
            "https://example-.com",
            "https://\(longLabel).com",
            "https://127.1",
            "https://127.000.0.1",
            "https://256.0.0.1",
            "https://0x7f.0.0.1",
            "https://127.0.0.1.",
        ] {
            #expect(origin(string) == nil, "\(string)")
            #expect(throws: NightscoutError.invalidURL, "\(string)") {
                try NightscoutClient(rawURLString: string)
            }
            if let url = URL(string: string) {
                #expect(throws: NightscoutError.invalidURL, "\(string)") {
                    try NightscoutClient(baseURL: url)
                }
            }
        }
    }

    @Test("names, IPv4 and IPv6 literals, and decoded escapes are accepted")
    func acceptsValidHosts() {
        #expect(origin("https://ex%41mple.com") == origin("https://example.com"))
        #expect(origin("https://192.0.2.10")?.host == "192.0.2.10")
        #expect(origin("https://my_site.example")?.host == "my_site.example")
        #expect(origin("https://example.com.")?.host == "example.com.")
        #expect(origin("https://example.com.") != origin("https://example.com"))
        #expect(origin("https://[::ffff:192.0.2.10]")?.host == "::ffff:192.0.2.10")
    }

    @Test("every valid origin round-trips through its canonical URL and description")
    func roundTrip() throws {
        for string in [
            "https://example.com",
            "HTTPS://user:synthetic@Example.com:443/api?token=x",
            "https://example.com:8443",
            "https://example.com.",
            "https://bücher.example",
            "https://my_site.example",
            "https://ex%41mple.com",
            "https://192.0.2.10",
            "http://localhost",
            "http://localhost:1337",
            "https://localhost",
            "http://127.0.0.1:1337",
            "http://[::1]:1337",
            "http://[0:0:0:0:0:0:0:1]:1337",
            "https://[::ffff:192.0.2.10]",
            "http://example.com:443",
        ] {
            let parsed = try #require(origin(string), "\(string)")
            #expect(SiteOrigin(url: parsed.url) == parsed, "\(string)")
            #expect(origin(parsed.description) == parsed, "\(string)")
        }
    }

    @Test("the canonical URL omits default ports and credentials")
    func canonicalURL() {
        #expect(origin("HTTPS://user:synthetic@Example.com:443/api?token=x")?.description == "https://example.com")
        #expect(origin("http://LocalHost:1337/")?.description == "http://localhost:1337")
        #expect(origin("http://[0:0:0:0:0:0:0:1]:1337")?.description == "http://[::1]:1337")
    }

    @Test("the client exposes the origin of its normalized base URL")
    func clientOrigin() throws {
        let client = try NightscoutClient(rawURLString: "Example.com/api/v1?token=synthetic")
        #expect(client.origin == origin("https://example.com:443"))
    }
}
