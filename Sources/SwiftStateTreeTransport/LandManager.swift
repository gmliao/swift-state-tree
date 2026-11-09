import Foundation
import SwiftStateTree
import Logging

/// Resolved keeper mode for a land instance.
public enum LandKeeperModeConfig: Sendable {
    case live
    case reevaluation(recordFilePath: String)
    /// Reject replay join (e.g. invalid instanceId). LandManager will throw when resolving.
    case invalidReplaySession(message: String)
}

/// Where a `LandManager` awaits its test hold hook (`installHolds`).
enum LandManagerHoldPoint: Hashable, Sendable {
    /// The start of each creation, after the existence check.
    case creation
    /// Right before a creation waits for a draining previous instance.
    case drainWait
    /// A built instance, right before the check that it isn't draining and its publication.
    case publish
    /// A built keeper and adapter, right before the adapter is attached to the keeper.
    case wiring
}

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
        /// Identifies this instance among all instances stored under `landID` over time, so a
        /// callback of a destroyed instance never removes its replacement.
        public let epoch: Epoch
        /// The instance's lifecycle-log number, drawn when it was built (`nil` with the log off).
        var lifecycleInstance: UInt64?

        private let logger: Logger
        
        /// Initialize a Container with all required components.
        ///
        /// - Parameters:
        ///   - landID: The unique identifier for this land.
        ///   - keeper: The LandKeeper actor managing the state.
        ///   - transport: The WebSocketTransport for connections.
        ///   - transportAdapter: The adapter connecting keeper and transport.
        ///   - epoch: The instance's epoch (`LandManager` assigns one per created instance).
        ///   - logger: Optional logger instance.
        public init(
            landID: LandID,
            keeper: LandKeeper<State>,
            transport: WebSocketTransport,
            transportAdapter: TransportAdapter<State>,
            epoch: Epoch = Epoch(rawValue: 0),
            logger: Logger? = nil
        ) {
            self.landID = landID
            self.keeper = keeper
            self.transport = transport
            self.transportAdapter = transportAdapter
            self.epoch = epoch
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
    /// Creations in progress, one per LandID: concurrent first joins share one creation.
    private var creations = SingleFlight<LandID, Container>()
    /// The keeper `buildLand` built last (tests: the instance before its publication).
    private(set) weak var lastBuiltKeeperForTesting: LandKeeper<State>?
    /// The adapter of the last instance built (tests).
    private(set) weak var lastBuiltAdapterForTesting: TransportAdapter<State>?

    /// Mints each created instance's epoch.
    private var epochs = EpochCounter()
    /// Instances removed by ID (`removeLand(landID:)`) while they may still drain, held weakly
    /// until their own `onLandDestroyed` runs. A creation for the same ID waits for any of them
    /// that is draining, as for a stored draining instance.
    private var detached: [LandID: [Epoch: DetachedKeeper<State>]] = [:]
    /// Set once by `shutdownAllLands`, before its first await, and never cleared: after a
    /// shutdown this manager creates no lands.
    private var isShuttingDown = false
    /// How long a creation waits for the previous instance's destruction before it fails with
    /// `JoinError.landShuttingDown` (not cached; the next join waits again).
    private var drainWaitTimeout: Duration = landDrainWaitTimeout
    /// Forced-interleaving hold points (tests only; a no-op unless installed).
    private var holds = HoldPoints<LandManagerHoldPoint>()
    /// Calls that joined a creation already in flight (tests: proves the calls shared it).
    private var creationJoins = 0
    private let landFactory: (LandID) -> LandDefinition<State>
    private let initialStateFactory: (LandID) -> State
    private let servicesFactory: (LandID, [String: String]) -> LandServices
    private let sharedTransport: WebSocketTransport?
    private let createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)?
    private let authenticatesPlayers: Bool
    private let logger: Logger
    private let transportEncoding: TransportEncodingConfig
    private let pathHashes: [String: UInt32]?

    /// The state-update features its lands' frames use, from the effective config
    /// (`TransportEncodingConfig.effective(pathHashes:)`, as each land's adapter computes them).
    /// A router in front of these lands requires and echoes exactly these.
    public nonisolated let stateUpdateFeatures: [String]
    private let eventHashes: [String: Int]?
    private let clientEventHashes: [String: Int]?
    private let keeperModeResolver: (@Sendable (LandID, [String: String]) -> LandKeeperModeConfig?)?

    /// The land lifecycle log (`LAND_LIFECYCLE_LOG_PATH`; off by default).
    private var lifecycleLog: LandLifecycleLog? = LandLifecycleLog.shared
    /// Each published instance's lifecycle-log number, by epoch, until its destruction ends.
    /// Empty while the log is off.
    private var lifecycleInstances: [Epoch: UInt64] = [:]

    /// Track creation time for each land
    private var landCreatedAt: [LandID: Date] = [:]
    private var landMetadata: [LandID: [String: String]] = [:]
    
    private let enableLiveStateHashRecording: Bool
    private let enableLoopPhaseOffset: Bool
    private let inTurnSync: Bool
    /// The sync-lag thresholds every land's adapter gets (#332).
    private let syncLagPolicy: SyncLagPolicy?
    
    /// Initialize a LandManager.
    ///
    /// - Parameters:
    ///   - landFactory: Factory function to create LandDefinition for a given LandID.
    ///   - initialStateFactory: Factory function to create initial state for a given LandID.
    ///   - transport: Optional shared WebSocketTransport instance.
    ///   - createGuestSession: Optional closure to create PlayerSession for guest users.
    ///   - authenticatesPlayers: The lands authenticate players (a JWT validator or
    ///     configuration is set); passed to each land's transport adapter (#209).
    ///   - transportEncoding: Encoding configuration for transport messages and state updates.
    ///   - enableLoopPhaseOffset: Per-land phase offset of live lands' tick and sync loops
    ///     (`LandLoopPhase`). Defaults to on unless `LAND_LOOP_PHASE_OFFSET` is false.
    ///   - inTurnSync: Run live lands' sync phases inside their keepers' turns (`InTurnSync`).
    ///     Passed to each land's transport adapter, which also honours `IN_TURN_SYNC`; an
    ///     explicit off in either place wins.
    ///   - logger: Optional logger instance.
    public init(
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        servicesFactory: @escaping @Sendable (LandID, [String: String]) -> LandServices = { _, _ in
            LandServices()
        },
        transport: WebSocketTransport? = nil,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        authenticatesPlayers: Bool = false,
        transportEncoding: TransportEncodingConfig = .json,
        enableLiveStateHashRecording: Bool = false,
        pathHashes: [String: UInt32]? = nil,
        eventHashes: [String: Int]? = nil,
        clientEventHashes: [String: Int]? = nil,
        keeperModeResolver: (@Sendable (LandID, [String: String]) -> LandKeeperModeConfig?)? = nil,
        enableLoopPhaseOffset: Bool = LandLoopPhase.isEnabled(),
        inTurnSync: Bool = true,
        logger: Logger? = nil
    ) {
        self.init(
            landFactory: landFactory, initialStateFactory: initialStateFactory, servicesFactory: servicesFactory,
            transport: transport, createGuestSession: createGuestSession, authenticatesPlayers: authenticatesPlayers,
            transportEncoding: transportEncoding, enableLiveStateHashRecording: enableLiveStateHashRecording,
            pathHashes: pathHashes, eventHashes: eventHashes, clientEventHashes: clientEventHashes,
            keeperModeResolver: keeperModeResolver, enableLoopPhaseOffset: enableLoopPhaseOffset,
            inTurnSync: inTurnSync, syncLagPolicy: nil, logger: logger
        )
    }

    /// The init with sync-lag thresholds (#332), for hosted lands (`NIOLandServer`): tracking runs
    /// only with an encoding that carries the sync sequence, which only package code builds.
    package init(
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        servicesFactory: @escaping @Sendable (LandID, [String: String]) -> LandServices = { _, _ in
            LandServices()
        },
        transport: WebSocketTransport? = nil,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        authenticatesPlayers: Bool = false,
        transportEncoding: TransportEncodingConfig = .json,
        enableLiveStateHashRecording: Bool = false,
        pathHashes: [String: UInt32]? = nil,
        eventHashes: [String: Int]? = nil,
        clientEventHashes: [String: Int]? = nil,
        keeperModeResolver: (@Sendable (LandID, [String: String]) -> LandKeeperModeConfig?)? = nil,
        enableLoopPhaseOffset: Bool = LandLoopPhase.isEnabled(),
        inTurnSync: Bool = true,
        syncLagPolicy: SyncLagPolicy?,
        logger: Logger? = nil
    ) {
        self.landFactory = landFactory
        self.initialStateFactory = initialStateFactory
        self.servicesFactory = servicesFactory
        self.sharedTransport = transport
        self.createGuestSession = createGuestSession
        self.authenticatesPlayers = authenticatesPlayers
        self.transportEncoding = transportEncoding
        self.stateUpdateFeatures = transportEncoding.effective(pathHashes: pathHashes).stateUpdateFeatures
        self.enableLiveStateHashRecording = enableLiveStateHashRecording
        self.enableLoopPhaseOffset = enableLoopPhaseOffset
        self.inTurnSync = inTurnSync
        self.syncLagPolicy = syncLagPolicy
        self.pathHashes = pathHashes
        self.eventHashes = eventHashes
        self.clientEventHashes = clientEventHashes
        self.keeperModeResolver = keeperModeResolver
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
    /// Concurrent calls for an ID with no live land share one creation (single-flight): they
    /// all get the same container, and exactly one keeper is created. A stored land that is
    /// draining (`LandKeeper.isDraining`) counts as absent: a join after an empty land started
    /// its destruction gets a fresh instance, created once that destruction has finished. A
    /// creation that throws is not cached; the next call starts a new one.
    ///
    /// The wait for the previous instance's destruction is bounded (`landDrainWaitTimeout`): if
    /// its finalize hangs, the creation fails with `JoinError.landShuttingDown` and the ID stays
    /// joinable once the destruction finishes. Each timed-out wait leaves one inner wait task,
    /// holding a reference to the old keeper, until that destruction ends; the cost is bounded
    /// by the joins retried meanwhile. After `shutdownAllLands` started, a call that would
    /// create a land throws `JoinError.landShuttingDown`, for the rest of the manager's life.
    ///
    /// - Returns: The LandContainer for the land (internal implementation detail, users should use LandManager methods instead).
    /// - Throws: When keeperModeResolver returns .reevaluation but the record file cannot be loaded.
    ///   A caller that is cancelled stops waiting with `CancellationError`; the creation goes on
    ///   for the other callers.
    public func getOrCreateLand(
        landID: LandID,
        definition: LandDefinition<State>,
        initialState: State,
        metadata: [String: String]
    ) async throws -> LandContainer<State> {
        if let existing = lands[landID], !existing.keeper.isDraining {
            return existing
        }
        guard !isShuttingDown else { throw JoinError.landShuttingDown }
        if creations.inFlight(landID) != nil {
            creationJoins += 1
        }
        // Reserve the creation before the first await (CLAUDE.md, "Actor reentrancy").
        let creation = creations.flight(for: landID) { token in
            Task {
                try await self.createLand(
                    landID: landID,
                    definition: definition,
                    initialState: initialState,
                    metadata: metadata,
                    token: token
                )
            }
        }
        return try await SingleFlight<LandID, Container>.value(of: creation)
    }

    /// One creation flight. Ends with the insert and `creations.finish` in one synchronous
    /// segment, or with `creations.finish` when it throws.
    private func createLand(
        landID: LandID,
        definition: LandDefinition<State>,
        initialState: State,
        metadata: [String: String],
        token: SingleFlight<LandID, Container>.Token
    ) async throws -> Container {
        do {
            // A previous instance is draining (stored, or removed by ID): let its destruction
            // finish first, so its finalize (OnFinalize, AfterFinalize, persistence) never
            // overlaps the new instance's initialize for the same LandID. Epoch removal alone
            // prevents only the map ABA, not this overlap.
            let previous = drainingInstances(of: landID)
            if !previous.isEmpty {
                await holds.at(.drainWait)
                try await waitForDrains(of: previous, landID: landID)
            }
            await holds.at(.creation)
            let container = try await buildLand(
                landID: landID,
                definition: definition,
                initialState: initialState,
                metadata: metadata
            )
            await holds.at(.publish)
            // Same synchronous segment as the publication: a land whose initialization already
            // failed (#104) is torn down, and its `onLandDestroyed` may have run before it was
            // stored (found nothing to remove) or never reach this manager (no transport yet).
            // Its drain flag is set before that callback, so a land not draining here is
            // removed by its callback later, as any other.
            guard !container.keeper.isDraining else {
                logger.warning("Created land was torn down before it was published (its initialization failed)", metadata: [
                    "landID": .string(landID.stringValue),
                ])
                // Its teardown may have finished before its adapter was wired, so nothing in it
                // releases this land's own transport's link to the adapter: released here, for
                // this exact instance (#346). A shared transport's delegate is the router.
                if sharedTransport == nil {
                    await container.transport.releaseDelegate(ifIdenticalTo: container.transportAdapter)
                }
                throw JoinError.landShuttingDown
            }
            lands[landID] = container
            landCreatedAt[landID] = Date()
            landMetadata[landID] = metadata
            creations.finish(landID, token: token)
            if let lifecycleLog, let instance = container.lifecycleInstance {
                lifecycleInstances[container.epoch] = instance
                lifecycleLog.log(.created, landID: landID, instance: instance, epoch: container.epoch)
            }

            logger.info("Created new land", metadata: [
                "landID": .string(landID.stringValue),
                "landType": .string(landID.landType),
                "instanceId": .string(landID.instanceId)
            ])
            return container
        } catch {
            creations.finish(landID, token: token)
            throw error
        }
    }

    /// The previous instances of `landID` whose destruction is in progress: the stored one if it
    /// is draining, and detached ones that are draining. A detached instance that is not
    /// draining still has players; nothing waits for it.
    private func drainingInstances(of landID: LandID) -> [LandKeeper<State>] {
        var keepers: [LandKeeper<State>] = []
        if let stored = lands[landID], stored.keeper.isDraining {
            keepers.append(stored.keeper)
        }
        if let entries = detached[landID] {
            for entry in entries.values {
                if let keeper = entry.keeper, keeper.isDraining {
                    keepers.append(keeper)
                }
            }
        }
        return keepers
    }

    /// Waits for every keeper's destruction within one `drainWaitTimeout`.
    /// - Throws: `JoinError.landShuttingDown` on timeout; `CancellationError` when cancelled.
    private func waitForDrains(of keepers: [LandKeeper<State>], landID: LandID) async throws {
        let deadline = ContinuousClock.now + drainWaitTimeout
        for keeper in keepers {
            let remaining = deadline - ContinuousClock.now
            if await waitUntilDrained(keeper, timeout: remaining) { continue }
            try Task.checkCancellation()
            logger.warning("Previous land instance did not finish its destruction in time", metadata: [
                "landID": .string(landID.stringValue),
                "timeout": .stringConvertible(drainWaitTimeout),
            ])
            throw JoinError.landShuttingDown
        }
    }

    /// Builds a land instance (keeper, adapter, transport wiring) without publishing it.
    private func buildLand(
        landID: LandID,
        definition: LandDefinition<State>,
        initialState: State,
        metadata: [String: String]
    ) async throws -> Container {
        let epoch = epochs.next()
        let landDefinition = definition
        let initial = initialState

        // The keeper mode first: a land it refuses builds no services, so a refused creation
        // starts nothing a services factory would (a replay runner, a connection). The
        // resolver sees only the land ID and metadata, never the services.
        let keeperMode = keeperModeResolver?(landID, metadata)
        if case let .invalidReplaySession(message)? = keeperMode {
            throw ReevaluationReplayError.invalidSessionDescriptor(message)
        }

        let metadataServices = servicesFactory(landID, metadata)

        let transport = self.sharedTransport ?? WebSocketTransport(logger: logger)

        let keeper: LandKeeper<State>
        // A re-evaluation keeper always syncs on the legacy path; its adapter keeps its own
        // executor, so replay encoding does not run on the keeper's executor.
        var isReevaluationKeeper = false
        if let config = keeperMode {
            if case let .reevaluation(recordFilePath) = config {
                let source = try ReevaluationRecordFile.openSource(filePath: recordFilePath)
                isReevaluationKeeper = true

                // Pre-register the RNG seed from the *recorded* game's landID.
                // This is critical for determinism: reevaluation must use the same RNG seed
                // as the original live game. Without this, setLandID() would derive the seed
                // from the replay landID (e.g. "hero-defense-replay:xyz") instead of the
                // original game's landID (e.g. "hero-defense:abc123"), causing divergence
                // in any RNG-based logic (e.g. initial player position in OnJoin).
                var reevalServices = metadataServices
                let recordedMetadata = try await source.getMetadata()
                // The engine's check: anything this build reads (2.5+, 3.x).
                guard ReevaluationRecordVersion.isReadable(recorded: recordedMetadata.version) else {
                    throw ReevaluationRecordVersionError.incompatible(
                        recorded: recordedMetadata.version,
                        required: ReevaluationRecordVersion.current
                    )
                }
                let rngSeed = recordedMetadata.rngSeed
                    ?? DeterministicSeed.fromLandID(recordedMetadata.landID)
                reevalServices.register(
                    DeterministicRngService(seed: rngSeed),
                    as: DeterministicRngService.self
                )

                keeper = LandKeeper<State>(
                    definition: landDefinition,
                    initialState: initial,
                    mode: .reevaluation,
                    reevaluationSource: source,
                    reevaluationSink: nil,
                    reevaluationOutputMode: .transportAndSink,
                    services: reevalServices,
                    autoStartLoops: true,
                    transport: nil,
                    logger: logger
                )
            } else {
                keeper = LandKeeper<State>(
                    definition: landDefinition,
                    initialState: initial,
                    services: metadataServices,
                    enableLiveStateHashRecording: enableLiveStateHashRecording,
                    enableLoopPhaseOffset: enableLoopPhaseOffset,
                    landID: landID.stringValue,
                    logger: logger
                )
            }
        } else {
            keeper = LandKeeper<State>(
                definition: landDefinition,
                initialState: initial,
                services: metadataServices,
                enableLiveStateHashRecording: enableLiveStateHashRecording,
                enableLoopPhaseOffset: enableLoopPhaseOffset,
                landID: landID.stringValue,
                logger: logger
            )
        }
        
        // Live keepers already got the instance ID in init (before their eager initialization).
        // This also covers the re-evaluation keeper, whose RNG seed comes from the record.
        await keeper.setLandID(landID.stringValue)

        // Debug: Check if pathHashes is available
        if let pathHashes = pathHashes {
            logger.info("🔍 PathHashes available for land", metadata: ["count": .stringConvertible(pathHashes.count)])
        } else {
            logger.warning("⚠️  PathHashes is nil for land")
        }
        
        let transportAdapter = TransportAdapter<State>(
            keeper: keeper,
            transport: transport,
            landID: landID.stringValue,
            createGuestSession: createGuestSession,
            authenticatesPlayers: authenticatesPlayers,
            onLandDestroyed: { [landID, epoch, weak keeper] in
                // Read before the hop: the keeper set it before its destruction started.
                let cause = keeper?.destructionCause
                // This instance only: a newer instance stored under the same ID stays.
                await self.removeLand(landID: landID, epoch: epoch, cause: cause)
            },
            encodingConfig: transportEncoding,
            pathHashes: pathHashes,
            eventHashes: eventHashes,
            clientEventHashes: clientEventHashes,
            inTurnSync: inTurnSync && !isReevaluationKeeper,
            logger: logger
        )
        if let syncLagPolicy {
            await transportAdapter.setSyncLagPolicy(syncLagPolicy)
        }
        
        // Configure record metadata (deterministic re-evaluation). After the adapter exists: the
        // sync stream is recorded only with in-turn sync on, which the adapter decides.
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
                version: ReevaluationRecordVersion.current,
                extensions: nil,
                hardwareInfo: hardwareInfo,
                recordsSyncStream: transportAdapter.inTurnSyncEnabled,
                syncConfig: transportAdapter.inTurnSyncEnabled ? transportAdapter.syncConfigForRecord : nil
            )
            await recorder.setMetadata(recordingMetadata)
        }
        
        // Drawn at build, so the adapter's session lines name the instance from its first join;
        // `created` logs it at publication. A land torn down before then leaves a gap.
        let lifecycleInstance = lifecycleLog?.nextInstance()
        if let lifecycleLog, let lifecycleInstance {
            await transportAdapter.attachLifecycleLog(lifecycleLog, instance: lifecycleInstance)
        }

        lastBuiltKeeperForTesting = keeper
        lastBuiltAdapterForTesting = transportAdapter
        await holds.at(.wiring)
        await keeper.setTransport(transportAdapter)
        
        // Note: setLandID was already called above before recording metadata
        // to ensure the RNG seed uses the actual landID
        
        // Only set delegate if we created the transport (own it)
        // If sharedTransport is provided, LandRouter handles delegation
        if self.sharedTransport == nil {
            await transport.setDelegate(transportAdapter)
        }
        
        lastBuiltKeeperForTesting = keeper
        var container = Container(
            landID: landID,
            keeper: keeper,
            transport: transport,
            transportAdapter: transportAdapter,
            epoch: epoch,
            logger: logger
        )
        container.lifecycleInstance = lifecycleInstance
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
    /// Removes by ID, whatever instance is stored (admin). The removed instance stays known as
    /// detached until its own `onLandDestroyed` runs, so a later creation for the ID still waits
    /// for its destruction if it is draining.
    public func removeLand(landID: LandID) async {
        if let stored = lands[landID] {
            detached[landID, default: [:]][stored.epoch] = DetachedKeeper(stored.keeper)
            if let lifecycleLog, let instance = lifecycleInstances[stored.epoch] {
                lifecycleLog.log(.removed, landID: landID, instance: instance, epoch: stored.epoch)
            }
        }
        removeStoredLand(landID: landID)
    }

    private func removeStoredLand(landID: LandID) {
        lands.removeValue(forKey: landID)
        landCreatedAt.removeValue(forKey: landID)
        landMetadata.removeValue(forKey: landID)
        logger.info("Removed land: \(landID.stringValue)")
    }

    /// Removes the instance with `epoch` only. A destroyed instance's callback can run after a
    /// newer instance was stored under the same ID (the old one was draining); that one stays.
    func removeLand(landID: LandID, epoch: Epoch, cause: LandDestructionCause? = nil) async {
        // Its destruction is over: a detached instance needs no more waiting for.
        dropDetached(landID: landID, epoch: epoch)
        // By epoch, whether or not it is still stored: an instance never published (its
        // initialization failed first) has no number and logs nothing.
        if let instance = lifecycleInstances.removeValue(forKey: epoch) {
            lifecycleLog?.log(.destroyed, landID: landID, instance: instance, epoch: epoch, cause: cause)
        }
        guard let stored = lands[landID], stored.epoch == epoch else {
            logger.debug("Destroyed land instance already replaced", metadata: [
                "landID": .string(landID.stringValue),
                "epoch": .stringConvertible(epoch),
            ])
            return
        }
        // Same synchronous segment as the identity check.
        removeStoredLand(landID: landID)
    }

    private func dropDetached(landID: LandID, epoch: Epoch) {
        guard var entries = detached[landID] else { return }
        entries.removeValue(forKey: epoch)
        // Instances already released need no tracking either.
        entries = entries.filter { $0.value.keeper != nil }
        detached[landID] = entries.isEmpty ? nil : entries
    }

    /// Replaces the lifecycle log (tests). Call before the first creation.
    func installLifecycleLog(_ log: LandLifecycleLog?) {
        lifecycleLog = log
    }

    /// Installs (or, with `nil`, removes) the hold hook for every `LandManagerHoldPoint` (tests).
    func installHolds(_ hook: (@Sendable (LandManagerHoldPoint) async -> Void)?) {
        holds.install(hook)
    }

    /// Sets the bound on waiting for a previous instance's destruction (tests).
    func setDrainWaitTimeout(_ timeout: Duration) {
        drainWaitTimeout = timeout
    }

    /// Calls that joined a creation already in flight (tests).
    func creationJoinCount() -> Int {
        creationJoins
    }

    /// Whether `shutdownAllLands` started (tests).
    func isShutdownStarted() -> Bool {
        isShuttingDown
    }

    /// Creations in progress (tests).
    func creationsInFlight() -> Int {
        creations.count
    }

    /// Force shutdown all active lands.
    /// Intended for benchmarks or test harnesses that need to end quickly.
    ///
    /// Creations are rejected from the start (`JoinError.landShuttingDown`) and for the rest of
    /// this manager's life; creations already in progress finish or fail first, so every land
    /// they publish is shut down too.
    public func shutdownAllLands() async {
        // Before the first await: no creation starts after this point.
        isShuttingDown = true
        while creations.count > 0 {
            for creation in creations.cancelAll() {
                _ = try? await creation.value
            }
        }
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

/// The bound on waiting for a previous instance's destruction before a recreate fails
/// (`LandManager.getOrCreateLand`). Long enough for slow persistence in `AfterFinalize`.
let landDrainWaitTimeout: Duration = .seconds(30)

/// An instance removed by ID, held weakly: a released keeper has nothing left to wait for.
private struct DetachedKeeper<State: StateNodeProtocol>: @unchecked Sendable {
    weak var keeper: LandKeeper<State>?

    init(_ keeper: LandKeeper<State>) {
        self.keeper = keeper
    }
}

/// Waits for `keeper`'s destruction for at most `timeout`. Returns false on timeout or when the
/// calling task is cancelled; the destruction itself is never cancelled. After a timeout the
/// inner wait task (and its keeper reference) stays until the destruction ends.
private func waitUntilDrained<State: StateNodeProtocol>(
    _ keeper: LandKeeper<State>,
    timeout: Duration
) async -> Bool {
    // A spent budget (several previous instances) waits no longer.
    let timeout = max(timeout, .zero)
    let outcome = DrainWaitOutcome()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            guard outcome.install(continuation) else { return }
            let timer = Task {
                try? await safeTaskSleep(for: timeout)
                outcome.resume(false)
            }
            outcome.setTimer(timer)
            Task {
                await keeper.waitUntilDrained()
                outcome.resume(true)
            }
        }
    } onCancel: {
        outcome.resume(false)
    }
}

/// The result of one bounded drain wait, delivered exactly once.
private final class DrainWaitOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timer: Task<Void, Never>?
    private var result: Bool?

    /// Stores the continuation, or resumes it at once if the outcome is already known.
    func install(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setTimer(_ timer: Task<Void, Never>) {
        lock.lock()
        let finished = result != nil
        if !finished { self.timer = timer }
        lock.unlock()
        if finished { timer.cancel() }
    }

    func resume(_ value: Bool) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        let continuation = self.continuation
        let timer = self.timer
        self.continuation = nil
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(returning: value)
    }
}
