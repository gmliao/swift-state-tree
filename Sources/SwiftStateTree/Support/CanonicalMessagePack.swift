import Foundation

/// A MessagePack encoding whose bytes depend only on the value: the same value gives the same
/// bytes on every platform and in every process.
///
/// Rules (the record format's, see `Notes/plans/2026-11-07-streaming-record-format.md` § 2):
/// - maps have string keys only, sorted by the keys' UTF-8 bytes, with no Unicode normalization;
///   a dictionary keyed by `Int` (or a `CodingKeyRepresentable` key) is written under the keys'
///   string form; a key encoded twice in one container throws. Keys are compared and written by
///   their UTF-8 bytes, and a map holding two spellings that `String ==` equates (an NFC and an
///   NFD spelling) throws as a duplicate key too (#805);
/// - a dictionary with any other key type, and a `Set`, throw (their order isn't deterministic);
/// - integers use the shortest form: unsigned forms for non-negative values, signed for negative;
/// - floats are always float64, `Float` widened; NaN is the one quiet NaN `0x7ff8000000000000`;
/// - a `Date` is its ISO-8601 string at whole seconds with `Z` (`1970-01-01T00:00:00Z`),
///   truncated toward negative infinity, formatted here rather than by `ISO8601DateFormatter`;
/// - an omitted optional (`encodeIfPresent` with `nil`) leaves the key out; `encodeNil` is `0xc0`;
/// - a `CanonicalBinary` is `bin` in its shortest form (`bin8`, `bin16`, `bin32`), from record
///   format 3.7. A plain `Data` keeps its own `Codable`'s form, an array of integers, so values that
///   hold one (resolver outputs, server inputs' record forms) are written as before 3.7 and still
///   read into an `AnyCodable` tree.
///
/// What it can't detect: a custom `encode(to:)` that writes a `Set` or a dictionary itself, element
/// by element (`encode(contentsOf:)`), in iteration order. Only values that reach the encoder as
/// a `Set` or `Dictionary` are checked; recording the same run twice and comparing the bytes is
/// the backstop for the rest.
///
/// The decoder is strict: a value decodes only into a matching type (an integer doesn't decode
/// into `Double`), with one widening rule: a float64 decodes into `Float` only when it converts
/// back to the same `Double`. Duplicate map keys and trailing bytes are rejected. Two keys of one
/// map are duplicates when their bytes are equal, and also when Swift's `String ==` equates them
/// (canonical equivalence: an NFC and an NFD spelling, or "K" and U+212A KELVIN SIGN): a Swift
/// dictionary or a keyed container would keep only one of their values. The encoder refuses to
/// write such a map too, at every depth (#805).
public enum CanonicalMessagePack {
    /// The deepest nesting of arrays and maps the decoder reads, so input from a file can't
    /// overflow the stack; the encoder refuses deeper values too, so it never writes what the
    /// decoder refuses. The encoder checks the depth on the way down, before a value recurses
    /// further, not after the tree is built (#802). Records nest a few levels; the limit also
    /// leaves room for the `Codable` types that recurse over the value. `AnyCodable` takes
    /// direct paths for that reason: through its own `Codable`, 128 levels took more than a
    /// 524 KiB pool thread's stack in a debug build.
    public static let maxDepth = 128

    /// What the canonical encoders' `userInfo` holds: a marker that `AnyCodable.encode(to:)` reads
    /// to refuse a bridged dictionary's merged keys under this encoder only (#805).
    static var encoderUserInfo: [CodingUserInfoKey: Any] { [.canonicalMessagePack: true] }

    /// Encodes `value` canonically.
    public static func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        let node = try CanonicalNodeEncoder.box(value, codingPath: [])
        var writer = CanonicalWriter()
        try writer.write(node)
        return writer.bytes
    }

    /// Whether the value in `bytes` holds a string or a map key that is not NFC. A record read
    /// by a build that writes NFC keys and IDs (#446) uses it to tell an older record whose
    /// hashes it cannot reproduce.
    static func holdsNonNFCText(_ bytes: [UInt8]) throws -> Bool {
        var reader = CanonicalReader(bytes: bytes)
        return holdsNonNFCText(try reader.readValue())
    }

    private static func holdsNonNFCText(_ node: CanonicalNode) -> Bool {
        switch node {
        case .string(let text):
            return !SnapshotValue.isNFC(text)
        case .array(let elements):
            return elements.contains(where: holdsNonNFCText)
        case .map(let entries):
            return entries.contains { !SnapshotValue.isNFC($0.key.string) || holdsNonNFCText($0.value) }
        case .null, .bool, .int, .uint, .double, .binary:
            return false
        }
    }

    /// Decodes a `T` from `bytes`, which must hold exactly one value.
    public static func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        var reader = CanonicalReader(bytes: bytes)
        let node = try reader.readValue()
        guard reader.offset == bytes.count else {
            throw CanonicalMessagePackError.trailingBytes(bytes.count - reader.offset)
        }
        return try CanonicalNodeDecoder.unbox(node, as: type, codingPath: [], integralFloats: false)
    }

    /// Decodes a `T` from `bytes` as `decode(_:from:)` does, and with `integralFloats` also
    /// decodes an integer into `Double` or `Float` when it converts exactly: for a tree read from
    /// JSON, which doesn't keep the float/integer split (`3.0` reads back as `3`, #521).
    package static func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8], integralFloats: Bool) throws -> T {
        var reader = CanonicalReader(bytes: bytes)
        let node = try reader.readValue()
        guard reader.offset == bytes.count else {
            throw CanonicalMessagePackError.trailingBytes(bytes.count - reader.offset)
        }
        return try CanonicalNodeDecoder.unbox(node, as: type, codingPath: [], integralFloats: integralFloats)
    }
}

#if DEBUG
/// Tests (debug builds): how often each growing buffer of the encoder moved to new storage. An
/// append in place moves a buffer only when it outgrows its capacity, O(log n) times for n
/// appends; an append that copies the buffer (a value taken out, appended to and put back)
/// moves it on every append. Counted by buffer: "elements" (an array's slots), "entries" (a
/// map's slots) and "bytes" (the writer's output).
package final class CanonicalBufferMoves: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    package init() {}

    package subscript(_ buffer: String) -> Int { lock.withLock { counts[buffer, default: 0] } }

    func note(_ buffer: String) { lock.withLock { counts[buffer, default: 0] += 1 } }

    /// Runs `append` on `value` and counts a move when its storage changed.
    @inline(__always)
    static func track<T>(_ buffer: String, _ value: inout T, _ append: (inout T) -> Void) {
        guard let moves = CanonicalMessagePack.bufferMovesForTesting else {
            append(&value)
            return
        }
        let before = storage(of: value)
        append(&value)
        if storage(of: value) != before { moves.note(buffer) }
    }

    /// The storage reference of a one-word copy-on-write collection (`Array`, `Dictionary`).
    private static func storage<T>(of value: T) -> Int {
        precondition(MemoryLayout<T>.size == MemoryLayout<Int>.size, "\(T.self) is not a one-word collection")
        return unsafeBitCast(value, to: Int.self)
    }
}

extension CanonicalMessagePack {
    /// Tests (debug builds): counts the encoder's buffer moves in this task.
    @TaskLocal package static var bufferMovesForTesting: CanonicalBufferMoves?

    /// Tests (debug builds): called for each value the encoder, the tree's finish, the writer, the
    /// reader and the decoder visit, so a test can note how deep the stack gets (#802).
    @TaskLocal package static var stackProbeForTesting: (@Sendable () -> Void)?

    /// Tests (debug builds): called where the reader refuses a tree nested past `maxDepth`, before
    /// the throw, so a test can tell that the deep part of a read was sampled (#874).
    @TaskLocal package static var depthRefusalProbeForTesting: (@Sendable () -> Void)?

    /// Tests (debug builds): `AnyCodable` takes its own `encode(to:)` / `init(from:)` instead of
    /// the direct paths, to compare the two.
    @TaskLocal package static var anyCodableGenericForTesting = false
}

/// Whether `AnyCodable` takes the direct paths (always, outside tests).
private var anyCodableDirect: Bool {
    !CanonicalMessagePack.anyCodableGenericForTesting
}
#else
private let anyCodableDirect = true
#endif

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
/// NFD spelling as one key; the format doesn't). A map whose keys differ in bytes but not under
/// `String ==` is refused on both sides (`firstEquivalentDuplicate(in:)`).
struct CanonicalKey: Hashable {
    /// Compared and hashed by its UTF-8 bytes (not by `String`'s canonical equivalence), without
    /// copying them: a decoder looks up every field by a new key.
    let string: String

    init(_ string: String) {
        var string = string
        string.makeContiguousUTF8()
        self.string = string
    }

    var utf8: [UInt8] { Array(string.utf8) }

    /// Whether every byte is ASCII.
    var isASCII: Bool { string.utf8.allSatisfy { $0 < 0x80 } }

    /// The first key, in byte order, that `String ==` equates with a key before it (#805), or nil.
    /// Such keys are distinct for the format but not for a Swift dictionary or a keyed container,
    /// which would keep one of the two values, so the writer and the reader refuse the map as a
    /// duplicate key. Equivalence comes from the standard library's Unicode data. Unicode's
    /// normalization stability policy keeps the decompositions of assigned characters fixed, so a
    /// map whose keys use only characters assigned in this toolchain's Unicode version stays
    /// accepted by a later toolchain; a code point unassigned here can gain a combining class
    /// later. Keys that are all ASCII skip the check: two ASCII strings are equal only when their
    /// bytes are. When any key isn't ASCII, every key is checked, ASCII ones included ("K" and
    /// U+212A). The keys are sorted only after a collision is found, so the key reported
    /// doesn't depend on the insertion or wire order: for a pair, the spelling later in byte
    /// order; for three spellings of one key, the second.
    static func firstEquivalentDuplicate<Keys: Collection>(in keys: Keys) -> String? where Keys.Element == CanonicalKey {
        guard keys.contains(where: { !$0.isASCII }) else { return nil }
        var seen = Set<String>(minimumCapacity: keys.count)
        guard keys.contains(where: { !seen.insert($0.string).inserted }) else { return nil }
        seen.removeAll(keepingCapacity: true)
        for key in keys.sorted(by: { $0.string.utf8.lexicographicallyPrecedes($1.string.utf8) }) where !seen.insert(key.string).inserted {
            return key.string
        }
        return nil
    }

    /// Throws `duplicateKey` for the first equivalent duplicate among `keys`. Out of line, so the
    /// recursive reader's and writer's frames hold none of the check's locals: the stack a value
    /// at the depth limit takes stays within its budget (#802).
    @inline(never)
    static func refuseEquivalentDuplicates(in keys: Dictionary<CanonicalKey, CanonicalNode>.Keys) throws {
        if let duplicate = firstEquivalentDuplicate(in: keys) {
            throw CanonicalMessagePackError.duplicateKey(duplicate)
        }
    }

    static func == (lhs: CanonicalKey, rhs: CanonicalKey) -> Bool {
        var left = lhs.string
        var right = rhs.string
        return left.withUTF8 { a in right.withUTF8 { b in a.elementsEqual(b) } }
    }

    func hash(into hasher: inout Hasher) {
        var string = string
        string.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}

/// Bytes that canonical MessagePack writes as `bin` (#700 K1a: a recorded payload's bytes).
/// Other encoders see a single `Data` value: base64 in JSON.
package struct CanonicalBinary: Codable, Sendable, Equatable {
    package let bytes: Data

    package init(_ bytes: Data) {
        self.bytes = bytes
    }

    package init(from decoder: Decoder) throws {
        bytes = try decoder.singleValueContainer().decode(Data.self)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

/// One decoded or to-be-encoded value.
enum CanonicalNode: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    /// MessagePack `bin`: a `Data`.
    case binary([UInt8])
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
        case let (.binary(a), .binary(b)): return a == b
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
        case .binary: return "bin"
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
        #if DEBUG
        CanonicalBufferMoves.track("entries", &entries) { $0[key] = child }
        #else
        entries[key] = child
        #endif
        return child
    }

    func appendChild() -> CanonicalSlot {
        let child = CanonicalSlot()
        #if DEBUG
        CanonicalBufferMoves.track("elements", &elements) { $0.append(child) }
        #else
        elements.append(child)
        #endif
        return child
    }

    var elementCount: Int { elements.count }

    func node() -> CanonicalNode {
        #if DEBUG
        CanonicalMessagePack.stackProbeForTesting?()
        #endif
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

/// Errors from non-throwing container calls (`nestedContainer(forKey:)` with a repeated key, or
/// past the depth bound), thrown when the encode finishes.
private final class CanonicalEncodingState {
    var deferredError: Error?
}

/// What `AnyCodable.encode(to:)` does with a base, in its order: an `NSNumber` from
/// `JSONSerialization` by its kind, then `Void`, `Bool`, `Int`, `Double`, `String`, an array, a
/// string-keyed dictionary, anything else `Encodable`; and nothing else encodes.
private enum AnyCodableShape {
    case node(CanonicalNode)
    case array([Any])
    case map([String: Any])
    case encodable(any Encodable)
    /// A bridged `NSDictionary` whose cast to `[String: Any]` merged two keys (#805): the key.
    case mergedKey(String)
    /// The base that doesn't encode: the innermost one, as the generic path reports it.
    case invalid(Any)

    @inline(never)
    init(_ base: Any) {
        // An `AnyCodable` holding an `AnyCodable` encodes its base at the same coding path, one
        // `encode(to:)` inside the other. Unwrapping them here keeps a chain of them from
        // recursing at one path, which the depth bound can't see, and a tree of nested
        // `AnyCodable` values to one frame per level.
        var base = base
        while let inner = base as? AnyCodable { base = inner.base }
        if let number = JSONSerializationNumber(base) {
            switch number {
            case .bool(let value): self = .node(.bool(value))
            case .int(let value): self = .node(.int(Int64(value)))
            case .unsigned(let value): self = .node(.uint(value))
            case .double(let value): self = .node(.double(value))
            }
            return
        }
        switch base {
        case is Void: self = .node(.null)
        case let value as Bool: self = .node(.bool(value))
        // `Int` before `Double` matters only on decode: here an `NSNumber` was taken above, and
        // a native `Int` doesn't cast to `Double`, so the two cases never compete.
        case let value as Int: self = .node(.int(Int64(value)))
        case let value as Double: self = .node(.double(value))
        case let value as String: self = .node(.string(value))
        case let value as [Any]: self = .array(value)
        case let value as [String: Any]:
            if let merged = AnyCodable.keyMergedByBridging(base, into: value) {
                self = .mergedKey(merged)
            } else {
                self = .map(value)
            }
        case let value as any Encodable: self = .encodable(value)
        default: self = .invalid(base)
        }
    }
}

private struct CanonicalNodeEncoder: Encoder {
    let slot: CanonicalSlot
    let state: CanonicalEncodingState
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { CanonicalMessagePack.encoderUserInfo }

    /// Whether a value or a container at `codingPath` is within the depth bound. A non-throwing
    /// call (`nestedContainer`, `superEncoder`) past it records the error for the end of the
    /// encode and writes into a detached slot, so the tree never grows past the bound, however
    /// the value descends (#802): every way down passes this check.
    ///
    /// `deferredError` keeps the first error recorded, so a depth refusal recorded first is the
    /// one thrown even when a later call records a `duplicateKey`, and it stands even if the
    /// value's `encode(to:)` drops that container and writes something else. Either way the
    /// encode is refused; only which error names it depends on the order.
    static func withinDepth(_ codingPath: [CodingKey], state: CanonicalEncodingState) -> Bool {
        if codingPath.count <= CanonicalMessagePack.maxDepth { return true }
        if state.deferredError == nil { state.deferredError = CanonicalMessagePackError.nestingTooDeep }
        return false
    }

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
        // The depth is checked on the way down, before the value recurses (#802): a value under
        // more than `maxDepth` keys sits inside more than `maxDepth` arrays and maps, which the
        // writer refuses anyway, and a deep enough value would overflow the stack before it got
        // there. A value at `maxDepth` keys that opens a container is left to the writer.
        guard codingPath.count <= CanonicalMessagePack.maxDepth else {
            throw CanonicalMessagePackError.nestingTooDeep
        }
        #if DEBUG
        CanonicalMessagePack.stackProbeForTesting?()
        #endif
        if T.self == AnyCodable.self, anyCodableDirect, let any = value as? AnyCodable {
            try encodeAnyCodable(any.base, into: slot, state: state, codingPath: codingPath)
            return
        }
        if let date = value as? Date {
            slot.setValue(.string(try CanonicalDate.format(date)))
            return
        }
        if let binary = value as? CanonicalBinary {
            slot.setValue(.binary(Array(binary.bytes)))
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

    /// `AnyCodable.encode(to:)`, written into `slot` directly (#802). The generic path goes through
    /// `AnyCodable`'s single-value container and `Array` / `Dictionary`'s own `encode(to:)`, about
    /// 4 KB of stack per level in a debug build: a tree at the depth limit overflows a 524 KiB
    /// pool thread. This takes the same cases in the same order (`AnyCodableShape`) and writes the same
    /// nodes at the same coding paths, with the same key types (`Int` positions as
    /// `CanonicalCodingKey`, as the unkeyed container names them; dictionary keys as `String`'s own
    /// `codingKey`, as `Dictionary.encode(to:)` names them), so the bytes and the errors are the
    /// same. Anything else `Encodable` takes the generic path, as `AnyCodable` does. The recursive
    /// part holds containers only: the casts happen in `AnyCodableShape`, whose frame is gone
    /// before the next level starts.
    static func encodeAnyCodable(
        _ base: Any, into slot: CanonicalSlot, state: CanonicalEncodingState, codingPath: [CodingKey]
    ) throws {
        guard codingPath.count <= CanonicalMessagePack.maxDepth else {
            throw CanonicalMessagePackError.nestingTooDeep
        }
        #if DEBUG
        CanonicalMessagePack.stackProbeForTesting?()
        #endif
        switch AnyCodableShape(base) {
        case .node(let node):
            slot.setValue(node)
        case .array(let elements):
            slot.becomeArray()
            for index in elements.indices {
                try encodeAnyCodable(
                    elements[index], into: slot.appendChild(), state: state,
                    codingPath: codingPath + [CanonicalCodingKey(intValue: index)]
                )
            }
        case .map(let entries):
            slot.becomeMap()
            for (key, element) in entries {
                // Keys of one dictionary are distinct strings, so distinct UTF-8 bytes too.
                guard let child = slot.insertChild(CanonicalKey(key)) else {
                    throw CanonicalMessagePackError.duplicateKey(key)
                }
                try encodeAnyCodable(
                    element, into: child, state: state,
                    codingPath: codingPath + [key.codingKey]
                )
            }
        case .encodable(let value):
            try encode(value, into: slot, state: state, codingPath: codingPath)
        case .mergedKey(let key):
            throw CanonicalMessagePackError.duplicateKey(key)
        case .invalid(let invalid):
            throw EncodingError.invalidValue(invalid, EncodingError.Context(
                codingPath: codingPath,
                debugDescription: "AnyCodable value cannot be encoded"
            ))
        }
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

    /// The slot a nested container or super encoder under `key` writes into: detached past the
    /// depth bound.
    private func nestedChild(for key: CodingKey) -> CanonicalSlot {
        guard CanonicalNodeEncoder.withinDepth(codingPath + [key], state: state) else { return CanonicalSlot() }
        return deferredChild(for: key)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let child = nestedChild(for: key)
        child.becomeMap()
        return KeyedEncodingContainer(CanonicalKeyedEncoder<NestedKey>(slot: child, state: state, codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let child = nestedChild(for: key)
        child.becomeArray()
        return CanonicalUnkeyedEncoder(slot: child, state: state, codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> Encoder {
        let key = CanonicalCodingKey(stringValue: "super")
        return CanonicalNodeEncoder(slot: nestedChild(for: key), state: state, codingPath: codingPath + [key])
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        CanonicalNodeEncoder(slot: nestedChild(for: key), state: state, codingPath: codingPath + [key])
    }
}

private struct CanonicalUnkeyedEncoder: UnkeyedEncodingContainer {
    let slot: CanonicalSlot
    let state: CanonicalEncodingState
    let codingPath: [CodingKey]

    /// Children refused past the depth bound. They are detached, but each still takes a
    /// position: a refusal can't throw, so `count` must advance as an append does, or an
    /// `encode(to:)` that fills the container until `count` reaches a target never ends (#809).
    private var refused = 0

    var count: Int { slot.elementCount + refused }

    private func append() -> CanonicalSlot { slot.appendChild() }

    /// The slot a nested container or super encoder at the next position writes into: detached
    /// past the depth bound, counted all the same.
    private mutating func appendNested(at key: CodingKey) -> CanonicalSlot {
        guard CanonicalNodeEncoder.withinDepth(codingPath + [key], state: state) else {
            refused += 1
            return CanonicalSlot()
        }
        return append()
    }

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
        let child = appendNested(at: key)
        child.becomeMap()
        return KeyedEncodingContainer(CanonicalKeyedEncoder<NestedKey>(slot: child, state: state, codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let key = nextKey
        let child = appendNested(at: key)
        child.becomeArray()
        return CanonicalUnkeyedEncoder(slot: child, state: state, codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> Encoder {
        let key = nextKey
        return CanonicalNodeEncoder(slot: appendNested(at: key), state: state, codingPath: codingPath + [key])
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
        #if DEBUG
        CanonicalMessagePack.stackProbeForTesting?()
        #endif
        switch node {
        case .null:
            put(0xc0)
        case .bool(let value):
            put(value ? 0xc3 : 0xc2)
        case .int(let value):
            if value >= 0 {
                writeUnsigned(UInt64(value))
            } else {
                writeNegative(value)
            }
        case .uint(let value):
            writeUnsigned(value)
        case .double(let value):
            put(0xcb)
            let bits = value.isNaN ? 0x7ff8_0000_0000_0000 : value.bitPattern
            appendBigEndian(bits, width: 8)
        case .string(let value):
            let utf8 = Array(value.utf8)
            try writeHeader(count: utf8.count, fix: 0xa0, fixMax: 31, u8: 0xd9, u16: 0xda, u32: 0xdb)
            put(contentsOf: utf8)
        case .binary(let value):
            // `bin` has no fix form: the count's shortest width.
            guard value.count <= Int(UInt32.max) else { throw CanonicalMessagePackError.lengthTooLarge(value.count) }
            let n = UInt64(value.count)
            if value.count <= 0xff {
                put(0xc4); appendBigEndian(n, width: 1)
            } else if value.count <= 0xffff {
                put(0xc5); appendBigEndian(n, width: 2)
            } else {
                put(0xc6); appendBigEndian(n, width: 4)
            }
            put(contentsOf: value)
        case .array(let elements):
            try enter()
            defer { depth -= 1 }
            try writeHeader(count: elements.count, fix: 0x90, fixMax: 15, u8: nil, u16: 0xdc, u32: 0xdd)
            for element in elements { try write(element) }
        case .map(let entries):
            try enter()
            defer { depth -= 1 }
            // Refused, not normalized: the reader refuses it the same way (#805).
            try CanonicalKey.refuseEquivalentDuplicates(in: entries.keys)
            try writeHeader(count: entries.count, fix: 0x80, fixMax: 15, u8: nil, u16: 0xde, u32: 0xdf)
            let sorted = entries.map { (key: $0.key.utf8, value: $0.value) }
                .sorted { $0.key.lexicographicallyPrecedes($1.key) }
            for entry in sorted {
                try writeHeader(count: entry.key.count, fix: 0xa0, fixMax: 31, u8: 0xd9, u16: 0xda, u32: 0xdb)
                put(contentsOf: entry.key)
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
        case 0...0x7f: put(UInt8(value))
        case 0x80...0xff: put(0xcc); put(UInt8(value))
        case 0x100...0xffff: put(0xcd); appendBigEndian(value, width: 2)
        case 0x1_0000...0xffff_ffff: put(0xce); appendBigEndian(value, width: 4)
        default: put(0xcf); appendBigEndian(value, width: 8)
        }
    }

    private mutating func writeNegative(_ value: Int64) {
        let bits = UInt64(bitPattern: value)
        switch value {
        case -32...(-1): put(UInt8(truncatingIfNeeded: bits))
        case -128...(-33): put(0xd0); appendBigEndian(bits, width: 1)
        case -32768...(-129): put(0xd1); appendBigEndian(bits, width: 2)
        case -2_147_483_648...(-32769): put(0xd2); appendBigEndian(bits, width: 4)
        default: put(0xd3); appendBigEndian(bits, width: 8)
        }
    }

    private mutating func writeHeader(count: Int, fix: UInt8, fixMax: Int, u8: UInt8?, u16: UInt8, u32: UInt8) throws {
        guard count <= Int(UInt32.max) else { throw CanonicalMessagePackError.lengthTooLarge(count) }
        let n = UInt64(count)
        if count <= fixMax {
            put(fix | UInt8(count))
        } else if let u8, count <= 0xff {
            put(u8); appendBigEndian(n, width: 1)
        } else if count <= 0xffff {
            put(u16); appendBigEndian(n, width: 2)
        } else {
            put(u32); appendBigEndian(n, width: 4)
        }
    }

    /// Every write goes through these two, so a test can count the output buffer's moves.
    private mutating func put(_ byte: UInt8) {
        #if DEBUG
        CanonicalBufferMoves.track("bytes", &bytes) { $0.append(byte) }
        #else
        bytes.append(byte)
        #endif
    }

    private mutating func put(contentsOf more: [UInt8]) {
        #if DEBUG
        CanonicalBufferMoves.track("bytes", &bytes) { $0.append(contentsOf: more) }
        #else
        bytes.append(contentsOf: more)
        #endif
    }

    private mutating func appendBigEndian(_ value: UInt64, width: Int) {
        for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
            put(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
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
        #if DEBUG
        CanonicalMessagePack.stackProbeForTesting?()
        #endif
        let type = try readByte()
        switch type {
        case 0x00...0x7f: return .uint(UInt64(type))
        case 0x80...0x8f: return try readMap(count: Int(type & 0x0f))
        case 0x90...0x9f: return try readArray(count: Int(type & 0x0f))
        case 0xa0...0xbf: return try readString(count: Int(type & 0x1f))
        case 0xc0: return .null
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)
        case 0xc4: return .binary(try readBytes(count: Int(try readBigEndian(1))))
        case 0xc5: return .binary(try readBytes(count: Int(try readBigEndian(2))))
        case 0xc6: return .binary(try readBytes(count: Int(try readBigEndian(4))))
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

    private mutating func readBytes(count: Int) throws -> [UInt8] {
        guard bytes.count - offset >= count else { throw CanonicalMessagePackError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
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
        guard depth <= CanonicalMessagePack.maxDepth else {
            #if DEBUG
            // The refusal's leaf, below the last `readValue` probe: the deepest sampled point of a
            // read of a too-deep tree (#874). The error's boxing and the unwinding run after it.
            CanonicalMessagePack.depthRefusalProbeForTesting?()
            #endif
            throw CanonicalMessagePackError.nestingTooDeep
        }
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
        // Distinct bytes, and distinct under `String ==` too (#805).
        try CanonicalKey.refuseEquivalentDuplicates(in: entries.keys)
        return .map(entries)
    }
}

// MARK: - Decoder

private struct CanonicalNodeDecoder: Decoder {
    let node: CanonicalNode
    let codingPath: [CodingKey]
    /// An integer decodes into `Double` or `Float` when it converts exactly (`decode(_:from:integralFloats:)`).
    let integralFloats: Bool
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    static func unbox<T: Decodable>(_ node: CanonicalNode, as type: T.Type, codingPath: [CodingKey], integralFloats: Bool) throws -> T {
        #if DEBUG
        CanonicalMessagePack.stackProbeForTesting?()
        #endif
        if type == Date.self {
            guard case .string(let text) = node else {
                throw CanonicalMessagePackError.typeMismatch(expected: "date string", path: pathString(codingPath))
            }
            return try CanonicalDate.parse(text, path: pathString(codingPath)) as! T
        }
        if type == CanonicalBinary.self {
            guard case .binary(let value) = node else {
                throw CanonicalMessagePackError.typeMismatch(expected: "bin", path: pathString(codingPath))
            }
            return CanonicalBinary(Data(value)) as! T
        }
        if type == Double.self { return try unboxDouble(node, codingPath: codingPath, integralFloats: integralFloats) as! T }
        if type == Float.self { return try unboxFloat(node, codingPath: codingPath, integralFloats: integralFloats) as! T }
        if type == AnyCodable.self, anyCodableDirect {
            guard let base = anyCodableBase(node, integralFloats: integralFloats) else {
                // `AnyCodable.init(from:)`'s error: its nested attempts are `try?`, so a value
                // that fails anywhere inside fails here, at the outermost `AnyCodable`.
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "AnyCodable value cannot be decoded"
                ))
            }
            return AnyCodable(base) as! T
        }
        return try T(from: CanonicalNodeDecoder(node: node, codingPath: codingPath, integralFloats: integralFloats))
    }

    /// `AnyCodable.init(from:)` over a node, without a decoder (#802): the same attempts in the
    /// same order (nil, `Bool`, `Int`, `Double`, `String`, an array, a string-keyed dictionary),
    /// each matched as this decoder's single-value container matches it, and `nil` where
    /// `AnyCodable` would throw. The generic path costs about 4 KB of stack per level in a debug
    /// build; the reader has already bounded the node's depth. The recursive part holds
    /// containers only; scalars are matched in `anyCodableScalar`.
    ///
    /// A map that holds two spellings of one key that `String` equates (NFC and NFD) never gets
    /// here: the reader refuses it as a duplicate key (#805).
    static func anyCodableBase(_ node: CanonicalNode, integralFloats: Bool) -> Any? {
        #if DEBUG
        CanonicalMessagePack.stackProbeForTesting?()
        #endif
        switch node {
        case .array(let elements):
            var bases: [Any] = []
            bases.reserveCapacity(elements.count)
            for index in elements.indices {
                guard let base = anyCodableBase(elements[index], integralFloats: integralFloats) else { return nil }
                bases.append(base)
            }
            return bases
        case .map(let entries):
            var bases: [String: Any] = [:]
            for (key, value) in entries {
                guard let base = anyCodableBase(value, integralFloats: integralFloats) else { return nil }
                bases[key.string] = base
            }
            return bases
        default:
            return anyCodableScalar(node, integralFloats: integralFloats)
        }
    }

    /// `anyCodableBase` for a node that isn't a container.
    @inline(never)
    static func anyCodableScalar(_ node: CanonicalNode, integralFloats: Bool) -> Any? {
        switch node {
        case .null:
            return ()
        case .bool(let value):
            return value
        case .int, .uint:
            if let value = try? unboxInteger(node, as: Int.self, codingPath: []) { return value }
            if let value = try? unboxDouble(node, codingPath: [], integralFloats: integralFloats) { return value }
            return nil
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .binary, .array, .map:
            return nil
        }
    }

    static func unboxDouble(_ node: CanonicalNode, codingPath: [CodingKey], integralFloats: Bool) throws -> Double {
        switch node {
        case .double(let value):
            return value
        case .int(let value) where integralFloats:
            if let exact = Double(exactly: value) { return exact }
        case .uint(let value) where integralFloats:
            if let exact = Double(exactly: value) { return exact }
        default:
            break
        }
        throw CanonicalMessagePackError.typeMismatch(expected: "float64", path: pathString(codingPath))
    }

    static func unboxFloat(_ node: CanonicalNode, codingPath: [CodingKey], integralFloats: Bool) throws -> Float {
        let value = try unboxDouble(node, codingPath: codingPath, integralFloats: integralFloats)
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
        return KeyedDecodingContainer(CanonicalKeyedDecoder<Key>(entries: entries, codingPath: codingPath, integralFloats: integralFloats))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let elements) = node else {
            throw CanonicalMessagePackError.typeMismatch(expected: "array", path: pathString(codingPath))
        }
        return CanonicalUnkeyedDecoder(elements: elements, codingPath: codingPath, integralFloats: integralFloats)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        CanonicalSingleValueDecoder(node: node, codingPath: codingPath, integralFloats: integralFloats)
    }
}

private struct CanonicalKeyedDecoder<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let entries: [CanonicalKey: CanonicalNode]
    let codingPath: [CodingKey]
    let integralFloats: Bool

    /// In the encoder's order, by the keys' UTF-8 bytes, so a decoder that walks the keys sees
    /// the same order on every run (the dictionary's own order follows the per-process seed).
    var allKeys: [Key] {
        entries.keys.sorted { $0.string.utf8.lexicographicallyPrecedes($1.string.utf8) }
            .compactMap { Key(stringValue: $0.string) }
    }

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

    /// The node at `key`, or `nil` when it is absent or null: one lookup, where the default
    /// `decodeIfPresent` makes three (`contains`, `decodeNil`, then `decode`).
    private func presentNode(for key: Key) -> CanonicalNode? {
        guard let node = entries[CanonicalKey(key.stringValue)] else { return nil }
        if case .null = node { return nil }
        return node
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard let node = presentNode(for: key) else { return nil }
        return try CanonicalNodeDecoder.unbox(node, as: type, codingPath: codingPath + [key], integralFloats: integralFloats)
    }

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? {
        guard let node = presentNode(for: key) else { return nil }
        return try CanonicalSingleValueDecoder(node: node, codingPath: codingPath + [key], integralFloats: integralFloats).decode(type)
    }

    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? {
        guard let node = presentNode(for: key) else { return nil }
        return try CanonicalSingleValueDecoder(node: node, codingPath: codingPath + [key], integralFloats: integralFloats).decode(type)
    }

    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? {
        guard let node = presentNode(for: key) else { return nil }
        return try CanonicalNodeDecoder.unboxInteger(node, as: type, codingPath: codingPath + [key])
    }

    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? {
        guard let node = presentNode(for: key) else { return nil }
        return try CanonicalNodeDecoder.unboxInteger(node, as: type, codingPath: codingPath + [key])
    }

    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? {
        guard let node = presentNode(for: key) else { return nil }
        return try CanonicalNodeDecoder.unboxInteger(node, as: type, codingPath: codingPath + [key])
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try CanonicalNodeDecoder.unbox(try node(for: key), as: type, codingPath: codingPath + [key], integralFloats: integralFloats)
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try CanonicalSingleValueDecoder(node: try node(for: key), codingPath: codingPath + [key], integralFloats: integralFloats).decode(type)
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try CanonicalSingleValueDecoder(node: try node(for: key), codingPath: codingPath + [key], integralFloats: integralFloats).decode(type)
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
        try CanonicalNodeDecoder(node: try node(for: key), codingPath: codingPath + [key], integralFloats: integralFloats).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        try CanonicalNodeDecoder(node: try node(for: key), codingPath: codingPath + [key], integralFloats: integralFloats).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        let key = CanonicalCodingKey(stringValue: "super")
        return CanonicalNodeDecoder(node: entries[CanonicalKey("super")] ?? .null, codingPath: codingPath + [key], integralFloats: integralFloats)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        CanonicalNodeDecoder(node: entries[CanonicalKey(key.stringValue)] ?? .null, codingPath: codingPath + [key], integralFloats: integralFloats)
    }
}

private struct CanonicalUnkeyedDecoder: UnkeyedDecodingContainer {
    let elements: [CanonicalNode]
    let codingPath: [CodingKey]
    let integralFloats: Bool
    var currentIndex = 0

    init(elements: [CanonicalNode], codingPath: [CodingKey], integralFloats: Bool) {
        self.elements = elements
        self.codingPath = codingPath
        self.integralFloats = integralFloats
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
        return try CanonicalNodeDecoder.unbox(node, as: type, codingPath: path, integralFloats: integralFloats)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let (node, path) = try next()
        return try CanonicalNodeDecoder(node: node, codingPath: path, integralFloats: integralFloats).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let (node, path) = try next()
        return try CanonicalNodeDecoder(node: node, codingPath: path, integralFloats: integralFloats).unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        let (node, path) = try next()
        return CanonicalNodeDecoder(node: node, codingPath: path, integralFloats: integralFloats)
    }
}

private struct CanonicalSingleValueDecoder: SingleValueDecodingContainer {
    let node: CanonicalNode
    let codingPath: [CodingKey]
    let integralFloats: Bool

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
        try CanonicalNodeDecoder.unboxDouble(node, codingPath: codingPath, integralFloats: integralFloats)
    }

    func decode(_ type: Float.Type) throws -> Float {
        try CanonicalNodeDecoder.unboxFloat(node, codingPath: codingPath, integralFloats: integralFloats)
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
        try CanonicalNodeDecoder.unbox(node, as: type, codingPath: codingPath, integralFloats: integralFloats)
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
