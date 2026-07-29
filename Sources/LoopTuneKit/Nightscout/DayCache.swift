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

    public init(day: String, fetchedAt: Date, entries: [NSEntry], treatments: [NSTreatment]) {
        self.day = day
        self.fetchedAt = fetchedAt
        self.entries = entries
        self.treatments = treatments
    }
}

/// Persistent per-day cache of fetched Nightscout data.
///
/// Layout: `<directory>/<site-host>/<yyyy-MM-dd>.json`, one file per UTC day.
/// Days are storage buckets, not analysis windows — the pipeline stitches
/// consecutive buckets back together, so bucketing in UTC keeps keys stable
/// even if the profile timezone changes.
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

    public func load(host: String, dayKey: String) -> CachedDay? {
        guard Self.isValidDayKey(dayKey) else { return nil }
        let url = fileURL(host: host, dayKey: dayKey)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let cached = try? JSONDecoder().decode(CachedDay.self, from: data) else {
            // Corrupt or outdated format: drop it so it refetches.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return cached
    }

    public func store(_ cachedDay: CachedDay, host: String) {
        guard Self.isValidDayKey(cachedDay.day) else { return }
        let url = fileURL(host: host, dayKey: cachedDay.day)
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

    /// Delete every cached day older than `maxAgeDays`, across all hosts.
    public func pruneExpired(now: Date = Date()) {
        let fileManager = FileManager.default
        guard let hosts = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        let cutoff = now.addingTimeInterval(-TimeInterval(maxAgeDays) * Self.dayLength)
        for hostDirectory in hosts {
            guard let files = try? fileManager.contentsOfDirectory(at: hostDirectory, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.pathExtension == "json" {
                let key = file.deletingPathExtension().lastPathComponent
                guard let dayStart = Self.parseDayKey(key) else { continue }
                if dayStart < cutoff {
                    try? fileManager.removeItem(at: file)
                }
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

    func fileURL(host: String, dayKey: String) -> URL {
        directory
            .appendingPathComponent(Self.sanitize(host), isDirectory: true)
            .appendingPathComponent(dayKey)
            .appendingPathExtension("json")
    }

    /// Make a host string safe as a directory name.
    static func sanitize(_ host: String) -> String {
        String(host.lowercased().map { character in
            character.isLetter || character.isNumber || character == "." || character == "-" ? character : "_"
        })
    }
}
