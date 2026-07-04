import ArgumentParser
import LoopTuneKit

@main
struct LoopTuneCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "looptune",
        abstract: "Recommend tuned Loop settings (basal, ISF, carb ratio) from Nightscout data.",
        version: LoopTuneKit.version
    )

    func run() async throws {
        print("looptune \(LoopTuneKit.version) — see `looptune --help` once subcommands land.")
    }
}
