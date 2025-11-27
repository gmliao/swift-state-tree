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

// MARK: - Common Response Types

/// Join response containing land ID and optional state snapshot for late join
public struct JoinResponse: Codable, Sendable {
    public let landID: String
    public let state: StateSnapshot?

    public init(landID: String, state: StateSnapshot? = nil) {
        self.landID = landID
        self.state = state
    }
}

/// Land information response
public struct LandInfo: Codable, Sendable {
    public let landID: String
    public let playerCount: Int

    public init(landID: String, playerCount: Int) {
        self.landID = landID
        self.playerCount = playerCount
    }
}

/// Card placeholder type (users should define their own Card type)
public struct Card: Codable, Sendable, Hashable {
    public let id: String
    public let value: Int

    public init(id: String, value: Int) {
        self.id = id
        self.value = value
    }
}

// MARK: - Land Services

/// Service abstraction structure (does not depend on HTTP)
///
/// Services are injected at the Transport layer and accessed through LandContext.
/// This allows Land DSL to use services without knowing transport details.
public struct LandServices: Sendable {
    /// Timeline service (optional)
    public let timelineService: TimelineService?
    /// User service (optional)
    public let userService: UserService?

    public init(
        timelineService: TimelineService? = nil,
        userService: UserService? = nil
    ) {
        self.timelineService = timelineService
        self.userService = userService
    }
}

/// Timeline service protocol (does not depend on HTTP)
public protocol TimelineService: Sendable {
    func fetch(page: Int) async throws -> [Post]
}

/// User service protocol (does not depend on HTTP)
public protocol UserService: Sendable {
    func getUser(by id: String) async throws -> User?
}

/// Placeholder types for services
/// These are example types - users should define their own types based on their domain

public struct Post: Codable, Sendable {
    public let id: String
    public let content: String

    public init(id: String, content: String) {
        self.id = id
        self.content = content
    }
}

public struct User: Codable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
