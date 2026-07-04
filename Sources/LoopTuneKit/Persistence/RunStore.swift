import Foundation

/// Persists completed runs so the app can list and revisit them. Runs are
/// stored as one JSON file per run under Application Support; the filename is
/// prefixed with the creation time so the directory listing sorts newest-first
/// without reading each file. The newest `maxRuns` are kept.
public struct RunStore: Sendable {
    public let directory: URL
    public let maxRuns: Int

    public init(directory: URL? = nil, maxRuns: Int = 50) {
        self.directory = directory ?? Self.defaultDirectory()
        self.maxRuns = maxRuns
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LoopTune/Runs", isDirectory: true)
    }

    /// Build a run id whose lexical order matches chronological order.
    public static func makeID(createdAt: Date) -> String {
        let millis = Int64((createdAt.timeIntervalSince1970 * 1000).rounded())
        // Zero-pad to a fixed width so string sorting matches time order.
        // `%lld` is required for Int64 — `%d` truncates it to 32 bits.
        let stamp = String(format: "%015lld", millis)
        let suffix = String(UUID().uuidString.prefix(8))
        return "\(stamp)-\(suffix)"
    }

    @discardableResult
    public func save(_ run: SavedRun) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(run)
            try data.write(to: fileURL(for: run.id), options: .atomic)
            enforceLimit()
            return true
        } catch {
            return false
        }
    }

    /// All saved runs, newest first.
    public func loadAll() -> [SavedRun] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let runs = files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap { url -> SavedRun? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(SavedRun.self, from: data)
            }
        return runs
    }

    public func delete(id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    /// Trim to the newest `maxRuns` files.
    private func enforceLimit() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        let jsonFiles = files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard jsonFiles.count > maxRuns else { return }
        for file in jsonFiles[maxRuns...] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("json")
    }
}
