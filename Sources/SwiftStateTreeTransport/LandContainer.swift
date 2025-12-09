import Foundation
import SwiftStateTree
import Logging

/// Container for a single Land instance.
///
/// Manages the complete lifecycle of one game room, including:
/// - LandKeeper (state management)
/// - Transport layer (WebSocket connections)
/// - State synchronization
///
/// This is a value type that holds references to the actor-based components.
public struct LandContainer<State: StateNodeProtocol>: Sendable {
    public let landID: LandID
    public let keeper: LandKeeper<State>
    public let transport: WebSocketTransport
    public let transportAdapter: TransportAdapter<State>
    
    private let logger: Logger
    
    /// Initialize a LandContainer with all required components.
    ///
    /// - Parameters:
    ///   - landID: The unique identifier for this land.
    ///   - keeper: The LandKeeper actor managing the state.
    ///   - transport: The WebSocketTransport for connections.
    ///   - transportAdapter: The adapter connecting keeper and transport.
    ///   - logger: Optional logger instance.
    public init(
        landID: LandID,
        keeper: LandKeeper<State>,
        transport: WebSocketTransport,
        transportAdapter: TransportAdapter<State>,
        logger: Logger? = nil
    ) {
        self.landID = landID
        self.keeper = keeper
        self.transport = transport
        self.transportAdapter = transportAdapter
        self.logger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.runtime",
            scope: "LandContainer"
        )
    }
    
    /// Get the current state of the land.
    ///
    /// - Returns: A snapshot of the current state.
    public func currentState() async -> State {
        await keeper.currentState()
    }
    
    /// Get statistics about this land.
    ///
    /// - Parameters:
    ///   - createdAt: The creation time of the land.
    /// - Returns: LandStats containing player count and activity information.
    public func getStats(createdAt: Date) async -> LandStats {
        let playerCount = await keeper.playerCount()
        return LandStats(
            landID: landID,
            playerCount: playerCount,
            createdAt: createdAt,
            lastActivityAt: Date()
        )
    }
}

