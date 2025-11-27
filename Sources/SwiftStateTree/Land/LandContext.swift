import Foundation

/// Request-scoped context for Land handlers
///
/// LandContext is created for each Action/Event request and released after processing.
/// It follows the Request-scoped Context pattern.
public struct LandContext: Sendable {
    /// Land identifier
    public let landID: String

    /// Player identifier (account level, user identity)
    public let playerID: PlayerID

    /// Client identifier (device level, client instance provided by application)
    public let clientID: ClientID

    /// Session identifier (connection level, dynamically generated for tracking)
    public let sessionID: SessionID

    /// Service abstractions (does not depend on HTTP)
    public let services: LandServices

    /// Send event handler closure (delegates to Runtime layer without exposing Transport)
    /// Accepts any ServerEventPayload, runtime will verify type.
    private let sendEventHandler: @Sendable (any ServerEventPayload, EventTarget) async -> Void

    /// Sync handler closure (delegates to Runtime layer without exposing Transport)
    private let syncHandler: @Sendable () async -> Void

    /// Internal initializer for creating LandContext
    internal init(
        landID: String,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        services: LandServices,
        sendEventHandler: @escaping @Sendable (any ServerEventPayload, EventTarget) async -> Void,
        syncHandler: @escaping @Sendable () async -> Void
    ) {
        self.landID = landID
        self.playerID = playerID
        self.clientID = clientID
        self.sessionID = sessionID
        self.services = services
        self.sendEventHandler = sendEventHandler
        self.syncHandler = syncHandler
    }

    // MARK: - Public Methods

    /// Send event to specified target
    ///
    /// Events are sent through closure delegation, without exposing Transport details.
    /// The actual implementation is handled by the Runtime layer (LandActor).
    ///
    /// - Parameters:
    ///   - event: ServerEventPayload to send
    ///   - target: EventTarget specifying recipients
    public func sendEvent(_ event: any ServerEventPayload, to target: EventTarget) async {
        await sendEventHandler(event, target)
    }

    /// Manually force immediate state synchronization (regardless of Tick configuration)
    public func syncNow() async {
        await syncHandler()
    }
}
