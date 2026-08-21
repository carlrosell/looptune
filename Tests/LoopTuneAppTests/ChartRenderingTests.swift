import AppKit
import SwiftUI
import Testing
import LoopTuneKit
@testable import LoopTuneApp

@Suite("Outcome chart rendering")
@MainActor
struct ChartRenderingTests {
    @Test("hourly glucose chart renders in both units")
    func chartsRender() throws {
        let glucose = (0..<24).map { hour in
            let median = 115 + 25 * sin(Double(hour - 7) / 24 * .pi * 2)
            return HourlyValueDistribution(
                hour: hour,
                sampleCount: 60,
                p10: median - 35,
                p25: median - 18,
                median: median,
                p75: median + 20,
                p90: median + 42
            )
        }

        for displayUnit in GlucoseUnit.allCases {
            let content = HourlyGlucoseChartView(
                distributions: glucose,
                days: 14,
                displayUnit: displayUnit
            )
            .padding(24)
            .frame(width: 1_100)
            .background(Color(nsColor: .windowBackgroundColor))

            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            #expect(image.size.width == 1_100)
            #expect(image.size.height > 250)

            if let outputPath = ProcessInfo.processInfo.environment["LOOPTUNE_CHART_SNAPSHOT"],
               displayUnit == .millimolesPerLiter,
               let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            }
        }
    }
}
