import Foundation

/// Decodes a JSON array element-by-element and counts elements that fail. The
/// network client rejects a nonzero `skippedCount`, while direct callers can
/// inspect the valid subset for diagnostics and tests.
public struct LenientArray<Element: Decodable>: Decodable {
    public let elements: [Element]
    public let skippedCount: Int

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var skippedCount = 0
        if let count = container.count {
            elements.reserveCapacity(count)
        }
        while !container.isAtEnd {
            let indexBefore = container.currentIndex
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // Consume one element so the cursor advances past the bad value.
                // `AnyDecodable` never throws, so the unkeyed container always
                // advances by exactly one.
                _ = try? container.decode(AnyDecodable.self)
                skippedCount += 1
            }
            // Safety: if nothing consumed this iteration, stop rather than loop.
            if container.currentIndex == indexBefore { break }
        }
        self.elements = elements
        self.skippedCount = skippedCount
    }

    /// A type that decodes successfully from any JSON value without inspecting
    /// it, used purely to advance an unkeyed container past a bad element.
    private struct AnyDecodable: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
