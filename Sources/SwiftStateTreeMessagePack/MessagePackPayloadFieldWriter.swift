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
///
/// `_PayloadWireLeaf` is public, so a leaf that writes a malformed value (a key outside an
/// object, a value without its key, two keys for one value, a key written twice in one object,
/// a second value, a negative count) can be a user's. The first such call is recorded, later calls are ignored, and `result()`
/// throws it: the encode fails, never the process (#690).
///
/// Objects nested deeper than `messagePackMaxNestingDepth` are refused the same way (#697): no
/// frame can hold them, and refusing them as they are opened keeps the value this builds, and the
/// recursion that later walks or frees it, bounded.
struct MessagePackPrimitiveWriter: _PayloadPrimitiveWriter {
    private struct OpenObject {
        var remaining: Int
        var map: [MessagePackValue: MessagePackValue] = [:]
        var pendingKey: String?
    }

    private var stack: [OpenObject] = []
    private var value: MessagePackValue?
    /// The first malformed call, if any.
    private var violation: String?

    mutating func int(_ value: Int64) { put(.int(value)) }
    mutating func uint(_ value: UInt64) { put(.uint(value)) }
    mutating func bool(_ value: Bool) { put(.bool(value)) }
    mutating func float(_ value: Float) { put(.float(value)) }
    mutating func double(_ value: Double) { put(.double(value)) }
    mutating func string(_ value: String) { put(.string(value)) }

    mutating func object(count: Int) {
        guard startsValue() else { return }
        if stack.count >= messagePackMaxNestingDepth {
            violation = "a leaf wrote objects nested deeper than \(messagePackMaxNestingDepth), deeper than any frame can hold"
        } else if count < 0 {
            violation = "a leaf wrote an object with a negative count (\(count))"
        } else if count == 0 {
            put(.map([:]))
        } else {
            stack.append(OpenObject(remaining: count))
        }
    }

    mutating func key(_ key: String) {
        guard violation == nil else { return }
        guard !stack.isEmpty else {
            violation = "a leaf wrote the key \(key) outside an object"
            return
        }
        guard stack[stack.count - 1].pendingKey == nil else {
            violation = "a leaf wrote the key \(key) before the previous key's value"
            return
        }
        guard stack[stack.count - 1].map[.string(key)] == nil else {
            violation = "a leaf wrote the key \(key) twice in one object"
            return
        }
        stack[stack.count - 1].pendingKey = key
    }

    /// Whether a value (a scalar or an object) may start here: inside an object after its key,
    /// or at the top level before any value. Records the violation otherwise.
    private mutating func startsValue() -> Bool {
        guard violation == nil else { return false }
        if let top = stack.last, top.pendingKey == nil {
            violation = "a leaf wrote an object value without its key"
            return false
        }
        if stack.isEmpty, value != nil {
            violation = "a leaf wrote more than one value"
            return false
        }
        return true
    }

    private mutating func put(_ item: MessagePackValue) {
        guard startsValue() else { return }
        var item = item
        while var top = stack.popLast() {
            // Every open object has its key here: `startsValue()` checked the innermost one,
            // and each enclosing one had its key when the object inside it started.
            guard let key = top.pendingKey else {
                violation = "a leaf wrote an object value without its key"
                return
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
        value = item
    }

    func result() throws -> MessagePackValue {
        if let violation {
            throw EncodingError.invalidValue(
                "leaf", .init(codingPath: [], debugDescription: violation)
            )
        }
        guard stack.isEmpty, let value else {
            throw EncodingError.invalidValue(
                "leaf", .init(codingPath: [], debugDescription: "a leaf wrote an incomplete value")
            )
        }
        return value
    }
}
