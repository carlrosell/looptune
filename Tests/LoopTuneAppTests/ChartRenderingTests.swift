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
            let image = try render(glucose, days: 14, displayUnit: displayUnit)
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

    @Test("sparse hourly glucose keeps omitted hours empty")
    func sparseHoursRender() throws {
        func distribution(hour: Int) -> HourlyValueDistribution {
            HourlyValueDistribution(
                hour: hour,
                sampleCount: 12,
                p10: 80,
                p25: 95,
                median: 120,
                p75: 145,
                p90: 170
            )
        }

        let glucose = [distribution(hour: 2), distribution(hour: 10)]
        let image = try render(glucose)
        #expect(image.size.width == 1_100)
        #expect(image.size.height > 250)

        let sparseBitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let emptyImage = try render([])
        let emptyBitmap = try #require(emptyImage.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        // At the fixed test width, this stripe crosses the omitted span near 06:00.
        let gapX = sparseBitmap.pixelsWide / 4
        #expect(try changedPixelCount(sparseBitmap, emptyBitmap, xRange: gapX..<(gapX + 4)) == 0)
        let hour2Range = sparseBitmap.pixelsWide / 12..<sparseBitmap.pixelsWide / 9
        let whiskerYRange = sparseBitmap.pixelsHigh / 4..<sparseBitmap.pixelsHigh * 2 / 5
        #expect(try changedPixelCount(
            sparseBitmap,
            emptyBitmap,
            xRange: hour2Range,
            yRange: whiskerYRange
        ) > 0)
        let hour10Range = sparseBitmap.pixelsWide * 2 / 5..<sparseBitmap.pixelsWide * 9 / 20
        #expect(try changedPixelCount(
            sparseBitmap,
            emptyBitmap,
            xRange: hour10Range,
            yRange: whiskerYRange
        ) > 0)
        let medianYRange = sparseBitmap.pixelsHigh * 2 / 5..<sparseBitmap.pixelsHigh * 3 / 5
        #expect(darkPixelCount(sparseBitmap, xRange: hour2Range, yRange: medianYRange) > 0)
        #expect(darkPixelCount(sparseBitmap, xRange: hour10Range, yRange: medianYRange) > 0)

        let adjacentImage = try render([distribution(hour: 2), distribution(hour: 3)])
        let adjacentBitmap = try #require(adjacentImage.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        // This stripe crosses the plot between the adjacent observations.
        let adjacentX = adjacentBitmap.pixelsWide / 9
        #expect(try changedPixelCount(
            adjacentBitmap,
            emptyBitmap,
            xRange: adjacentX..<(adjacentX + 4)
        ) > 0)

        if let outputPath = ProcessInfo.processInfo.environment["LOOPTUNE_SPARSE_CHART_SNAPSHOT"],
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    private func render(
        _ distributions: [HourlyValueDistribution],
        days: Int = 1,
        displayUnit: GlucoseUnit = .milligramsPerDeciliter
    ) throws -> NSImage {
        let content = HourlyGlucoseChartView(
            distributions: distributions,
            days: days,
            displayUnit: displayUnit
        )
        .padding(24)
        .frame(width: 1_100)
        .environment(\.colorScheme, .light)
        .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return try #require(renderer.nsImage)
    }

    private func changedPixelCount(
        _ first: NSBitmapImageRep,
        _ second: NSBitmapImageRep,
        xRange: Range<Int>,
        yRange: Range<Int>? = nil
    ) throws -> Int {
        try #require(first.pixelsWide == second.pixelsWide)
        try #require(first.pixelsHigh == second.pixelsHigh)
        try #require(first.bitsPerPixel == second.bitsPerPixel)
        let firstBytes = try #require(first.bitmapData)
        let secondBytes = try #require(second.bitmapData)
        let bytesPerPixel = first.bitsPerPixel / 8
        try #require(bytesPerPixel > 0)

        var changedPixels = 0
        for y in yRange ?? 0..<first.pixelsHigh {
            for x in xRange {
                let firstOffset = y * first.bytesPerRow + x * bytesPerPixel
                let secondOffset = y * second.bytesPerRow + x * bytesPerPixel
                if (0..<bytesPerPixel).contains(where: {
                    abs(Int(firstBytes[firstOffset + $0]) - Int(secondBytes[secondOffset + $0])) > 1
                }) {
                    changedPixels += 1
                }
            }
        }
        return changedPixels
    }

    private func darkPixelCount(
        _ image: NSBitmapImageRep,
        xRange: Range<Int>,
        yRange: Range<Int>
    ) -> Int {
        var darkPixels = 0
        for y in yRange {
            for x in xRange {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.redComponent < 0.25,
                   color.greenComponent < 0.25,
                   color.blueComponent < 0.25 {
                    darkPixels += 1
                }
            }
        }
        return darkPixels
    }
}
