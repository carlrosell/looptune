import Foundation
import Security

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

    var urlString: String? {
        get { defaults.string(forKey: Key.url) }
        nonmutating set { defaults.set(newValue, forKey: Key.url) }
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
    func saveToken(_ token: String?, forHost host: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: host,
        ]

        guard let token, !token.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let tokenData = Data(token.utf8)
        let attributes: [String: Any] = [kSecValueData as String: tokenData]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = tokenData
            addQuery[kSecAttrLabel as String] = "LoopTune — Nightscout token (\(host))"
            SecItemAdd(addQuery as CFDictionary, nil)
        }
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

    /// The keychain account key for a user-entered URL string (its host).
    static func host(from urlString: String) -> String? {
        var string = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        if !string.contains("://") { string = "https://" + string }
        return URLComponents(string: string)?.host?.lowercased()
    }
}
