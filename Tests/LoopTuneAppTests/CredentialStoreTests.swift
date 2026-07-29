import Testing
@testable import LoopTuneApp

@Suite("CredentialStore URL handling")
struct CredentialStoreTests {
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
}
