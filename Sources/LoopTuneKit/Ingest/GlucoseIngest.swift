import Foundation

/// Converts Nightscout `entries` into domain glucose samples.
public enum GlucoseIngest {
    /// Filter out sensor-error codes (`sgv < 39`), keep only real CGM readings,
    /// sort ascending, and drop duplicate timestamps.
    public static func ingest(_ entries: [NSEntry]) -> [GlucoseSample] {
        let samples = entries
            .filter { entry in
                guard entry.sgv.isFinite, entry.sgv >= GlucoseSample.minimumValidValue else { return false }
                // Keep sgv entries; some sites omit `type` on sgv docs.
                if let type = entry.type { return type == "sgv" }
                return true
            }
            .sorted { $0.date < $1.date }
            .map { GlucoseSample(date: $0.date, milligramsPerDeciliter: $0.sgv, provenance: $0.device ?? "nightscout") }

        // Drop exact-timestamp duplicates (multiple uploaders), keeping the first.
        var result: [GlucoseSample] = []
        for sample in samples {
            if let last = result.last, last.date == sample.date { continue }
            result.append(sample)
        }
        return result
    }
}
