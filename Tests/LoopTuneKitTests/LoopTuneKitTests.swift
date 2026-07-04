import Testing
@testable import LoopTuneKit

@Suite("LoopTuneKit basics")
struct LoopTuneKitTests {
    @Test("version is a semantic version")
    func versionIsSemVer() {
        let parts = LoopTuneKit.version.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
    }
}
