import AppKit
import SwiftUI
import Testing
import LoopTuneKit
@testable import LoopTuneApp

/// Hours with insufficient data have no LoopTune rate, so the basal chart
/// must not draw their pump rate as one (ADR 0011).
@Suite("Basal chart for hours with insufficient data")
@MainActor
struct BasalChartDataTests {
    /// CGM from 08:00 to 20:00 tunes basal hours 05–18. The other hours offer
    /// the pump rate and an alternative interpolated from 18:00 and 05:00.
    private func hours(pumpAt2: Double = 1.0) -> [BasalHourRecommendation] {
        (0..<24).map { hour in
            if (5...18).contains(hour) {
                return BasalHourRecommendation(hour: hour, pumpRate: 1.0, rawTunedRate: 1.1, untuned: false, sampleCount: 12)
            }
            return BasalHourRecommendation(
                hour: hour,
                pumpRate: hour == 2 ? pumpAt2 : 1.0,
                interpolatedRate: 1.02,
                sources: [18 * 3600, 5 * 3600]
            )
        }
    }

    @Test("the LoopTune series stops at insufficient hours and the alternative is a separate series")
    func seriesBreaks() {
        let points = BasalChartData.points(for: hours())
        let loopTune = points.filter { $0.series == .loopTune }
        // Hours 05–18, plus the closing step at 19 that gives 18:00 its width.
        #expect(loopTune.map(\.hour) == Array(5...19))
        #expect(Set(loopTune.map(\.segment)).count == 1)
        #expect(loopTune.allSatisfy { $0.rate == 1.1 })

        let interpolated = points.filter { $0.series == .interpolated }
        #expect(interpolated.map(\.hour) == Array(0...5) + Array(19...24))
        #expect(Set(interpolated.map(\.segment)).count == 2)
        #expect(interpolated.allSatisfy { $0.rate == 1.02 })

        let pump = points.filter { $0.series == .pump }
        #expect(pump.map(\.hour) == Array(0...24))

        #expect(BasalChartData.insufficientRanges(for: hours()) == [0..<5, 19..<24])
        #expect(Set(points.map(\.id)).count == points.count)
    }

    @Test("the tooltip for an insufficient hour shows both choices, not a LoopTune rate")
    func tooltip() {
        let lines = BasalChartData.tooltipLines(for: hours(pumpAt2: 0.825)[2])
        #expect(!lines.contains { $0.label.contains("LoopTune") })
        #expect(lines.map(\.label) == ["Insufficient data", "Pump (keep)", "Interpolated", "Interpolated from"])
        #expect(lines.map(\.value) == ["no LoopTune rate", "0.825 U/hr", "0.95 U/hr", "18:00 and 05:00"])

        let tuned = BasalChartData.tooltipLines(for: hours()[10])
        #expect(tuned.map(\.label) == ["Pump", "LoopTune (unrounded)", "Enter into Loop"])

        let zero = BasalHourRecommendation(hour: 3, pumpRate: 0, interpolatedRate: 1.0, sources: [2 * 3600, 4 * 3600])
        let zeroLines = BasalChartData.tooltipLines(for: zero)
        #expect(zeroLines.last == BasalChartData.TooltipLine(
            series: nil,
            label: "Interpolated value",
            value: "outside Loop's recommended range"
        ))

        let alone = BasalHourRecommendation(hour: 3, pumpRate: 1.0, interpolatedRate: nil, sources: [])
        #expect(BasalChartData.tooltipLines(for: alone).last?.value == "none")
        #expect(BasalChartData.points(for: [alone]).allSatisfy { $0.series == .pump })
    }

    @Test("an alternative outside Loop's recommended range is marked")
    func choiceWarning() throws {
        func width(_ status: LoopGuardrails.Status) throws -> CGFloat {
            let view = ChoiceText(pump: "380.0", interpolated: "420.0 interpolated", interpolatedStatus: status)
                .fixedSize()
            let renderer = ImageRenderer(content: view)
            return try #require(renderer.nsImage).size.width
        }
        #expect(try width(.outsideRecommended) > width(.ok))
        #expect(try width(.atLimit) > width(.ok))
    }
}
