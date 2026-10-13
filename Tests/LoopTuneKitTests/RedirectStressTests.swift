import Testing
import Foundation
@testable import LoopTuneKit

private let statusJSON = #"{"version":"15.0.0","settings":{"units":"mg/dL"}}"#

/// Runs many refused and followed redirects concurrently through the real
/// `URLSessionTransport` while other threads keep the CPU busy. Each fetch
/// must end as the redirect policy decides. A task that finishes with neither
/// a response nor an error traps inside `URLSession.data(for:delegate:)` and
/// kills the test process; a fake site that finishes before the redirect
/// delegate decides can also return the redirect response for a followed
/// redirect (#41). Before that fix, `fakeSites` failed in most runs of:
///
/// ```sh
/// LOOPTUNE_REDIRECT_STRESS=5000 swift test --filter RedirectStressTests/fakeSites
/// ```
///
/// The value is the number of rounds of 32 concurrent fetches. A loopback
/// round takes about two seconds, so use a smaller value for
/// `loopbackServers`. Too slow for the default run.
@Suite(
    "URLSessionTransport redirect stress",
    .enabled(if: RedirectStress.rounds > 0, "set LOOPTUNE_REDIRECT_STRESS=<rounds>")
)
struct RedirectStressTests {
    @Test("concurrent HTTPS redirects through fake sites end as the policy decides")
    func fakeSites() async throws {
        FakeSiteProtocol.register(host: "stress.site.example") { request in
            request.url?.path == "/moved"
                ? .json(statusJSON)
                : .redirect(status: 302, location: "https://stress.other.example/api/v1/status.json")
        }
        FakeSiteProtocol.register(host: "stress-same.site.example") { request in
            request.url?.path == "/moved"
                ? .json(statusJSON)
                : .redirect(status: 307, location: "/moved")
        }
        FakeSiteProtocol.register(host: "stress.other.example") { _ in .json(statusJSON) }
        let session = FakeSiteProtocol.session
        let refused = try NightscoutClient(
            rawURLString: "https://stress.site.example",
            credentials: .apiSecret("synthetic-secret"),
            transport: URLSessionTransport(session: session)
        )
        let followed = try NightscoutClient(
            rawURLString: "https://stress-same.site.example",
            credentials: .apiSecret("synthetic-secret"),
            transport: URLSessionTransport(session: session)
        )

        try await RedirectStress.run(refused: refused, followed: followed)
        #expect(FakeSiteProtocol.requests(to: "stress.other.example").isEmpty)
    }

    @Test("concurrent redirects between loopback servers end as the policy decides")
    func loopbackServers() async throws {
        let target = try await LocalHTTPServer.start { _ in .json(statusJSON) }
        let site = try await LocalHTTPServer.start { request in
            request.target.hasPrefix("/moved")
                ? .json(statusJSON)
                : .redirect(to: "http://localhost:\(target.port)/api/v1/status.json")
        }
        let same = try await LocalHTTPServer.start { request in
            request.target.hasPrefix("/moved") ? .json(statusJSON) : .redirect(307, to: "/moved")
        }
        let refused = try NightscoutClient(
            rawURLString: site.baseURL,
            credentials: .apiSecret("synthetic-secret"),
            transport: URLSessionTransport()
        )
        let followed = try NightscoutClient(
            rawURLString: same.baseURL,
            credentials: .apiSecret("synthetic-secret"),
            transport: URLSessionTransport()
        )

        try await RedirectStress.run(refused: refused, followed: followed)
        #expect(target.requests.isEmpty)
    }
}

private enum RedirectStress {
    static let rounds = Int(ProcessInfo.processInfo.environment["LOOPTUNE_REDIRECT_STRESS"] ?? "") ?? 0
    static let width = 32

    /// `rounds` batches of `width` concurrent fetches, alternating refused and
    /// followed redirects so both completion paths race each other.
    static func run(refused: NightscoutClient, followed: NightscoutClient) async throws {
        let load = CPULoad()
        defer { load.stop() }
        for _ in 0..<rounds {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<width {
                    group.addTask {
                        if index.isMultiple(of: 2) {
                            await #expect(throws: NightscoutError.disallowedRedirect) {
                                _ = try await refused.fetchStatus()
                            }
                        } else {
                            let status = try await followed.fetchStatus()
                            #expect(status.version == "15.0.0")
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}

/// Keeps every core busy so URLSession's queues contend for CPU, as they do
/// when the whole suite runs in parallel.
private final class CPULoad: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true

    init() {
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            Thread { [self] in
                var x = 0
                while isRunning { for i in 0..<10_000 { x &+= i } }
                _ = x
            }.start()
        }
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
    }
}
