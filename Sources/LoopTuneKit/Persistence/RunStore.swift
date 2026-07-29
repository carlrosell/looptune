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
        self.maxRuns = max(0, maxRuns)
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LoopTune/Runs", isDirectory: true)
    }

    /// Build a run id whose lexical order matches chronological order.
    public static func makeID(createdAt: Date) -> String {
        let rawMillis = createdAt.timeIntervalSince1970 * 1000
        let millis: Int64
        if rawMillis.isFinite,
           rawMillis >= Double(Int64.min),
           rawMillis < Double(Int64.max) {
            millis = Int64(rawMillis.rounded())
        } else {
            millis = 0
        }
        // Zero-pad to a fixed width so string sorting matches time order.
        // `%lld` is required for Int64 — `%d` truncates it to 32 bits.
        let stamp = String(format: "%015lld", millis)
        let suffix = String(UUID().uuidString.prefix(8))
        return "\(stamp)-\(suffix)"
    }

    @discardableResult
    public func save(_ run: SavedRun) -> Bool {
        guard Self.isSafeID(run.id) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONEncoder().encode(run)
            let url = fileURL(for: run.id)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
            .filter {
                $0.pathExtension == "json"
                    && Self.isSafeID($0.deletingPathExtension().lastPathComponent)
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap { url -> SavedRun? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(SavedRun.self, from: data)
            }
        return runs
    }

    @discardableResult
    public func delete(id: String) -> Bool {
        guard Self.isSafeID(id) else { return false }
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
            return true
        } catch {
            return false
        }
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

    /// IDs are filenames, not paths. Keeping this whitelist deliberately small
    /// prevents a decoded/imported run from escaping the runs directory.
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }
}
