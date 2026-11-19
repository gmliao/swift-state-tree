import Foundation
import SwiftStateTree

/// A client input's payload as the MessagePack decoder unpacked it (#521): decoded straight into
/// its type, without building an `AnyCodable` tree or going through JSON.
///
/// The payload is walked once, when the source is made, as the frame decoder made the tree before:
/// a map key that isn't a string is refused there, as `decodeAnyCodable` refused it. The same walk
/// notes what today's intake refuses later, in its round trip or its depth check: a non-finite
/// number anywhere in the tree, and nesting deeper than `PayloadNesting.clientFrameMaxDepth`.
/// `validateRecordable()` throws for those, so the keeper refuses the same inputs at the same
/// step. On a client frame the depth can't be exceeded (the unpacker's own limit is the same,
/// and the payload sits inside the frame); it bounds a source made from any other value.
package struct MessagePackPayloadSource: PayloadDecodingSource {
    package let value: MessagePackValue
    private let hasNonFiniteNumber: Bool
    private let tooDeep: PayloadNesting.TooDeep?

    /// Walks `value` (counted in `PayloadNesting.walks`), refusing a map key that isn't a string.
    package init(validating value: MessagePackValue, maxDepth: Int = PayloadNesting.clientFrameMaxDepth) throws {
        PayloadNesting.walks?.add()
        var walk = Walk(maxDepth: maxDepth)
        try walk.visit(value, depth: 0)
        self.value = value
        self.hasNonFiniteNumber = walk.hasNonFiniteNumber
        self.tooDeep = walk.exceedsDepth ? PayloadNesting.TooDeep(limit: maxDepth) : nil
    }

    package func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try MessagePackValueDecoder(clientPayload: true).decode(type, from: value)
    }

    /// Throws `PayloadNesting.TooDeep` for a payload nested past the limit, as the depth check
    /// before today's round trip does, and `EncodingError.invalidValue` for a non-finite number,
    /// as that round trip's `JSONEncoder` does.
    package func validateRecordable() throws {
        if let tooDeep { throw tooDeep }
        if hasNonFiniteNumber {
            throw EncodingError.invalidValue(Double.nan, EncodingError.Context(
                codingPath: [],
                debugDescription: "A non-finite number in a client payload (NaN or an infinity), which a record can't hold"
            ))
        }
    }

    package var boxedPayload: AnyCodable {
        // The walk refused every value the conversion refuses, so this can't throw.
        (try? Self.anyCodable(from: value)) ?? AnyCodable(Optional<Int>.none)
    }

    /// The `AnyCodable` tree of a MessagePack value: today's conversion of a client payload.
    static func anyCodable(from value: MessagePackValue) throws -> AnyCodable {
        switch value {
        case .nil:
            return AnyCodable(Optional<Int>.none)
        case .bool(let value):
            return AnyCodable(value)
        case .int(let value):
            if value >= Int64(Int.min) && value <= Int64(Int.max) {
                return AnyCodable(Int(value))
            }
            return AnyCodable(value)
        case .uint(let value):
            if value <= UInt64(Int.max) {
                return AnyCodable(Int(value))
            }
            return AnyCodable(value)
        case .float(let value):
            return AnyCodable(Double(value))
        case .double(let value):
            return AnyCodable(value)
        case .string(let value):
            return AnyCodable(value)
        case .binary(let value):
            return AnyCodable(value)
        case .array(let values):
            let array = try values.map { try anyCodable(from: $0).base }
            return AnyCodable(array)
        case .map(let values):
            var object: [String: Any] = [:]
            for (key, value) in values {
                guard case let .string(keyString) = key else {
                    throw MessagePackDirectDecodingError.invalidFormat("Non-string AnyCodable key")
                }
                object[keyString] = try anyCodable(from: value).base
            }
            return AnyCodable(object)
        case .extended(_, let data):
            return AnyCodable(data)
        }
    }

    /// One pass over the value: the keys, the numbers and the depth.
    private struct Walk {
        let maxDepth: Int
        var hasNonFiniteNumber = false
        var exceedsDepth = false

        init(maxDepth: Int) {
            self.maxDepth = maxDepth
        }

        /// `depth` is that of the container `value` would be, as in `PayloadNesting.check`.
        mutating func visit(_ value: MessagePackValue, depth: Int) throws {
            switch value {
            case .float(let number):
                if !number.isFinite { hasNonFiniteNumber = true }
            case .double(let number):
                if !number.isFinite { hasNonFiniteNumber = true }
            case .array(let values):
                if depth >= maxDepth { exceedsDepth = true }
                for element in values { try visit(element, depth: depth + 1) }
            case .map(let values):
                if depth >= maxDepth { exceedsDepth = true }
                for (key, element) in values {
                    guard case .string = key else {
                        throw MessagePackDirectDecodingError.invalidFormat("Non-string AnyCodable key")
                    }
                    try visit(element, depth: depth + 1)
                }
            case .nil, .bool, .int, .uint, .string, .binary, .extended:
                break
            }
        }
    }
}
