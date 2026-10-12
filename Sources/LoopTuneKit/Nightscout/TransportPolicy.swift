import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Which URLs a Nightscout request may reach. Requests use HTTPS, or plain
/// HTTP to a strict loopback host, and a redirect may only stay on the origin
/// of the request it answers. See ADR 0006.
enum TransportPolicy {
    /// Whether `url` may be contacted: it has a `SiteOrigin`, and its scheme is
    /// `https`, or `http` with a loopback host.
    static func permits(_ url: URL) -> Bool {
        guard let origin = SiteOrigin(url: url) else { return false }
        if origin.scheme == "https" { return true }
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host else { return false }
        return permitsPlainHTTP(host: host)
    }

    /// Whether a request to `origin` may follow a redirect to `url`. The target
    /// must be contactable and have exactly the same origin, so a change of
    /// scheme (including an upgrade from `http` to `https`), host, or effective
    /// port is rejected. A percent-encoded host is rejected as well: its
    /// decoded origin need not match the host a connection would use.
    static func permitsRedirect(to url: URL, from origin: SiteOrigin) -> Bool {
        guard permits(url),
              SiteOrigin(url: url) == origin,
              url.host(percentEncoded: true) == url.host(percentEncoded: false) else {
            return false
        }
        return true
    }

    /// Whether `host` may use plain HTTP. Only `localhost`, a canonical dotted-quad
    /// literal in 127.0.0.0/8, or the bracketed IPv6 loopback literal qualify.
    /// Any other name could resolve to a remote server, so `127.example.com`,
    /// shorthand such as `127.1`, and leading zeros (read as octal by some
    /// resolvers) are rejected rather than reinterpreted.
    static func permitsPlainHTTP(host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "localhost" { return true }
        if normalized.hasPrefix("[") && normalized.hasSuffix("]") {
            return isIPv6Loopback(String(normalized.dropFirst().dropLast()))
        }
        return isIPv4Loopback(normalized)
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        for octet in octets {
            guard (1...3).contains(octet.count),
                  octet.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  octet == "0" || octet.first != "0",
                  let value = Int(octet), value <= 255 else {
                return false
            }
        }
        return octets[0] == "127"
    }

    /// Accepts any spelling of `::1`. Zone IDs and embedded IPv4 notation are
    /// rejected up front because `inet_pton` ignores text after `%`.
    private static func isIPv6Loopback(_ address: String) -> Bool {
        guard address.allSatisfy({ $0 == ":" || $0.isHexDigit }) else { return false }
        var parsed = in6_addr()
        guard inet_pton(AF_INET6, address, &parsed) == 1 else { return false }
        return withUnsafeBytes(of: &parsed) { bytes in
            bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        }
    }
}
