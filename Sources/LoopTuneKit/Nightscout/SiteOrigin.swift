import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The canonical identity of a Nightscout site: scheme, normalized host, and
/// effective port. Two URLs name the same site exactly when their origins are
/// equal, so `http://localhost:1337` and `http://localhost:8080` are distinct
/// while `https://Example.com` and `https://example.com:443/api` are the same.
///
/// User information, path, query, and fragment are not part of the origin and
/// never appear in `url` or `description`. The origin does not decide whether
/// a URL is safe to contact; transport policy belongs to `NightscoutClient`.
/// See ADR 0003.
public struct SiteOrigin: Hashable, Sendable {
    /// `http` or `https`, lowercased.
    public let scheme: String
    /// Lowercased ASCII host. Internationalized names use their punycode
    /// form and IPv6 literals use their compressed form without brackets.
    public let host: String
    /// The port requests actually use, with the scheme default filled in.
    public let port: Int

    /// The origin of an absolute `http` or `https` URL, or `nil` when the URL
    /// has another scheme, no host, or a port outside 1…65535.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let defaultPort = Self.defaultPort(forScheme: scheme),
              let rawHost = url.host(percentEncoded: false),
              let host = Self.normalizeHost(rawHost) else {
            return nil
        }
        let port = url.port ?? defaultPort
        guard (1...65_535).contains(port) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    /// Whether `port` is the default for `scheme`, so it is omitted from URLs.
    public var usesDefaultPort: Bool {
        port == Self.defaultPort(forScheme: scheme)
    }

    /// Whether the host is an IPv6 literal, which URLs write in brackets.
    public var isIPv6Literal: Bool {
        host.contains(":")
    }

    /// The canonical base URL: scheme, host, and a non-default port only.
    public var url: URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = isIPv6Literal ? "[\(host)]" : host
        components.port = usesDefaultPort ? nil : port
        // Every component was validated on construction.
        return components.url!
    }

    static func defaultPort(forScheme scheme: String) -> Int? {
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func normalizeHost(_ raw: String) -> String? {
        var host = raw.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return nil }
        guard host.contains(":") else { return host }
        return canonicalIPv6(host)
    }

    /// Compress an IPv6 literal so equivalent spellings compare equal. Zone
    /// IDs are rejected because Darwin's `inet_pton` ignores text after `%`,
    /// which would merge distinct scoped addresses.
    private static func canonicalIPv6(_ literal: String) -> String? {
        guard literal.allSatisfy({ $0 == ":" || $0 == "." || $0.isHexDigit }) else { return nil }
        var address = in6_addr()
        guard inet_pton(AF_INET6, literal, &address) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension SiteOrigin: CustomStringConvertible {
    /// The canonical base URL string, for example `http://localhost:1337`.
    public var description: String {
        url.absoluteString
    }
}
