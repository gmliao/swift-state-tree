// Sources/SwiftStateTree/Sync/SyncPolicy.swift

import Foundation

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

