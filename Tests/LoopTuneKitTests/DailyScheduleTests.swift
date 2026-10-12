import Testing
import Foundation
import LoopAlgorithm
@testable import LoopTuneKit

@Suite("DailySchedule")
struct DailyScheduleTests {
    // A UTC "day" schedule: 0.8 from midnight, 1.0 from 06:00, 0.7 from 22:00.
    private func makeSchedule() throws -> DailySchedule<Double> {
        try DailySchedule(entries: [
            .init(secondsSinceMidnight: 0, value: 0.8),
            .init(secondsSinceMidnight: 6 * 3600, value: 1.0),
            .init(secondsSinceMidnight: 22 * 3600, value: 0.7),
        ])
    }

    @Test("rejects a schedule without a midnight entry")
    func requiresMidnight() {
        #expect(throws: DailySchedule<Double>.ScheduleError.self) {
            try DailySchedule(entries: [.init(secondsSinceMidnight: 3600, value: 1.0)])
        }
    }

    @Test("rejects an empty schedule")
    func rejectsEmpty() {
        #expect(throws: DailySchedule<Double>.ScheduleError.self) {
            try DailySchedule<Double>(entries: [])
        }
    }

    @Test("duplicate offsets keep the last value")
    func duplicateOffsetsKeepLast() throws {
        let schedule = try DailySchedule(entries: [
            .init(secondsSinceMidnight: 0, value: 0.8),
            .init(secondsSinceMidnight: 3600, value: 0.9),
            .init(secondsSinceMidnight: 3600, value: 1.1),
        ])
        #expect(schedule.value(atSecondsSinceMidnight: 3600) == 1.1)
    }

    @Test("collapses adjacent equal values")
    func collapsesEqualBlocks() throws {
        let schedule = try DailySchedule(entries: [
            .init(secondsSinceMidnight: 0, value: 0.8),
            .init(secondsSinceMidnight: 3600, value: 0.8),
            .init(secondsSinceMidnight: 7200, value: 0.9),
        ])
        #expect(schedule.entries.count == 2)
    }

    @Test("time-of-day lookup returns the active block")
    func timeOfDayLookup() throws {
        let schedule = try makeSchedule()
        #expect(schedule.value(atSecondsSinceMidnight: 0) == 0.8)
        #expect(schedule.value(atSecondsSinceMidnight: 6 * 3600 - 1) == 0.8)
        #expect(schedule.value(atSecondsSinceMidnight: 6 * 3600) == 1.0)
        #expect(schedule.value(atSecondsSinceMidnight: 21 * 3600) == 1.0)
        #expect(schedule.value(atSecondsSinceMidnight: 22 * 3600) == 0.7)
        #expect(schedule.value(atSecondsSinceMidnight: 86_399) == 0.7)
    }

    @Test("Entry(time:) parses HH:mm and HH:mm:ss")
    func entryTimeParsing() throws {
        #expect(DailySchedule.Entry(time: "06:30", value: 1.0)?.secondsSinceMidnight == 6 * 3600 + 30 * 60)
        #expect(DailySchedule.Entry(time: "22:00:15", value: 1.0)?.secondsSinceMidnight == 22 * 3600 + 15)
        #expect(DailySchedule.Entry(time: "nope", value: 1.0) == nil)
        #expect(DailySchedule.Entry(time: "25:00", value: 1.0) == nil)
    }

    @Test("expansion tiles the window contiguously")
    func expansionContiguous() throws {
        let schedule = try makeSchedule()
        let utc = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 0)          // 1970-01-01 00:00 UTC
        let end = start.addingTimeInterval(48 * 3600)       // two days later
        let timeline = schedule.expand(from: start, to: end, timeZone: utc)

        #expect(timeline.first?.startDate == start)
        #expect(timeline.last?.endDate == end)
        // Contiguous: each segment starts where the previous ended.
        for index in 1..<timeline.count {
            #expect(timeline[index].startDate == timeline[index - 1].endDate)
        }
        // Two days × 3 blocks = 6 segments.
        #expect(timeline.count == 6)
        #expect(timeline[0].value == 0.8)
        #expect(timeline[1].value == 1.0)
        #expect(timeline[2].value == 0.7)
    }

    @Test("expansion boundaries land at correct absolute instants (UTC)")
    func expansionBoundaries() throws {
        let schedule = try makeSchedule()
        let utc = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(24 * 3600)
        let timeline = schedule.expand(from: start, to: end, timeZone: utc)

        #expect(timeline[1].startDate == start.addingTimeInterval(6 * 3600))
        #expect(timeline[2].startDate == start.addingTimeInterval(22 * 3600))
    }

    @Test("a nonexistent 02:00 spring-forward block starts at the first valid instant")
    func expansionDST() throws {
        // US spring-forward 2023-03-12: 02:00 -> 03:00 in America/New_York.
        let schedule = try DailySchedule(entries: [
            .init(secondsSinceMidnight: 0, value: 0.8),
            .init(secondsSinceMidnight: 2 * 3600, value: 1.0),
            .init(secondsSinceMidnight: 12 * 3600, value: 0.9),
        ])
        let tz = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let dayStart = calendar.date(from: DateComponents(year: 2023, month: 3, day: 12, hour: 0, minute: 0))!
        let dayEnd = calendar.date(from: DateComponents(year: 2023, month: 3, day: 13, hour: 0, minute: 0))!

        let timeline = schedule.expand(from: dayStart, to: dayEnd, timeZone: tz)

        // 02:00 does not exist on this date. The 1.0 block starts at the
        // transition, the first valid instant, which reads as 03:00 local.
        let postJumpSegment = timeline.first { $0.value == 1.0 }
        #expect(postJumpSegment != nil)
        #expect(DailySchedule<Double>.secondsSinceMidnight(of: postJumpSegment!.startDate, in: tz) == 3 * 3600)

        // Every segment's start should read back as the right local wall-clock offset.
        for segment in timeline {
            let seconds = DailySchedule<Double>.secondsSinceMidnight(of: segment.startDate, in: tz)
            // Its value must equal the schedule looked up at that local time.
            #expect(segment.value == schedule.value(atSecondsSinceMidnight: seconds))
        }
        // The 12:00 block start is exactly noon local even though the day is 23h long.
        let noonSegment = timeline.first { $0.value == 0.9 }
        let noonSeconds = DailySchedule<Double>.secondsSinceMidnight(of: noonSegment!.startDate, in: tz)
        #expect(noonSeconds == 12 * 3600)
        // And the whole day is 23 hours (spring-forward), tiled contiguously.
        #expect(timeline.last!.endDate.timeIntervalSince(timeline.first!.startDate) == 23 * 3600)
    }

    // MARK: - Daylight-saving agreement

    private static func utc(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    private static func schedule(_ entries: [(String, Double)]) throws -> DailySchedule<Double> {
        try DailySchedule(entries: entries.map { DailySchedule.Entry(time: $0.0, value: $0.1)! })
    }

    /// Expands `[start, end]` and checks the timeline is clipped, contiguous and
    /// merged, and that it gives the direct-lookup value every minute and one
    /// second either side of every cut and offset transition.
    private func expectExpansionMatchesLookup(
        _ schedule: DailySchedule<Double>,
        timeZone: TimeZone,
        from start: Date,
        to end: Date,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> [AbsoluteScheduleValue<Double>] {
        let timeline = schedule.expand(from: start, to: end, timeZone: timeZone)
        #expect(timeline.first?.startDate == start, sourceLocation: sourceLocation)
        #expect(timeline.last?.endDate == end, sourceLocation: sourceLocation)
        for segment in timeline {
            #expect(segment.startDate < segment.endDate, sourceLocation: sourceLocation)
        }
        for index in timeline.indices.dropFirst() {
            #expect(timeline[index].startDate == timeline[index - 1].endDate, sourceLocation: sourceLocation)
            #expect(timeline[index].value != timeline[index - 1].value, sourceLocation: sourceLocation)
        }

        var probes = Array(stride(from: start, to: end, by: 60))
        var transition = timeZone.nextDaylightSavingTimeTransition(after: start)
        while let instant = transition, instant < end {
            probes.append(instant)
            transition = timeZone.nextDaylightSavingTimeTransition(after: instant)
        }
        for segment in timeline {
            probes += [-1, 0, 1].map { segment.startDate.addingTimeInterval($0) }
        }
        for probe in probes where probe >= start && probe < end {
            let expanded = timeline.first { $0.startDate <= probe && probe < $0.endDate }?.value
            let direct = schedule.value(at: probe, timeZone: timeZone)
            #expect(
                expanded == direct,
                "\(ISO8601DateFormatter().string(from: probe)): expanded \(String(describing: expanded)), direct \(direct)",
                sourceLocation: sourceLocation
            )
        }
        return timeline
    }

    @Test("fall-back expansion follows both passes through the repeated hour")
    func expansionFallBackRepeatedHour() throws {
        // America/New_York 2026-11-01: 02:00 EDT (06:00Z) returns to 01:00 EST.
        let schedule = try Self.schedule([("00:00", 1), ("01:30", 2), ("02:00", 3)])
        let tz = TimeZone(identifier: "America/New_York")!
        let start = Self.utc("2026-11-01T04:00:00Z")
        let end = Self.utc("2026-11-01T09:00:00Z")

        let timeline = expectExpansionMatchesLookup(schedule, timeZone: tz, from: start, to: end)

        // The second local 01:15 is still in the midnight block.
        let secondQuarterPastOne = Self.utc("2026-11-01T06:15:00Z")
        #expect(schedule.value(at: secondQuarterPastOne, timeZone: tz) == 1)
        #expect(timeline.first { $0.startDate <= secondQuarterPastOne && secondQuarterPastOne < $0.endDate }?.value == 1)

        // 01:30 occurs twice and the clock transition is a cut.
        #expect(timeline.map(\.startDate) == [
            start,
            Self.utc("2026-11-01T05:30:00Z"),  // 01:30 EDT
            Self.utc("2026-11-01T06:00:00Z"),  // 02:00 EDT becomes 01:00 EST
            Self.utc("2026-11-01T06:30:00Z"),  // 01:30 EST
            Self.utc("2026-11-01T07:00:00Z"),  // 02:00 EST
        ])
        #expect(timeline.map(\.value) == [1, 2, 1, 2, 3])
    }

    @Test("spring-forward expansion starts a skipped block at the clock transition")
    func expansionSpringForwardSkippedBoundary() throws {
        // America/New_York 2026-03-08: 02:00 EST (07:00Z) jumps to 03:00 EDT, so
        // 02:30 never occurs and 03:00 local is the transition instant.
        let schedule = try Self.schedule([("00:00", 1), ("01:30", 2), ("02:30", 3), ("04:00", 4)])
        let tz = TimeZone(identifier: "America/New_York")!
        let start = Self.utc("2026-03-08T05:00:00Z")
        let end = Self.utc("2026-03-08T10:00:00Z")

        let timeline = expectExpansionMatchesLookup(schedule, timeZone: tz, from: start, to: end)

        #expect(timeline.map(\.startDate) == [
            start,
            Self.utc("2026-03-08T06:30:00Z"),  // 01:30 EST
            Self.utc("2026-03-08T07:00:00Z"),  // 02:00 EST becomes 03:00 EDT
            Self.utc("2026-03-08T08:00:00Z"),  // 04:00 EDT
        ])
        #expect(timeline.map(\.value) == [1, 2, 3, 4])
    }

    @Test("expansion agrees with lookup through Lord Howe's 30-minute shifts")
    func expansionHalfHourShift() throws {
        let tz = TimeZone(identifier: "Australia/Lord_Howe")!

        // 2026-04-05: 02:00 +11:00 (15:00Z) returns to 01:30 +10:30.
        let fallBack = try Self.schedule([("00:00", 1), ("01:45", 2), ("02:00", 3)])
        let fallBackTimeline = expectExpansionMatchesLookup(
            fallBack, timeZone: tz,
            from: Self.utc("2026-04-04T13:00:00Z"), to: Self.utc("2026-04-04T17:00:00Z")
        )
        #expect(fallBackTimeline.map(\.startDate) == [
            Self.utc("2026-04-04T13:00:00Z"),  // local midnight
            Self.utc("2026-04-04T14:45:00Z"),  // first 01:45
            Self.utc("2026-04-04T15:00:00Z"),  // 02:00 becomes 01:30
            Self.utc("2026-04-04T15:15:00Z"),  // second 01:45
            Self.utc("2026-04-04T15:30:00Z"),  // 02:00
        ])
        #expect(fallBackTimeline.map(\.value) == [1, 2, 1, 2, 3])

        // 2026-10-04: 02:00 +10:30 (15:30Z) jumps to 02:30 +11:00.
        let springForward = try Self.schedule([("00:00", 1), ("02:15", 2), ("03:00", 3)])
        let springTimeline = expectExpansionMatchesLookup(
            springForward, timeZone: tz,
            from: Self.utc("2026-10-03T13:30:00Z"), to: Self.utc("2026-10-03T17:00:00Z")
        )
        #expect(springTimeline.map(\.startDate) == [
            Self.utc("2026-10-03T13:30:00Z"),  // local midnight
            Self.utc("2026-10-03T15:30:00Z"),  // 02:00 becomes 02:30
            Self.utc("2026-10-03T16:00:00Z"),  // 03:00
        ])
        #expect(springTimeline.map(\.value) == [1, 2, 3])
    }

    @Test("expansion clips to a window that starts and ends inside DST blocks")
    func expansionClipsAcrossTransition() throws {
        let schedule = try Self.schedule([("00:00", 1), ("01:30", 2), ("02:00", 3)])
        let tz = TimeZone(identifier: "America/New_York")!
        // Starts in the first 01:30 block and ends inside the second.
        let start = Self.utc("2026-11-01T05:40:00Z")
        let end = Self.utc("2026-11-01T06:45:00Z")

        let timeline = expectExpansionMatchesLookup(schedule, timeZone: tz, from: start, to: end)

        #expect(timeline.map(\.value) == [2, 1, 2])
        #expect(schedule.expand(from: start, to: start, timeZone: tz).isEmpty)
    }

    @Test("value(at:) matches expansion under a non-UTC zone")
    func valueAtMatchesExpansion() throws {
        let schedule = try makeSchedule()
        let tz = TimeZone(identifier: "Europe/Stockholm")!
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in stride(from: 0.0, to: 24 * 3600, by: 1800) {
            let date = start.addingTimeInterval(offset)
            let direct = schedule.value(at: date, timeZone: tz)
            let seconds = DailySchedule<Double>.secondsSinceMidnight(of: date, in: tz)
            #expect(direct == schedule.value(atSecondsSinceMidnight: seconds))
        }
    }
}
