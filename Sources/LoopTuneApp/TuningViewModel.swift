import Foundation
import Observation
import LoopTuneKit

/// Drives the tuning flow for the UI: holds the connection form state, runs the
/// pipeline off the main actor, persists completed runs, and exposes the run
/// history for the sidebar.
@MainActor
@Observable
final class TuningViewModel {
    enum Phase: Equatable {
        case idle
        case running
        case done
        case failed(String)
    }

    // Connection form
    var urlString: String = ""
    var token: String = ""
    var days: Int = 7
    var insulinType: InsulinType = .novolog

    // State
    var phase: Phase = .idle
    /// Saved runs, newest first (the sidebar list).
    var runs: [SavedRun] = []
    /// The run currently shown in the detail pane.
    var selectedRunID: String?

    private let store: CredentialStore
    private let runStore: RunStore

    var selectedRun: SavedRun? {
        runs.first { $0.id == selectedRunID }
    }

    init(store: CredentialStore = CredentialStore(), runStore: RunStore = RunStore()) {
        self.store = store
        self.runStore = runStore
        restore()
        runs = runStore.loadAll()
        selectedRunID = runs.first?.id
    }

    var canRun: Bool {
        !urlString.trimmingCharacters(in: .whitespaces).isEmpty && phase != .running
    }

    /// Restore the last-used connection settings (token from the Keychain).
    private func restore() {
        if let saved = store.urlString {
            urlString = saved
            if let host = CredentialStore.host(from: saved), let savedToken = store.token(forHost: host) {
                token = savedToken
            }
        }
        if let savedDays = store.days { days = savedDays }
        if let raw = store.insulinTypeRaw, let type = InsulinType(rawValue: raw) { insulinType = type }
    }

    /// Persist settings after a successful analysis (token to the Keychain).
    private func persistSettings() {
        store.urlString = urlString
        store.days = days
        store.insulinTypeRaw = insulinType.rawValue
        if let host = CredentialStore.host(from: urlString) {
            store.saveToken(token, forHost: host)
        }
    }

    func run() {
        guard canRun else { return }
        phase = .running

        let urlString = self.urlString
        let credentials: NightscoutCredentials = token.isEmpty ? .none : .token(token)
        let config = TuningConfiguration(days: days, insulinType: insulinType)
        let now = Date()

        Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    let client = try NightscoutClient(rawURLString: urlString, credentials: credentials)
                    // Finished days are served from the local day cache; the
                    // current day is always fetched fresh.
                    return try await TuningPipeline().runWithDiagnostics(client: client, configuration: config, endingAt: now, cache: DayCache())
                }.value

                let run = SavedRun(
                    id: RunStore.makeID(createdAt: now),
                    createdAt: now,
                    siteHost: output.host,
                    days: config.days,
                    insulinType: config.insulinType,
                    recommendation: output.recommendation,
                    diagnostics: output.diagnostics
                )
                self.runStore.save(run)
                self.runs.insert(run, at: 0)
                self.selectedRunID = run.id
                self.phase = .done
                self.persistSettings()
            } catch {
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    func deleteRun(id: String) {
        runStore.delete(id: id)
        runs.removeAll { $0.id == id }
        if selectedRunID == id {
            selectedRunID = runs.first?.id
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case NightscoutError.unauthorized:
            return "Not authorized. Check your access token."
        case NightscoutError.invalidURL:
            return "That doesn't look like a valid Nightscout URL."
        case let NightscoutError.httpStatus(code):
            return "Nightscout returned HTTP \(code)."
        case TuningPipeline.PipelineError.noProfile:
            return "No profile found on this Nightscout site."
        case TuningPipeline.PipelineError.noGlucose:
            return "Not enough glucose data in the selected window."
        default:
            return "\(error)"
        }
    }
}
