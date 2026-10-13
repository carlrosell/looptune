import Foundation
import LoopTuneKit

/// The connection and analysis settings captured when a run starts. A
/// successful run persists exactly these values, never the live form.
struct AnalysisRequest: Sendable {
    var urlString: String
    var token: String
    var configuration: TuningConfiguration
    var endingAt: Date

    var credentials: NightscoutCredentials {
        token.isEmpty ? .none : .token(token)
    }
}

typealias AnalysisOutput = (recommendation: TuningRecommendation, diagnostics: RunDiagnostics, host: String)

/// Executes one analysis. The app uses `liveAnalysis`; tests substitute a runner
/// whose completion they control.
typealias AnalysisRunner = @Sendable (AnalysisRequest) async throws -> AnalysisOutput

/// Fetches from Nightscout and runs the pipeline off the main actor.
@Sendable
func liveAnalysis(_ request: AnalysisRequest) async throws -> AnalysisOutput {
    try await Task.detached(priority: .userInitiated) {
        let client = try NightscoutClient(rawURLString: request.urlString, credentials: request.credentials)
        // Finished days are served from the local day cache; the current day
        // is always fetched fresh.
        return try await TuningPipeline().runWithDiagnostics(
            client: client,
            configuration: request.configuration,
            endingAt: request.endingAt,
            cache: DayCache()
        )
    }.value
}

/// Where the connection form is remembered between launches. `CredentialStore`
/// is the live store; tests substitute one that touches neither the Keychain
/// nor UserDefaults.
protocol ConnectionSettingsStore {
    var urlString: String? { get nonmutating set }
    var days: Int? { get nonmutating set }
    var insulinTypeRaw: String? { get nonmutating set }
    /// The saved URL with any user information removed. See ADR 0009.
    func restoreURL() -> String?
    func saveToken(_ token: String?, forHost host: String) -> Bool
    func token(forHost host: String) -> String?
}

extension CredentialStore: ConnectionSettingsStore {}
