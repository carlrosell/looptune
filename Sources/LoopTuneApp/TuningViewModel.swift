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
    var urlString: String = "" {
        didSet {
            guard !isRestoring else { return }
            let oldAccount = CredentialStore.accountKey(from: oldValue)
            let newAccount = CredentialStore.accountKey(from: urlString)
            if oldAccount != newAccount {
                token = newAccount.flatMap(store.token(forHost:)) ?? ""
            }
        }
    }
    var token: String = ""
    var days: Int = 7
    var insulinType: InsulinType = .novolog

    // State
    var phase: Phase = .idle
    var notice: String?
    /// Saved runs, newest first (the sidebar list).
    var runs: [SavedRun] = []
    /// The run currently shown in the detail pane.
    var selectedRunID: String?

    private let store: any ConnectionSettingsStore
    private let runStore: RunStore
    private let runner: AnalysisRunner
    private var isRestoring = false
    /// The analysis in flight, if any. Tests await it to observe completion.
    @ObservationIgnored private(set) var runTask: Task<Void, Never>?

    var selectedRun: SavedRun? {
        runs.first { $0.id == selectedRunID }
    }

    init(
        store: any ConnectionSettingsStore = CredentialStore(),
        runStore: RunStore = RunStore(),
        runner: @escaping AnalysisRunner = liveAnalysis
    ) {
        self.store = store
        self.runStore = runStore
        self.runner = runner
        isRestoring = true
        restore()
        isRestoring = false
        runs = runStore.loadAll()
        selectedRunID = runs.first?.id
    }

    /// True while an analysis is pending. The sidebar locks the connection and
    /// analysis settings so the form keeps showing the request in flight.
    var isRunning: Bool {
        phase == .running
    }

    var canRun: Bool {
        !urlString.trimmingCharacters(in: .whitespaces).isEmpty && !isRunning
    }

    /// Restore the last-used connection settings (token from the Keychain).
    private func restore() {
        if let saved = store.restoreURL() {
            urlString = saved
            if let host = CredentialStore.accountKey(from: saved), let savedToken = store.token(forHost: host) {
                token = savedToken
            }
        }
        if let savedDays = store.days { days = savedDays }
        if let raw = store.insulinTypeRaw, let type = InsulinType(rawValue: raw) { insulinType = type }
    }

    /// Persist the settings that produced a successful analysis (token to the
    /// Keychain). They come from the request captured at start, never the live
    /// form, so an edit made while the run was pending cannot be saved as the
    /// successful configuration or delete the token that worked.
    private func persistSettings(from request: AnalysisRequest) {
        if let sanitized = CredentialStore.sanitizedURLString(request.urlString) {
            store.urlString = sanitized
            if urlString == request.urlString {
                urlString = sanitized
            }
        }
        store.days = request.configuration.days
        store.insulinTypeRaw = request.configuration.insulinType.rawValue
        if let host = CredentialStore.accountKey(from: request.urlString),
           !store.saveToken(request.token, forHost: host) {
            notice = "The analysis succeeded, but the access token could not be saved to Keychain."
        }
    }

    func run() {
        guard canRun else { return }
        phase = .running
        notice = nil

        let request = AnalysisRequest(
            urlString: urlString,
            token: token,
            configuration: TuningConfiguration(days: days, insulinType: insulinType),
            endingAt: Date()
        )
        let runner = self.runner

        runTask = Task {
            do {
                let output = try await runner(request)

                let run = SavedRun(
                    id: RunStore.makeID(createdAt: request.endingAt),
                    createdAt: request.endingAt,
                    origin: output.origin,
                    days: request.configuration.days,
                    insulinType: request.configuration.insulinType,
                    recommendation: output.recommendation,
                    diagnostics: output.diagnostics
                )
                if !self.runStore.save(run) {
                    self.notice = "The analysis succeeded, but its history file could not be saved."
                }
                self.runs.insert(run, at: 0)
                self.selectedRunID = run.id
                self.phase = .done
                self.persistSettings(from: request)
            } catch {
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    func deleteRun(id: String) {
        guard runStore.delete(id: id) else {
            notice = "That saved analysis could not be deleted."
            return
        }
        runs.removeAll { $0.id == id }
        if selectedRunID == id {
            selectedRunID = runs.first?.id
        }
    }

    /// The failure text the app shows. It never includes text carried by the
    /// error, such as a failing request URL with its access token.
    static func describe(_ error: Error) -> String {
        ErrorMessage.describe(error)
    }
}
