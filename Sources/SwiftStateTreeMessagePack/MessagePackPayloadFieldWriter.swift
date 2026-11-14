// The MessagePack side of the typed payload writer (#521): a payload's fields as
// `MessagePackValue`s, in field order. A leaf writes itself as the value the encoders' top-level
// path gave its type; any other field takes that path itself (`encodeAnyCodable`), so its value
// is the same by construction.

import Foundation
import SwiftStateTree

package struct MessagePackPayloadFieldWriter: _PayloadFieldWriter {
    package private(set) var fields: [MessagePackValue] = []

    package init() {}

    package mutating func leaf<T: _PayloadWireLeaf>(_ value: T) throws {
        var primitives = MessagePackPrimitiveWriter()
        value._writeWire(into: &primitives)
        fields.append(try primitives.result())
    }

    package mutating func fallback<T: Encodable>(_ value: T) throws {
        fields.append(try MessagePackDirectEncoder().encodeAnyCodable(AnyCodable(value)))
    }

    /// The payload's positional value.
    package static func positional(_ payload: some PayloadCompression) throws -> MessagePackValue {
        var writer = MessagePackPayloadFieldWriter()
        try payload._writePayloadFields(into: &writer)
        return .array(writer.fields)
    }
}

/// Builds one `MessagePackValue` from a leaf's primitives. An object is a count followed by its
/// entries; nested objects are completed innermost first.
struct MessagePackPrimitiveWriter: _PayloadPrimitiveWriter {
    private struct OpenObject {
        var remaining: Int
        var map: [MessagePackValue: MessagePackValue] = [:]
        var pendingKey: String?
    }

    private var stack: [OpenObject] = []
    private var value: MessagePackValue?

    mutating func int(_ value: Int64) { put(.int(value)) }
    mutating func uint(_ value: UInt64) { put(.uint(value)) }
    mutating func bool(_ value: Bool) { put(.bool(value)) }
    mutating func float(_ value: Float) { put(.float(value)) }
    mutating func double(_ value: Double) { put(.double(value)) }
    mutating func string(_ value: String) { put(.string(value)) }

    mutating func object(count: Int) {
        if count == 0 {
            put(.map([:]))
        } else {
            stack.append(OpenObject(remaining: count))
        }
    }

    mutating func key(_ key: String) {
        stack[stack.count - 1].pendingKey = key
    }

    private mutating func put(_ item: MessagePackValue) {
        var item = item
        while var top = stack.popLast() {
            guard let key = top.pendingKey else {
                preconditionFailure("a leaf wrote an object value without its key")
            }
            top.map[.string(key)] = item
            top.pendingKey = nil
            top.remaining -= 1
            if top.remaining > 0 {
                stack.append(top)
                return
            }
            item = .map(top.map)
        }
        precondition(value == nil, "a leaf wrote more than one value")
        value = item
    }

    func result() throws -> MessagePackValue {
        guard stack.isEmpty, let value else {
            throw EncodingError.invalidValue(
                "leaf", .init(codingPath: [], debugDescription: "a leaf wrote an incomplete value")
            )
        }
        return value
    }
}
