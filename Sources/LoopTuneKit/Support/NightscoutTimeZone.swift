import Foundation

/// Parses timezone identifiers as they appear in Nightscout/Loop profiles.
///
/// Loop maps fixed-offset zones through a table that yields non-canonical,
/// uppercase POSIX identifiers like `ETC/GMT+5`, where — per the POSIX
/// convention — the sign is **inverted** relative to the UTC offset
/// (`ETC/GMT+5` means UTC−5). Real IANA identifiers (`Europe/Stockholm`) are
/// passed through unchanged.
public enum NightscoutTimeZone {
    /// Resolve a Nightscout profile timezone string to a `TimeZone`.
    /// Returns `nil` only when the string cannot be interpreted at all.
    public static func parse(_ identifier: String?) -> TimeZone? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)

        // Direct hit (handles canonical IANA zones).
        if let zone = TimeZone(identifier: trimmed) {
            return zone
        }

        // Case-insensitive match against known IANA identifiers.
        let lowered = trimmed.lowercased()
        for known in TimeZone.knownTimeZoneIdentifiers where known.lowercased() == lowered {
            if let zone = TimeZone(identifier: known) {
                return zone
            }
        }

        // Handle ETC/GMT±N (POSIX inverted sign) and GMT±HH[:MM] forms.
        if let seconds = fixedOffsetSeconds(from: trimmed) {
            return TimeZone(secondsFromGMT: seconds)
        }

        return nil
    }

    /// Interpret POSIX-style fixed-offset identifiers, returning the true UTC
    /// offset in seconds (already sign-corrected for the `Etc/GMT` inversion).
    static func fixedOffsetSeconds(from identifier: String) -> Int? {
        let upper = identifier.uppercased()

        // Etc/GMT+N or GMT+N (POSIX): the numeric part is whole hours and the
        // sign is inverted for the ETC/ prefix.
        if let range = upper.range(of: "GMT") {
            let remainder = String(upper[range.upperBound...])
            if remainder.isEmpty { return 0 }

            let isPosixEtc = upper.hasPrefix("ETC/")
            guard let signChar = remainder.first, signChar == "+" || signChar == "-" else {
                return nil
            }
            let magnitudePart = remainder.dropFirst()
            let pieces = magnitudePart.split(separator: ":")
            guard let hours = Int(pieces[0]) else { return nil }
            let minutes = pieces.count > 1 ? (Int(pieces[1]) ?? 0) : 0

            let sign = (signChar == "+") ? 1 : -1
            let posixOffset = sign * (hours * 3600 + minutes * 60)
            // POSIX/Etc-GMT invert the sign relative to the real UTC offset.
            return isPosixEtc ? -posixOffset : posixOffset
        }

        return nil
    }
}
