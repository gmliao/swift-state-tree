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
    /// A shutdown's land list taken (`beginShutdown`), right before it returns.
    case shutdownListed
    /// A land stop's detach done (`detachForStop`, the instance marked stopping), before the
    /// stop closes its sessions (#102).
    case stopDetached
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
    /// The instances a shutdown has handed out for destruction (`beginShutdown`, then
    /// `creationLandsForShutdown`), so each goes out once.
    private var shutdownListedEpochs: Set<Epoch> = []
    /// The keeper `buildLand` built last (tests: the instance before its publication).
    private(set) weak var lastBuiltKeeperForTesting: LandKeeper<State>?
    /// The adapter of the last instance built (tests).
    private(set) weak var lastBuiltAdapterForTesting: TransportAdapter<State>?

    /// Mints each created instance's epoch.
    private var epochs = EpochCounter()
    /// Instances detached by ID (`detachLand`, `detachForStop`) while they may still drain, held
    /// weakly until their own `onLandDestroyed` runs. A creation for the same ID waits for any of
    /// them that is draining, as for a stored draining instance, and for a stopping one (#102).
    private var detached: [LandID: [Epoch: DetachedKeeper<State>]] = [:]
    /// Creations waiting for a stopping instance's drop (#102), by instance and waiter: resumed
    /// by `dropDetached`, or removed when their bounded wait gives up. Kept here, not in the
    /// detached entry, so replacing an entry can't lose them.
    private var dropWaiters: [DropKey: [UInt64: CheckedContinuation<Void, Never>]] = [:]
    /// Drop waits whose waiter has run (`waitUntilDropped` entered), until their bounded wait
    /// ends; and those that gave up before it ran, which then return at once.
    private var startedDropWaits: Set<UInt64> = []
    private var abandonedDropWaits: Set<UInt64> = []
    private var nextDropWaitID: UInt64 = 0

    private struct DropKey: Hashable {
        let landID: LandID
        let epoch: Epoch
    }
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
    /// (`TransportEncodingConfig.effective(pathHashes:)`, as each land's adapter computes them),
    /// without `rowAddressing`: whether a land has that in effect is its adapter's to say
    /// (`TransportAdapter.stateUpdateFeatures`). A router in front of these lands requires these
    /// before a land exists, and then the land's own list.
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
        self.stateUpdateFeatures = transportEncoding.effective(pathHashes: pathHashes).withRowAddressing(false).stateUpdateFeatures
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
            let previous = drainWaits(of: landID)
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

    /// What a creation waits for before it builds a new instance of a land ID.
    private enum DrainWait {
        /// An instance whose destruction has started: its keeper's drain.
        case keeper(LandKeeper<State>)
        /// An instance a stop detached (#102): its destruction starts only after its sessions'
        /// leaves, and its keeper's drain wait would return at once before that. Waited for
        /// until the manager drops its epoch (its `onLandDestroyed`).
        case stopping(LandID, Epoch)
    }

    /// The previous instances of `landID` a creation waits for: the stored one if it is
    /// draining, detached ones that are draining, and a stopping one whatever its stage. A
    /// detached instance that is neither still has players; nothing waits for it.
    private func drainWaits(of landID: LandID) -> [DrainWait] {
        var waits: [DrainWait] = []
        if let stored = lands[landID], stored.keeper.isDraining {
            waits.append(.keeper(stored.keeper))
        }
        if let entries = detached[landID] {
            for (epoch, entry) in entries {
                guard let keeper = entry.keeper else { continue }
                if entry.stopping {
                    waits.append(.stopping(landID, epoch))
                } else if keeper.isDraining {
                    waits.append(.keeper(keeper))
                }
            }
        }
        return waits
    }

    /// Waits for every previous instance's destruction within one `drainWaitTimeout`.
    /// - Throws: `JoinError.landShuttingDown` on timeout; `CancellationError` when cancelled.
    private func waitForDrains(of waits: [DrainWait], landID: LandID) async throws {
        let deadline = ContinuousClock.now + drainWaitTimeout
        for wait in waits {
            let remaining = deadline - ContinuousClock.now
            let finished: Bool
            switch wait {
            case .keeper(let keeper):
                finished = await waitUntilDrained(keeper, timeout: remaining)
            case .stopping(let landID, let epoch):
                let key = DropKey(landID: landID, epoch: epoch)
                nextDropWaitID += 1
                let id = nextDropWaitID
                finished = await boundedDrainWait(timeout: remaining) { await self.waitUntilDropped(key, id: id) }
                // Timed out or cancelled: the waiter leaves now, not at the drop, so a destroy
                // that hangs doesn't collect one per join attempt.
                endDropWait(key, id: id, gaveUp: !finished)
            }
            if finished { continue }
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
            logger: logger,
            // With a shared transport the router owns its delegate and every join.
            joinsThroughRouter: sharedTransport != nil
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
    
    /// An instance detached by ID, held strongly by whoever detached it.
    package struct DetachedInstance: Sendable {
        package let landID: LandID
        package let epoch: Epoch
        package let keeper: LandKeeper<State>
        package let adapter: TransportAdapter<State>
    }

    /// Detaches the stored instance of `landID`, whatever it is. It leaves the stored map and
    /// keeps running with its players; it stays known as detached until its own
    /// `onLandDestroyed` runs, so a later creation for the ID waits for its destruction once it
    /// is draining. Returns the detached instance, or nil when none is stored.
    ///
    /// The admin API stops a land instead (`detachForStop`, #102); this plain detach is what
    /// the stop builds on, and what tests use to leave an instance running beside a new one.
    @discardableResult
    package func detachLand(landID: LandID) -> DetachedInstance? {
        detach(landID: landID, stopping: false)
    }

    /// The first segment of a land stop (#102). Detaches the stored instance of `landID`,
    /// marked stopping, and returns it; or, with none stored, returns the instance a stop
    /// already detached and that is not destroyed yet; or nil.
    ///
    /// A creation for the ID waits until a stopping instance is dropped (its `onLandDestroyed`),
    /// within `drainWaitTimeout`, then builds a fresh one: the stopping instance's destruction
    /// starts only after its sessions' leaves, so its drain alone isn't a signal yet.
    package func detachForStop(landID: LandID) async -> DetachedInstance? {
        if let detachedNow = detach(landID: landID, stopping: true) {
            await holds.at(.stopDetached)
            return detachedNow
        }
        guard let entries = detached[landID] else { return nil }
        for (epoch, entry) in entries where entry.stopping {
            if let keeper = entry.keeper, let adapter = entry.adapter {
                return DetachedInstance(landID: landID, epoch: epoch, keeper: keeper, adapter: adapter)
            }
        }
        return nil
    }

    /// Moves the stored instance of `landID` to `detached`, in this one segment.
    private func detach(landID: LandID, stopping: Bool) -> DetachedInstance? {
        guard let stored = lands[landID] else { return nil }
        detached[landID, default: [:]][stored.epoch] = DetachedKeeper(
            stored.keeper, adapter: stored.transportAdapter, stopping: stopping
        )
        if let lifecycleLog, let instance = lifecycleInstances[stored.epoch] {
            lifecycleLog.log(.removed, landID: landID, instance: instance, epoch: stored.epoch)
        }
        removeStoredLand(landID: landID)
        return DetachedInstance(landID: landID, epoch: stored.epoch, keeper: stored.keeper, adapter: stored.transportAdapter)
    }

    /// Returns once the instance is no longer detached (its `onLandDestroyed` ran, or it was
    /// released), or at once if it already isn't (#102). The check and the registration are one
    /// segment, so a drop before it is seen; `dropDetached` resumes it in its own segment.
    private func waitUntilDropped(_ key: DropKey, id: UInt64) async {
        if abandonedDropWaits.remove(id) != nil { return }
        startedDropWaits.insert(id)
        guard detached[key.landID]?[key.epoch] != nil else { return }
        await withCheckedContinuation { dropWaiters[key, default: [:]][id] = $0 }
    }

    /// A bounded drop wait ended. One that gave up resumes and removes its waiter if parked,
    /// or, if the waiter hasn't run yet, makes it return at once when it does.
    private func endDropWait(_ key: DropKey, id: UInt64, gaveUp: Bool) {
        if let waiter = dropWaiters[key]?.removeValue(forKey: id) {
            if dropWaiters[key]?.isEmpty == true { dropWaiters[key] = nil }
            waiter.resume()
        }
        if startedDropWaits.remove(id) == nil, gaveUp {
            abandonedDropWaits.insert(id)
        }
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

    /// Whether the instance with `epoch` is still this manager's: stored, or detached and not
    /// yet past its destruction (its `onLandDestroyed` drops the entry). A session bound to an
    /// instance that is not live gets the "land no longer exists" answer (#390).
    package func isLive(landID: LandID, epoch: Epoch) -> Bool {
        if let stored = lands[landID], stored.epoch == epoch { return true }
        return detached[landID]?[epoch]?.keeper != nil
    }

    /// The adapter of the instance with `epoch`, stored or detached, while it is live.
    package func adapter(landID: LandID, epoch: Epoch) -> TransportAdapter<State>? {
        if let stored = lands[landID], stored.epoch == epoch { return stored.transportAdapter }
        guard let entry = detached[landID]?[epoch], entry.keeper != nil else { return nil }
        return entry.adapter
    }

    private func dropDetached(landID: LandID, epoch: Epoch) {
        guard var entries = detached[landID] else { return }
        let before = Set(entries.keys)
        entries.removeValue(forKey: epoch)
        // Instances already released need no tracking either.
        entries = entries.filter { $0.value.keeper != nil }
        detached[landID] = entries.isEmpty ? nil : entries
        // A creation waiting for any instance no longer tracked goes on (#102), in the
        // removal's segment.
        for dropped in before.subtracting(entries.keys) {
            for waiter in (dropWaiters.removeValue(forKey: DropKey(landID: landID, epoch: dropped)) ?? [:]).values {
                waiter.resume()
            }
        }
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

    /// Creations in progress (tests, and a shutdown's summary: creations whose land never
    /// reached a destroy).
    package func creationsInFlight() -> Int {
        creations.count
    }

    /// Force shutdown all active lands.
    /// Intended for benchmarks or test harnesses that need to end quickly.
    ///
    /// Creations are rejected from the start (`JoinError.landShuttingDown`) and for the rest of
    /// this manager's life; creations already in progress finish or fail first, so every land
    /// they publish is shut down too.
    public func shutdownAllLands() async {
        let listed = await beginShutdown()
        let late = creationLandsForShutdown()
        // Each land on its own: one hung destroy or creation holds no other land.
        await withTaskGroup(of: Void.self) { group in
            for keeper in listed.all.map(\.keeper) {
                group.addTask { await keeper.forceShutdown() }
            }
            for await land in late {
                group.addTask { await land.keeper.forceShutdown() }
            }
        }
    }
    
    /// Rejects creations from this segment on (`JoinError.landShuttingDown`), for the rest of
    /// this manager's life: the first step of a server shutdown (#351), before its sessions close.
    package func stopCreations() {
        isShuttingDown = true
    }

    /// A land instance a shutdown destroys: stored, or detached by ID (`detachLand`,
    /// `detachForStop`) and still alive.
    package struct ShutdownLand: Sendable {
        package let landID: LandID
        package let epoch: Epoch
        package let keeper: LandKeeper<State>
    }

    /// The lands a shutdown destroys first: those stored now, and the live detached ones.
    package struct ShutdownListing: Sendable {
        package let stored: [ShutdownLand]
        package let detached: [ShutdownLand]
        package var all: [ShutdownLand] { stored + detached }
    }

    /// Stops creations and lists the lands to destroy now: every stored land, and every
    /// detached instance (`detachLand`, `detachForStop`) still alive, which no session
    /// step reaches but which still has a destroy and a save to run. Creations in progress are
    /// not waited for here (`awaitCreationsForShutdown`), so one that ignores cancellation can't
    /// hold the stored lands' destruction.
    package func beginShutdown() async -> ShutdownListing {
        // Same segment as the listing: no creation starts after this point.
        isShuttingDown = true
        let stored = lands.values.map { ShutdownLand(landID: $0.landID, epoch: $0.epoch, keeper: $0.keeper) }
        var detachedLands: [ShutdownLand] = []
        for (landID, entries) in detached {
            for (epoch, entry) in entries {
                if let keeper = entry.keeper { detachedLands.append(ShutdownLand(landID: landID, epoch: epoch, keeper: keeper)) }
            }
        }
        shutdownListedEpochs.formUnion((stored + detachedLands).map(\.epoch))
        await holds.at(.shutdownListed)
        return ShutdownListing(stored: stored, detached: detachedLands)
    }

    /// The lands a shutdown's second batch destroys, each yielded as soon as it is known: the
    /// land of each creation in progress once that creation ends (each awaited on its own, so
    /// one that ignores cancellation holds no other), then any live instance not yet listed (a
    /// land created and removed meanwhile). The stream finishes when every creation has ended.
    /// Cancels the creations; call after `beginShutdown()`.
    package func creationLandsForShutdown() -> AsyncStream<ShutdownLand> {
        let (stream, continuation) = AsyncStream.makeStream(of: ShutdownLand.self)
        Task { await self.yieldCreationLands(to: continuation) }
        return stream
    }

    private func yieldCreationLands(to continuation: AsyncStream<ShutdownLand>.Continuation) async {
        while creations.count > 0 {
            // Same segment as the snapshot: a creation that published after the listing and
            // ended before this point has no flight left here, so its land goes out now, not
            // when some other creation ends.
            let flights = creations.cancelAll()
            yieldUnlistedLands(to: continuation)
            await withTaskGroup(of: Void.self) { group in
                for flight in flights {
                    group.addTask {
                        _ = try? await flight.value
                        await self.yieldUnlistedLands(to: continuation)
                    }
                }
            }
        }
        yieldUnlistedLands(to: continuation)
        continuation.finish()
    }

    /// Yields each live instance (stored or detached) not handed out yet, and marks it, in one
    /// segment: each instance goes out once.
    private func yieldUnlistedLands(to continuation: AsyncStream<ShutdownLand>.Continuation) {
        var live = lands.values.map { ShutdownLand(landID: $0.landID, epoch: $0.epoch, keeper: $0.keeper) }
        for (landID, entries) in detached {
            for (epoch, entry) in entries {
                if let keeper = entry.keeper { live.append(ShutdownLand(landID: landID, epoch: epoch, keeper: keeper)) }
            }
        }
        for land in live where shutdownListedEpochs.insert(land.epoch).inserted {
            continuation.yield(land)
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

/// An instance detached by ID, held weakly: a released keeper has nothing left to wait for.
private struct DetachedKeeper<State: StateNodeProtocol>: @unchecked Sendable {
    weak var keeper: LandKeeper<State>?
    /// The instance's adapter, for its sessions' leaves and ticket ends (#390). Weak too:
    /// the entry never keeps a released instance alive.
    weak var adapter: TransportAdapter<State>?
    /// Detached by a stop (#102): a creation for the ID waits for its drop, not its drain.
    let stopping: Bool

    init(_ keeper: LandKeeper<State>, adapter: TransportAdapter<State>, stopping: Bool) {
        self.keeper = keeper
        self.adapter = adapter
        self.stopping = stopping
    }
}

/// Waits for `keeper`'s destruction for at most `timeout`. Returns false on timeout or when the
/// calling task is cancelled; the destruction itself is never cancelled. After a timeout the
/// inner wait task (and its keeper reference) stays until the destruction ends.
private func waitUntilDrained<State: StateNodeProtocol>(
    _ keeper: LandKeeper<State>,
    timeout: Duration
) async -> Bool {
    await boundedDrainWait(timeout: timeout) { await keeper.waitUntilDrained() }
}

/// Runs `wait` for at most `timeout`. Returns false on timeout or when the calling task is
/// cancelled; `wait` itself is never cancelled, and after a timeout its task stays until it
/// returns.
private func boundedDrainWait(
    timeout: Duration,
    _ wait: @escaping @Sendable () async -> Void
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
                await wait()
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
