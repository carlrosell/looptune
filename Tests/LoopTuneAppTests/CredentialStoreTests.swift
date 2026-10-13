import Foundation
import Testing
@testable import LoopTuneApp

@Suite("CredentialStore URL handling")
struct CredentialStoreTests {
    /// A store backed by its own UserDefaults suite, removed after `body`.
    private func withIsolatedStore(_ body: (CredentialStore, UserDefaults) throws -> Void) rethrows {
        let suite = "LoopTuneTests.CredentialStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(CredentialStore(defaults: defaults), defaults)
    }

    /// Whether any stored preference mentions a synthetic credential.
    private func containsSyntheticSecret(_ defaults: UserDefaults) -> Bool {
        "\(defaults.dictionaryRepresentation())".contains("audit")
    }

    @Test("Keychain account includes a non-default port")
    func accountIncludesPort() {
        #expect(CredentialStore.accountKey(from: "https://example.com") == "example.com")
        #expect(CredentialStore.accountKey(from: "http://localhost:1337/path") == "localhost:1337")
    }

    @Test("persisted URL strips paths, fragments, and pasted tokens")
    func sanitizesPersistedURL() {
        #expect(
            CredentialStore.sanitizedURLString(
                " HTTPS://Example.COM:8443/api/v1/entries?token=secret#fragment "
            ) == "https://example.com:8443"
        )
        #expect(CredentialStore.sanitizedURLString("") == nil)
    }

    @Test("persisted URL removes every form of user information")
    func sanitizesUserInfo() {
        for (raw, expected) in [
            ("https://audit-user:audit-password@example.com/path?token=audit-token#fragment", "https://example.com"),
            ("https://audit-user@example.com", "https://example.com"),
            ("https://:audit-password@example.com", "https://example.com"),
            ("https://@example.com", "https://example.com"),
            ("https://%61udit-user:%61udit-password@example.com", "https://example.com"),
            ("https://audit%40user:audit-pass@word@example.com:8443", "https://example.com:8443"),
            ("audit-user:audit-password@Example.com", "https://example.com"),
            ("http://audit-user:audit-password@localhost:1337", "http://localhost:1337"),
        ] {
            let sanitized = CredentialStore.sanitizedURLString(raw)
            #expect(sanitized == expected, "\(raw)")
            let components = sanitized.flatMap(URLComponents.init(string:))
            #expect(components?.percentEncodedUser == nil, "\(raw)")
            #expect(components?.percentEncodedPassword == nil, "\(raw)")
        }
    }

    @Test("saving a URL with user information stores only its scheme, host, and port")
    func savingStripsUserInfo() {
        withIsolatedStore { store, defaults in
            store.urlString = "https://audit-user:audit-password@example.com/api?token=audit-token"
            #expect(store.urlString == "https://example.com")
            #expect(!containsSyntheticSecret(defaults))
        }
    }

    @Test("restoring a stored URL with user information removes it from preferences")
    func restoreReplacesUserInfo() {
        withIsolatedStore { store, defaults in
            // A value an earlier version could have written, bypassing the setter.
            defaults.set("https://audit-user:audit-password@example.com:8443", forKey: "nightscoutURL")

            #expect(store.restoreURL() == "https://example.com:8443")
            #expect(defaults.string(forKey: "nightscoutURL") == "https://example.com:8443")
            #expect(!containsSyntheticSecret(defaults))
        }
    }

    @Test("restoring a stored URL without a site origin removes it")
    func restoreRemovesInvalid() {
        withIsolatedStore { store, defaults in
            defaults.set("ftp://audit-user:audit-password@example.com", forKey: "nightscoutURL")
            #expect(store.restoreURL() == nil)
            #expect(defaults.object(forKey: "nightscoutURL") == nil)
            #expect(!containsSyntheticSecret(defaults))
        }
    }

    @Test("restoring leaves a URL without user information unchanged")
    func restoreKeepsSanitized() {
        withIsolatedStore { store, defaults in
            for saved in ["http://localhost:1337", "https://example.com:443"] {
                defaults.set(saved, forKey: "nightscoutURL")
                #expect(store.restoreURL() == saved)
                #expect(defaults.string(forKey: "nightscoutURL") == saved)
            }
        }
    }

    @Test("sanitizing keeps the Keychain account of the entered URL")
    func sanitizingKeepsAccount() {
        for raw in [
            "https://audit-user:audit-password@Example.com:443/api",
            "https://audit-user@example.com:8443",
            "http://audit-user:audit-password@localhost:1337",
            "audit-user:audit-password@example.com",
        ] {
            let sanitized = CredentialStore.sanitizedURLString(raw)
            #expect(sanitized.flatMap(CredentialStore.accountKey(from:)) == CredentialStore.accountKey(from: raw), "\(raw)")
        }
    }
}
