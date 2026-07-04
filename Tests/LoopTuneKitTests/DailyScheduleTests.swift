import Testing
import Foundation
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

    @Test("expansion is DST-correct: a 02:00 boundary stays at 02:00 local across spring-forward")
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
