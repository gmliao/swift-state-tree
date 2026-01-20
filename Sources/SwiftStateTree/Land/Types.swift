import Foundation

// MARK: - Identity Types

/// Client identifier (device level)
///
/// Used to identify a client instance across multiple tabs/devices.
/// Provided by the application layer.
public struct ClientID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Session identifier (connection level)
///
/// Used to identify a specific WebSocket connection.
/// Dynamically generated for tracking purposes.
public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

// MARK: - Event Target

/// Event delivery target for sending events to specific recipients
public enum EventTarget: Sendable {
    /// Send to all players in the land
    case all
    /// Send to all connections for a specific playerID (all devices/tabs)
    case player(PlayerID)
    /// Send to a specific clientID (all tabs on a single device)
    case client(ClientID)
    /// Send to a specific sessionID (single connection)
    case session(SessionID)
    /// Send to multiple players
    case players([PlayerID])
}

// MARK: - Land Services

/// Service abstraction structure (does not depend on HTTP)
///
/// Services are injected at the Transport layer and accessed through LandContext.
/// This allows Land DSL to use services without knowing transport details.
///
/// Currently supports dynamic service registration via type-based lookup.
/// This is a temporary implementation and may be refined in the future.
/// Protocol for RNG services that provide a seed for deterministic replay.
/// Services implementing this protocol can have their seed extracted for recording.
public protocol RngSeedProvider: Sendable {
    var seed: UInt64 { get }
}

public struct LandServices: Sendable {
    private var services: [ObjectIdentifier: any Sendable] = [:]
    
    public init() {}
    
    /// Register a service instance with a specific type identifier
    public mutating func register<Service: Sendable>(_ service: Service, as type: Service.Type) {
        services[ObjectIdentifier(type)] = service
    }
    
    /// Retrieve a service by its type
    public func get<Service: Sendable>(_ type: Service.Type) -> Service? {
        return services[ObjectIdentifier(type)] as? Service
    }
    
    /// Extract RNG seed from any service implementing RngSeedProvider.
    /// Returns the first RNG seed found, or nil if no RNG service is registered.
    public func extractRngSeed() -> UInt64? {
        for service in services.values {
            if let rngProvider = service as? RngSeedProvider {
                return rngProvider.seed
            }
        }
        return nil
    }

    /// Merge another LandServices into this instance.
    public mutating func merge(_ other: LandServices) {
        services.merge(other.services) { _, new in new }
    }

    /// Return a new LandServices by merging another instance.
    public func merging(_ other: LandServices) -> LandServices {
        var combined = self
        combined.merge(other)
        return combined
    }
}
