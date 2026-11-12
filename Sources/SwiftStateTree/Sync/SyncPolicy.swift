// Sources/SwiftStateTree/Sync/SyncPolicy.swift

import Foundation

/// Represents the synchronization policy for a field.
///
/// **Policy Types Overview**:
/// - `.serverOnly`: Field is not synced to clients (returns `nil`)
/// - `.broadcast`: Field is synced to all clients with the same value (returns `Value` as-is)
/// - `.perPlayer`: Field is filtered per player (returns `Value?`, same type, can be different for each player)
/// - `.masked`: Field is masked for all players (returns `Value`, same type, same value for all)
/// - `.custom`: Deprecated; the same as `.perPlayer` with the arguments swapped (#173)
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
    case masked(@Sendable (Value) -> Value)
    
    /// Per-player filtering with the arguments in the other order: the same as `.perPlayer`.
    /// - Parameter: `(PlayerID, Value)` - The player ID and the field value (note: order differs from `.perPlayer`)
    /// - Returns: `Value?` - The filtered value for this player (same type), or `nil` to hide the field
    /// - Note: Deprecated (#173). Since every policy returns `Value`, `.custom` cannot change the
    ///   type, so it duplicates `.perPlayer`. Replace `.custom { playerID, value in ... }` with
    ///   `.perPlayer { value, playerID in ... }`. It will be removed in the next minor release.
    @available(*, deprecated, message: "Use .perPlayer; its closure takes (value, playerID), the reverse of .custom")
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
    
    /// Filter value for a player, or, when playerID is nil, the view every player shares:
    /// broadcast fields as they are, and masked ones with the mask applied, since a mask's result
    /// is the same for everyone (#179). Server-only and per-player fields are left out.
    ///
    /// Returns Value? to maintain type safety, making it easier to work with in macro-generated code.
    public func filteredValue(_ value: Value, for playerID: PlayerID?) -> Value? {
        guard let playerID = playerID else {
            switch self {
            case .broadcast:
                return value
            case let .masked(mask):
                return mask(value)
            case .serverOnly, .perPlayer, .custom:
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
///
/// **The policy belongs to the declaration** (#520): the wrapper stores only the value and its
/// dirty flag. `@StateNodeBuilder` emits the attribute's argument as a static of the node type,
/// and the generated snapshot and sync code filter through it. So a node type whose field values
/// are trivially copyable is trivially copyable too.
///
/// **When the policy expression is evaluated:**
/// - In a node type that isn't generic, once per type, at the first read of the policy. Every
///   instance filters with that value.
/// - In a generic node type, or one declared inside an extension or a function, on every read.
/// - The attribute's argument is also evaluated at each instance's init, and that value is
///   discarded.
///
/// So a policy expression must be pure: callable from any context (the first read runs on
/// whichever executor syncs the land), and depending on nothing that changes after the land
/// starts. A filter closure must be a pure function of its arguments, as before.
@propertyWrapper
public struct Sync<Value: Sendable>: Sendable {
    private var _wrappedValue: Value
    private var _isDirty: Bool = false
    
    public var wrappedValue: Value {
        get { _wrappedValue }
        set {
            // Mark as dirty whenever value is set (no comparison needed)
            _wrappedValue = newValue
            _isDirty = true
        }
        // In place: `state.items[k] = v`, `state.list.append(x)`, `f(&state.items)` and a nested
        // node's field write mutate the stored value. Without this accessor a mutation is a get
        // into a temporary and a set, and while the temporary exists the stored value still
        // holds the collection's buffer, so every write copies the whole collection.
        // Marked dirty before the yield: an access ended by a throw (`try f(&_x.wrappedValue)`)
        // doesn't run the code after the yield, and a write made before the throw is kept (#87),
        // so it must be synced.
        _modify {
            _isDirty = true
            yield &_wrappedValue
        }
    }

    /// - Parameter policy: The field's policy. It isn't stored: `@StateNodeBuilder` reads it
    ///   from the attribute and emits it once per declaration.
    public init(wrappedValue: Value, _ policy: SyncPolicy<Value>) {
        self._wrappedValue = wrappedValue
        self._isDirty = false
    }

    /// Removed: the policy is per declaration (#520).
    @available(*, unavailable, message: "The policy is per declaration now; @StateNodeBuilder reads it from the @Sync attribute")
    public var policy: SyncPolicy<Value> { fatalError("unavailable") }
    
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
