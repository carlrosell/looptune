import Foundation

/// One cached UTC day of raw Nightscout documents for a site. Stored in wire
/// format so it round-trips through the same lenient decoders as live fetches
/// and stays inspectable on disk.
public struct CachedDay: Codable, Sendable {
    /// UTC day key, `yyyy-MM-dd`.
    public var day: String
    public var fetchedAt: Date
    public var entries: [NSEntry]
    public var treatments: [NSTreatment]
    /// Whether every entry and treatment in the day was retrieved. Days
    /// written before this was recorded decode as `false`: they came from a
    /// single count-limited query that may have been truncated.
    public var isComplete: Bool

    public init(
        day: String,
        fetchedAt: Date,
        entries: [NSEntry],
        treatments: [NSTreatment],
        isComplete: Bool = false
    ) {
        self.day = day
        self.fetchedAt = fetchedAt
        self.entries = entries
        self.treatments = treatments
        self.isComplete = isComplete
    }

    private enum CodingKeys: String, CodingKey {
        case day, fetchedAt, entries, treatments, isComplete = "complete"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(String.self, forKey: .day)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        entries = try container.decode([NSEntry].self, forKey: .entries)
        treatments = try container.decode([NSTreatment].self, forKey: .treatments)
        isComplete = try container.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false
    }
}

/// Persistent per-day cache of fetched Nightscout data.
///
/// Layout: `<directory>/v2/<site-origin>/<yyyy-MM-dd>.json`, one file per UTC
/// day, keyed by the site's full `SiteOrigin` (ADR 0003). The original layout,
/// `<directory>/<site-host>/<yyyy-MM-dd>.json`, ignored scheme and port and so
/// mixed sites on one host; its entries are never read and are deleted on prune.
///
/// Days are storage buckets, not analysis windows — the pipeline stitches
/// consecutive buckets back together, so bucketing in UTC keeps keys stable
/// even if the profile timezone changes.
///
/// The pipeline stores only days whose records were fetched completely and
/// reuses only days marked complete (ADR 0005).
///
/// A day is only cached once it has been over for `freshnessMargin` (default
/// 24 h), because Loop edits treatments retroactively (carb edits, temp-basal
/// reconciliation) for about a day. Files whose day is older than `maxAgeDays`
/// are deleted on prune — matching the 30-day maximum analysis window.
public struct DayCache: Sendable {
    public let directory: URL
    public let maxAgeDays: Int
    /// How long after a day ends before it is considered final and cacheable.
    public let freshnessMargin: TimeInterval

    /// Seconds in a UTC day (no DST in UTC).
    static let dayLength: TimeInterval = 86_400

    /// Subdirectory holding the current origin-keyed layout.
    static let layoutDirectoryName = "v2"

    public init(
        directory: URL? = nil,
        maxAgeDays: Int = 30,
        freshnessMargin: TimeInterval = 24 * 3600
    ) {
        self.directory = directory ?? Self.defaultDirectory()
        self.maxAgeDays = max(0, maxAgeDays)
        self.freshnessMargin = max(0, freshnessMargin)
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LoopTune/DayCache", isDirectory: true)
    }

    // MARK: - Load / store

    public func load(origin: SiteOrigin, dayKey: String) -> CachedDay? {
        guard Self.isValidDayKey(dayKey) else { return nil }
        let url = fileURL(origin: origin, dayKey: dayKey)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let cached = try? JSONDecoder().decode(CachedDay.self, from: data) else {
            // Corrupt or outdated format: drop it so it refetches.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return cached
    }

    public func store(_ cachedDay: CachedDay, origin: SiteOrigin) {
        guard Self.isValidDayKey(cachedDay.day) else { return }
        let url = fileURL(origin: origin, dayKey: cachedDay.day)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.deletingLastPathComponent().path
            )
            let data = try JSONEncoder().encode(cachedDay)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Caching is best-effort; a failed write only costs a refetch.
        }
    }

    /// Whether a day bucket ending at `dayEnd` is final enough to cache.
    public func shouldStore(dayEnd: Date, now: Date = Date()) -> Bool {
        dayEnd <= now.addingTimeInterval(-freshnessMargin)
    }

    // MARK: - Eviction

    /// Delete every cached day older than `maxAgeDays`, across all sites, and
    /// every day stored in the hostname-only layout.
    public func pruneExpired(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-TimeInterval(maxAgeDays) * Self.dayLength)
        for siteDirectory in subdirectories(of: layoutDirectory) {
            removeDayFiles(in: siteDirectory) { $0 < cutoff }
        }
        removeLegacyEntries()
    }

    /// Delete day files from the hostname-only layout. Only day-named JSON
    /// files and the directories they leave empty are removed.
    private func removeLegacyEntries() {
        for hostDirectory in subdirectories(of: directory)
        where hostDirectory.lastPathComponent != Self.layoutDirectoryName {
            removeDayFiles(in: hostDirectory) { _ in true }
            let remaining = try? FileManager.default.contentsOfDirectory(atPath: hostDirectory.path)
            if remaining?.isEmpty == true {
                try? FileManager.default.removeItem(at: hostDirectory)
            }
        }
    }

    private func subdirectories(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func removeDayFiles(in directory: URL, where shouldRemove: (Date) -> Bool) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            guard Self.isValidDayKey(key), let dayStart = Self.parseDayKey(key) else { continue }
            if shouldRemove(dayStart) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Day bucket math (UTC)

    /// Tile `[start, end]` with UTC day buckets (first and last cover the
    /// containing days fully, so keys are stable across runs).
    public static func utcDayBuckets(covering start: Date, to end: Date) -> [(key: String, interval: DateInterval)] {
        guard start <= end else { return [] }
        var buckets: [(String, DateInterval)] = []
        var dayStart = floorToUTCDay(start)
        while dayStart < end {
            let dayEnd = dayStart.addingTimeInterval(dayLength)
            buckets.append((dayKey(for: dayStart), DateInterval(start: dayStart, end: dayEnd)))
            dayStart = dayEnd
        }
        return buckets
    }

    static func floorToUTCDay(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / dayLength).rounded(.down) * dayLength)
    }

    static func dayKey(for dayStart: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: dayStart)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func parseDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func isValidDayKey(_ key: String) -> Bool {
        guard key.count == 10, let date = parseDayKey(key) else { return false }
        return dayKey(for: date) == key
    }

    var layoutDirectory: URL {
        directory.appendingPathComponent(Self.layoutDirectoryName, isDirectory: true)
    }

    func fileURL(origin: SiteOrigin, dayKey: String) -> URL {
        layoutDirectory
            .appendingPathComponent(Self.directoryName(for: origin), isDirectory: true)
            .appendingPathComponent(dayKey)
            .appendingPathExtension("json")
    }

    /// A readable directory name that is distinct for every origin, such as
    /// `http_localhost_1337`. The host keeps only `a-z`, `0-9`, `.`, and `-`;
    /// other bytes are percent-encoded, so `_` separates the parts unambiguously.
    static func directoryName(for origin: SiteOrigin) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-".utf8)
        let host = origin.host.utf8.map { byte in
            allowed.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
        return "\(origin.scheme)_\(host)_\(origin.port)"
    }
}
