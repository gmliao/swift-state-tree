import Foundation

// MARK: - Aggregated Land Configuration

/// Flattened configuration that the runtime consumes after the DSL is processed.
public struct LandConfig: Sendable {
    /// Whether the land can be discovered/joined publicly
    public var allowPublic: Bool
    /// Maximum number of players (nil = unlimited, runtime may still enforce transport caps)
    public var maxPlayers: Int?
    /// Allowed client events enforced at the transport layer
    public var allowedClientEvents: Set<AllowedEventIdentifier>
    /// Tick interval requested by Lifetime block
    public var tickInterval: Duration?
    /// Destroy land when empty for the specified duration
    public var destroyWhenEmptyAfter: Duration?
    /// Persist snapshot interval
    public var persistInterval: Duration?

    public init(
        allowPublic: Bool = true,
        maxPlayers: Int? = nil,
        allowedClientEvents: Set<AllowedEventIdentifier> = [],
        tickInterval: Duration? = nil,
        destroyWhenEmptyAfter: Duration? = nil,
        persistInterval: Duration? = nil
    ) {
        self.allowPublic = allowPublic
        self.maxPlayers = maxPlayers
        self.allowedClientEvents = allowedClientEvents
        self.tickInterval = tickInterval
        self.destroyWhenEmptyAfter = destroyWhenEmptyAfter
        self.persistInterval = persistInterval
    }
}

// MARK: - Access Control Configuration

/// Configuration for the `AccessControl { ... }` block.
public struct AccessControlConfig: Sendable {
    public var maxPlayers: Int?
    public var allowPublic: Bool

    public init(
        maxPlayers: Int? = nil,
        allowPublic: Bool = true
    ) {
        self.maxPlayers = maxPlayers
        self.allowPublic = allowPublic
    }
}

// MARK: - Allowed Event Identifier

public struct AllowedEventIdentifier: Hashable, @unchecked Sendable {
    let storage: AnyHashable

    public init<H: Hashable & Sendable>(_ value: H) {
        self.storage = AnyHashable(value)
    }

    init(anyHashable: AnyHashable) {
        self.storage = anyHashable
    }
}

