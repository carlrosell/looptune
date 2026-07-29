import ArgumentParser
import Foundation
import LoopTuneKit

@main
struct LoopTuneCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "looptune",
        abstract: "Recommend tuned Loop settings (basal, ISF, carb ratio) from Nightscout data.",
        version: LoopTuneKit.version,
        subcommands: [Tune.self, Fetch.self]
    )
}

/// Shared Nightscout connection options.
struct ConnectionOptions: ParsableArguments {
    @Argument(help: "Nightscout site URL (e.g. https://mysite.herokuapp.com).")
    var url: String

    @Option(name: .long, help: "Nightscout access token (prefer the LOOPTUNE_TOKEN environment variable so it is not exposed in process arguments).")
    var token: String?

    @Option(name: .long, help: "Nightscout API secret (prefer LOOPTUNE_API_SECRET; sent as a SHA-1 api-secret header).")
    var apiSecret: String?

    func makeClient() throws -> NightscoutClient {
        let environment = ProcessInfo.processInfo.environment
        let effectiveToken = token ?? environment["LOOPTUNE_TOKEN"]
        let effectiveSecret = apiSecret ?? environment["LOOPTUNE_API_SECRET"]
        guard effectiveToken == nil || effectiveSecret == nil else {
            throw ValidationError("Provide either a Nightscout token or an API secret, not both.")
        }
        let credentials: NightscoutCredentials
        if let effectiveToken { credentials = .token(effectiveToken) }
        else if let effectiveSecret { credentials = .apiSecret(effectiveSecret) }
        else { credentials = .none }
        return try NightscoutClient(rawURLString: url, credentials: credentials)
    }
}

struct Tune: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Fetch data and print tuning recommendations.")

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .long, help: "Days of history to analyze (1-30).")
    var days: Int = 7

    @Option(name: .long, help: "Insulin type: novolog, humalog, apidra, fiasp, lyumjev, afrezza.")
    var insulin: String = "novolog"

    @Option(name: .long, help: "Display units: auto (site default), mgdl, or mmol.")
    var units: String = "auto"

    @Option(name: .long, help: "Pump basal increment for the Rounded column (Loop default 0.05 U/hr).")
    var basalIncrement: Double = 0.05

    @Flag(name: .long, help: "Emit the recommendation as JSON instead of a table.")
    var json = false

    @Flag(name: .long, help: "Bypass the local day cache and fetch everything from Nightscout.")
    var noCache = false

    func run() async throws {
        guard (1...30).contains(days) else {
            throw ValidationError("days must be between 1 and 30")
        }
        let client = try connection.makeClient()
        guard let insulinType = InsulinType(rawValue: insulin.lowercased()) else {
            throw ValidationError("Unknown insulin type: \(insulin)")
        }
        let displayUnit = try Self.parseUnits(units)
        guard basalIncrement.isFinite, basalIncrement > 0, basalIncrement <= 1 else {
            throw ValidationError("basal-increment must be between 0 and 1 U/hr")
        }
        let config = TuningConfiguration(days: days, insulinType: insulinType)
        let cache: DayCache? = noCache ? nil : DayCache()
        let recommendation = try await TuningPipeline().run(client: client, configuration: config, endingAt: Date(), cache: cache)

        if json {
            print(try RecommendationJSON.encode(recommendation, displayUnit: displayUnit, basalIncrement: basalIncrement))
        } else {
            print(TuningReport.render(recommendation, displayUnit: displayUnit, basalIncrement: basalIncrement))
        }
    }

    /// `nil` = auto (use the site's own unit).
    static func parseUnits(_ raw: String) throws -> GlucoseUnit? {
        switch raw.lowercased() {
        case "auto": return nil
        case "mgdl", "mg/dl": return .milligramsPerDeciliter
        case "mmol", "mmol/l": return .millimolesPerLiter
        default: throw ValidationError("Unknown units: \(raw) (use auto, mgdl, or mmol)")
        }
    }
}

struct Fetch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Fetch and print normalized Nightscout data (diagnostic).")

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .long, help: "Days of history to fetch (1-30).")
    var days: Int = 7

    @Flag(name: .long, help: "Bypass the local day cache and fetch everything from Nightscout.")
    var noCache = false

    func run() async throws {
        guard (1...30).contains(days) else {
            throw ValidationError("days must be between 1 and 30")
        }
        let client = try connection.makeClient()
        let authorized = await client.checkAuthorized()
        FileHandle.standardError.write(Data("authorized: \(authorized)\n".utf8))
        let inputs = try await TuningPipeline().fetchInputs(
            client: client,
            configuration: TuningConfiguration(days: days),
            endingAt: Date(),
            cache: noCache ? nil : DayCache()
        )
        print("glucose samples: \(inputs.glucose.count)")
        print("doses: \(inputs.doses.count)")
        print("carbs: \(inputs.carbs.count)")
        print("overrides: \(inputs.overrides.count)")
        print("timezone: \(inputs.profile.timeZone.identifier)")
        print("units: \(inputs.profile.glucoseUnit.rawValue)")
    }
}
