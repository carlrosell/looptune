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
    /// The canonical base URL: scheme, host, and a non-default port only.
    public let url: URL

    /// The origin of an absolute `http` or `https` URL, or `nil` when the URL
    /// has another scheme, a port outside 1…65535, or a host that is not a
    /// DNS name, canonical IPv4 literal, or IPv6 literal (see `normalizeHost`).
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let defaultPort = Self.defaultPort(forScheme: scheme),
              let rawHost = url.host(percentEncoded: false),
              let host = Self.normalizeHost(rawHost) else {
            return nil
        }
        let port = url.port ?? defaultPort
        guard (1...65_535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port == defaultPort ? nil : port
        // Keep only origins whose canonical URL reads back as the same origin.
        guard let canonical = components.url,
              canonical.host(percentEncoded: false) == host,
              (canonical.port ?? defaultPort) == port else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        self.port = port
        self.url = canonical
    }

    /// Whether `port` is the default for `scheme`, so it is omitted from URLs.
    public var usesDefaultPort: Bool {
        port == Self.defaultPort(forScheme: scheme)
    }

    /// Whether the host is an IPv6 literal, which URLs write in brackets.
    public var isIPv6Literal: Bool {
        host.contains(":")
    }

    static func defaultPort(forScheme scheme: String) -> Int? {
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    /// Lowercase and validate a percent-decoded host. A name is dot-separated
    /// labels of 1…63 characters from `a-z`, `0-9`, `-`, and `_`, not starting
    /// or ending with `-`, at most 253 characters plus an optional trailing
    /// dot. A name whose last label is numeric must be a canonical dotted-quad
    /// IPv4 literal, so `127.1` and `127.000.0.1` are rejected rather than
    /// kept as names. Spaces, control characters, `/`, `@`, `#`, `?`, `%`,
    /// and empty labels leave the host without an origin.
    private static func normalizeHost(_ raw: String) -> String? {
        var host = raw.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return nil }
        if host.contains(":") { return canonicalIPv6(host) }
        return isValidName(host) ? host : nil
    }

    private static func isValidName(_ host: String) -> Bool {
        let hasTrailingDot = host.hasSuffix(".")
        let name = hasTrailingDot ? host.dropLast() : Substring(host)
        guard !name.isEmpty, name.utf8.count <= 253 else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.utf8.count),
                  label.utf8.allSatisfy(isNameByte),
                  label.first != "-", label.last != "-" else {
                return false
            }
        }
        guard let last = labels.last, isNumericLabel(last) else { return true }
        return !hasTrailingDot && isCanonicalIPv4(labels)
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }

    /// Whether URL parsers read `label` as a number: decimal digits, or `0x`
    /// followed by hex digits.
    private static func isNumericLabel(_ label: Substring) -> Bool {
        if label.hasPrefix("0x") {
            return label.dropFirst(2).allSatisfy(\.isHexDigit)
        }
        return label.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    private static func isCanonicalIPv4(_ octets: [Substring]) -> Bool {
        octets.count == 4 && octets.allSatisfy { octet in
            octet.count <= 3
                && octet.allSatisfy { $0 >= "0" && $0 <= "9" }
                && (octet == "0" || octet.first != "0")
                && (Int(octet) ?? 256) <= 255
        }
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
