import Foundation
import Security
import LoopTuneKit

/// Persists the connection form between launches: the Nightscout access token
/// goes in the login Keychain (a generic-password item keyed by site host);
/// non-secret preferences (URL, days, insulin type) go in UserDefaults.
struct CredentialStore {
    static let service = "com.looptune.nightscout-token"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Non-secret preferences

    private enum Key {
        static let url = "nightscoutURL"
        static let days = "analysisDays"
        static let insulinType = "insulinType"
    }

    /// The saved connection URL. Writing stores the sanitized form (see
    /// `sanitizedURLString`), and a value without a site origin clears it.
    var urlString: String? {
        get { defaults.string(forKey: Key.url) }
        nonmutating set { defaults.set(newValue.flatMap(Self.sanitizedURLString), forKey: Key.url) }
    }

    /// The saved connection URL for restoring the form. An earlier version
    /// could save user information in the URL, so a value not already in
    /// sanitized form is replaced by its sanitized form, or removed when it
    /// has none. The secret is neither kept nor written back.
    func restoreURL() -> String? {
        guard let saved = urlString else { return nil }
        let sanitized = Self.sanitizedURLString(saved)
        if sanitized != saved {
            urlString = sanitized
        }
        return sanitized
    }

    var days: Int? {
        get { defaults.object(forKey: Key.days) as? Int }
        nonmutating set { defaults.set(newValue, forKey: Key.days) }
    }

    var insulinTypeRaw: String? {
        get { defaults.string(forKey: Key.insulinType) }
        nonmutating set { defaults.set(newValue, forKey: Key.insulinType) }
    }

    // MARK: - Keychain (token)

    /// Store (or clear, when nil/empty) the access token for a site host.
    @discardableResult
    func saveToken(_ token: String?, forHost host: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: host,
        ]

        guard let token, !token.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let tokenData = Data(token.utf8)
        let attributes: [String: Any] = [kSecValueData as String: tokenData]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = tokenData
            addQuery[kSecAttrLabel as String] = "LoopTune — Nightscout token (\(host))"
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return updateStatus == errSecSuccess
    }

    /// Read the stored token for a site host.
    func token(forHost host: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The keychain account key for a user-entered URL. The port matters:
    /// `localhost:1337` and `localhost:8080` can be unrelated sites.
    static func accountKey(from urlString: String) -> String? {
        var string = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        if !string.contains("://") { string = "https://" + string }
        guard let components = URLComponents(string: string),
              let host = components.host?.lowercased() else { return nil }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    /// Reduce a connection URL to scheme, host, and port before it is written
    /// to UserDefaults. Paths, queries, fragments, and user information are
    /// removed, so neither a pasted `?token=` nor a `user:password@` prefix
    /// persists, and a URL without a `SiteOrigin` is refused. The host and
    /// port keep their entered spelling (lowercased), so `accountKey` of the
    /// result matches the account the token is saved under. See ADR 0009.
    static func sanitizedURLString(_ urlString: String) -> String? {
        guard let url = SiteOrigin.url(fromUserInput: urlString),
              SiteOrigin(url: url) != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString
    }
}
