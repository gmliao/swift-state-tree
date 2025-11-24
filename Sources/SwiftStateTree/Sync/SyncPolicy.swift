// Sources/SwiftStateTree/Sync/SyncPolicy.swift

import Foundation

/// Represents the synchronization policy for a field.
public enum SyncPolicy<Value: Sendable>: Sendable {
    case serverOnly
    case broadcast
    case perPlayer(@Sendable (Value, PlayerID) -> Any?)
    case masked(@Sendable (Value) -> Any)
    case custom(@Sendable (PlayerID, Value) -> Any?)

    public func filteredValue(_ value: Value, for playerID: PlayerID) -> Any? {
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
    
    /// Filter value for a player, or return broadcast-only fields if playerID is nil
    public func filteredValue(_ value: Value, for playerID: PlayerID?) -> Any? {
        guard let playerID = playerID else {
            // When playerID is nil, only return broadcast fields
            switch self {
            case .broadcast:
                return value
            case .serverOnly, .perPlayer, .masked, .custom:
                return nil
            }
        }
        return filteredValue(value, for: playerID)
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

/// Marks a StateNode field with a synchronization policy.
///
/// **Type Requirements**: The `Value` type must conform to `Sendable`.
///
/// **Dirty Tracking**: Any assignment to `wrappedValue` will automatically mark the field as dirty.
/// This is a simple and efficient approach that avoids the overhead of value comparison.
/// Use `clearDirty()` to reset the dirty flag after synchronization.
///
/// Most types used with `@Sync` naturally conform to `Sendable`:
/// - Basic types: `Int`, `String`, `Bool`, etc.
/// - Collections: `[Element]`, `[Key: Value]`, `Set<Element>` (when elements are `Sendable`)
/// - Optionals: `Type?` (when `Type` is `Sendable`)
/// - Custom types: Should conform to `Sendable` for thread-safe usage
@propertyWrapper
public struct Sync<Value: Sendable>: Sendable {
    public let policy: SyncPolicy<Value>
    private var _wrappedValue: Value
    private var _isDirty: Bool = false
    
    public var wrappedValue: Value {
        get { _wrappedValue }
        set {
            // Mark as dirty whenever value is set (no comparison needed)
            _wrappedValue = newValue
            _isDirty = true
        }
    }

    public init(wrappedValue: Value, _ policy: SyncPolicy<Value>) {
        self._wrappedValue = wrappedValue
        self.policy = policy
        self._isDirty = false
    }
    
    // MARK: - Dirty Tracking
    
    /// Check if this field has been modified since last clear
    public var isDirty: Bool { _isDirty }
    
    /// Clear the dirty flag
    public mutating func clearDirty() {
        _isDirty = false
    }
    
    /// Manually mark this field as dirty (useful for container types)
    public mutating func markDirty() {
        _isDirty = true
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
