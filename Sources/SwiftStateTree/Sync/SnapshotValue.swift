// Sources/SwiftStateTree/Sync/SnapshotValue.swift

import Foundation
import SwiftStateTurns

/// Allowed data types for snapshots, used for JSON-friendly output structures.
@PlainData
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
///
/// Synced state is made of value types (#464). A state field's type is `PlainData`, which the
/// compiler checks; registration and conversion still refuse a conforming class, which a
/// hand-written `PlainData` witness outside this repository could put in state.
public protocol SnapshotValueConvertible {
    func toSnapshotValue() throws -> SnapshotValue
    /// `toSnapshotValue()` with the budget at this value (#716). `@SnapshotConvertible`
    /// generates it, spending the value's object and converting each property within the rest.
    ///
    /// A type that implements only `toSnapshotValue()` gets the default, which checks what it
    /// returned, after it ran: the conversion inside it counts from the root. A type that
    /// implements this one must pass `budget` on: nothing checks its result (`make` and the
    /// typed maps trust it), so an override that ignores `budget` is not bounded. A conversion
    /// that recurses into its own type implements this one, so the count reaches its recursion.
    func toSnapshotValue(budget: NestingBudget) throws -> SnapshotValue
}

public extension SnapshotValueConvertible {
    func toSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
        let value = try toSnapshotValue()
        NestingBudget.note(.resultCheck)
        try budget.check(value)
        return value
    }
}

extension SnapshotValue {
    /// The error for a class in synced state (#464): registration refuses one it can see in debug
    /// builds, and conversion refuses the rest, and in a release build all of them.
    static func classRefusal(_ value: Any) -> SyncError {
        .unsupportedValue("\(type(of: value)) is a class; synced state must be value types (#464)")
    }
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

    /// A map key as it is written on the wire: in NFC (#446). Swift's `String ==` already holds
    /// an NFC and an NFD spelling as one dictionary key; this makes the bytes one too, so a
    /// client that compares bytes (JavaScript) sees one key.
    ///
    /// Text below U+0300 (ASCII, and the precomposed Latin letters after it) is NFC as it
    /// stands and is returned without a conversion: one pass over its bytes. Other text is
    /// converted, NFC or not, which costs a few hundred nanoseconds a key.
    ///
    /// Every dictionary conversion below passes its `String` keys through here. A `PlayerID` is
    /// NFC from its creation. A value that builds its own object (`toSnapshotValue()`, or an
    /// object nested inside a `SnapshotValue`) writes the keys it is given.
    static func wireKey(_ key: String) -> String {
        mayNotBeNFC(key) ? key.precomposedStringWithCanonicalMapping : key
    }

    /// Whether `text` is in NFC, by its bytes.
    static func isNFC(_ text: String) -> Bool {
        !mayNotBeNFC(text) || text.utf8.elementsEqual(text.precomposedStringWithCanonicalMapping.utf8)
    }

    /// False for text that is certainly NFC: every scalar is below U+0300, the first code point
    /// that combines or decomposes. In UTF-8 those are the bytes below 0xCC.
    private static func mayNotBeNFC(_ text: String) -> Bool {
        func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            // ASCII first, in a loop the compiler vectorizes.
            var all: UInt8 = 0
            for byte in bytes { all |= byte }
            if all < 0x80 { return false }
            for byte in bytes where byte >= 0xCC { return true }
            return false
        }
        if let known = text.utf8.withContiguousStorageIfAvailable(scan) { return known }
        return text.utf8.contains { $0 >= 0xCC }
    }

    /// The value inside every `Optional` around `value`, with one hop spent per `.some`, or `nil`
    /// for a `.none` (#716).
    ///
    /// Runs before any other cast in `make` and `makeFull`. A cast that fails on an `Optional`
    /// unwraps it and casts its payload, and the payload of an `Optional<Any>` can be another
    /// one, so the first cast on a long chain would recurse through every level inside the
    /// runtime before a hop could refuse it. This cast succeeds at the first level, because
    /// `Optional` itself conforms, and the loop takes the levels one at a time.
    ///
    /// An `AnyHashable` is taken out of its box here too, by its exact type, so its value converts
    /// as itself: otherwise the scalar casts below see the box (`AnyHashable(1)` casts to `Bool`
    /// on Darwin), and so does an `[Any]` holding it. The box spends no hop: `AnyHashable` never
    /// holds another one, and an `Optional` inside it spends its own.
    fileprivate static func unwrappingOptionals(_ value: Any, budget: NestingBudget) throws -> (Any, NestingBudget)? {
        var value = value
        var budget = budget
        while true {
            if Swift.type(of: value) == AnyHashable.self, let box = value as? AnyHashable {
                value = box.base
                continue
            }
            guard let optional = value as? any NestingOptionalPayload else { break }
            guard let payload = optional.nestingPayload else { return nil }
            budget = try budget.hop()
            value = payload
        }
        return (value, budget)
    }

    /// Converts `value` as clients see it, from a root field's budget (`make(from:for:budget:)`).
    static func make(from value: Any, for playerID: PlayerID? = nil) throws -> SnapshotValue {
        try make(from: value, for: playerID, budget: NestingBudget())
    }

    /// `make(from:for:)` with the budget at `value` (#716): every container it converts, and
    /// every `Optional` it unwraps, spends from `budget`, and a value past it throws
    /// `SyncError.nestingTooDeep`.
    static func make(from value: Any, for playerID: PlayerID? = nil, budget: NestingBudget) throws -> SnapshotValue {
        guard case let (value, budget)? = try unwrappingOptionals(value, budget: budget) else { return .null }
        // Short-circuit if value is already a snapshot-friendly type
        // A tree that is already built is checked iteratively: nothing below recurses on it.
        if let snapshotValue = value as? SnapshotValue {
            try budget.check(snapshotValue)
            return snapshotValue
        }
        if let snapshot = value as? StateSnapshot {
            let object = SnapshotValue.object(snapshot.values)
            try budget.check(object)
            return object
        }
        
        // Priority 1: Check if type conforms to StateNodeProtocol (for recursive filtering)
        // This must be checked before SnapshotValueConvertible to enable recursive @Sync policy filtering
        if let stateNode = value as? any StateNodeProtocol {
            if playerID == nil {
                try refusePlayerDependentNode(stateNode)
            }
            // Recursively apply @Sync policies by calling snapshot(for:)
            let snapshot = try stateNode.snapshot(for: playerID, dirtyFields: nil, budget: try budget.enteringContainer())
            // Convert StateSnapshot to SnapshotValue.object
            return .object(snapshot.values)
        }
        
        // Priority 2: Check if type conforms to SnapshotValueConvertible (best performance)
        if let convertible = value as? SnapshotValueConvertible {
            // A conforming class stored in an existential field at runtime (#464). The cast's
            // result, not `value`: `as?` unwraps an `Optional` boxed in `Any`, while
            // `type(of: value)` stays `Optional<C>`. A metatype check, since `value is AnyObject`
            // is true for a bridged `String` on Darwin.
            if Swift.type(of: convertible) is AnyObject.Type { throw classRefusal(convertible) }
            return try convertible.toSnapshotValue(budget: budget)
        }
        
        // Priority 3: Handle known collection types directly (avoid Mirror overhead).
        // Each matches its exact dynamic type, never a collection cast: a collection cast
        // converts every element, and unwraps an `Optional` chain inside an `[Any]` with no hop
        // counted (#716).
        let valueType = Swift.type(of: value)
        if valueType == [SnapshotValue].self, let arrayValue = value as? [SnapshotValue] {
            let array = SnapshotValue.array(arrayValue)
            try budget.check(array)
            return array
        }
        if valueType == [String: SnapshotValue].self, let dictValue = value as? [String: SnapshotValue] {
            try budget.check(.object(dictValue))
            // Its own keys are written in NFC, as `makeFull` writes them (through `[String: Any]`);
            // objects inside its values are the caller's and are sent as written.
            guard dictValue.keys.contains(where: mayNotBeNFC) else { return .object(dictValue) }
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(dictValue.count)
            for (key, val) in dictValue {
                object[wireKey(key)] = val
            }
            return .object(object)
        }
        if valueType == [PlayerID: SnapshotValue].self, let playerSnapshotDict = value as? [PlayerID: SnapshotValue] {
            let inner = try budget.enteringContainer()
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(playerSnapshotDict.count)
            for (key, val) in playerSnapshotDict {
                try inner.check(val)
                object[key.rawValue] = val
            }
            return .object(object)
        }
        
        // Priority 4: Handle other common collection types directly
        if valueType == [String].self, let stringArray = value as? [String] {
            _ = try budget.enteringContainer()
            let mapped = stringArray.map { SnapshotValue.string($0) }
            return .array(mapped)
        }
        if valueType == [Int].self, let intArray = value as? [Int] {
            _ = try budget.enteringContainer()
            let mapped = intArray.map { SnapshotValue.int($0) }
            return .array(mapped)
        }
        // Typed maps of nodes and of convertibles, by their conditional conformance: one check
        // on the type's metadata, so no element is cast (#716). Nodes first, as `make` checks
        // `StateNodeProtocol` first (#175).
        if let nodeMap = value as? any _StateNodeMap {
            NestingBudget.note(.nodeMap)
            return try nodeMap._snapshotNodeMap(for: playerID, budget: budget)
        }
        if let convertibleMap = value as? any _SnapshotConvertibleMap {
            NestingBudget.note(.convertibleMap)
            return try convertibleMap._snapshotConvertibleMap(for: playerID, budget: budget)
        }
        if let dictStringAny = value as? [String: Any] {
            let inner = try budget.enteringContainer()
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(dictStringAny.count)
            for (key, val) in dictStringAny {
                object[wireKey(key)] = try make(from: val, for: playerID, budget: inner)
            }
            return .object(object)
        }
        if let playerIDDict = value as? [PlayerID: Any] {
            let inner = try budget.enteringContainer()
            // Treat as a normal dictionary (including single-element dictionaries from perPlayerSlice)
            // The structure is consistent: server and client both see dictionary structure
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(playerIDDict.count)
            for (key, val) in playerIDDict {
                object[key.rawValue] = try make(from: val, for: playerID, budget: inner)
            }
            return .object(object)
        }
        
        // Priority 5: Handle basic types directly (no Mirror needed)
        // A metatype check, not `value is NSNull`: on Linux that cast bridges a Swift collection
        // to `NSArray` element by element, which recursed through the whole nested value (#716).
        if Swift.type(of: value) is NSNull.Type {
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

        // Only a custom mirror can say `.optional` here: every `Optional` was unwrapped above.
        if mirror.displayStyle == .optional {
            if let child = mirror.children.first {
                return try make(from: child.value, for: playerID, budget: try budget.hop())
            } else {
                return .null
            }
        }

        switch mirror.displayStyle {
        case .collection:
            let inner = try budget.enteringContainer()
            // Optimize: Direct iteration instead of map to reduce dynamic dispatch
            // Pre-count children if possible for capacity reservation
            let childrenArray = Array(mirror.children)
            var array: [SnapshotValue] = []
            array.reserveCapacity(childrenArray.count)
            for child in childrenArray {
                array.append(try make(from: child.value, for: playerID, budget: inner))
            }
            return .array(array)
        case .dictionary:
            let inner = try budget.enteringContainer()
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
                let mappedValue = try make(from: valueMirror.value, for: playerID, budget: inner)
                // Two keys that convert to the same string: one would overwrite the other on
                // every client (#535 D8).
                if object.updateValue(mappedValue, forKey: keyString) != nil {
                    throw collidingKeys(in: value, key: keyString)
                }
            }
            return .object(object)
        case .class:
            // Registration refuses a class field in debug builds (`SyncValueSemantics`); this is
            // the backstop for one only known at runtime, in an `Any` or `any P` field, and for
            // every one in a release build.
            throw classRefusal(value)
        case .struct:
            let inner = try budget.enteringContainer()
            // Optimize: Pre-allocate capacity based on expected field count
            let childrenArray = Array(mirror.children)
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(childrenArray.count)
            for child in childrenArray {
                guard let label = child.label else { continue }
                object[label] = try make(from: child.value, for: playerID, budget: inner)
            }
            return .object(object)
        default:
            throw SyncError.unsupportedValue("Unsupported type: \(type(of: value))")
        }
    }

    /// The view without a player of a state node, as an object: what `make(from:)` returns for
    /// a node, without boxing it into `Any` first. Refuses a node with player-dependent fields
    /// (#179). The macro's broadcast path for a single nested node calls it on every encode.
    static func broadcastView(of node: some StateNodeProtocol) throws -> SnapshotValue {
        try broadcastView(of: node, budget: NestingBudget())
    }

    /// `broadcastView(of:)` with the budget at the node's value (#716): the node's object is a
    /// container, and its fields convert inside it.
    static func broadcastView(of node: some StateNodeProtocol, budget: NestingBudget) throws -> SnapshotValue {
        try refusePlayerDependentNode(node)
        return .object(try node.snapshot(for: nil, dirtyFields: nil, budget: try budget.enteringContainer()).values)
    }

    /// The view without a player (a broadcast encoding) of a state node with player-dependent
    /// fields would leave those fields out for every player (#179). `SyncPolicyNesting.validate`
    /// rejects such a nesting where it can see it; this refuses every other path to it (a plain
    /// holder in an empty collection, a land built without the check). One stored flag per type
    /// (`hasPlayerDependentSyncFields`), so it adds no walk to the broadcast encoding.
    fileprivate static func refusePlayerDependentNode(_ node: any StateNodeProtocol) throws {
        guard type(of: node).hasPlayerDependentSyncFields else { return }
        throw SyncError.unsupportedValue(
            "\(type(of: node)) has player-dependent fields and is encoded without a player, under a broadcast field: those fields would reach no player (#179)"
        )
    }

    /// Two keys of `map` that convert to `key` (#535 D8).
    internal static func collidingKeys(in map: Any, key: String) -> SyncError {
        .collidingKeys("Two keys of \(type(of: map)) convert to \"\(key)\"")
    }

    private static func makeKeyString(from value: Any) throws -> String {
        if let playerID = value as? PlayerID {
            return playerID.rawValue
        }
        if let stringKey = value as? String {
            return wireKey(stringKey)
        }
        if let convertible = value as? CustomStringConvertible {
            return wireKey(convertible.description)
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
    /// `toFullSnapshotValue()` with the budget at this value (#716), generated and defaulted as
    /// `toSnapshotValue(budget:)` is: the default checks the result of `toFullSnapshotValue()`,
    /// and an override of this one must pass `budget` on, since `makeFull` trusts its result.
    func toFullSnapshotValue(budget: NestingBudget) throws -> SnapshotValue
}

public extension FullSnapshotValueConvertible {
    func toFullSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
        let value = try toFullSnapshotValue()
        NestingBudget.note(.resultCheck)
        try budget.check(value)
        return value
    }
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
        try makeFull(from: value, budget: NestingBudget())
    }

    /// `makeFull(from:)` with the budget at `value` (#716), counted as `make(from:for:budget:)`
    /// counts.
    static func makeFull(from value: Any, budget: NestingBudget) throws -> SnapshotValue {
        guard case let (value, budget)? = try unwrappingOptionals(value, budget: budget) else { return .null }
        if let snapshotValue = value as? SnapshotValue {
            try budget.check(snapshotValue)
            return snapshotValue
        }
        if let snapshot = value as? StateSnapshot {
            let object = SnapshotValue.object(snapshot.values)
            try budget.check(object)
            return object
        }
        if let stateNode = value as? any StateNodeProtocol {
            FullStateConversionProbe.record()
            return .object(try stateNode.fullStateSnapshot(budget: try budget.enteringContainer()).values)
        }
        if let leaf = fullLeaf(value) {
            return leaf
        }
        if let full = value as? FullSnapshotValueConvertible {
            // The cast's result, as in `make`: an `Optional` boxed in `Any` is unwrapped by `as?`.
            if Swift.type(of: full) is AnyObject.Type { throw classRefusal(full) }
            return try full.toFullSnapshotValue(budget: budget)
        }
        if let convertible = value as? SnapshotValueConvertible {
            if Swift.type(of: convertible) is AnyObject.Type { throw classRefusal(convertible) }
            return try convertible.toSnapshotValue(budget: budget)
        }
        // Common containers without Mirror.
        if let dict = value as? [String: Any] {
            let inner = try budget.enteringContainer()
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(dict.count)
            for (key, element) in dict {
                object[wireKey(key)] = try makeFull(from: element, budget: inner)
            }
            return .object(object)
        }
        if let dict = value as? [PlayerID: Any] {
            let inner = try budget.enteringContainer()
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(dict.count)
            for (key, element) in dict {
                object[key.rawValue] = try makeFull(from: element, budget: inner)
            }
            return .object(object)
        }

        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            // Only a custom mirror: every `Optional` was unwrapped above.
            guard let child = mirror.children.first else { return .null }
            return try makeFull(from: child.value, budget: try budget.hop())
        case .collection:
            let inner = try budget.enteringContainer()
            var array: [SnapshotValue] = []
            array.reserveCapacity(Int(mirror.children.count))
            for child in mirror.children {
                array.append(try makeFull(from: child.value, budget: inner))
            }
            return .array(array)
        case .set:
            let inner = try budget.enteringContainer()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var keyed: [(key: [UInt8], value: SnapshotValue)] = []
            for child in mirror.children {
                let converted = try makeFull(from: child.value, budget: inner)
                keyed.append((Array(try encoder.encode(converted)), converted))
            }
            keyed.sort { $0.key.lexicographicallyPrecedes($1.key) }
            return .array(keyed.map(\.value))
        case .dictionary:
            let inner = try budget.enteringContainer()
            var object: [String: SnapshotValue] = [:]
            object.reserveCapacity(Int(mirror.children.count))
            for child in mirror.children {
                let pair = Array(Mirror(reflecting: child.value).children)
                guard pair.count == 2 else {
                    throw SyncError.unsupportedValue("Dictionary entry must contain exactly two children.")
                }
                let key = try makeKeyString(from: pair[0].value)
                guard object[key] == nil else {
                    throw collidingKeys(in: value, key: key)
                }
                object[key] = try makeFull(from: pair[1].value, budget: inner)
            }
            return .object(object)
        case .class:
            throw classRefusal(value)
        case .struct:
            let inner = try budget.enteringContainer()
            var object: [String: SnapshotValue] = [:]
            for child in mirror.children {
                guard let label = child.label else { continue }
                object[label] = try makeFull(from: child.value, budget: inner)
            }
            return .object(object)
        case .enum:
            // A case without a payload is its name; with one, `{name: payload}`. Payload nodes
            // are converted in full like any other value.
            guard let payload = mirror.children.first else {
                return .string(String(describing: value))
            }
            return .object([payload.label ?? String(describing: value): try makeFull(from: payload.value, budget: try budget.enteringContainer())])
        case .tuple:
            let inner = try budget.enteringContainer()
            return .array(try mirror.children.map { try makeFull(from: $0.value, budget: inner) })
        default:
            return try make(from: value, budget: budget)
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

/// An `Optional`'s payload, read without a cast that could unwrap it (#716,
/// `SnapshotValue.unwrappingOptionals`).
protocol NestingOptionalPayload {
    /// The payload of a `.some`, boxed in `Any`, or `nil` for `.none`.
    var nestingPayload: Any? { get }
}

extension Optional: NestingOptionalPayload {
    var nestingPayload: Any? { map { $0 as Any } }
}

// MARK: - Typed maps (#716)

/// A key a typed map converts without boxing it: its string as the wire spells it.
package protocol _SnapshotMapKey: Hashable {
    var _snapshotWireKey: String { get }
}

extension PlayerID: _SnapshotMapKey {
    package var _snapshotWireKey: String { rawValue }
}

extension String: _SnapshotMapKey {
    package var _snapshotWireKey: String { SnapshotValue.wireKey(self) }
}

/// A map of state nodes, converted without casting its elements (#716). `Dictionary` conforms
/// when its values are state nodes, so `make` finds it with one check on the type's metadata.
package protocol _StateNodeMap {
    /// The map as an object: each node converted by its own policies for `playerID`.
    func _snapshotNodeMap(for playerID: PlayerID?, budget: NestingBudget) throws -> SnapshotValue
}

extension Dictionary: _StateNodeMap where Key: _SnapshotMapKey, Value: StateNodeProtocol {
    package func _snapshotNodeMap(for playerID: PlayerID?, budget: NestingBudget) throws -> SnapshotValue {
        let inner = try budget.enteringContainer()
        var object: [String: SnapshotValue] = [:]
        object.reserveCapacity(count)
        for (key, node) in self {
            // As `make` converts a node: the view without a player refuses a player-dependent
            // node (#179), and the node's object is a container.
            if playerID == nil {
                try SnapshotValue.refusePlayerDependentNode(node)
            }
            let snapshot = try node.snapshot(for: playerID, dirtyFields: nil, budget: try inner.enteringContainer())
            object[key._snapshotWireKey] = .object(snapshot.values)
        }
        return .object(object)
    }
}

/// A map of convertible values, converted without casting its elements (#716), as
/// `_StateNodeMap` is. A separate protocol: `Dictionary` can conform to one protocol under only
/// one set of conditions.
package protocol _SnapshotConvertibleMap {
    /// The map as an object, each value through `make`.
    func _snapshotConvertibleMap(for playerID: PlayerID?, budget: NestingBudget) throws -> SnapshotValue
}

extension Dictionary: _SnapshotConvertibleMap where Key: _SnapshotMapKey, Value: SnapshotValueConvertible {
    package func _snapshotConvertibleMap(for playerID: PlayerID?, budget: NestingBudget) throws -> SnapshotValue {
        let inner = try budget.enteringContainer()
        var object: [String: SnapshotValue] = [:]
        object.reserveCapacity(count)
        for (key, value) in self {
            // Through `make`, never straight to `toSnapshotValue()`: a value that is also a state
            // node converts by its own policies (#175), and a class is refused (#464).
            object[key._snapshotWireKey] = try SnapshotValue.make(from: value, for: playerID, budget: inner)
        }
        return .object(object)
    }
}
