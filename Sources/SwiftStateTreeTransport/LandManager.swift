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
        public func getStats(createdAt: Date, metadata: [String: String]) async -> LandStats {
            let playerCount = await keeper.playerCount()
            return LandStats(
                landID: landID,
                playerCount: playerCount,
                createdAt: createdAt,
                lastActivityAt: Date(),
                metadata: metadata
            )
        }
    }
    
    private var lands: [LandID: Container] = [:]
    private let landFactory: (LandID) -> LandDefinition<State>
    private let initialStateFactory: (LandID) -> State
    private let servicesFactory: (LandID, [String: String]) -> LandServices
    private let sharedTransport: WebSocketTransport?
    private let createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)?
    private let logger: Logger
    private let transportEncoding: TransportEncodingConfig
    private let pathHashes: [String: UInt32]?
    private let eventHashes: [String: Int]?
    private let clientEventHashes: [String: Int]?
    
    /// Track creation time for each land
    private var landCreatedAt: [LandID: Date] = [:]
    private var landMetadata: [LandID: [String: String]] = [:]
    
    private let enableLiveStateHashRecording: Bool
    
    /// Initialize a LandManager.
    ///
    /// - Parameters:
    ///   - landFactory: Factory function to create LandDefinition for a given LandID.
    ///   - initialStateFactory: Factory function to create initial state for a given LandID.
    ///   - transport: Optional shared WebSocketTransport instance.
    ///   - createGuestSession: Optional closure to create PlayerSession for guest users.
    ///   - transportEncoding: Encoding configuration for transport messages and state updates.
    ///   - logger: Optional logger instance.
    public init(
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        servicesFactory: @escaping @Sendable (LandID, [String: String]) -> LandServices = { _, _ in
            LandServices()
        },
        transport: WebSocketTransport? = nil,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        transportEncoding: TransportEncodingConfig = .json,
        enableLiveStateHashRecording: Bool = false,
        pathHashes: [String: UInt32]? = nil,
        eventHashes: [String: Int]? = nil,
        clientEventHashes: [String: Int]? = nil,
        logger: Logger? = nil
    ) {
        self.landFactory = landFactory
        self.initialStateFactory = initialStateFactory
        self.servicesFactory = servicesFactory
        self.sharedTransport = transport
        self.createGuestSession = createGuestSession
        self.transportEncoding = transportEncoding
        self.enableLiveStateHashRecording = enableLiveStateHashRecording
        self.pathHashes = pathHashes
        self.eventHashes = eventHashes
        self.clientEventHashes = clientEventHashes
        self.logger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.runtime",
            scope: "LandManager"
        )
        
        // Validate: Warn if opcodeJsonArray is used without pathHashes
        if transportEncoding.stateUpdate == .opcodeJsonArray && pathHashes == nil {
            self.logger.warning(
                "⚠️ LandManager: opcodeJsonArray encoding without pathHashes",
                metadata: [
                    "encoding": .string(transportEncoding.stateUpdate.rawValue),
                    "issue": .string("PathHash compression disabled for all lands"),
                    "solution": .string("Provide pathHashes in server configuration (e.g. NIOLandServerConfiguration)")
                ]
            )
        }
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
        initialState: State,
        metadata: [String: String]
    ) async -> LandContainer<State> {
        // Check if land already exists
        if let existing = lands[landID] {
            // Land exists, return it (monitoring task will auto-remove when destroyed)
            return existing
        }
        
        // Create new land (use provided parameters)
        let landDefinition = definition
        let initial = initialState

        let metadataServices = servicesFactory(landID, metadata)

        let transport = self.sharedTransport ?? WebSocketTransport(logger: logger)

        let keeper = LandKeeper<State>(
            definition: landDefinition,
            initialState: initial,
            services: metadataServices,
            enableLiveStateHashRecording: enableLiveStateHashRecording,
            logger: logger
        )
        
        // Set the actual land instance ID before recording metadata
        // This ensures the RNG seed is updated to use the actual landID (not just definition.id)
        await keeper.setLandID(landID.stringValue)

        // Configure record metadata (deterministic re-evaluation)
        if let recorder = await keeper.getReevaluationRecorder() {
            // Extract RNG seed from LandKeeper's services for deterministic re-evaluation
            // RNG seed is critical when RNG is used in game logic (e.g., monster spawning, player positioning)
            // Note: DeterministicRngService is automatically registered by LandKeeper if not provided,
            // and setLandID() ensures it uses the actual landID seed
            let rngSeed = await keeper.getRngSeed()
            
            // Note: We do NOT record tickInterval/syncInterval because:
            // 1. Replay mode uses manual tick stepping (stepTickOnce()), not automatic loops
            // 2. These intervals are runtime configuration, not game logic
            // 3. Recording them could cause confusion if they change later
            // Only record configuration that affects game logic determinism
            
            // Collect hardware information for cross-architecture verification
            let hardwareInfo = HardwareInfoCollector.collect()
            
            let recordingMetadata = ReevaluationRecordMetadata(
                landID: landID.stringValue,
                landType: landID.landType,
                createdAt: Date(),
                metadata: metadata,
                landDefinitionID: landDefinition.id,
                initialStateHash: nil,
                landConfig: nil, // No runtime config needed for re-evaluation
                rngSeed: rngSeed,
                ruleVariantId: nil,
                ruleParams: nil,
                version: "2.0",
                extensions: nil,
                hardwareInfo: hardwareInfo
            )
            await recorder.setMetadata(recordingMetadata)
        }
        
        // Debug: Check if pathHashes is available
        if let pathHashes = pathHashes {
            logger.info("🔍 PathHashes available for land", metadata: ["count": .stringConvertible(pathHashes.count)])
        } else {
            logger.warning("⚠️  PathHashes is nil for land")
        }
        
        let transportAdapter = TransportAdapter<State>(
            keeper: keeper,
            transport: transport,
            transportSendQueue: transport.transportSendQueue,
            landID: landID.stringValue,
            createGuestSession: createGuestSession,
            onLandDestroyed: { [landID] in
                await self.removeLand(landID: landID)
            },
            encodingConfig: transportEncoding,
            pathHashes: pathHashes,
            eventHashes: eventHashes,
            clientEventHashes: clientEventHashes,
            logger: logger
        )
        
        await keeper.setTransport(transportAdapter)
        
        // Note: setLandID was already called above before recording metadata
        // to ensure the RNG seed uses the actual landID
        
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
        landMetadata[landID] = metadata
        
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
        landMetadata.removeValue(forKey: landID)
        logger.info("Removed land: \(landID.stringValue)")
    }

    /// Force shutdown all active lands.
    /// Intended for benchmarks or test harnesses that need to end quickly.
    public func shutdownAllLands() async {
        let containers = Array(lands.values)
        await withTaskGroup(of: Void.self) { group in
            for container in containers {
                group.addTask {
                    await container.keeper.forceShutdown()
                }
            }
        }
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
        let stats = await container.getStats(createdAt: createdAt, metadata: landMetadata[landID] ?? [:])
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
}

// MARK: - Typealias for backward compatibility

/// Type alias for `LandManager.Container`.
///
/// This typealias provides backward compatibility while `LandContainer` is now
/// a nested type within `LandManager`.
public typealias LandContainer<State: StateNodeProtocol> = LandManager<State>.Container
