import Foundation
import Testing
import LoopTuneKit
@testable import LoopTuneApp

@Suite("TuningViewModel run lifecycle")
@MainActor
struct TuningViewModelRunTests {
    private let siteA = "https://site-a.example.com"
    private let siteB = "https://site-b.example.com"

    @Test("a successful run persists the request it ran")
    func persistsRequestOnSuccess() async throws {
        let store = InMemorySettingsStore()
        let runner = ControlledRunner()
        let model = TuningViewModel(store: store, runStore: Self.temporaryRunStore(), runner: runner.run)
        model.urlString = "HTTPS://Site-A.example.com/api/v1?token=pasted"
        model.token = "token-a"
        model.days = 14
        model.insulinType = .fiasp

        model.run()
        try await runner.waitForRequest()
        let request = try #require(runner.requests.first)
        #expect(request.token == "token-a")
        #expect(request.configuration.days == 14)
        try runner.succeed(origin: siteA)
        await model.runTask?.value

        #expect(model.phase == .done)
        #expect(model.notice == nil)
        #expect(store.urlString == siteA)
        #expect(model.urlString == siteA)
        #expect(store.days == 14)
        #expect(store.insulinTypeRaw == InsulinType.fiasp.rawValue)
        #expect(store.tokens == ["site-a.example.com": "token-a"])
        let run = try #require(model.selectedRun)
        #expect(run.siteHost == "site-a.example.com")
        #expect(run.days == 14)
        #expect(run.insulinType == .fiasp)
    }

    @Test("settings are locked only while a run is pending")
    func settingsLockedWhileRunning() async throws {
        let runner = ControlledRunner()
        let model = TuningViewModel(store: InMemorySettingsStore(), runStore: Self.temporaryRunStore(), runner: runner.run)
        model.urlString = siteA
        #expect(!model.isRunning)

        model.run()
        try await runner.waitForRequest()
        #expect(model.isRunning)
        #expect(!model.canRun)
        model.run()
        try runner.succeed(origin: siteA)
        await model.runTask?.value
        #expect(!model.isRunning)
        #expect(model.canRun)
        #expect(runner.requests.count == 1)

        model.run()
        try await runner.waitForRequest()
        #expect(model.isRunning)
        runner.fail(NightscoutError.httpStatus(503))
        await model.runTask?.value
        #expect(!model.isRunning)
        #expect(model.canRun)
    }

    @Test("clearing the token during a run keeps the token that succeeded")
    func clearedTokenDuringRun() async throws {
        let store = InMemorySettingsStore(urlString: siteA, tokens: ["site-a.example.com": "token-a"])
        let runner = ControlledRunner()
        let model = TuningViewModel(store: store, runStore: Self.temporaryRunStore(), runner: runner.run)
        #expect(model.token == "token-a")

        model.run()
        try await runner.waitForRequest()
        model.token = ""
        try runner.succeed(origin: siteA)
        await model.runTask?.value

        #expect(model.phase == .done)
        #expect(store.tokens == ["site-a.example.com": "token-a"])
        #expect(store.urlString == siteA)
    }

    @Test("switching site, window, and insulin during a run persists the run's settings")
    func switchedSettingsDuringRun() async throws {
        let store = InMemorySettingsStore(
            urlString: siteA,
            days: 7,
            insulinTypeRaw: InsulinType.novolog.rawValue,
            tokens: ["site-a.example.com": "token-a", "site-b.example.com": "token-b"]
        )
        let runner = ControlledRunner()
        let model = TuningViewModel(store: store, runStore: Self.temporaryRunStore(), runner: runner.run)

        model.run()
        try await runner.waitForRequest()
        model.urlString = siteB
        model.token = "edited-b"
        model.days = 30
        model.insulinType = .lyumjev
        try runner.succeed(origin: siteA)
        await model.runTask?.value

        #expect(model.phase == .done)
        #expect(store.urlString == siteA)
        #expect(store.days == 7)
        #expect(store.insulinTypeRaw == InsulinType.novolog.rawValue)
        #expect(store.tokens == ["site-a.example.com": "token-a", "site-b.example.com": "token-b"])
        let run = try #require(model.selectedRun)
        #expect(run.siteHost == "site-a.example.com")
        #expect(run.source.label == siteA)
        #expect(run.days == 7)
        #expect(run.insulinType == .novolog)
        // Completion leaves the form alone rather than overwriting edits.
        #expect(model.urlString == siteB)
        #expect(model.days == 30)
    }

    @Test("a failed run persists nothing")
    func failurePersistsNothing() async throws {
        let store = InMemorySettingsStore()
        let runner = ControlledRunner()
        let runStore = Self.temporaryRunStore()
        let model = TuningViewModel(store: store, runStore: runStore, runner: runner.run)
        model.urlString = siteA
        model.token = "wrong-token"

        model.run()
        try await runner.waitForRequest()
        runner.fail(NightscoutError.unauthorized)
        await model.runTask?.value

        #expect(model.phase == .failed(TuningViewModel.describe(NightscoutError.unauthorized)))
        #expect(store.urlString == nil)
        #expect(store.days == nil)
        #expect(store.insulinTypeRaw == nil)
        #expect(store.tokens.isEmpty)
        #expect(model.runs.isEmpty)
        #expect(runStore.loadAll().isEmpty)
    }

    @Test("a Keychain failure after success is reported")
    func tokenSaveFailureNotice() async throws {
        let store = InMemorySettingsStore()
        store.failsTokenSaves = true
        let runner = ControlledRunner()
        let model = TuningViewModel(store: store, runStore: Self.temporaryRunStore(), runner: runner.run)
        model.urlString = siteA
        model.token = "token-a"

        model.run()
        try await runner.waitForRequest()
        try runner.succeed(origin: siteA)
        await model.runTask?.value

        #expect(model.phase == .done)
        #expect(model.notice == "The analysis succeeded, but the access token could not be saved to Keychain.")
        #expect(store.urlString == siteA)
        #expect(model.selectedRun != nil)
    }

    @Test("a history save failure after success is reported")
    func historySaveFailureNotice() async throws {
        // A regular file where the run directory's parent should be makes
        // every save fail.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("looptune-blocked-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let store = InMemorySettingsStore()
        let runner = ControlledRunner()
        let model = TuningViewModel(
            store: store,
            runStore: RunStore(directory: blocker.appendingPathComponent("Runs", isDirectory: true)),
            runner: runner.run
        )
        model.urlString = siteA

        model.run()
        try await runner.waitForRequest()
        try runner.succeed(origin: siteA)
        await model.runTask?.value

        #expect(model.phase == .done)
        #expect(model.notice == "The analysis succeeded, but its history file could not be saved.")
        #expect(model.selectedRun?.siteHost == "site-a.example.com")
        #expect(store.urlString == siteA)
    }

    @Test("restoring a saved URL with user information shows and keeps it without")
    func restoreRemovesUserInfo() {
        let store = InMemorySettingsStore(
            urlString: "https://audit-user:audit-password@Site-A.example.com:8443",
            tokens: ["site-a.example.com:8443": "token-a"]
        )
        let model = TuningViewModel(store: store, runStore: Self.temporaryRunStore(), runner: ControlledRunner().run)

        #expect(model.urlString == "https://site-a.example.com:8443")
        #expect(model.token == "token-a")
        #expect(store.urlString == "https://site-a.example.com:8443")

        let invalid = InMemorySettingsStore(urlString: "ftp://audit-user:audit-password@site-a.example.com")
        let emptyModel = TuningViewModel(store: invalid, runStore: Self.temporaryRunStore(), runner: ControlledRunner().run)
        #expect(emptyModel.urlString == "")
        #expect(invalid.urlString == nil)
    }

    @Test("a run entered with user information saves and restores without it")
    func userInfoRoundTrip() async throws {
        let store = InMemorySettingsStore()
        let runner = ControlledRunner()
        let model = TuningViewModel(store: store, runStore: Self.temporaryRunStore(), runner: runner.run)
        model.urlString = "https://audit-user:audit-password@site-a.example.com:8443/api"
        model.token = "token-a"

        model.run()
        try await runner.waitForRequest()
        // The origin the live runner reports for the URL as entered.
        let entered = try #require(runner.requests.last).urlString
        try runner.succeed(origin: NightscoutClient(rawURLString: entered, credentials: .none).origin.description)
        await model.runTask?.value

        #expect(model.phase == .done)
        #expect(model.selectedRun?.source.label == "https://site-a.example.com:8443")
        #expect(store.urlString == "https://site-a.example.com:8443")
        #expect(model.urlString == "https://site-a.example.com:8443")
        #expect(store.tokens == ["site-a.example.com:8443": "token-a"])

        let relaunched = TuningViewModel(store: store, runStore: Self.temporaryRunStore(), runner: runner.run)
        #expect(relaunched.urlString == "https://site-a.example.com:8443")
        #expect(relaunched.token == "token-a")
    }

    @Test("history shows each run's own site, including sites that differ only by port")
    func historyShowsEachRunsSource() async throws {
        let siteOn1337 = "http://localhost:1337"
        let siteOn8080 = "http://localhost:8080"
        let runner = ControlledRunner()
        let runStore = Self.temporaryRunStore()
        let model = TuningViewModel(store: InMemorySettingsStore(), runStore: runStore, runner: runner.run)

        var ids: [String: String] = [:]
        for site in [siteOn1337, siteOn8080] {
            model.urlString = site
            model.run()
            try await runner.waitForRequest()
            try runner.succeed(origin: site)
            await model.runTask?.value
            ids[site] = try #require(model.selectedRun).id
        }
        model.urlString = siteB

        for site in [siteOn1337, siteOn8080, siteOn1337] {
            model.selectedRunID = ids[site]
            #expect(model.selectedRun?.source.label == site)
        }

        // The history list reloaded from disk keeps both ports apart.
        let reloaded = TuningViewModel(store: InMemorySettingsStore(urlString: siteB), runStore: runStore, runner: runner.run)
        let labels = Dictionary(uniqueKeysWithValues: reloaded.runs.map { ($0.id, $0.source.label) })
        #expect(labels == [ids[siteOn1337]!: siteOn1337, ids[siteOn8080]!: siteOn8080])
    }

    private static func temporaryRunStore() -> RunStore {
        RunStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("looptune-app-runs-\(UUID().uuidString)", isDirectory: true))
    }
}

/// Connection settings held in memory, so tests never reach the Keychain or a
/// UserDefaults domain.
private final class InMemorySettingsStore: ConnectionSettingsStore {
    var urlString: String?
    var days: Int?
    var insulinTypeRaw: String?
    var tokens: [String: String]
    var failsTokenSaves = false

    init(urlString: String? = nil, days: Int? = nil, insulinTypeRaw: String? = nil, tokens: [String: String] = [:]) {
        self.urlString = urlString
        self.days = days
        self.insulinTypeRaw = insulinTypeRaw
        self.tokens = tokens
    }

    /// Cleans with the live store's sanitizer and writes the result back the
    /// way `CredentialStore.restoreURL()` does.
    func restoreURL() -> String? {
        guard let saved = urlString else { return nil }
        let sanitized = CredentialStore.sanitizedURLString(saved)
        if sanitized != saved {
            urlString = sanitized
        }
        return sanitized
    }

    func saveToken(_ token: String?, forHost host: String) -> Bool {
        guard !failsTokenSaves else { return false }
        if let token, !token.isEmpty {
            tokens[host] = token
        } else {
            tokens[host] = nil
        }
        return true
    }

    func token(forHost host: String) -> String? {
        tokens[host]
    }
}

/// An analysis runner that records each request and suspends until the test
/// completes it.
private final class ControlledRunner: @unchecked Sendable {
    private struct Timeout: Error {}

    private let lock = NSLock()
    private var recorded: [AnalysisRequest] = []
    private var pending: [CheckedContinuation<AnalysisOutput, Error>] = []

    var requests: [AnalysisRequest] {
        lock.withLock { recorded }
    }

    @Sendable
    func run(_ request: AnalysisRequest) async throws -> AnalysisOutput {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                recorded.append(request)
                pending.append(continuation)
            }
        }
    }

    func waitForRequest() async throws {
        for _ in 0..<2_000 {
            if lock.withLock({ !pending.isEmpty }) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw Timeout()
    }

    func succeed(origin: String) throws {
        let siteOrigin = try #require(URL(string: origin).flatMap(SiteOrigin.init(url:)))
        let output = TuningOutput(
            tunedBasalHourly: Array(repeating: 1.0, count: 24),
            pumpBasalHourly: Array(repeating: 1.0, count: 24),
            untunedBasalHours: Array(repeating: false, count: 24),
            tunedISF: 50, pumpISF: 50, tunedCarbRatio: 10, pumpCarbRatio: 10,
            categoryCounts: [:], totalSamples: 10
        )
        let recommendation = try TuningRecommendation(from: output, daysAnalyzed: 1)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let diagnostics = RunDiagnostics(
            glucoseCount: 288, doseCount: 5, carbCount: 2,
            windowStart: start, windowEnd: start.addingTimeInterval(86_400),
            daySummaries: [], hourlyDeviation: [],
            meanAbsDeviationBefore: 4, meanAbsDeviationAfter: 3
        )
        resume(with: .success((recommendation, diagnostics, siteOrigin)))
    }

    func fail(_ error: Error) {
        resume(with: .failure(error))
    }

    private func resume(with result: Result<AnalysisOutput, Error>) {
        let continuation = lock.withLock { pending.removeFirst() }
        continuation.resume(with: result)
    }
}
