import Foundation
import Observation
import LoopTuneKit

/// Drives the tuning flow for the UI: holds the connection form state, runs the
/// pipeline off the main actor, and publishes the result.
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

    // Result
    var phase: Phase = .idle
    var recommendation: TuningRecommendation?

    var canRun: Bool {
        !urlString.trimmingCharacters(in: .whitespaces).isEmpty && phase != .running
    }

    func run() {
        guard canRun else { return }
        phase = .running
        recommendation = nil

        let urlString = self.urlString
        let credentials: NightscoutCredentials = token.isEmpty ? .none : .token(token)
        let config = TuningConfiguration(days: days, insulinType: insulinType)

        Task {
            do {
                let client = try NightscoutClient(rawURLString: urlString, credentials: credentials)
                let result = try await TuningPipeline().run(client: client, configuration: config, endingAt: Date())
                self.recommendation = result
                self.phase = .done
            } catch {
                self.phase = .failed(Self.describe(error))
            }
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
