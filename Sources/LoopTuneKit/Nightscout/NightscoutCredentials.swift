import Foundation
import CryptoKit

/// How LoopTune authenticates to a Nightscout site.
///
/// Reading typically only needs an access **token** (role `readable`); many
/// sites are publicly readable and need nothing. The legacy **api-secret**
/// header (SHA-1 hex of the raw secret) is also supported.
public enum NightscoutCredentials: Sendable, Equatable {
    /// No credentials (public site).
    case none
    /// An access token appended as `?token=…` to every request.
    case token(String)
    /// A raw API secret sent as the SHA-1 `api-secret` header.
    case apiSecret(String)

    /// The `api-secret` header value, if applicable (lowercase SHA-1 hex of the
    /// raw secret — modern Nightscout rejects the raw secret).
    var apiSecretHeader: String? {
        guard case .apiSecret(let secret) = self else { return nil }
        let digest = Insecure.SHA1.hash(data: Data(secret.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The token query value, if applicable.
    var tokenQueryValue: String? {
        guard case .token(let token) = self else { return nil }
        return token
    }
}
