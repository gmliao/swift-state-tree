// Sources/SwiftStateTree/Sync/Sync.swift

import Foundation

/// Player identifier (account level)
public struct PlayerID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }
    
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Represents the synchronization policy for a field.
public enum SyncPolicy<Value: Sendable>: Sendable {
    case serverOnly
    case broadcast
    case perPlayer(@Sendable (Value, PlayerID) -> Any?)
    case masked(@Sendable (Value) -> Any)
    case custom(@Sendable (PlayerID, Value) -> Any?)

    func filteredValue(_ value: Value, for playerID: PlayerID) -> Any? {
        switch self {
        case .serverOnly:
            return nil
        case .broadcast:
            return value
        case let .perPlayer(filter):
            return filter(value, playerID)
        case let .masked(mask):
            return mask(value)
        case let .custom(handler):
            return handler(playerID, value)
        }
    }
}

public extension SyncPolicy {
    /// Convenience method for handling dictionaries keyed by PlayerID, only syncing the value for that player.
    static func perPlayerDictionaryValue<Element>() -> SyncPolicy<[PlayerID: Element]> {
        .perPlayer { value, playerID in
            value[playerID]
        }
    }
}

/// Marks a StateTree field with a synchronization policy.
@propertyWrapper
public struct Sync<Value: Sendable>: Sendable {
    public let policy: SyncPolicy<Value>
    public var wrappedValue: Value

    public init(wrappedValue: Value, _ policy: SyncPolicy<Value>) {
        self.policy = policy
        self.wrappedValue = wrappedValue
    }
}

/// Marks a field as server-only internal use, not requiring synchronization or validation.
/// 
/// Difference from `@Sync(.serverOnly)`:
/// - `@Sync(.serverOnly)`: The sync engine knows this field exists but doesn't output it to clients
/// - `@Internal`: The sync engine doesn't need to know about this field at all; purely for server internal use
@propertyWrapper
public struct Internal<Value: Sendable>: Sendable {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}

/// Type-erased access to synchronized values.
private protocol SyncValueProvider {
    func syncValue(for playerID: PlayerID) -> Any?
}

extension Sync: SyncValueProvider {
    fileprivate func syncValue(for playerID: PlayerID) -> Any? {
        policy.filteredValue(wrappedValue, for: playerID)
    }
}

/// Allowed data types for snapshots, used for JSON-friendly output structures.
public enum SnapshotValue: Equatable, Sendable {
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
}

public enum SyncError: Error, Equatable {
    case unsupportedValue(String)
    case unsupportedKey(String)
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
    static func make(from value: Any) throws -> SnapshotValue {
        // Priority 1: Check if type conforms to SnapshotValueConvertible (best performance)
        if let convertible = value as? SnapshotValueConvertible {
            return try convertible.toSnapshotValue()
        }
        
        // Priority 2: Handle basic types directly (no Mirror needed)
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
            return .int(Int(uintValue))
        case let uint8Value as UInt8:
            return .int(Int(uint8Value))
        case let uint16Value as UInt16:
            return .int(Int(uint16Value))
        case let uint32Value as UInt32:
            return .int(Int(uint32Value))
        case let uint64Value as UInt64:
            return .int(Int(uint64Value))
        case let doubleValue as Double:
            return .double(doubleValue)
        case let floatValue as Float:
            return .double(Double(floatValue))
        case let stringValue as String:
            return .string(stringValue)
        case let playerID as PlayerID:
            return .string(playerID.rawValue)
        default:
            break
        }

        let mirror = Mirror(reflecting: value)

        if mirror.displayStyle == .optional {
            if let child = mirror.children.first {
                return try make(from: child.value)
            } else {
                return .null
            }
        }

        switch mirror.displayStyle {
        case .collection:
            let array = try mirror.children.map { try make(from: $0.value) }
            return .array(array)
        case .dictionary:
            var object: [String: SnapshotValue] = [:]
            for child in mirror.children {
                let pair = Mirror(reflecting: child.value)
                guard pair.children.count == 2 else {
                    throw SyncError.unsupportedValue("Dictionary entry must contain exactly two children.")
                }
                let keyMirror = pair.children.first!
                let valueMirror = pair.children.dropFirst().first!
                let keyString = try makeKeyString(from: keyMirror.value)
                let mappedValue = try make(from: valueMirror.value)
                object[keyString] = mappedValue
            }
            return .object(object)
        case .struct, .class:
            var object: [String: SnapshotValue] = [:]
            for child in mirror.children {
                guard let label = child.label else { continue }
                object[label] = try make(from: child.value)
            }
            return .object(object)
        default:
            throw SyncError.unsupportedValue("Unsupported type: \(type(of: value))")
        }
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

/// Filtered state snapshot (JSON-friendly structure).
public struct StateSnapshot: Equatable, Sendable {
    public let values: [String: SnapshotValue]

    public init(values: [String: SnapshotValue]) {
        self.values = values
    }

    public subscript(_ key: String) -> SnapshotValue? {
        values[key]
    }

    public var isEmpty: Bool {
        values.isEmpty
    }
}

/// SyncEngine filters StateTree according to SyncPolicy and outputs StateSnapshot.
///
/// **Current Implementation**: This method delegates to `StateTreeProtocol.snapshot(for:)`,
/// which is generated at compile time by the `@StateTreeBuilder` macro, avoiding runtime reflection.
///
/// **Future Extensions**: SyncEngine will be responsible for:
/// - Diff calculation: Compare old and new snapshots, generate path-based diffs
/// - Cache management: Cache broadcast and perPlayer snapshots
/// - Batch synchronization: Optimize multi-player synchronization performance
///
/// **Usage Recommendations**:
/// - Simple scenarios: Use `state.snapshot(for: playerID)` directly
/// - When SyncEngine features are needed: Use `SyncEngine().snapshot(for:from:)`
public struct SyncEngine: Sendable {
    public init() {}

    /// Generate a snapshot of the StateTree for a specific player
    ///
    /// This method delegates to the `snapshot(for:)` method generated by the `@StateTreeBuilder` macro,
    /// which avoids runtime reflection and provides better performance.
    ///
    /// **Note**: For simple use cases, you can call `state.snapshot(for: playerID)` directly.
    ///
    /// - Parameters:
    ///   - playerID: The player ID to generate the snapshot for
    ///   - state: The StateTree instance
    /// - Returns: A `StateSnapshot` containing filtered fields based on sync policies
    /// - Throws: `SyncError` if value conversion fails
    public func snapshot<State: StateTreeProtocol>(
        for playerID: PlayerID,
        from state: State
    ) throws -> StateSnapshot {
        // Delegate to the macro-generated snapshot method
        // This avoids runtime reflection and provides better performance
        return try state.snapshot(for: playerID)
    }
}
