// Sources/SwiftStateTree/Sync/SnapshotValue.swift

import Foundation

/// Allowed data types for snapshots, used for JSON-friendly output structures.
public enum SnapshotValue: Equatable, Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([SnapshotValue])
    case object([String: SnapshotValue])

    public var objectValue: [String: SnapshotValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var arrayValue: [SnapshotValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case let .int(value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case let .double(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    // MARK: - Custom Codable Implementation

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .int(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .double(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for element in values {
                try container.encode(element)
            }
        case .object(let values):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in values {
                guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
                try container.encode(value, forKey: codingKey)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let singleValueContainer = try decoder.singleValueContainer()

        if singleValueContainer.decodeNil() {
            self = .null
            return
        }
        if let boolValue = try? singleValueContainer.decode(Bool.self) {
            self = .bool(boolValue)
            return
        }
        if let intValue = try? singleValueContainer.decode(Int.self) {
            self = .int(intValue)
            return
        }
        if let doubleValue = try? singleValueContainer.decode(Double.self) {
            self = .double(doubleValue)
            return
        }
        if let stringValue = try? singleValueContainer.decode(String.self) {
            self = .string(stringValue)
            return
        }
        if let arrayValue = try? singleValueContainer.decode([SnapshotValue].self) {
            self = .array(arrayValue)
            return
        }
        if let objectValue = try? singleValueContainer.decode([String: SnapshotValue].self) {
            self = .object(objectValue)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: singleValueContainer,
            debugDescription: "Unsupported SnapshotValue payload"
        )
    }
}

/// Protocol for types that can efficiently convert themselves to SnapshotValue
/// without using runtime reflection.
///
/// Types conforming to this protocol can provide their own conversion implementation,
/// which avoids the performance overhead of using Mirror for reflection.
///
/// **Recommended Usage**: Use `@SnapshotConvertible` macro to automatically generate
/// the protocol conformance implementation.
///
/// Example with macro (recommended):
/// ```swift
/// @SnapshotConvertible
/// struct PlayerState: Codable {
///     var name: String
///     var hpCurrent: Int
///     var hpMax: Int
/// }
/// // Macro automatically generates the protocol conformance
/// ```
///
/// Example with manual implementation:
/// ```swift
/// extension PlayerState: SnapshotValueConvertible {
///     func toSnapshotValue() throws -> SnapshotValue {
///         return .object([
///             "name": .string(name),
///             "hpCurrent": .int(hpCurrent),
///             "hpMax": .int(hpMax)
///         ])
///     }
/// }
/// ```
public protocol SnapshotValueConvertible {
    func toSnapshotValue() throws -> SnapshotValue
}

public extension SnapshotValue {
    /// An unsigned integer: `.int` when it fits in `Int`, else its decimal digits as `.string`.
    /// A value above `Int.max` used to trap in `Int(_:)`; it is now sent and hashed losslessly.
    static func unsigned<T: UnsignedInteger & FixedWidthInteger>(_ value: T) -> SnapshotValue {
        if let fitting = Int(exactly: value) {
            return .int(fitting)
        }
        return .string(String(value))
    }

    static func make(from value: Any, for playerID: PlayerID? = nil) throws -> SnapshotValue {
        // Short-circuit if value is already a snapshot-friendly type
        if let snapshotValue = value as? SnapshotValue {
            return snapshotValue
        }
        if let snapshot = value as? StateSnapshot {
            return .object(snapshot.values)
        }
        
        // Priority 1: Check if type conforms to StateNodeProtocol (for recursive filtering)
        // This must be checked before SnapshotValueConvertible to enable recursive @Sync policy filtering
        if let stateNode = value as? any StateNodeProtocol {
            // Recursively apply @Sync policies by calling snapshot(for:)
            let snapshot = try stateNode.snapshot(for: playerID, dirtyFields: nil)
            // Convert StateSnapshot to SnapshotValue.object
            return .object(snapshot.values)
        }
        
        // Priority 2: Check if type conforms to SnapshotValueConvertible (best performance)
        if let convertible = value as? SnapshotValueConvertible {
            return try convertible.toSnapshotValue()
        }
        
        // Priority 3: Handle known collection types directly (avoid Mirror overhead)
        // This significantly reduces dynamic dispatch overhead for common types
        if let arrayValue = value as? [SnapshotValue] {
            return .array(arrayValue)
        }
        if let dictValue = value as? [String: SnapshotValue] {
            return .object(dictValue)
        }
        if let playerSnapshotDict = value as? [PlayerID: SnapshotValue] {
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(playerSnapshotDict.count)
            for (key, val) in playerSnapshotDict {
                object[key.rawValue] = val
            }
            return .object(object)
        }
        
        // Priority 4: Handle other common collection types directly
        if let stringArray = value as? [String] {
            let mapped = stringArray.map { SnapshotValue.string($0) }
            return .array(mapped)
        }
        if let intArray = value as? [Int] {
            let mapped = intArray.map { SnapshotValue.int($0) }
            return .array(mapped)
        }
        // Map elements go through `make` again, never straight to `toSnapshotValue()`: a state
        // node that is also `SnapshotValueConvertible` (`@SnapshotConvertible`) must still be
        // converted by its own `@Sync` policies, and `make` checks `StateNodeProtocol` first (#175).
        if let playerConvertibleDict = value as? [PlayerID: SnapshotValueConvertible] {
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(playerConvertibleDict.count)
            for (key, val) in playerConvertibleDict {
                object[key.rawValue] = try make(from: val, for: playerID)
            }
            return .object(object)
        }
        if let playerStateNodeDict = value as? [PlayerID: any StateNodeProtocol] {
            // Process all StateNodes in the dictionary (including single-element dictionaries from perPlayerSlice)
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(playerStateNodeDict.count)
            for (key, val) in playerStateNodeDict {
                let snapshot = try val.snapshot(for: playerID, dirtyFields: nil)
                object[key.rawValue] = .object(snapshot.values)
            }
            return .object(object)
        }
        if let stringConvertibleDict = value as? [String: SnapshotValueConvertible] {
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(stringConvertibleDict.count)
            for (key, val) in stringConvertibleDict {
                object[key] = try make(from: val, for: playerID)
            }
            return .object(object)
        }
        if let dictStringAny = value as? [String: Any] {
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(dictStringAny.count)
            for (key, val) in dictStringAny {
                object[key] = try make(from: val, for: playerID)
            }
            return .object(object)
        }
        if let playerIDDict = value as? [PlayerID: Any] {
            // Treat as a normal dictionary (including single-element dictionaries from perPlayerSlice)
            // The structure is consistent: server and client both see dictionary structure
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(playerIDDict.count)
            for (key, val) in playerIDDict {
                object[key.rawValue] = try make(from: val, for: playerID)
            }
            return .object(object)
        }
        
        // Priority 5: Handle basic types directly (no Mirror needed)
        if value is NSNull {
            return .null
        }
        switch value {
        case let boolValue as Bool:
            return .bool(boolValue)
        case let intValue as Int:
            return .int(intValue)
        case let int8Value as Int8:
            return .int(Int(int8Value))
        case let int16Value as Int16:
            return .int(Int(int16Value))
        case let int32Value as Int32:
            return .int(Int(int32Value))
        case let int64Value as Int64:
            return .int(Int(int64Value))
        case let uintValue as UInt:
            return unsigned(uintValue)
        case let uint8Value as UInt8:
            return .int(Int(uint8Value))
        case let uint16Value as UInt16:
            return .int(Int(uint16Value))
        case let uint32Value as UInt32:
            return .int(Int(uint32Value))
        case let uint64Value as UInt64:
            return unsigned(uint64Value)
        case let doubleValue as Double:
            return .double(doubleValue)
        case let floatValue as Float:
            return .double(Double(floatValue))
        case let stringValue as String:
            return .string(stringValue)
        case let playerID as PlayerID:
            return .string(playerID.rawValue)
        // Strings on the wire, like their Codable form (#154)
        case let clientID as ClientID:
            return .string(clientID.rawValue)
        case let sessionID as SessionID:
            return .string(sessionID.rawValue)
        case let landID as LandID:
            return .string(landID.rawValue)
        default:
            break
        }

        let mirror = Mirror(reflecting: value)

        if mirror.displayStyle == .optional {
            if let child = mirror.children.first {
                return try make(from: child.value, for: playerID)
            } else {
                return .null
            }
        }

        switch mirror.displayStyle {
        case .collection:
            // Optimize: Direct iteration instead of map to reduce dynamic dispatch
            // Pre-count children if possible for capacity reservation
            let childrenArray = Array(mirror.children)
            var array: [SnapshotValue] = []
            array.reserveCapacity(childrenArray.count)
            for child in childrenArray {
                array.append(try make(from: child.value, for: playerID))
            }
            return .array(array)
        case .dictionary:
            // Optimize: Pre-allocate capacity and use direct iteration
            let childrenArray = Array(mirror.children)
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(childrenArray.count)
            for child in childrenArray {
                let pair = Mirror(reflecting: child.value)
                guard pair.children.count == 2 else {
                    throw SyncError.unsupportedValue("Dictionary entry must contain exactly two children.")
                }
                // Use Array conversion to avoid iterator overhead
                let pairChildren = Array(pair.children)
                let keyMirror = pairChildren[0]
                let valueMirror = pairChildren[1]
                let keyString = try makeKeyString(from: keyMirror.value)
                let mappedValue = try make(from: valueMirror.value, for: playerID)
                object[keyString] = mappedValue
            }
            return .object(object)
        case .struct, .class:
            // Optimize: Pre-allocate capacity based on expected field count
            let childrenArray = Array(mirror.children)
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(childrenArray.count)
            for child in childrenArray {
                guard let label = child.label else { continue }
                if playerID == nil {
                    try refusePlayerDependentNode(child.value, in: value)
                }
                object[label] = try make(from: child.value, for: playerID)
            }
            return .object(object)
        default:
            throw SyncError.unsupportedValue("Unsupported type: \(type(of: value))")
        }
    }

    /// The view without a player (a broadcast encoding) of a plain struct or class that holds a
    /// state node with player-dependent fields would leave those fields out for every player
    /// (#179). `SyncPolicyNesting.validate` rejects that shape where a default instance shows it;
    /// this refuses the rest (a holder that was in an empty collection then).
    private static func refusePlayerDependentNode(_ child: Any, in holder: Any) throws {
        guard let node = child as? any StateNodeProtocol,
              SyncPolicyNesting.hasPlayerDependentFields(type(of: node))
        else { return }
        throw SyncError.unsupportedValue(
            "\(type(of: holder)) holds the state node \(type(of: node)), which has player-dependent fields, under a broadcast field: those fields would reach no player (#179)"
        )
    }

    private static func makeKeyString(from value: Any) throws -> String {
        if let playerID = value as? PlayerID {
            return playerID.rawValue
        }
        if let stringKey = value as? String {
            return stringKey
        }
        if let convertible = value as? CustomStringConvertible {
            return convertible.description
        }
        throw SyncError.unsupportedKey("Unsupported dictionary key type: \(type(of: value))")
    }
}

// MARK: - Full conversion (replay state hash)

/// A value's conversion for the replay state hash (#180), when it differs from
/// `toSnapshotValue()`: every stored property through `SnapshotValue.makeFull`, so state nodes
/// it holds contribute their full state. `@SnapshotConvertible` generates it. A value with only
/// a hand-written `toSnapshotValue()` is hashed through that, as clients see it.
public protocol FullSnapshotValueConvertible {
    func toFullSnapshotValue() throws -> SnapshotValue
}

public extension SnapshotValue {
    /// Converts `value` for the replay state hash (#180), ignoring every `@Sync` policy: a state
    /// node contributes `fullStateSnapshot()`, at any depth (maps, arrays, sets, optionals,
    /// nested nodes); everything else converts as for clients.
    ///
    /// The result is deterministic for equal state: map keys become strings as for clients and
    /// two keys that collide as strings throw, and set elements are ordered by their canonical
    /// encoding under this conversion. Never used on a client path.
    static func makeFull(from value: Any) throws -> SnapshotValue {
        if let snapshotValue = value as? SnapshotValue {
            return snapshotValue
        }
        if let snapshot = value as? StateSnapshot {
            return .object(snapshot.values)
        }
        if let stateNode = value as? any StateNodeProtocol {
            FullStateConversionProbe.record()
            return .object(try stateNode.fullStateSnapshot().values)
        }
        if let leaf = fullLeaf(value) {
            return leaf
        }
        if let full = value as? FullSnapshotValueConvertible {
            return try full.toFullSnapshotValue()
        }
        if let convertible = value as? SnapshotValueConvertible {
            return try convertible.toSnapshotValue()
        }
        // Common containers without Mirror.
        if let dict = value as? [String: Any] {
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(dict.count)
            for (key, element) in dict {
                object[key] = try makeFull(from: element)
            }
            return .object(object)
        }
        if let dict = value as? [PlayerID: Any] {
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(dict.count)
            for (key, element) in dict {
                object[key.rawValue] = try makeFull(from: element)
            }
            return .object(object)
        }

        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            guard let child = mirror.children.first else { return .null }
            return try makeFull(from: child.value)
        case .collection:
            var array: [SnapshotValue] = []
            array.reserveCapacity(Int(mirror.children.count))
            for child in mirror.children {
                array.append(try makeFull(from: child.value))
            }
            return .array(array)
        case .set:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var keyed: [(key: [UInt8], value: SnapshotValue)] = []
            for child in mirror.children {
                let converted = try makeFull(from: child.value)
                keyed.append((Array(try encoder.encode(converted)), converted))
            }
            keyed.sort { $0.key.lexicographicallyPrecedes($1.key) }
            return .array(keyed.map(\.value))
        case .dictionary:
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(Int(mirror.children.count))
            for child in mirror.children {
                let pair = Array(Mirror(reflecting: child.value).children)
                guard pair.count == 2 else {
                    throw SyncError.unsupportedValue("Dictionary entry must contain exactly two children.")
                }
                let key = try makeKeyString(from: pair[0].value)
                guard object[key] == nil else {
                    throw SyncError.unsupportedKey("Two keys of \(type(of: value)) convert to \"\(key)\"")
                }
                object[key] = try makeFull(from: pair[1].value)
            }
            return .object(object)
        case .struct, .class:
            var object: [String: SnapshotValue] = [:]
            for child in mirror.children {
                guard let label = child.label else { continue }
                object[label] = try makeFull(from: child.value)
            }
            return .object(object)
        case .enum:
            // A case without a payload is its name; with one, `{name: payload}`. Payload nodes
            // are converted in full like any other value.
            guard let payload = mirror.children.first else {
                return .string(String(describing: value))
            }
            return .object([payload.label ?? String(describing: value): try makeFull(from: payload.value)])
        case .tuple:
            return .array(try mirror.children.map { try makeFull(from: $0.value) })
        default:
            return try make(from: value)
        }
    }

    /// Scalars, converted as `make(from:for:)` converts them.
    private static func fullLeaf(_ value: Any) -> SnapshotValue? {
        switch value {
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(v)
        case let v as Int8: return .int(Int(v))
        case let v as Int16: return .int(Int(v))
        case let v as Int32: return .int(Int(v))
        case let v as Int64: return .int(Int(v))
        case let v as UInt: return unsigned(v)
        case let v as UInt8: return .int(Int(v))
        case let v as UInt16: return .int(Int(v))
        case let v as UInt32: return .int(Int(v))
        case let v as UInt64: return unsigned(v)
        case let v as Double: return .double(v)
        case let v as Float: return .double(Double(v))
        case let v as String: return .string(v)
        case let v as PlayerID: return .string(v.rawValue)
        case let v as ClientID: return .string(v.rawValue)
        case let v as SessionID: return .string(v.rawValue)
        case let v as LandID: return .string(v.rawValue)
        default: return nil
        }
    }
}

/// Counts the state nodes the full conversion visits inside `count`, so tests can show that no
/// client path runs it. Outside `count` it reads one unset task-local per node.
package enum FullStateConversionProbe {
    package final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @TaskLocal package static var counter: Counter?

    static func record() {
        counter?.increment()
    }

    package static func count(_ body: () throws -> Void) rethrows -> Int {
        let counter = Counter()
        try $counter.withValue(counter) { try body() }
        return counter.count
    }
}

// MARK: - Strict Extraction Helpers (for SnapshotValueDecodable implementations)

public extension SnapshotValue {
    func requireInt() throws -> Int {
        guard case .int(let v) = self else {
            throw SnapshotDecodeError.typeMismatch(expected: "Int (.int)", got: self)
        }
        return v
    }

    func requireBool() throws -> Bool {
        guard case .bool(let v) = self else {
            throw SnapshotDecodeError.typeMismatch(expected: "Bool (.bool)", got: self)
        }
        return v
    }

    func requireString() throws -> String {
        guard case .string(let v) = self else {
            throw SnapshotDecodeError.typeMismatch(expected: "String (.string)", got: self)
        }
        return v
    }

    func requireDouble() throws -> Double {
        guard case .double(let v) = self else {
            throw SnapshotDecodeError.typeMismatch(expected: "Double (.double)", got: self)
        }
        return v
    }
}
