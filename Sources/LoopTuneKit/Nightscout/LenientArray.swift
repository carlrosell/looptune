import Foundation

/// Decodes a JSON array element-by-element, silently skipping any element that
/// fails to decode. Nightscout responses mix many uploaders, and a single
/// malformed document should not discard an entire day of otherwise-valid data.
public struct LenientArray<Element: Decodable>: Decodable {
    public let elements: [Element]

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
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
            }
            // Safety: if nothing consumed this iteration, stop rather than loop.
            if container.currentIndex == indexBefore { break }
        }
        self.elements = elements
    }

    /// A type that decodes successfully from any JSON value without inspecting
    /// it, used purely to advance an unkeyed container past a bad element.
    private struct AnyDecodable: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
