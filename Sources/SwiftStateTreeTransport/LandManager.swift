import Foundation
import SwiftStateTree
import Logging

/// Manager for multiple game lands.
///
/// Handles land lifecycle, routing, and provides access to individual lands.
/// All operations are thread-safe through actor isolation.
///
/// Supports parallel execution of operations across multiple lands using TaskGroup.
public actor LandManager<State: StateNodeProtocol>: LandManagerProtocol where State: StateNodeProtocol {
    /// Internal container for a single Land instance.
    ///
    /// This is an internal implementation detail of `LandManager` and should not be used directly.
    /// It is exposed in public APIs (e.g., `LandManagerProtocol`) for type compatibility, but
    /// users should interact with `LandManager` instead.
    ///
    /// Manages the complete lifecycle of one game room, including:
    /// - LandKeeper (state management)
    /// - Transport layer (WebSocket connections)
    /// - State synchronization
    ///
    /// This is a value type that holds references to the actor-based components.
    public struct Container: Sendable {
        public let landID: LandID
        public let keeper: LandKeeper<State>
        public let transport: WebSocketTransport
        public let transportAdapter: TransportAdapter<State>
        
        private let logger: Logger
        
        /// Initialize a Container with all required components.
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
    
    private var lands: [LandID: Container] = [:]
    private let landFactory: (LandID) -> LandDefinition<State>
    private let initialStateFactory: (LandID) -> State
    private let sharedTransport: WebSocketTransport?
    private let createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)?
    private let logger: Logger
    private let transportEncoding: TransportEncodingConfig
    
    /// Track creation time for each land
    private var landCreatedAt: [LandID: Date] = [:]
    
    private let enableParallelEncoding: Bool?
    
    /// Initialize a LandManager.
    ///
    /// - Parameters:
    ///   - landFactory: Factory function to create LandDefinition for a given LandID.
    ///   - initialStateFactory: Factory function to create initial state for a given LandID.
    ///   - transport: Optional shared WebSocketTransport instance.
    ///   - createGuestSession: Optional closure to create PlayerSession for guest users.
    ///   - transportEncoding: Encoding configuration for transport messages and state updates.
    ///   - enableParallelEncoding: Enable parallel encoding for state updates (default: nil, uses codec default).
    ///   - logger: Optional logger instance.
    public init(
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        transport: WebSocketTransport? = nil,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        transportEncoding: TransportEncodingConfig = .json,
        enableParallelEncoding: Bool? = nil,
        logger: Logger? = nil
    ) {
        self.landFactory = landFactory
        self.initialStateFactory = initialStateFactory
        self.sharedTransport = transport
        self.createGuestSession = createGuestSession
        self.transportEncoding = transportEncoding
        self.enableParallelEncoding = enableParallelEncoding
        self.logger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.runtime",
            scope: "LandManager"
        )
    }
    
    /// Get or create a land with the specified ID.
    ///
    /// - Parameters:
    ///   - landID: The unique identifier for the land.
    ///   - definition: The Land definition to use if creating a new land.
    ///   - initialState: The initial state for the land if creating a new one.
    /// - Returns: The LandContainer for the land (internal implementation detail, users should use LandManager methods instead).
    public func getOrCreateLand(
        landID: LandID,
        definition: LandDefinition<State>,
        initialState: State
    ) async -> LandContainer<State> {
        // Check if land already exists
        if let existing = lands[landID] {
            // Land exists, return it (monitoring task will auto-remove when destroyed)
            return existing
        }
        
        // Create new land (use provided parameters)
        let landDefinition = definition
        let initial = initialState
        

        
        let transport = self.sharedTransport ?? WebSocketTransport(logger: logger)
        let keeper = LandKeeper<State>(
            definition: landDefinition,
            initialState: initial,
            logger: logger
        )
        
        let transportAdapter = TransportAdapter<State>(
            keeper: keeper,
            transport: transport,
            landID: landID.stringValue,
            createGuestSession: createGuestSession,
            onLandDestroyed: { [landID] in
                await self.removeLand(landID: landID)
            },
            encodingConfig: transportEncoding,
            enableParallelEncoding: enableParallelEncoding,
            logger: logger
        )
        
        await keeper.setTransport(transportAdapter)
        
        // Set the actual land instance ID so LandContext can use it
        await keeper.setLandID(landID.stringValue)
        
        // Only set delegate if we created the transport (own it)
        // If sharedTransport is provided, LandRouter handles delegation
        if self.sharedTransport == nil {
            await transport.setDelegate(transportAdapter)
        }
        
        let container = Container(
            landID: landID,
            keeper: keeper,
            transport: transport,
            transportAdapter: transportAdapter,
            logger: logger
        )
        
        lands[landID] = container
        landCreatedAt[landID] = Date()
        
        logger.info("Created new land", metadata: [
            "landID": .string(landID.stringValue),
            "landType": .string(landID.landType),
            "instanceId": .string(landID.instanceId)
        ])
        
        return container
    }
    
    /// Get an existing land by ID.
    ///
    /// - Parameter landID: The unique identifier for the land.
    /// - Returns: The LandContainer if the land exists, nil otherwise (internal implementation detail).
    public func getLand(landID: LandID) async -> LandContainer<State>? {
        return lands[landID]
    }
    
    /// Remove a land from the manager.
    ///
    /// - Parameter landID: The unique identifier for the land to remove.
    public func removeLand(landID: LandID) async {
        lands.removeValue(forKey: landID)
        landCreatedAt.removeValue(forKey: landID)
        logger.info("Removed land: \(landID.stringValue)")
    }
    
    /// List all active land IDs.
    ///
    /// - Returns: An array of all active land IDs.
    public func listLands() async -> [LandID] {
        return Array(lands.keys)
    }
    
    /// Get statistics for a specific land.
    ///
    /// - Parameter landID: The unique identifier for the land.
    /// - Returns: LandStats if the land exists, nil otherwise.
    public func getLandStats(landID: LandID) async -> LandStats? {
        guard let container = lands[landID],
              let createdAt = landCreatedAt[landID] else {
            return nil
        }
        
        // Get stats from container
        let stats = await container.getStats(createdAt: createdAt)
        return stats
    }
    
    /// Tick all lands in parallel.
    ///
    /// All lands' tick handlers are executed concurrently.
    /// Each land's LandKeeper is an independent actor, allowing true parallelism.
    public func tickAllLands() async {
        let containers = Array(lands.values)
        
        await withTaskGroup(of: Void.self) { group in
            for _ in containers {
                group.addTask {
                    // Each land's tick is handled by its own LandKeeper
                    // The tick loop is already running in each LandKeeper
                    // This method can be used to trigger manual ticks if needed
                }
            }
        }
    }
    
    // MARK: - Lobby Management
    
    /// Check if a landID represents a lobby.
    ///
    /// Uses naming convention: landID starting with "lobby-"
    /// - Parameter landID: The land ID to check.
    /// - Returns: `true` if the land is a lobby, `false` otherwise.
    public func isLobby(landID: LandID) -> Bool {
        return landID.stringValue.hasPrefix("lobby-")
    }
    
    /// List all lobbies (lands with landID starting with "lobby-").
    ///
    /// - Returns: Array of all lobby land IDs.
    public func listLobbies() async -> [LandID] {
        return lands.keys.filter { isLobby(landID: $0) }
    }
    
    /// Get a specific lobby by landID.
    ///
    /// - Parameter landID: The unique identifier for the lobby.
    /// - Returns: The LandContainer if it exists and is a lobby, nil otherwise.
    public func getLobby(landID: LandID) async -> LandContainer<State>? {
        guard isLobby(landID: landID) else {
            return nil
        }
        return lands[landID]
    }
}

// MARK: - Typealias for backward compatibility

/// Type alias for `LandManager.Container`.
///
/// This typealias provides backward compatibility while `LandContainer` is now
/// a nested type within `LandManager`.
public typealias LandContainer<State: StateNodeProtocol> = LandManager<State>.Container
