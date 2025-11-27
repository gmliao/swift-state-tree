// Sources/SwiftStateTree/Land/LandConfig.swift

import Foundation

// MARK: - Land Configuration

/// Land configuration structure
/// 
/// Contains configuration options for land lifecycle, tick interval, and player limits.
/// Network layer details (baseURL, webSocketURL) are handled at the Transport layer,
/// not in StateTree/Land layer.
public struct LandConfig: Sendable {
    /// Maximum number of players allowed in the land
    public var maxPlayers: Int?
    
    /// Tick interval for periodic updates (Tick-based mode)
    /// If `nil`, the land operates in Event-driven mode (no automatic ticks)
    public var tickInterval: Duration?
    
    /// Idle timeout duration before land cleanup
    public var idleTimeout: Duration?
    
    public init(
        maxPlayers: Int? = nil,
        tickInterval: Duration? = nil,
        idleTimeout: Duration? = nil
    ) {
        self.maxPlayers = maxPlayers
        self.tickInterval = tickInterval
        self.idleTimeout = idleTimeout
    }
    
    /// Mutating method to update max players
    public mutating func setMaxPlayers(_ value: Int?) {
        self.maxPlayers = value
    }
    
    /// Mutating method to set tick interval
    public mutating func setTickInterval(_ value: Duration?) {
        self.tickInterval = value
    }
    
    /// Mutating method to set idle timeout
    public mutating func setIdleTimeout(_ value: Duration?) {
        self.idleTimeout = value
    }
}

// MARK: - Config DSL Components

/// Config builder for Land DSL
/// 
/// Used within Land DSL to configure land settings.
/// 
/// Example:
/// ```swift
/// Land("match-3", using: GameStateTree.self) {
///     Config {
///         MaxPlayers(4)
///         Tick(every: .milliseconds(100))
///         IdleTimeout(.seconds(60))
///     }
/// }
/// ```
@resultBuilder
public enum ConfigBuilder {
    public static func buildBlock(_ components: ConfigComponent...) -> LandConfig {
        var config = LandConfig()
        for component in components {
            component.apply(to: &config)
        }
        return config
    }
}

/// Protocol for config components
public protocol ConfigComponent: Sendable {
    func apply(to config: inout LandConfig)
}

/// MaxPlayers configuration component
public struct MaxPlayers: ConfigComponent {
    public let value: Int
    
    public init(_ value: Int) {
        self.value = value
    }
    
    public func apply(to config: inout LandConfig) {
        config.setMaxPlayers(value)
    }
}

/// Tick configuration component
public struct Tick: ConfigComponent {
    public let interval: Duration
    
    public init(every interval: Duration) {
        self.interval = interval
    }
    
    public func apply(to config: inout LandConfig) {
        config.setTickInterval(interval)
    }
}

/// IdleTimeout configuration component
public struct IdleTimeout: ConfigComponent {
    public let duration: Duration
    
    public init(_ duration: Duration) {
        self.duration = duration
    }
    
    public func apply(to config: inout LandConfig) {
        config.setIdleTimeout(duration)
    }
}

/// Config function for Land DSL
/// 
/// Creates a configuration block using ConfigBuilder.
/// 
/// Example:
/// ```swift
/// Config {
///     MaxPlayers(4)
///     Tick(every: .milliseconds(100))
///     IdleTimeout(.seconds(60))
/// }
/// ```
public func Config(@ConfigBuilder _ content: () -> LandConfig) -> LandConfig {
    content()
}

