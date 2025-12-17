// Sources/SwiftStateTree/Sync/SyncPolicy.swift

import Foundation

/// Represents the synchronization policy for a field.
///
/// **Policy Types Overview**:
/// - `.serverOnly`: Field is not synced to clients (returns `nil`)
/// - `.broadcast`: Field is synced to all clients with the same value (returns `Value` as-is)
/// - `.perPlayer`: Field is filtered per player (returns `Value?`, same type, can be different for each player)
/// - `.masked`: Field is masked for all players (returns `Value`, same type, same value for all)
/// - `.custom`: Fully custom filtering logic (returns `Value?`, same type, can be different for each player)
public enum SyncPolicy<Value: Sendable>: Sendable {
    /// Field is not synced to clients
    case serverOnly
    
    /// Field is synced to all clients with the same value
    case broadcast
    
    /// Field is filtered per player based on playerID
    /// - Parameter: `(Value, PlayerID)` - The field value and the player ID
    /// - Returns: `Value?` - The filtered value for this player (same type), or `nil` to hide the field
    /// - Note: Must return the same type as input to ensure type safety in macro-generated code
    case perPlayer(@Sendable (Value, PlayerID) -> Value?)
    
    /// Field is masked for all players (same masked value for everyone)
    /// - Parameter: `Value` - The field value
    /// - Returns: `Value` - The masked value (MUST be the same type as input)
    /// - Note: Must return the same type to ensure type safety in macro-generated code
    ///   If you need to return a different type, use `.custom` instead
    case masked(@Sendable (Value) -> Value)
    
    /// Fully custom filtering logic with playerID and value
    /// - Parameter: `(PlayerID, Value)` - The player ID and the field value (note: order differs from `.perPlayer`)
    /// - Returns: `Value?` - The filtered value for this player (same type), or `nil` to hide the field
    /// - Note: Must return the same type as input to ensure type safety in macro-generated code
    case custom(@Sendable (PlayerID, Value) -> Value?)

    /// Filter value for a player, returning the same type as input (Value?)
    ///
    /// This method maintains type safety by returning Value? instead of Any?.
    /// The return type matches the input type, making it easier to work with in macro-generated code.
    public func filteredValue(_ value: Value, for playerID: PlayerID) -> Value? {
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
    ///
    /// Returns Value? to maintain type safety, making it easier to work with in macro-generated code.
    public func filteredValue(_ value: Value, for playerID: PlayerID?) -> Value? {
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
    /// Convenience method for handling dictionaries keyed by PlayerID, only syncing the slice for that player.
    /// 
    /// **Semantics**: Returns a dictionary containing only the current player's key-value pair.
    /// The snapshot structure matches the server structure (both are dictionaries), but only contains
    /// the current player's entry.
    /// 
    /// **Usage**: When used with `[PlayerID: Element]`, the snapshot will contain a dictionary
    /// with only the current player's key: `{"playerID": element}` or the field will be absent if the player has no value.
    static func perPlayerSlice<Element>() -> SyncPolicy<[PlayerID: Element]> {
        .perPlayer { value, playerID in
            // Return a dictionary slice containing only this player's key-value pair
            if let element = value[playerID] {
                return [playerID: element]  // Return a dictionary with only this player's value
            }
            return nil
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
    
    /// Update the wrapped value without marking as dirty.
    ///
    /// This is primarily intended for code generated by macros and advanced
    /// internal usage (e.g. recursively clearing nested StateNode dirty flags).
    /// Regular application code should rarely need to call this directly.
    ///
    /// - Parameter newValue: The new value to set.
    public mutating func updateValueWithoutMarkingDirty(_ newValue: Value) {
        _wrappedValue = newValue
        // Note: We intentionally do NOT set _isDirty = true here
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
