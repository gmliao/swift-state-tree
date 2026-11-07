import Foundation

/// A MessagePack encoding whose bytes depend only on the value: the same value gives the same
/// bytes on every platform and in every process.
///
/// Rules (the record format's, see `Notes/plans/2026-11-07-streaming-record-format.md` § 2):
/// - maps have string keys only, sorted by the keys' UTF-8 bytes, with no Unicode normalization;
///   a dictionary keyed by `Int` (or a `CodingKeyRepresentable` key) is written under the keys'
///   string form; a key encoded twice in one container throws (keys are compared by their UTF-8
///   bytes, so an NFC and an NFD spelling are two keys, as they are two keys on the wire);
/// - a dictionary with any other key type, and a `Set`, throw (their order isn't deterministic);
/// - integers use the shortest form: unsigned forms for non-negative values, signed for negative;
/// - floats are always float64, `Float` widened; NaN is the one quiet NaN `0x7ff8000000000000`;
/// - a `Date` is its ISO-8601 string at whole seconds with `Z` (`1970-01-01T00:00:00Z`),
///   truncated toward negative infinity, formatted here rather than by `ISO8601DateFormatter`;
/// - an omitted optional (`encodeIfPresent` with `nil`) leaves the key out; `encodeNil` is `0xc0`.
///
/// What it can't detect: a custom `encode(to:)` that writes a `Set` or a dictionary itself, element
/// by element (`encode(contentsOf:)`), in iteration order. Only values that reach the encoder as
/// a `Set` or `Dictionary` are checked; recording the same run twice and comparing the bytes is
/// the backstop for the rest.
///
/// The decoder is strict: a value decodes only into a matching type (an integer doesn't decode
/// into `Double`), with one widening rule: a float64 decodes into `Float` only when it converts
/// back to the same `Double`. Duplicate map keys and trailing bytes are rejected.
public enum CanonicalMessagePack {
    /// The deepest nesting of arrays and maps the decoder reads, so input from a file can't
    /// overflow the stack; the encoder refuses deeper values too, so it never writes what the
    /// decoder refuses. Records nest a few levels; the limit also leaves room for the
    /// `Decodable` types that recurse over the value (`AnyCodable` at 512 levels overflows a
    /// test thread's stack in a debug build).
    public static let maxDepth = 128

    /// Encodes `value` canonically.
    public static func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        let node = try CanonicalNodeEncoder.box(value, codingPath: [])
        var writer = CanonicalWriter()
        try writer.write(node)
        return writer.bytes
    }

    /// Decodes a `T` from `bytes`, which must hold exactly one value.
    public static func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        var reader = CanonicalReader(bytes: bytes)
        let node = try reader.readValue()
        guard reader.offset == bytes.count else {
            throw CanonicalMessagePackError.trailingBytes(bytes.count - reader.offset)
        }
        return try CanonicalNodeDecoder.unbox(node, as: type, codingPath: [])
    }
}

public enum CanonicalMessagePackError: Error, Equatable, CustomStringConvertible {
    /// A key encoded twice in one keyed container (or found twice in one map when decoding).
    case duplicateKey(String)
    /// A value whose encoding would depend on iteration order (a `Set`, or a dictionary whose
    /// keys aren't strings, `Int`s or `CodingKeyRepresentable`), named by its type.
    case unorderedCollection(String)
    /// A `Date` outside the years 0001–9999.
    case dateOutOfRange(Double)
    /// The input ends inside a value.
    case truncated
    /// Bytes left after the value.
    case trailingBytes(Int)
    /// A MessagePack type byte this format doesn't use (bin, ext, float32).
    case unsupportedFormat(UInt8)
    /// Arrays and maps nested deeper than `CanonicalMessagePack.maxDepth`.
    case nestingTooDeep
    /// A string, array or map with more than `UInt32.max` elements or bytes.
    case lengthTooLarge(Int)
    /// A string that isn't valid UTF-8.
    case invalidUTF8
    /// A value that doesn't fit the requested type, at `path`.
    case typeMismatch(expected: String, path: String)
    /// A key the decoded type requires, at `path`.
    case missingKey(String, path: String)
    /// The end of an array reached while decoding an element, at `path`.
    case missingElement(path: String)

    public var description: String {
        switch self {
        case .duplicateKey(let key): return "canonical MessagePack: duplicate key \"\(key)\""
        case .unorderedCollection(let type): return "canonical MessagePack: \(type) has no deterministic order"
        case .dateOutOfRange(let seconds): return "canonical MessagePack: date \(seconds) is outside 0001-9999"
        case .truncated: return "canonical MessagePack: truncated input"
        case .trailingBytes(let count): return "canonical MessagePack: \(count) bytes after the value"
        case .unsupportedFormat(let byte): return "canonical MessagePack: unsupported type byte 0x\(String(byte, radix: 16))"
        case .nestingTooDeep: return "canonical MessagePack: nested deeper than \(CanonicalMessagePack.maxDepth)"
        case .lengthTooLarge(let count): return "canonical MessagePack: length \(count) doesn't fit in 32 bits"
        case .invalidUTF8: return "canonical MessagePack: string isn't valid UTF-8"
        case .typeMismatch(let expected, let path): return "canonical MessagePack: expected \(expected) at \(path)"
        case .missingKey(let key, let path): return "canonical MessagePack: missing key \"\(key)\" at \(path)"
        case .missingElement(let path): return "canonical MessagePack: missing array element at \(path)"
        }
    }
}

// MARK: - Value tree

/// A map key, equal and hashed by its UTF-8 bytes (Swift `String` equality treats an NFC and an
/// NFD spelling as one key; the format doesn't).
struct CanonicalKey: Hashable {
    let utf8: [UInt8]

    init(_ string: String) {
        utf8 = Array(string.utf8)
    }

    var string: String { String(decoding: utf8, as: UTF8.self) }
}

/// One decoded or to-be-encoded value.
enum CanonicalNode: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([CanonicalNode])
    case map([CanonicalKey: CanonicalNode])

    static func == (lhs: CanonicalNode, rhs: CanonicalNode) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.uint(a), .uint(b)): return a == b
        case let (.double(a), .double(b)): return a.bitPattern == b.bitPattern
        case let (.string(a), .string(b)): return a.utf8.elementsEqual(b.utf8)
        case let (.array(a), .array(b)): return a == b
        case let (.map(a), .map(b)): return a == b
        default: return false
        }
    }

    var kindName: String {
        switch self {
        case .null: return "nil"
        case .bool: return "bool"
        case .int, .uint: return "integer"
        case .double: return "float64"
        case .string: return "string"
        case .array: return "array"
        case .map: return "map"
        }
    }
}

private func pathString(_ codingPath: [CodingKey]) -> String {
    codingPath.isEmpty ? "<root>" : codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
}

// MARK: - Probes for unordered collections

/// `Set` has no deterministic order.
private protocol CanonicalUnorderedProbe {}
extension Set: CanonicalUnorderedProbe {}

/// A `Dictionary` is encoded as a keyed container only for string-like keys; any other key type
/// becomes an unkeyed list in iteration order.
private protocol CanonicalDictionaryProbe {
    static var hasStringLikeKeys: Bool { get }
}

extension Dictionary: CanonicalDictionaryProbe {
    static var hasStringLikeKeys: Bool {
        Key.self == String.self || Key.self == Int.self || Key.self is any CodingKeyRepresentable.Type
    }
}

// MARK: - Encoder

/// A container under construction; finished into a `CanonicalNode` when the encode returns.
/// Children are kept in the slot's own stored properties and mutated in place, so an append or
/// insert doesn't copy the collection (no copy-on-write of a value taken out and put back).
private final class CanonicalSlot {
    private enum Kind {
        case empty, value, map, array
    }

    private var kind: Kind = .empty
    private var value: CanonicalNode = .null
    private var entries: [CanonicalKey: CanonicalSlot] = [:]
    private var elements: [CanonicalSlot] = []

    func setValue(_ node: CanonicalNode) {
        kind = .value
        value = node
    }

    /// Makes this slot a map; a second keyed container on the same encoder keeps its entries.
    func becomeMap() {
        if kind != .map {
            kind = .map
            entries = [:]
        }
    }

    /// Makes this slot an array; a second unkeyed container on the same encoder keeps its elements.
    func becomeArray() {
        if kind != .array {
            kind = .array
            elements = []
        }
    }

    /// A new child under `key`, or `nil` when the key is already there.
    func insertChild(_ key: CanonicalKey) -> CanonicalSlot? {
        guard entries[key] == nil else { return nil }
        let child = CanonicalSlot()
        entries[key] = child
        return child
    }

    func appendChild() -> CanonicalSlot {
        let child = CanonicalSlot()
        elements.append(child)
        return child
    }

    var elementCount: Int { elements.count }

    func node() -> CanonicalNode {
        switch kind {
        // A value that encoded nothing (an empty custom `encode(to:)`) is an empty map, as
        // `JSONEncoder` writes `{}`.
        case .empty: return .map([:])
        case .value: return value
        case .map: return .map(entries.mapValues { $0.node() })
        case .array: return .array(elements.map { $0.node() })
        }
    }
}

/// Errors from non-throwing container calls (`nestedContainer(forKey:)` with a repeated key),
/// thrown when the encode finishes.
private final class CanonicalEncodingState {
    var deferredError: Error?
}

private struct CanonicalNodeEncoder: Encoder {
    let slot: CanonicalSlot
    let state: CanonicalEncodingState
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    /// Encodes `value` into a finished node.
    static func box<T: Encodable>(_ value: T, codingPath: [CodingKey]) throws -> CanonicalNode {
        let state = CanonicalEncodingState()
        let slot = CanonicalSlot()
        try encode(value, into: slot, state: state, codingPath: codingPath)
        if let error = state.deferredError { throw error }
        return slot.node()
    }

    /// Writes `value` into `slot`, with the special cases (dates, floats, unordered collections)
    /// taken before the value's own `encode(to:)`.
    static func encode<T: Encodable>(
        _ value: T, into slot: CanonicalSlot, state: CanonicalEncodingState, codingPath: [CodingKey]
    ) throws {
        if let date = value as? Date {
            slot.setValue(.string(try CanonicalDate.format(date)))
            return
        }
        if let double = value as? Double {
            slot.setValue(.double(double))
            return
        }
        if let float = value as? Float {
            slot.setValue(.double(Double(float)))
            return
        }
        if T.self is CanonicalUnorderedProbe.Type {
            throw CanonicalMessagePackError.unorderedCollection(String(describing: T.self))
        }
        if let dictionary = T.self as? CanonicalDictionaryProbe.Type, !dictionary.hasStringLikeKeys {
            throw CanonicalMessagePackError.unorderedCollection(String(describing: T.self))
        }
        try value.encode(to: CanonicalNodeEncoder(slot: slot, state: state, codingPath: codingPath))
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        slot.becomeMap()
        return KeyedEncodingContainer(CanonicalKeyedEncoder<Key>(slot: slot, state: state, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        slot.becomeArray()
        return CanonicalUnkeyedEncoder(slot: slot, state: state, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        CanonicalSingleValueEncoder(slot: slot, state: state, codingPath: codingPath)
    }
}

private struct CanonicalKeyedEncoder<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let slot: CanonicalSlot
    let state: CanonicalEncodingState
    let codingPath: [CodingKey]

    /// A new child slot under `key`; a key already present is a duplicate.
    private func child(for key: CodingKey) throws -> CanonicalSlot {
        guard let child = slot.insertChild(CanonicalKey(key.stringValue)) else {
            throw CanonicalMessagePackError.duplicateKey(key.stringValue)
        }
        return child
    }

    /// `child(for:)` for the non-throwing calls: a duplicate is thrown when the encode finishes.
    private func deferredChild(for key: CodingKey) -> CanonicalSlot {
        do {
            return try child(for: key)
        } catch {
            if state.deferredError == nil { state.deferredError = error }
            return CanonicalSlot()
        }
    }

    private func set(_ node: CanonicalNode, for key: Key) throws {
        try child(for: key).setValue(node)
    }

    mutating func encodeNil(forKey key: Key) throws { try set(.null, for: key) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { try set(.bool(value), for: key) }
    mutating func encode(_ value: String, forKey key: Key) throws { try set(.string(value), for: key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { try set(.double(value), for: key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { try set(.double(Double(value)), for: key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { try set(.int(Int64(value)), for: key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { try set(.int(Int64(value)), for: key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { try set(.int(Int64(value)), for: key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { try set(.int(Int64(value)), for: key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { try set(.int(value), for: key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { try set(.uint(UInt64(value)), for: key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { try set(.uint(UInt64(value)), for: key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { try set(.uint(UInt64(value)), for: key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { try set(.uint(UInt64(value)), for: key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { try set(.uint(value), for: key) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        let child = try child(for: key)
        try CanonicalNodeEncoder.encode(value, into: child, state: state, codingPath: codingPath + [key])
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let child = deferredChild(for: key)
        child.becomeMap()
        return KeyedEncodingContainer(CanonicalKeyedEncoder<NestedKey>(slot: child, state: state, codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let child = deferredChild(for: key)
        child.becomeArray()
        return CanonicalUnkeyedEncoder(slot: child, state: state, codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> Encoder {
        let key = CanonicalCodingKey(stringValue: "super")
        return CanonicalNodeEncoder(slot: deferredChild(for: key), state: state, codingPath: codingPath + [key])
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        CanonicalNodeEncoder(slot: deferredChild(for: key), state: state, codingPath: codingPath + [key])
    }
}

private struct CanonicalUnkeyedEncoder: UnkeyedEncodingContainer {
    let slot: CanonicalSlot
    let state: CanonicalEncodingState
    let codingPath: [CodingKey]

    var count: Int { slot.elementCount }

    private func append() -> CanonicalSlot { slot.appendChild() }

    private func append(_ node: CanonicalNode) { append().setValue(node) }

    private var nextKey: CodingKey { CanonicalCodingKey(intValue: count) }

    mutating func encodeNil() throws { append(.null) }
    mutating func encode(_ value: Bool) throws { append(.bool(value)) }
    mutating func encode(_ value: String) throws { append(.string(value)) }
    mutating func encode(_ value: Double) throws { append(.double(value)) }
    mutating func encode(_ value: Float) throws { append(.double(Double(value))) }
    mutating func encode(_ value: Int) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int8) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int16) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int32) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int64) throws { append(.int(value)) }
    mutating func encode(_ value: UInt) throws { append(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt8) throws { append(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt16) throws { append(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt32) throws { append(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt64) throws { append(.uint(value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let key = nextKey
        try CanonicalNodeEncoder.encode(value, into: append(), state: state, codingPath: codingPath + [key])
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let key = nextKey
        let child = append()
        child.becomeMap()
        return KeyedEncodingContainer(CanonicalKeyedEncoder<NestedKey>(slot: child, state: state, codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let key = nextKey
        let child = append()
        child.becomeArray()
        return CanonicalUnkeyedEncoder(slot: child, state: state, codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> Encoder {
        let key = nextKey
        return CanonicalNodeEncoder(slot: append(), state: state, codingPath: codingPath + [key])
    }
}

private struct CanonicalSingleValueEncoder: SingleValueEncodingContainer {
    let slot: CanonicalSlot
    let state: CanonicalEncodingState
    let codingPath: [CodingKey]

    private func set(_ node: CanonicalNode) { slot.setValue(node) }

    mutating func encodeNil() throws { set(.null) }
    mutating func encode(_ value: Bool) throws { set(.bool(value)) }
    mutating func encode(_ value: String) throws { set(.string(value)) }
    mutating func encode(_ value: Double) throws { set(.double(value)) }
    mutating func encode(_ value: Float) throws { set(.double(Double(value))) }
    mutating func encode(_ value: Int) throws { set(.int(Int64(value))) }
    mutating func encode(_ value: Int8) throws { set(.int(Int64(value))) }
    mutating func encode(_ value: Int16) throws { set(.int(Int64(value))) }
    mutating func encode(_ value: Int32) throws { set(.int(Int64(value))) }
    mutating func encode(_ value: Int64) throws { set(.int(value)) }
    mutating func encode(_ value: UInt) throws { set(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt8) throws { set(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt16) throws { set(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt32) throws { set(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt64) throws { set(.uint(value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try CanonicalNodeEncoder.encode(value, into: slot, state: state, codingPath: codingPath)
    }
}

private struct CanonicalCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = Int(stringValue)
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

// MARK: - Writer

private struct CanonicalWriter {
    var bytes: [UInt8] = []
    /// Arrays and maps open around the value being written.
    private var depth = 0

    mutating func write(_ node: CanonicalNode) throws {
        switch node {
        case .null:
            bytes.append(0xc0)
        case .bool(let value):
            bytes.append(value ? 0xc3 : 0xc2)
        case .int(let value):
            if value >= 0 {
                writeUnsigned(UInt64(value))
            } else {
                writeNegative(value)
            }
        case .uint(let value):
            writeUnsigned(value)
        case .double(let value):
            bytes.append(0xcb)
            let bits = value.isNaN ? 0x7ff8_0000_0000_0000 : value.bitPattern
            appendBigEndian(bits, width: 8)
        case .string(let value):
            let utf8 = Array(value.utf8)
            try writeHeader(count: utf8.count, fix: 0xa0, fixMax: 31, u8: 0xd9, u16: 0xda, u32: 0xdb)
            bytes.append(contentsOf: utf8)
        case .array(let elements):
            try enter()
            defer { depth -= 1 }
            try writeHeader(count: elements.count, fix: 0x90, fixMax: 15, u8: nil, u16: 0xdc, u32: 0xdd)
            for element in elements { try write(element) }
        case .map(let entries):
            try enter()
            defer { depth -= 1 }
            try writeHeader(count: entries.count, fix: 0x80, fixMax: 15, u8: nil, u16: 0xde, u32: 0xdf)
            let sorted = entries.map { (key: $0.key.utf8, value: $0.value) }
                .sorted { $0.key.lexicographicallyPrecedes($1.key) }
            for entry in sorted {
                try writeHeader(count: entry.key.count, fix: 0xa0, fixMax: 31, u8: 0xd9, u16: 0xda, u32: 0xdb)
                bytes.append(contentsOf: entry.key)
                try write(entry.value)
            }
        }
    }

    private mutating func enter() throws {
        depth += 1
        guard depth <= CanonicalMessagePack.maxDepth else { throw CanonicalMessagePackError.nestingTooDeep }
    }

    private mutating func writeUnsigned(_ value: UInt64) {
        switch value {
        case 0...0x7f: bytes.append(UInt8(value))
        case 0x80...0xff: bytes.append(0xcc); bytes.append(UInt8(value))
        case 0x100...0xffff: bytes.append(0xcd); appendBigEndian(value, width: 2)
        case 0x1_0000...0xffff_ffff: bytes.append(0xce); appendBigEndian(value, width: 4)
        default: bytes.append(0xcf); appendBigEndian(value, width: 8)
        }
    }

    private mutating func writeNegative(_ value: Int64) {
        let bits = UInt64(bitPattern: value)
        switch value {
        case -32...(-1): bytes.append(UInt8(truncatingIfNeeded: bits))
        case -128...(-33): bytes.append(0xd0); appendBigEndian(bits, width: 1)
        case -32768...(-129): bytes.append(0xd1); appendBigEndian(bits, width: 2)
        case -2_147_483_648...(-32769): bytes.append(0xd2); appendBigEndian(bits, width: 4)
        default: bytes.append(0xd3); appendBigEndian(bits, width: 8)
        }
    }

    private mutating func writeHeader(count: Int, fix: UInt8, fixMax: Int, u8: UInt8?, u16: UInt8, u32: UInt8) throws {
        guard count <= Int(UInt32.max) else { throw CanonicalMessagePackError.lengthTooLarge(count) }
        let n = UInt64(count)
        if count <= fixMax {
            bytes.append(fix | UInt8(count))
        } else if let u8, count <= 0xff {
            bytes.append(u8); appendBigEndian(n, width: 1)
        } else if count <= 0xffff {
            bytes.append(u16); appendBigEndian(n, width: 2)
        } else {
            bytes.append(u32); appendBigEndian(n, width: 4)
        }
    }

    private mutating func appendBigEndian(_ value: UInt64, width: Int) {
        for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}

// MARK: - Reader

private struct CanonicalReader {
    let bytes: [UInt8]
    var offset = 0
    /// Arrays and maps open around the value being read.
    private var depth = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readValue() throws -> CanonicalNode {
        let type = try readByte()
        switch type {
        case 0x00...0x7f: return .uint(UInt64(type))
        case 0x80...0x8f: return try readMap(count: Int(type & 0x0f))
        case 0x90...0x9f: return try readArray(count: Int(type & 0x0f))
        case 0xa0...0xbf: return try readString(count: Int(type & 0x1f))
        case 0xc0: return .null
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)
        case 0xcb: return .double(Double(bitPattern: try readBigEndian(8)))
        case 0xcc: return .uint(try readBigEndian(1))
        case 0xcd: return .uint(try readBigEndian(2))
        case 0xce: return .uint(try readBigEndian(4))
        case 0xcf: return .uint(try readBigEndian(8))
        case 0xd0: return .int(Int64(Int8(truncatingIfNeeded: try readBigEndian(1))))
        case 0xd1: return .int(Int64(Int16(truncatingIfNeeded: try readBigEndian(2))))
        case 0xd2: return .int(Int64(Int32(truncatingIfNeeded: try readBigEndian(4))))
        case 0xd3: return .int(Int64(bitPattern: try readBigEndian(8)))
        case 0xd9: return try readString(count: Int(try readBigEndian(1)))
        case 0xda: return try readString(count: Int(try readBigEndian(2)))
        case 0xdb: return try readString(count: Int(try readBigEndian(4)))
        case 0xdc: return try readArray(count: Int(try readBigEndian(2)))
        case 0xdd: return try readArray(count: Int(try readBigEndian(4)))
        case 0xde: return try readMap(count: Int(try readBigEndian(2)))
        case 0xdf: return try readMap(count: Int(try readBigEndian(4)))
        case 0xe0...0xff: return .int(Int64(Int8(bitPattern: type)))
        default: throw CanonicalMessagePackError.unsupportedFormat(type)
        }
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw CanonicalMessagePackError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    private mutating func readBigEndian(_ width: Int) throws -> UInt64 {
        guard bytes.count - offset >= width else { throw CanonicalMessagePackError.truncated }
        var value: UInt64 = 0
        for index in offset..<(offset + width) {
            value = value << 8 | UInt64(bytes[index])
        }
        offset += width
        return value
    }

    private mutating func readString(count: Int) throws -> CanonicalNode {
        .string(try readStringValue(count: count))
    }

    private mutating func readStringValue(count: Int) throws -> String {
        guard bytes.count - offset >= count else { throw CanonicalMessagePackError.truncated }
        let slice = bytes[offset..<(offset + count)]
        offset += count
        // Decoding with repair, then comparing the byte counts, rejects invalid UTF-8 (a repaired
        // sequence becomes U+FFFD, whose encoding has a different length or position).
        let string = String(decoding: slice, as: UTF8.self)
        guard string.utf8.elementsEqual(slice) else {
            throw CanonicalMessagePackError.invalidUTF8
        }
        return string
    }

    private mutating func enter() throws {
        depth += 1
        guard depth <= CanonicalMessagePack.maxDepth else { throw CanonicalMessagePackError.nestingTooDeep }
    }

    private mutating func readArray(count: Int) throws -> CanonicalNode {
        try enter()
        defer { depth -= 1 }
        // Each element takes at least one byte, so a count beyond the input is truncated.
        guard count <= bytes.count - offset else { throw CanonicalMessagePackError.truncated }
        var elements: [CanonicalNode] = []
        elements.reserveCapacity(count)
        for _ in 0..<count { elements.append(try readValue()) }
        return .array(elements)
    }

    private mutating func readMap(count: Int) throws -> CanonicalNode {
        try enter()
        defer { depth -= 1 }
        guard count <= (bytes.count - offset) / 2 else { throw CanonicalMessagePackError.truncated }
        var entries: [CanonicalKey: CanonicalNode] = [:]
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard case .string(let key) = try readValue() else {
                throw CanonicalMessagePackError.typeMismatch(expected: "string map key", path: "<map>")
            }
            let value = try readValue()
            if entries.updateValue(value, forKey: CanonicalKey(key)) != nil {
                throw CanonicalMessagePackError.duplicateKey(key)
            }
        }
        return .map(entries)
    }
}

// MARK: - Decoder

private struct CanonicalNodeDecoder: Decoder {
    let node: CanonicalNode
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    static func unbox<T: Decodable>(_ node: CanonicalNode, as type: T.Type, codingPath: [CodingKey]) throws -> T {
        if type == Date.self {
            guard case .string(let text) = node else {
                throw CanonicalMessagePackError.typeMismatch(expected: "date string", path: pathString(codingPath))
            }
            return try CanonicalDate.parse(text, path: pathString(codingPath)) as! T
        }
        if type == Double.self { return try unboxDouble(node, codingPath: codingPath) as! T }
        if type == Float.self { return try unboxFloat(node, codingPath: codingPath) as! T }
        return try T(from: CanonicalNodeDecoder(node: node, codingPath: codingPath))
    }

    static func unboxDouble(_ node: CanonicalNode, codingPath: [CodingKey]) throws -> Double {
        guard case .double(let value) = node else {
            throw CanonicalMessagePackError.typeMismatch(expected: "float64", path: pathString(codingPath))
        }
        return value
    }

    static func unboxFloat(_ node: CanonicalNode, codingPath: [CodingKey]) throws -> Float {
        let value = try unboxDouble(node, codingPath: codingPath)
        let narrowed = Float(value)
        // Exact only: NaN stays NaN, every other value must convert back to the same Double.
        guard value.isNaN || Double(narrowed) == value else {
            throw CanonicalMessagePackError.typeMismatch(expected: "float64 exact in Float", path: pathString(codingPath))
        }
        return narrowed
    }

    static func unboxInteger<I: FixedWidthInteger>(_ node: CanonicalNode, as type: I.Type, codingPath: [CodingKey]) throws -> I {
        let result: I?
        switch node {
        case .int(let value): result = I(exactly: value)
        case .uint(let value): result = I(exactly: value)
        default: result = nil
        }
        guard let result else {
            throw CanonicalMessagePackError.typeMismatch(expected: "\(I.self)", path: pathString(codingPath))
        }
        return result
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .map(let entries) = node else {
            throw CanonicalMessagePackError.typeMismatch(expected: "map", path: pathString(codingPath))
        }
        return KeyedDecodingContainer(CanonicalKeyedDecoder<Key>(entries: entries, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let elements) = node else {
            throw CanonicalMessagePackError.typeMismatch(expected: "array", path: pathString(codingPath))
        }
        return CanonicalUnkeyedDecoder(elements: elements, codingPath: codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        CanonicalSingleValueDecoder(node: node, codingPath: codingPath)
    }
}

private struct CanonicalKeyedDecoder<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let entries: [CanonicalKey: CanonicalNode]
    let codingPath: [CodingKey]

    var allKeys: [Key] { entries.keys.compactMap { Key(stringValue: $0.string) } }

    func contains(_ key: Key) -> Bool { entries[CanonicalKey(key.stringValue)] != nil }

    private func node(for key: Key) throws -> CanonicalNode {
        guard let node = entries[CanonicalKey(key.stringValue)] else {
            throw CanonicalMessagePackError.missingKey(key.stringValue, path: pathString(codingPath))
        }
        return node
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        try node(for: key) == .null
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try CanonicalNodeDecoder.unbox(try node(for: key), as: type, codingPath: codingPath + [key])
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try CanonicalSingleValueDecoder(node: try node(for: key), codingPath: codingPath + [key]).decode(type)
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try CanonicalSingleValueDecoder(node: try node(for: key), codingPath: codingPath + [key]).decode(type)
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try CanonicalNodeDecoder.unboxInteger(try node(for: key), as: type, codingPath: codingPath + [key])
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try CanonicalNodeDecoder.unboxInteger(try node(for: key), as: type, codingPath: codingPath + [key])
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try CanonicalNodeDecoder.unboxInteger(try node(for: key), as: type, codingPath: codingPath + [key])
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try CanonicalNodeDecoder(node: try node(for: key), codingPath: codingPath + [key]).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        try CanonicalNodeDecoder(node: try node(for: key), codingPath: codingPath + [key]).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        let key = CanonicalCodingKey(stringValue: "super")
        return CanonicalNodeDecoder(node: entries[CanonicalKey("super")] ?? .null, codingPath: codingPath + [key])
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        CanonicalNodeDecoder(node: entries[CanonicalKey(key.stringValue)] ?? .null, codingPath: codingPath + [key])
    }
}

private struct CanonicalUnkeyedDecoder: UnkeyedDecodingContainer {
    let elements: [CanonicalNode]
    let codingPath: [CodingKey]
    var currentIndex = 0

    init(elements: [CanonicalNode], codingPath: [CodingKey]) {
        self.elements = elements
        self.codingPath = codingPath
    }

    var count: Int? { elements.count }
    var isAtEnd: Bool { currentIndex >= elements.count }

    private mutating func next() throws -> (CanonicalNode, [CodingKey]) {
        guard !isAtEnd else {
            throw CanonicalMessagePackError.missingElement(path: pathString(codingPath))
        }
        defer { currentIndex += 1 }
        return (elements[currentIndex], codingPath + [CanonicalCodingKey(intValue: currentIndex)])
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else {
            throw CanonicalMessagePackError.missingElement(path: pathString(codingPath))
        }
        if elements[currentIndex] == .null {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let (node, path) = try next()
        return try CanonicalNodeDecoder.unbox(node, as: type, codingPath: path)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let (node, path) = try next()
        return try CanonicalNodeDecoder(node: node, codingPath: path).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let (node, path) = try next()
        return try CanonicalNodeDecoder(node: node, codingPath: path).unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        let (node, path) = try next()
        return CanonicalNodeDecoder(node: node, codingPath: path)
    }
}

private struct CanonicalSingleValueDecoder: SingleValueDecodingContainer {
    let node: CanonicalNode
    let codingPath: [CodingKey]

    private func mismatch(_ expected: String) -> CanonicalMessagePackError {
        .typeMismatch(expected: expected, path: pathString(codingPath))
    }

    func decodeNil() -> Bool { node == .null }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard case .bool(let value) = node else { throw mismatch("bool") }
        return value
    }

    func decode(_ type: String.Type) throws -> String {
        guard case .string(let value) = node else { throw mismatch("string") }
        return value
    }

    func decode(_ type: Double.Type) throws -> Double {
        try CanonicalNodeDecoder.unboxDouble(node, codingPath: codingPath)
    }

    func decode(_ type: Float.Type) throws -> Float {
        try CanonicalNodeDecoder.unboxFloat(node, codingPath: codingPath)
    }

    func decode(_ type: Int.Type) throws -> Int { try CanonicalNodeDecoder.unboxInteger(node, as: type, codingPath: codingPath) }
    func decode(_ type: Int8.Type) throws -> Int8 { try CanonicalNodeDecoder.unboxInteger(node, as: type, codingPath: codingPath) }
    func decode(_ type: Int16.Type) throws -> Int16 { try CanonicalNodeDecoder.unboxInteger(node, as: type, codingPath: codingPath) }
    func decode(_ type: Int32.Type) throws -> Int32 { try CanonicalNodeDecoder.unboxInteger(node, as: type, codingPath: codingPath) }
    func decode(_ type: Int64.Type) throws -> Int64 { try CanonicalNodeDecoder.unboxInteger(node, as: type, codingPath: codingPath) }
    func decode(_ type: UInt.Type) throws -> UInt { try CanonicalNodeDecoder.unboxInteger(node, as: type, codingPath: codingPath) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try CanonicalNodeDecoder.unboxInteger(node, as: type, codingPath: codingPath) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try CanonicalNodeDecoder.unboxInteger(node, as: type, codingPath: codingPath) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try CanonicalNodeDecoder.unboxInteger(node, as: type, codingPath: codingPath) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try CanonicalNodeDecoder.unboxInteger(node, as: type, codingPath: codingPath) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try CanonicalNodeDecoder.unbox(node, as: type, codingPath: codingPath)
    }
}

// MARK: - Dates

/// ISO-8601 at whole seconds with `Z`, from and to the integer seconds since 1970 (proleptic
/// Gregorian calendar, days-from-civil), so no platform formatter is involved.
enum CanonicalDate {
    static func format(_ date: Date) throws -> String {
        let interval = date.timeIntervalSince1970
        // 0001-01-01T00:00:00Z and 9999-12-31T23:59:59Z
        guard interval.isFinite, interval >= -62_135_596_800, interval < 253_402_300_800 else {
            throw CanonicalMessagePackError.dateOutOfRange(interval)
        }
        let seconds = Int64(interval.rounded(.down))
        let days = floorDiv(seconds, 86_400)
        let secondOfDay = seconds - days * 86_400
        let (year, month, day) = civil(fromDays: days)
        return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2) + "T"
            + pad(secondOfDay / 3600, 2) + ":" + pad(secondOfDay % 3600 / 60, 2) + ":" + pad(secondOfDay % 60, 2) + "Z"
    }

    static func parse(_ text: String, path: String) throws -> Date {
        let digits = Array(text.utf8)
        func number(_ range: Range<Int>) -> Int64? {
            var value: Int64 = 0
            for index in range {
                let byte = digits[index]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int64(byte - 0x30)
            }
            return value
        }
        let separators: [(Int, UInt8)] = [(4, 0x2d), (7, 0x2d), (10, 0x54), (13, 0x3a), (16, 0x3a), (19, 0x5a)]
        guard digits.count == 20, separators.allSatisfy({ digits[$0.0] == $0.1 }),
              let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              year >= 1, (1...12).contains(month), (1...daysInMonth(year, month)).contains(day),
              hour < 24, minute < 60, second < 60
        else {
            throw CanonicalMessagePackError.typeMismatch(expected: "date YYYY-MM-DDTHH:MM:SSZ", path: path)
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        return Date(timeIntervalSince1970: Double(days * 86_400 + hour * 3600 + minute * 60 + second))
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// Days since 1970-01-01 → (year, month, day).
    private static func civil(fromDays days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    /// (year, month, day) → days since 1970-01-01.
    private static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func daysInMonth(_ year: Int64, _ month: Int64) -> Int64 {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}
