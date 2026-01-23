import Foundation
import Logging

// MARK: - Helper for Replay Mode

// Note: AnyCodableResolverOutput is now defined in LandContext.swift for access by dynamic member lookup

/// The runtime executor for a Land instance.
///
/// `LandKeeper` is an actor that manages the authoritative state and executes the handlers
/// defined in a `LandDefinition`. It handles:
/// - Player join/leave lifecycle
/// - Action and event processing
/// - Periodic ticks
/// - Automatic shutdown when empty
/// - State synchronization using snapshot model
///
/// All state mutations are serialized through the actor, ensuring thread-safety.
/// Sync operations use snapshot model - they take a snapshot at the start and work with it,
/// allowing mutations to proceed concurrently without blocking.
///
/// **Sync Model**: Snapshot-based, non-blocking
/// - Sync takes a snapshot of state at the start
/// - Mutations can proceed concurrently (not blocked by sync)
/// - Each sync gets a consistent snapshot (actor serialization ensures this)
/// - Sync deduplication prevents redundant concurrent sync operations
///
///     /// TODO: Performance considerations:
///     /// - When Resolver mechanism is implemented and Action Handlers become synchronous,
///     ///   we may be able to directly modify state without copying
///     /// - Consider sync queue or debouncing for high-frequency sync scenarios
public enum LandMode: Sendable {
    case live
    case reevaluation
}

public actor LandKeeper<State: StateNodeProtocol>: LandKeeperProtocol {
    /// Unified pending item for actions and client events
    public enum PendingItem: Sendable {
        case action(PendingActionItem)
        case clientEvent(PendingClientEventItem)
        case lifecycle(PendingLifecycleItem)
    }

    public enum LifecycleKind: String, Codable, Sendable {
        case initialize
        case join
        case leave
    }

    public struct PendingLifecycleItem: Sendable {
        public let sequence: Int64
        public let kind: LifecycleKind
        public let playerID: PlayerID?
        public let clientID: ClientID?
        public let sessionID: SessionID?
        public let deviceID: String?
        public let isGuest: Bool?
        public let metadata: [String: String]
        public let resolverOutputs: [String: any ResolverOutput]
        public let resolvedAtTick: Int64

        public init(
            sequence: Int64,
            kind: LifecycleKind,
            playerID: PlayerID?,
            clientID: ClientID?,
            sessionID: SessionID?,
            deviceID: String?,
            isGuest: Bool?,
            metadata: [String: String],
            resolverOutputs: [String: any ResolverOutput],
            resolvedAtTick: Int64
        ) {
            self.sequence = sequence
            self.kind = kind
            self.playerID = playerID
            self.clientID = clientID
            self.sessionID = sessionID
            self.deviceID = deviceID
            self.isGuest = isGuest
            self.metadata = metadata
            self.resolverOutputs = resolverOutputs
            self.resolvedAtTick = resolvedAtTick
        }
    }

    public struct PendingActionItem: Sendable {
        public let sequence: Int64
        public let action: AnyCodable
        public let actionType: any ActionPayload.Type
        public let playerID: PlayerID
        public let clientID: ClientID
        public let sessionID: SessionID
        public let resolverOutputs: [String: any ResolverOutput]
        public let resolvedAtTick: Int64

        public init(
            sequence: Int64,
            action: AnyCodable,
            actionType: any ActionPayload.Type,
            playerID: PlayerID,
            clientID: ClientID,
            sessionID: SessionID,
            resolverOutputs: [String: any ResolverOutput],
            resolvedAtTick: Int64
        ) {
            self.sequence = sequence
            self.action = action
            self.actionType = actionType
            self.playerID = playerID
            self.clientID = clientID
            self.sessionID = sessionID
            self.resolverOutputs = resolverOutputs
            self.resolvedAtTick = resolvedAtTick
        }
    }

    public struct PendingClientEventItem: Sendable {
        public let sequence: Int64
        public let event: AnyClientEvent
        public let playerID: PlayerID
        public let clientID: ClientID
        public let sessionID: SessionID
        public let resolvedAtTick: Int64

        public init(
            sequence: Int64,
            event: AnyClientEvent,
            playerID: PlayerID,
            clientID: ClientID,
            sessionID: SessionID,
            resolvedAtTick: Int64
        ) {
            self.sequence = sequence
            self.event = event
            self.playerID = playerID
            self.clientID = clientID
            self.sessionID = sessionID
            self.resolvedAtTick = resolvedAtTick
        }
    }

    // Legacy PendingAction kept for backward compatibility during migration
    public struct PendingAction<ID: Hashable & Sendable>: Sendable {
        public let id: ID
        public let action: AnyCodable
        public let actionType: any ActionPayload.Type
        public let playerID: PlayerID
        public let clientID: ClientID
        public let sessionID: SessionID
        public let resolverOutputs: [String: any ResolverOutput]
        public let resolvedAtTick: Int64

        public init(
            id: ID,
            action: AnyCodable,
            actionType: any ActionPayload.Type,
            playerID: PlayerID,
            clientID: ClientID,
            sessionID: SessionID,
            resolverOutputs: [String: any ResolverOutput],
            resolvedAtTick: Int64
        ) {
            self.id = id
            self.action = action
            self.actionType = actionType
            self.playerID = playerID
            self.clientID = clientID
            self.sessionID = sessionID
            self.resolverOutputs = resolverOutputs
            self.resolvedAtTick = resolvedAtTick
        }
    }

    public let definition: LandDefinition<State>

    private var state: State
    private var players: [PlayerID: InternalPlayerSession] = [:]
    private var services: LandServices

    private var transport: LandKeeperTransport?
    private let logger: Logger
    private let autoStartLoops: Bool
    private let enableLiveStateHashRecording: Bool

    private var pendingItems: [PendingItem] = []
    private var mode: LandMode

    private struct EmittedEvent: Sendable {
        let sequence: Int64
        let tickId: Int64
        let event: AnyServerEvent
        let target: EventTarget
    }

    private struct SyncRequests: Sendable {
        var syncNow: Bool = false
        var syncBroadcastOnly: Bool = false
    }

    private final class OutputCollector: @unchecked Sendable {
        var nextSequence: Int64 = 0
        var emittedEvents: [EmittedEvent] = []
        var syncRequestsByTick: [Int64: SyncRequests] = [:]

        func takeNextSequence() -> Int64 {
            let s = nextSequence
            nextSequence += 1
            return s
        }

        func enqueueEmittedEvent(_ anyEvent: AnyServerEvent, to target: EventTarget, tickId: Int64) {
            let seq = takeNextSequence()
            emittedEvents.append(EmittedEvent(sequence: seq, tickId: tickId, event: anyEvent, target: target))
        }

        func requestSyncNow(tickId: Int64) {
            var req = syncRequestsByTick[tickId] ?? SyncRequests()
            req.syncNow = true
            syncRequestsByTick[tickId] = req
        }

        func requestSyncBroadcastOnly(tickId: Int64) {
            var req = syncRequestsByTick[tickId] ?? SyncRequests()
            req.syncBroadcastOnly = true
            syncRequestsByTick[tickId] = req
        }
    }

    private let outputCollector = OutputCollector()

    /// Recorder for deterministic re-evaluation (only in .live mode).
    private var reevaluationRecorder: ReevaluationRecorder?

    /// Source for reading recorded inputs during re-evaluation (only in .reevaluation mode).
    private var reevaluationSource: (any ReevaluationSource)?

    /// Optional sink for emitting recorded outputs during re-evaluation.
    private var reevaluationSink: (any ReevaluationSink)?

    /// Actual land instance ID (e.g., "counter:550e8400-...")
    /// This is different from definition.id which is just the land type (e.g., "counter")
    private var actualLandID: String?

    /// Set the transport interface (called after TransportAdapter is created)
    public func setTransport(_ transport: LandKeeperTransport?) {
        self.transport = transport
    }

    /// Set the actual land instance ID (called after LandKeeper is created)
    /// This allows LandContext to use the actual instance ID instead of just the land type
    /// Also updates the RNG service seed if it was created with a default seed
    public func setLandID(_ landID: String) {
        actualLandID = landID

        // Update RNG service seed if it was created with definition.id seed
        // This ensures deterministic behavior based on actual land instance ID
        if let rngService = services.get(DeterministicRngService.self),
           rngService.seed == DeterministicSeed.fromLandID(definition.id)
        {
            // Replace with new RNG service using actual landID seed
            let newSeed = DeterministicSeed.fromLandID(landID)
            let newRngService = DeterministicRngService(seed: newSeed)
            var updatedServices = services
            updatedServices.register(newRngService, as: DeterministicRngService.self)
            services = updatedServices
        }
    }

    /// Get the RNG seed for recording purposes.
    /// Returns the seed from the DeterministicRngService if it exists, nil otherwise.
    public func getRngSeed() -> UInt64? {
        return services.get(DeterministicRngService.self)?.seed
    }

    private var tickTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var destroyTask: Task<Void, Never>?
    private var initializationTask: Task<Void, Never>?
    private var didInitialize = false

    /// Next tick ID (0-based, increments with each tick) for deterministic replay.
    /// This represents the ID that will be assigned to the next tick execution.
    /// Using Int64 for long-running servers and replay compatibility.
    private var nextTickId: Int64 = 0

    /// Last committed tick ID (the most recent tick that has completed execution).
    /// This represents the world state's current committed tick.
    /// Action/Event handlers should use this to bind to the committed world state.
    /// Initialized to -1 to indicate no ticks have been committed yet.
    private var lastCommittedTickId: Int64 = -1

    private func flushOutputs(forTick tickId: Int64) async {
        let toFlush = outputCollector.emittedEvents
            .filter { $0.tickId == tickId }
            .sorted { $0.sequence < $1.sequence }
        if !toFlush.isEmpty {
            // Remove flushed events first to keep deterministic behavior even if downstream awaits.
            outputCollector.emittedEvents.removeAll { $0.tickId == tickId }
        }

        switch mode {
        case .live:
            for item in toFlush {
                await transport?.sendEventToTransport(item.event, to: item.target)
            }
        case .reevaluation:
            if let sink = reevaluationSink, !toFlush.isEmpty {
                let records = toFlush.map { item in
                    ReevaluationRecordedServerEvent(
                        kind: "serverEvent",
                        sequence: item.sequence,
                        tickId: item.tickId,
                        typeIdentifier: item.event.type,
                        payload: item.event.payload,
                        target: ReevaluationEventTargetRecord.from(item.target)
                    )
                }
                await sink.onEmittedServerEvents(tickId: tickId, events: records)
            }
        }

        if let req = outputCollector.syncRequestsByTick.removeValue(forKey: tickId) {
            if mode == .live {
                if req.syncNow {
                    await transport?.syncNowFromTransport()
                } else if req.syncBroadcastOnly {
                    await transport?.syncBroadcastOnlyFromTransport()
                }
            }
        }
    }

    /// Flag to prevent duplicate sync operations (for deduplication only).
    ///
    /// **Note**: This flag is used for deduplication, NOT for blocking mutations.
    /// Sync operations use snapshot model - they take a snapshot of state at the start,
    /// which naturally provides consistency without blocking mutations.
    ///
    /// When sync is in progress, concurrent sync requests are skipped to avoid redundant work.
    /// Mutations (actions/events) are NOT blocked and can proceed concurrently with sync.
    ///
    /// TODO: Future optimizations to consider:
    /// - Sync queue: Queue sync requests and batch them to reduce overhead
    /// - Debouncing: Debounce rapid sync requests to reduce frequency
    /// - Metrics: Track sync frequency and performance
    private var isSyncing = false

    // Use public system IDs from LandContext
    private let systemPlayerID = LandContext.systemPlayerID
    private let systemClientID = LandContext.systemClientID
    private let systemSessionID = LandContext.systemSessionID

    /// Initializes a new LandKeeper with the given definition and initial state.
    ///
    /// - Parameters:
    ///   - definition: The Land definition containing all handlers and configuration.
    ///   - initialState: The initial state of the Land.
    ///   - mode: The execution mode (live or re-evaluation). Defaults to .live.
    ///   - reevaluationSource: Optional re-evaluation source. Required when mode is .reevaluation.
    ///   - transport: Optional transport interface for sending events and syncing state.
    ///                If not provided, operations will be no-ops (useful for testing).
    ///   - logger: Optional logger instance. If not provided, a default logger will be created.
    public init(
        definition: LandDefinition<State>,
        initialState: State,
        mode: LandMode = .live,
        reevaluationSource: (any ReevaluationSource)? = nil,
        reevaluationSink: (any ReevaluationSink)? = nil,
        services: LandServices = LandServices(),
        enableLiveStateHashRecording: Bool = false,
        autoStartLoops: Bool = true,
        transport: LandKeeperTransport? = nil,
        logger: Logger? = nil
    ) {
        self.definition = definition
        state = initialState
        self.mode = mode
        self.reevaluationSink = reevaluationSink

        // Ensure DeterministicRngService is always registered for deterministic behavior
        // If not provided, create one based on definition.id (will be updated with actualLandID later)
        var resolvedServices = services
        if resolvedServices.get(DeterministicRngService.self) == nil {
            let seed = DeterministicSeed.fromLandID(definition.id)
            let rngService = DeterministicRngService(seed: seed)
            resolvedServices.register(rngService, as: DeterministicRngService.self)
        }
        self.services = resolvedServices

        self.transport = transport
        self.autoStartLoops = autoStartLoops
        self.enableLiveStateHashRecording = (mode == .live) ? enableLiveStateHashRecording : false
        let resolvedLogger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.runtime",
            scope: "LandKeeper"
        )
        self.logger = resolvedLogger

        // Initialize recorder if in live mode
        if mode == .live {
            let recorder = ReevaluationRecorder(flushInterval: 60)
            reevaluationRecorder = recorder

            // Register recorder service
            resolvedServices.register(
                ReevaluationRecorderService(recorder: recorder),
                as: ReevaluationRecorderService.self
            )
            self.services = resolvedServices
        }

        // Initialize source if in re-evaluation mode
        if mode == .reevaluation {
            self.reevaluationSource = reevaluationSource
        }

        // Execute OnInitialize handler and then start tick/sync loops.
        // Initialization is performed lazily (first entry point call) to avoid escaping self in init.

        // Kick off initialization eagerly to preserve existing semantics:
        // - OnInitialize runs when Land is created
        // - Tick/sync loops start automatically when configured
        Task { [weak self] in
            guard let self else { return }
            await self.ensureInitialized()
        }
    }

    private func ensureInitialized() async {
        if didInitialize { return }
        if let task = initializationTask {
            await task.value
            return
        }

        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performInitialization()
        }
        initializationTask = task
        await task.value
        initializationTask = nil
        didInitialize = true
    }

    private func performInitialization() async {
        // Execute OnInitialize immediately in live mode (preserve existing semantics).
        // Record it as a lifecycle event under tick 0 so replay can apply it deterministically
        // before the first tick handler runs.
        if mode == .live, let handler = definition.lifetimeHandlers.onInitialize {
            let sequence = outputCollector.takeNextSequence()

            var ctx = makeContext(
                playerID: systemPlayerID,
                clientID: systemClientID,
                sessionID: systemSessionID,
                tickId: lastCommittedTickId
            )

            // Execute resolvers in parallel if any are declared
            if !definition.lifetimeHandlers.onInitializeResolverExecutors.isEmpty {
                let resolverContext = ResolverContext(
                    landContext: ctx,
                    actionPayload: nil,
                    eventPayload: nil,
                    currentState: state
                )
                do {
                    ctx = try await ResolverExecutor.executeResolvers(
                        executors: definition.lifetimeHandlers.onInitializeResolverExecutors,
                        resolverContext: resolverContext,
                        landContext: ctx
                    )
                } catch {
                    logger.error("❌ OnInitialize resolvers failed", metadata: [
                        "error": .string(String(describing: error)),
                    ])
                }
            }

            do {
                try withMutableStateSync { state in
                    try handler(&state, ctx)
                }
            } catch {
                logger.error("❌ OnInitialize handler failed", metadata: [
                    "error": .string(String(describing: error)),
                ])
            }

            if let recorder = reevaluationRecorder {
                let resolverOutputsDict = ctx.getAllResolverOutputs().mapValues { output in
                    ReevaluationRecordedResolverOutput(
                        typeIdentifier: String(describing: type(of: output)),
                        value: AnyCodable(output)
                    )
                }
                let recorded = ReevaluationRecordedLifecycleEvent(
                    kind: LifecycleKind.initialize.rawValue,
                    sequence: sequence,
                    tickId: 0,
                    playerID: nil,
                    clientID: nil,
                    sessionID: nil,
                    deviceID: nil,
                    isGuest: nil,
                    metadata: [:],
                    resolverOutputs: resolverOutputsDict,
                    resolvedAtTick: lastCommittedTickId
                )
                await recorder.record(
                    tickId: 0,
                    actions: [],
                    clientEvents: [],
                    lifecycleEvents: [recorded]
                )
            }
        }

        // Then, start tick and sync loops if configured (only after OnInitialize completes)
        guard autoStartLoops else { return }
        let tickInterval = definition.lifetimeHandlers.tickInterval
        let syncInterval = definition.lifetimeHandlers.syncInterval

        // Start tick loop if configured
        if let interval = tickInterval,
           definition.lifetimeHandlers.tickHandler != nil
        {
            await configureTickLoop(interval: interval)
        }

        // Start sync loop: use configured interval, or fallback to tick interval if not configured
        let effectiveSyncInterval: Duration?
        if let sync = syncInterval {
            effectiveSyncInterval = sync
        } else if let tick = tickInterval {
            // Auto-configure sync to match tick interval if sync is not explicitly set
            effectiveSyncInterval = tick
            logger.warning(
                "⚠️ Sync interval not configured for land '\(definition.id)'. Auto-configuring sync to match tick interval (\(tick)). Consider explicitly setting StateSync(every:) in Lifetime block for better control.",
                metadata: [
                    "landID": .string(definition.id),
                    "tickInterval": .string("\(tick)"),
                    "autoSyncInterval": .string("\(tick)"),
                ]
            )
        } else {
            effectiveSyncInterval = nil
        }

        if let interval = effectiveSyncInterval {
            await configureSyncLoop(interval: interval)
        }
    }

    /// Execute OnInitialize handler with resolvers if needed
    private func executeOnInitialize(
        handler: @Sendable (inout State, LandContext) throws -> Void
    ) async {
        let ctx = makeContext(
            playerID: systemPlayerID,
            clientID: systemClientID,
            sessionID: systemSessionID
        )

        do {
            var updatedCtx = ctx

            // Execute resolvers in parallel if any are declared
            if !definition.lifetimeHandlers.onInitializeResolverExecutors.isEmpty {
                let resolverContext = ResolverContext(
                    landContext: ctx,
                    actionPayload: nil,
                    eventPayload: nil,
                    currentState: state
                )
                updatedCtx = try await ResolverExecutor.executeResolvers(
                    executors: definition.lifetimeHandlers.onInitializeResolverExecutors,
                    resolverContext: resolverContext,
                    landContext: ctx
                )
            }

            // Execute handler synchronously (resolvers already executed above)
            try withMutableStateSync { state in
                try handler(&state, updatedCtx)
            }
        } catch {
            logger.error("❌ OnInitialize handler failed", metadata: [
                "error": .string(String(describing: error)),
            ])
        }
    }

    /// Returns the current state snapshot.
    ///
    /// This is a read-only view of the state. Mutations should be done through action/event handlers.
    ///
    /// Note: This method does not check sync lock. For sync operations, use `beginSync()` instead.
    public func currentState() -> State {
        state
    }

    /// Begin a sync operation, taking a snapshot of current state.
    ///
    /// **Simplified Model**: Sync uses snapshot model - it takes a snapshot at the start
    /// and works with that snapshot. Mutations are NOT blocked during sync.
    ///
    /// - Returns: The current state snapshot if sync can proceed, `nil` if another sync is already in progress (deduplication).
    /// - Important: Always call `endSync()` after sync completes, even if an error occurs.
    ///
    /// **Why snapshot model works**:
    /// - Each sync gets a consistent snapshot (actor serialization ensures this)
    /// - Mutations can proceed concurrently (they'll be included in next sync)
    /// - No blocking = better performance and simpler code
    ///
    /// Example:
    /// ```swift
    /// guard let state = await keeper.beginSync() else {
    ///     // Another sync in progress, skip this one (deduplication)
    ///     return
    /// }
    /// defer { await keeper.endSync() }
    /// // ... perform sync operations with state snapshot ...
    /// ```
    public func beginSync() -> State? {
        guard !isSyncing else {
            return nil // Deduplication: skip concurrent sync requests
        }
        isSyncing = true
        return state // Direct snapshot - no blocking
    }

    /// End a sync operation, releasing the sync flag and optionally clearing dirty flags.
    ///
    /// This must be called after `beginSync()` to allow new sync requests.
    /// Optionally clears all dirty flags after sync completes to prevent accumulation
    /// and maintain dirty tracking optimization effectiveness.
    ///
    /// **Performance Note**: `clearDirty()` is optimized to only perform recursive clearing
    /// for nested StateNodes when the wrapper itself is dirty, minimizing runtime type checks
    /// and value copying overhead. For primitive and collection types, clearing is O(1).
    ///
    /// - Parameter clearDirtyFlags: If `true`, clears dirty flags after sync. Set to `false`
    ///   to skip clearing and avoid value copying overhead when dirty tracking is disabled.
    public func endSync(clearDirtyFlags: Bool = true) {
        isSyncing = false
        // Clear dirty flags after sync completes to prevent accumulation
        // This ensures dirty tracking optimization remains effective over time
        // PERFORMANCE: clearDirty() is optimized to avoid unnecessary work for unchanged fields
        // When dirty tracking is disabled, set clearDirtyFlags to false to avoid overhead
        if clearDirtyFlags {
            state.clearDirty()
        }
    }

    /// Returns the current number of players in the land.
    ///
    /// This counts unique players (not connections), as a player can have multiple connections.
    public func playerCount() -> Int {
        players.count
    }

    /// Get the ReevaluationRecorder instance (for testing/debugging).
    /// Returns nil if not in live mode or recorder is not available.
    public func getReevaluationRecorder() -> ReevaluationRecorder? {
        reevaluationRecorder
    }

    deinit {
        tickTask?.cancel()
        syncTask?.cancel()
        destroyTask?.cancel()
    }

    // MARK: - Player Lifecycle

    /// Handles a player joining the Land (legacy method for backward compatibility).
    ///
    /// This method creates a PlayerSession internally and calls the new join method.
    /// For new code, consider using the overload that accepts PlayerSession.
    ///
    /// - Parameters:
    ///   - playerID: The player's unique identifier.
    ///   - clientID: The client instance identifier.
    ///   - sessionID: The session/connection identifier.
    ///   - services: Services to inject into the LandContext.
    public func join(
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        services: LandServices = LandServices()
    ) async throws {
        await ensureInitialized()
        // Check for duplicate playerID login (Kick Old strategy)
        if let existingSession = players[playerID], let oldClientID = existingSession.clientID {
            logger.info("Duplicate playerID login detected: \(playerID.rawValue), kicking old client: \(oldClientID.rawValue)")
            // Kick old connection by calling leave
            // This will call OnLeave handler and clean up state
            try await leave(playerID: playerID, clientID: oldClientID)
        }

        var session = players[playerID] ?? InternalPlayerSession(services: services)
        let isFirst = session.clientID == nil

        session.clientID = clientID
        session.lastSessionID = sessionID
        session.services = services
        players[playerID] = session

        destroyTask?.cancel()
        destroyTask = nil

        guard isFirst, definition.lifetimeHandlers.onJoin != nil else { return }

        // Allocate sequence number (shared across Action + ClientEvent + ServerEvent + Lifecycle)
        let sequence = outputCollector.takeNextSequence()

        // Snapshot tick at request time; update after resolver completion for async determinism.
        var resolvedAtTick = lastCommittedTickId
        var resolverOutputs: [String: any ResolverOutput] = [:]

        // Execute resolvers in parallel if any are declared
        if !definition.lifetimeHandlers.onJoinResolverExecutors.isEmpty {
            var ctx = makeContext(
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                servicesOverride: services
            )
            let resolverContext = ResolverContext(
                landContext: ctx,
                actionPayload: nil,
                eventPayload: nil,
                currentState: state
            )
            ctx = try await ResolverExecutor.executeResolvers(
                executors: definition.lifetimeHandlers.onJoinResolverExecutors,
                resolverContext: resolverContext,
                landContext: ctx
            )
            resolverOutputs = ctx.getAllResolverOutputs()
            // Bind to the tick that was current when resolvers completed
            resolvedAtTick = lastCommittedTickId
        }

        let pendingItem = PendingItem.lifecycle(
            PendingLifecycleItem(
                sequence: sequence,
                kind: .join,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                deviceID: session.deviceID,
                isGuest: session.isGuest,
                metadata: session.metadata,
                resolverOutputs: resolverOutputs,
                resolvedAtTick: resolvedAtTick
            )
        )
        pendingItems.append(pendingItem)

        // If there's no tick handler, process lifecycle immediately (backward-compatible mode)
        if definition.lifetimeHandlers.tickHandler == nil {
            _ = try await processPendingActions()
        }
    }

    /// Handles a player joining the Land with session-based validation.
    ///
    /// This method supports the CanJoin handler for pre-validation before adding
    /// the player to the authoritative state.
    ///
    /// - Parameters:
    ///   - session: The player session information.
    ///   - clientID: The client instance identifier.
    ///   - sessionID: The session/connection identifier.
    ///   - services: Services to inject into the LandContext.
    /// - Returns: JoinDecision indicating if the join was allowed or denied.
    /// - Throws: Errors from the CanJoin handler if join validation fails.
    public func join(
        session: PlayerSession,
        clientID: ClientID,
        sessionID: SessionID,
        services: LandServices
    ) async throws -> JoinDecision {
        await ensureInitialized()
        // Call CanJoin handler if defined
        var decision: JoinDecision = .allow(playerID: PlayerID(session.playerID))

        if let canJoinHandler = definition.lifetimeHandlers.canJoin {
            var ctx = makeContext(
                playerID: PlayerID("_pending"), // Temporary ID for validation
                clientID: clientID,
                sessionID: sessionID,
                servicesOverride: services
            )

            // Execute resolvers in parallel if any are declared
            if !definition.lifetimeHandlers.canJoinResolverExecutors.isEmpty {
                let resolverContext = ResolverContext(
                    landContext: ctx,
                    actionPayload: nil,
                    eventPayload: nil,
                    currentState: state
                )
                ctx = try await ResolverExecutor.executeResolvers(
                    executors: definition.lifetimeHandlers.canJoinResolverExecutors,
                    resolverContext: resolverContext,
                    landContext: ctx
                )
            }

            // Execute handler synchronously (resolvers already executed above)
            decision = try canJoinHandler(state, session, ctx)
        }

        // If denied, return early
        guard case let .allow(playerID) = decision else {
            return decision
        }

        // Check maxPlayers limit after CanJoin handler (using the playerID returned by CanJoin)
        // Skip check if player is already in the room (reconnection scenario)
        let isReconnection = players[playerID] != nil

        if let maxPlayers = definition.config.maxPlayers, !isReconnection {
            let currentPlayerCount = players.count
            guard currentPlayerCount < maxPlayers else {
                logger.info("Join rejected: room is full", metadata: [
                    "currentPlayers": .stringConvertible(currentPlayerCount),
                    "maxPlayers": .stringConvertible(maxPlayers),
                ])
                throw JoinError.roomIsFull
            }
        }

        // Check for duplicate playerID login (Kick Old strategy)
        if let existingSession = players[playerID], let oldClientID = existingSession.clientID {
            logger.info("Duplicate playerID login detected: \(playerID.rawValue), kicking old client: \(oldClientID.rawValue)")
            // Kick old connection by calling leave
            // This will call OnLeave handler and clean up state
            try await leave(playerID: playerID, clientID: oldClientID)
        }

        // Proceed with join
        var playerSession = players[playerID] ?? InternalPlayerSession(
            services: services,
            deviceID: session.deviceID,
            isGuest: session.isGuest,
            metadata: session.metadata
        )
        let isFirst = playerSession.clientID == nil

        playerSession.clientID = clientID
        playerSession.lastSessionID = sessionID
        playerSession.services = services
        // Update deviceID, isGuest, and metadata if provided (for reconnection scenarios)
        if let deviceID = session.deviceID {
            playerSession.deviceID = deviceID
        }
        playerSession.isGuest = session.isGuest
        if !session.metadata.isEmpty {
            playerSession.metadata = session.metadata
        }
        players[playerID] = playerSession

        destroyTask?.cancel()
        destroyTask = nil

        guard isFirst, definition.lifetimeHandlers.onJoin != nil else { return decision }

        // Allocate sequence number (shared across Action + ClientEvent + ServerEvent + Lifecycle)
        let sequence = outputCollector.takeNextSequence()

        // Snapshot tick at request time; update after resolver completion for async determinism.
        var resolvedAtTick = lastCommittedTickId
        var resolverOutputs: [String: any ResolverOutput] = [:]

        // Execute resolvers in parallel if any are declared
        if !definition.lifetimeHandlers.onJoinResolverExecutors.isEmpty {
            var ctx = makeContext(
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                servicesOverride: services,
                deviceID: session.deviceID,
                isGuest: session.isGuest,
                metadata: session.metadata
            )
            let resolverContext = ResolverContext(
                landContext: ctx,
                actionPayload: nil,
                eventPayload: nil,
                currentState: state
            )
            ctx = try await ResolverExecutor.executeResolvers(
                executors: definition.lifetimeHandlers.onJoinResolverExecutors,
                resolverContext: resolverContext,
                landContext: ctx
            )
            resolverOutputs = ctx.getAllResolverOutputs()
            resolvedAtTick = lastCommittedTickId
        }

        let pendingItem = PendingItem.lifecycle(
            PendingLifecycleItem(
                sequence: sequence,
                kind: .join,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                deviceID: session.deviceID,
                isGuest: session.isGuest,
                metadata: session.metadata,
                resolverOutputs: resolverOutputs,
                resolvedAtTick: resolvedAtTick
            )
        )
        pendingItems.append(pendingItem)

        // If there's no tick handler, process lifecycle immediately (backward-compatible mode)
        if definition.lifetimeHandlers.tickHandler == nil {
            _ = try await processPendingActions()
        }

        return decision
    }

    /// Handles a player/client leaving the Land.
    ///
    /// If this is the player's last connection, the `OnLeave` handler is called.
    /// If the Land becomes empty, automatic shutdown may be scheduled.
    ///
    /// - Parameters:
    ///   - playerID: The player's unique identifier.
    ///   - clientID: The client instance identifier.
    public func leave(playerID: PlayerID, clientID: ClientID) async throws {
        await ensureInitialized()
        guard let session = players[playerID] else {
            if logger.logLevel <= .debug {
                logger.debug("Leave called for player \(playerID.rawValue) but not found in players dictionary")
            }
            return
        }

        // Verify this is the correct client (should always match since we only allow one client per playerID)
        guard session.clientID == clientID else {
            if logger.logLevel <= .debug {
                logger.debug("Leave called for player \(playerID.rawValue) with mismatched clientID: expected=\(session.clientID?.rawValue ?? "nil"), received=\(clientID.rawValue)")
            }
            return
        }

        if logger.logLevel <= .debug {
            logger.debug("Player \(playerID.rawValue) leave: clientID=\(clientID.rawValue)")
        }

        // Since we only allow one client per playerID, always call OnLeave handler
        let deviceID = session.deviceID
        let isGuest = session.isGuest
        let metadata = session.metadata
        players.removeValue(forKey: playerID)

        logger.info("Player \(playerID.rawValue) leaving, enqueuing OnLeave lifecycle item")

        guard definition.lifetimeHandlers.onLeave != nil else {
            scheduleDestroyIfNeeded()
            return
        }

        // Allocate sequence number (shared across Action + ClientEvent + ServerEvent + Lifecycle)
        let sequence = outputCollector.takeNextSequence()

        // Snapshot tick at request time; update after resolver completion for async determinism.
        var resolvedAtTick = lastCommittedTickId
        var resolverOutputs: [String: any ResolverOutput] = [:]

        // Execute resolvers in parallel if any are declared
        if !definition.lifetimeHandlers.onLeaveResolverExecutors.isEmpty {
            var ctx = makeContext(
                playerID: playerID,
                clientID: clientID,
                sessionID: session.lastSessionID ?? systemSessionID,
                servicesOverride: session.services,
                deviceID: deviceID,
                isGuest: isGuest,
                metadata: metadata
            )
            let resolverContext = ResolverContext(
                landContext: ctx,
                actionPayload: nil,
                eventPayload: nil,
                currentState: state
            )
            ctx = try await ResolverExecutor.executeResolvers(
                executors: definition.lifetimeHandlers.onLeaveResolverExecutors,
                resolverContext: resolverContext,
                landContext: ctx
            )
            resolverOutputs = ctx.getAllResolverOutputs()
            resolvedAtTick = lastCommittedTickId
        }

        let pendingItem = PendingItem.lifecycle(
            PendingLifecycleItem(
                sequence: sequence,
                kind: .leave,
                playerID: playerID,
                clientID: clientID,
                sessionID: session.lastSessionID ?? systemSessionID,
                deviceID: deviceID,
                isGuest: isGuest,
                metadata: metadata,
                resolverOutputs: resolverOutputs,
                resolvedAtTick: resolvedAtTick
            )
        )
        pendingItems.append(pendingItem)

        // If there's no tick handler, process lifecycle immediately (backward-compatible mode)
        if definition.lifetimeHandlers.tickHandler == nil {
            _ = try await processPendingActions()
        }

        scheduleDestroyIfNeeded()
    }

    // MARK: - Action & Event Handling

    /// Handles an action envelope by decoding and dispatching to the registered handler.
    ///
    /// This is used by transport adapters that receive type-erased `ActionEnvelope` payloads.
    /// In `.live` mode, actions are queued and executed in ticks. In `.reevaluation` mode, returns immediately.
    public func handleActionEnvelope(
        _ envelope: ActionEnvelope,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async throws -> AnyCodable {
        await ensureInitialized()
        // In re-evaluation mode, actions come from ReevaluationSource, not from transport.
        guard mode == .live else {
            // Return empty response in re-evaluation mode.
            return AnyCodable(())
        }

        let decoder = JSONDecoder()
        let typeIdentifier = envelope.typeIdentifier

        guard let handler = definition.actionHandlers.first(where: { handler in
            let actionType = handler.getActionType()
            let actionTypeName = String(describing: actionType)

            // Direct type name match (e.g., "AddGoldAction" == "AddGoldAction")
            if actionTypeName == typeIdentifier {
                return true
            }

            // Match last component (e.g., "Module.AddGoldAction" == "AddGoldAction")
            if actionTypeName.split(separator: ".").last == typeIdentifier.split(separator: ".").last {
                return true
            }

            // Match schema format (camelCase, without "Action" suffix)
            // e.g., "AddGoldAction" -> "AddGold" matches "AddGold"
            let schemaActionID = generateActionIDForMatching(from: actionType)
            if schemaActionID == typeIdentifier {
                return true
            }

            // Also support case-insensitive matching for backward compatibility
            if schemaActionID.lowercased() == typeIdentifier.lowercased() {
                return true
            }

            return false
        }) else {
            throw LandError.actionNotRegistered
        }

        let actionType = handler.getActionType()
        guard let actionPayloadType = actionType as? any ActionPayload.Type else {
            throw LandError.actionNotRegistered
        }

        // Decode action payload from AnyCodable
        let payloadData = try JSONEncoder().encode(envelope.payload)
        let decodedAction = try decoder.decode(actionPayloadType, from: payloadData)

        // Allocate sequence number (shared across Action + ClientEvent + ServerEvent)
        let sequence = outputCollector.takeNextSequence()

        // Bind action to lastCommittedTickId; if resolvers are async, update after they complete.
        var resolvedAtTick = lastCommittedTickId

        // Execute resolvers in parallel if any are declared
        var resolverOutputs: [String: any ResolverOutput] = [:]
        if !handler.resolverExecutors.isEmpty {
            var ctx = makeContext(
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                tickId: resolvedAtTick
            )

            // ActionPayload already conforms to Sendable, so we can use it directly
            let actionPayloadAsSendable = decodedAction as (any Sendable)
            let resolverContext = ResolverContext(
                landContext: ctx,
                actionPayload: actionPayloadAsSendable,
                eventPayload: nil,
                currentState: state
            )
            ctx = try await ResolverExecutor.executeResolvers(
                executors: handler.resolverExecutors,
                resolverContext: resolverContext,
                landContext: ctx
            )

            // Extract resolver outputs from context
            resolverOutputs = ctx.getAllResolverOutputs()

            // Bind to the tick that was current when resolvers completed (deterministic ordering)
            resolvedAtTick = lastCommittedTickId
        }

        // Create pending item and add to queue
        let pendingItem = PendingItem.action(
            PendingActionItem(
                sequence: sequence,
                action: envelope.payload,
                actionType: actionPayloadType,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                resolverOutputs: resolverOutputs,
                resolvedAtTick: resolvedAtTick
            )
        )
        pendingItems.append(pendingItem)

        // If there's no tick handler, process pending actions immediately and return response
        // This maintains backward compatibility for tests and simple use cases
        if definition.lifetimeHandlers.tickHandler == nil {
            do {
                if let response = try await processPendingActions() {
                    return response
                }
            } catch {
                logger.error("Error processing pending actions", metadata: [
                    "error": .string(String(describing: error)),
                ])
                throw error
            }
        }

        // Return immediate ACK (handler will execute in tick)
        // Return empty response - actual response will be available after tick execution
        return AnyCodable(())
    }

    /// Generate action ID for matching (same format as schema generation).
    ///
    /// Converts type name to camelCase action ID format (without "Action" suffix).
    /// Example: "AddGoldAction" -> "AddGold"
    private func generateActionIDForMatching(from actionType: Any.Type) -> String {
        let typeName = String(describing: actionType)

        // Remove module prefix if present (e.g., "Module.AddGoldAction" -> "AddGoldAction")
        let baseTypeName: String
        if let lastComponent = typeName.split(separator: ".").last {
            baseTypeName = String(lastComponent)
        } else {
            baseTypeName = typeName
        }

        // Remove "Action" suffix if present, keep camelCase format
        // Example: "AddGoldAction" -> "AddGold"
        var actionID = baseTypeName
        if actionID.hasSuffix("Action") {
            actionID = String(actionID.dropLast(6))
        }

        // Return camelCase format (e.g., "AddGold")
        return actionID
    }

    /// Handles a client event from a player.
    ///
    /// In `.live` mode, events are queued and executed in ticks. In `.reevaluation` mode, returns immediately.
    ///
    /// - Parameters:
    ///   - event: The client event (type-erased).
    ///   - playerID: The player sending the event.
    ///   - clientID: The client instance.
    ///   - sessionID: The session identifier.
    /// - Throws: Errors from event validation (e.g., event not registered)
    ///
    /// **Error Handling**:
    /// - If any event handler throws an error, the error is propagated to the caller
    /// - The caller (TransportAdapter) should send the error to the client
    public func handleClientEvent(
        _ event: AnyClientEvent,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async throws {
        await ensureInitialized()
        // In re-evaluation mode, events come from ReevaluationSource, not from transport.
        guard mode == .live else {
            return
        }

        // Check if event is registered in the client event registry
        guard let descriptor = definition.clientEventRegistry.findDescriptor(for: event.type) else {
            logger.error(
                "Client event type '\(event.type)' is not registered in ClientEvents { Register(...) }",
                metadata: [
                    "eventType": .string(event.type),
                    "landID": .string(definition.id),
                    "playerID": .string(playerID.rawValue),
                ]
            )
            throw LandError.eventNotRegistered
        }

        // Find handlers that can handle this event type
        let matchingHandlers = definition.eventHandlers.filter { handler in
            handler.canHandle(descriptor.type)
        }

        guard !matchingHandlers.isEmpty else {
            logger.error(
                "No handler found for client event type '\(event.type)'",
                metadata: [
                    "eventType": .string(event.type),
                    "landID": .string(definition.id),
                    "playerID": .string(playerID.rawValue),
                ]
            )
            throw LandError.eventNotRegistered
        }

        // Allocate sequence number (shared across Action + ClientEvent + ServerEvent)
        let sequence = outputCollector.takeNextSequence()

        // Bind event to lastCommittedTickId for replay logging
        let resolvedAtTick = lastCommittedTickId

        // Create pending item and add to queue
        let pendingItem = PendingItem.clientEvent(
            PendingClientEventItem(
                sequence: sequence,
                event: event,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                resolvedAtTick: resolvedAtTick
            )
        )
        pendingItems.append(pendingItem)

        // If there's no tick handler, process pending actions immediately
        // This maintains backward compatibility for tests and simple use cases
        // Note: This is async, but we can't await in a non-async context
        // So we use Task to handle it asynchronously
        // IMPORTANT: processPendingActions() will automatically advance tick counter
        // if needed to ensure valid tick IDs for recording
        if definition.lifetimeHandlers.tickHandler == nil {
            Task { [weak self] in
                guard let self = self else { return }
                do {
                    _ = try await self.processPendingActions(flushOutputsImmediately: true)
                } catch {
                    self.logger.error("Error processing pending actions", metadata: [
                        "error": .string(String(describing: error)),
                    ])
                }
            }
        }

        // Return immediately (handler will execute in tick or immediately if no tick handler)
    }

    // MARK: - Helpers

    private func makeContext(
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        servicesOverride: LandServices? = nil,
        deviceID: String? = nil,
        isGuest: Bool? = nil,
        metadata: [String: String] = [:],
        tickId: Int64? = nil,
        resolverOutputs: [String: any ResolverOutput] = [:]
    ) -> LandContext {
        let baseServices = servicesOverride ?? LandServices()
        let playerServices = players[playerID]?.services
        let resolvedServices = services.merging(baseServices).merging(playerServices ?? LandServices())
        let playerSession = players[playerID]
        // Use actual land instance ID if available, otherwise fall back to definition.id (land type)
        let landID = actualLandID ?? definition.id
        let eventRecordingTickId = tickId ?? lastCommittedTickId
        let collector = outputCollector
        return LandContext(
            landID: landID,
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            services: resolvedServices,
            logger: logger,
            deviceID: deviceID ?? playerSession?.deviceID,
            isGuest: isGuest ?? playerSession?.isGuest ?? false,
            metadata: metadata.isEmpty ? (playerSession?.metadata ?? [:]) : metadata,
            tickId: tickId,
            emitEventHandler: { anyEvent, target in
                collector.enqueueEmittedEvent(anyEvent, to: target, tickId: eventRecordingTickId)
            },
            requestSyncNowHandler: {
                collector.requestSyncNow(tickId: eventRecordingTickId)
            },
            requestSyncBroadcastOnlyHandler: {
                collector.requestSyncBroadcastOnly(tickId: eventRecordingTickId)
            },
            resolverOutputs: resolverOutputs
        )
    }

    /// Execute a synchronous closure with mutable state access.
    ///
    /// Since handlers are now synchronous, we can directly modify state
    /// without copying (actor isolation is maintained because we're in the actor).
    ///
    /// **Optimization**: This function is synchronous because the body closure is synchronous.
    /// No async/await overhead is needed - we directly modify the actor-isolated state.
    ///
    /// **Performance**: No state copying is required since the closure is synchronous and
    /// cannot suspend, maintaining actor isolation guarantees without copying overhead.
    private func withMutableStateSync<R>(
        _ body: (inout State) throws -> R
    ) rethrows -> R {
        // Directly execute synchronous body - no copying, no async overhead
        return try body(&state)
    }

    // MARK: - Tick & Lifetime

    /// Ensure tick ID is advanced for tickless lands (no tick handler)
    /// This prevents all records from ending up with tickId = -1
    private func ensureTickIdForTicklessLand() {
        // Advance tick counter to ensure records use a valid tick ID
        // Use max(lastCommittedTickId+1, 0) to ensure non-negative tick IDs
        if nextTickId <= lastCommittedTickId {
            nextTickId = max(lastCommittedTickId + 1, 0)
        }
    }

    private func configureTickLoop(interval: Duration) async {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            guard let self = self else { return }

            var nextTickTime = ContinuousClock.now + interval

            while !Task.isCancelled {
                let now = ContinuousClock.now

                // If we're already past the scheduled time, execute immediately
                // Otherwise, sleep until the scheduled time
                if now < nextTickTime {
                    try? await Task.sleep(until: nextTickTime, clock: .continuous)
                }

                await self.runTick(allowWhenNoTickTask: false)

                // Fixed-rate scheduling: calculate next time from the scheduled time, not from now
                // This maintains a consistent tick rate even if execution takes longer than interval
                // If execution time exceeds interval, we skip ahead to maintain the rate
                nextTickTime = nextTickTime + interval

                // If we're still behind schedule after skipping, continue skipping
                // This prevents the loop from getting stuck if execution time consistently exceeds interval
                while nextTickTime <= ContinuousClock.now {
                    nextTickTime = nextTickTime + interval
                }
            }
        }
    }

    /// Manually execute a single tick (for deterministic tests/tools).
    ///
    /// This bypasses the internal tick loop guard and allows stepping a land deterministically
    /// without relying on wall-clock time.
    public func stepTickOnce() async {
        await ensureInitialized()
        await runTick(allowWhenNoTickTask: true)
    }

    /// Process pending actions and client events that are ready to execute
    /// Returns the response from the last executed action (if any)
    /// - Parameter flushOutputsImmediately: If true, flush outputs after processing. If false, defer flushing (caller should flush after tick handler).
    private func processPendingActions(flushOutputsImmediately: Bool = true) async throws -> AnyCodable? {
        // The tick currently executing (best-effort).
        // In the normal tick loop, nextTickId has already been incremented for this tick.
        // For tickless lands, ensure we have a valid tick ID for recording
        var executingTickId = nextTickId - 1
        
        // If executingTickId is negative (e.g., nextTickId is 0 and hasn't been advanced),
        // advance nextTickId to ensure valid tick IDs for recording
        if executingTickId < 0 {
            nextTickId = max(lastCommittedTickId + 1, 0)
            executingTickId = nextTickId - 1
            // If still negative (lastCommittedTickId was -1), use 0
            if executingTickId < 0 {
                nextTickId = 1
                executingTickId = 0
            }
        }

        // Filter items that are ready to execute (resolvedAtTick < nextTickId)
        let readyItems = pendingItems.filter { item in
            let resolvedAtTick: Int64
            switch item {
            case let .action(actionItem):
                resolvedAtTick = actionItem.resolvedAtTick
            case let .clientEvent(eventItem):
                resolvedAtTick = eventItem.resolvedAtTick
            case let .lifecycle(lifecycleItem):
                resolvedAtTick = lifecycleItem.resolvedAtTick
            }
            return resolvedAtTick < nextTickId
        }

        // Sort by resolvedAtTick (primary) and sequence (secondary)
        let sortedItems = readyItems.sorted { item1, item2 in
            let (resolvedAtTick1, sequence1): (Int64, Int64)
            let (resolvedAtTick2, sequence2): (Int64, Int64)

            switch item1 {
            case let .action(actionItem):
                resolvedAtTick1 = actionItem.resolvedAtTick
                sequence1 = actionItem.sequence
            case let .clientEvent(eventItem):
                resolvedAtTick1 = eventItem.resolvedAtTick
                sequence1 = eventItem.sequence
            case let .lifecycle(lifecycleItem):
                resolvedAtTick1 = lifecycleItem.resolvedAtTick
                sequence1 = lifecycleItem.sequence
            }

            switch item2 {
            case let .action(actionItem):
                resolvedAtTick2 = actionItem.resolvedAtTick
                sequence2 = actionItem.sequence
            case let .clientEvent(eventItem):
                resolvedAtTick2 = eventItem.resolvedAtTick
                sequence2 = eventItem.sequence
            case let .lifecycle(lifecycleItem):
                resolvedAtTick2 = lifecycleItem.resolvedAtTick
                sequence2 = lifecycleItem.sequence
            }

            if resolvedAtTick1 != resolvedAtTick2 {
                return resolvedAtTick1 < resolvedAtTick2
            }
            return sequence1 < sequence2
        }

        // Execute each item and track the last action response
        var lastActionResponse: AnyCodable? = nil
        var recordedActions: [ReevaluationRecordedAction] = []
        var recordedClientEvents: [ReevaluationRecordedClientEvent] = []
        var recordedLifecycleEvents: [ReevaluationRecordedLifecycleEvent] = []
        var shouldSyncBroadcastOnly = false

        for item in sortedItems {
            switch item {
            case let .action(actionItem):
                // Find handler for this action type
                guard let handler = definition.actionHandlers.first(where: { handler in
                    handler.canHandle(actionItem.actionType)
                }) else {
                    logger.error("Handler not found for action type", metadata: [
                        "actionType": .string(String(describing: actionItem.actionType)),
                    ])
                    continue
                }

                // Decode action from AnyCodable
                let decoder = JSONDecoder()
                let payloadData = try JSONEncoder().encode(actionItem.action)
                let decodedAction = try decoder.decode(actionItem.actionType, from: payloadData)

                // Create context with resolver outputs
                let ctx = makeContext(
                    playerID: actionItem.playerID,
                    clientID: actionItem.clientID,
                    sessionID: actionItem.sessionID,
                    tickId: executingTickId,
                    resolverOutputs: actionItem.resolverOutputs
                )

                // Execute handler and capture response
                let response = try withMutableStateSync { state in
                    try handler.invokeErased(&state, action: decodedAction, ctx: ctx)
                }
                lastActionResponse = response

                // Record action for deterministic re-evaluation
                let resolverOutputsDict = actionItem.resolverOutputs.mapValues { output in
                    ReevaluationRecordedResolverOutput(
                        typeIdentifier: String(describing: type(of: output)),
                        value: AnyCodable(output)
                    )
                }
                let recordedAction = ReevaluationRecordedAction(
                    kind: "action",
                    sequence: actionItem.sequence,
                    typeIdentifier: String(describing: actionItem.actionType),
                    payload: actionItem.action,
                    playerID: actionItem.playerID.rawValue,
                    clientID: actionItem.clientID.rawValue,
                    sessionID: actionItem.sessionID.rawValue,
                    resolverOutputs: resolverOutputsDict,
                    resolvedAtTick: actionItem.resolvedAtTick
                )
                recordedActions.append(recordedAction)

            case let .clientEvent(eventItem):
                // Find handlers for this event type
                guard let descriptor = definition.clientEventRegistry.findDescriptor(for: eventItem.event.type) else {
                    logger.error("Event descriptor not found", metadata: [
                        "eventType": .string(eventItem.event.type),
                    ])
                    continue
                }

                let matchingHandlers = definition.eventHandlers.filter { handler in
                    handler.canHandle(descriptor.type)
                }

                guard !matchingHandlers.isEmpty else {
                    logger.error("No handler found for client event", metadata: [
                        "eventType": .string(eventItem.event.type),
                    ])
                    continue
                }

                // Create context (client events don't have resolver outputs)
                let ctx = makeContext(
                    playerID: eventItem.playerID,
                    clientID: eventItem.clientID,
                    sessionID: eventItem.sessionID,
                    tickId: executingTickId,
                    resolverOutputs: [:]
                )

                // Execute handlers
                try withMutableStateSync { state in
                    for handler in matchingHandlers {
                        try handler.invoke(&state, event: eventItem.event, ctx: ctx)
                    }
                }

                // Record client event for deterministic re-evaluation
                let recordedClientEvent = ReevaluationRecordedClientEvent(
                    kind: "clientEvent",
                    sequence: eventItem.sequence,
                    typeIdentifier: eventItem.event.type,
                    payload: eventItem.event.payload,
                    playerID: eventItem.playerID.rawValue,
                    clientID: eventItem.clientID.rawValue,
                    sessionID: eventItem.sessionID.rawValue,
                    resolvedAtTick: eventItem.resolvedAtTick
                )
                recordedClientEvents.append(recordedClientEvent)

            case let .lifecycle(lifecycleItem):
                switch lifecycleItem.kind {
                case .initialize:
                    guard let handler = definition.lifetimeHandlers.onInitialize else { break }
                    let ctx = makeContext(
                        playerID: systemPlayerID,
                        clientID: systemClientID,
                        sessionID: systemSessionID,
                        tickId: executingTickId,
                        resolverOutputs: lifecycleItem.resolverOutputs
                    )
                    // Execute handler synchronously (resolver outputs already injected)
                    try withMutableStateSync { state in
                        try handler(&state, ctx)
                    }
                case .join:
                    guard
                        let playerID = lifecycleItem.playerID,
                        let clientID = lifecycleItem.clientID,
                        let sessionID = lifecycleItem.sessionID,
                        let handler = definition.lifetimeHandlers.onJoin
                    else { break }
                    let ctx = makeContext(
                        playerID: playerID,
                        clientID: clientID,
                        sessionID: sessionID,
                        deviceID: lifecycleItem.deviceID,
                        isGuest: lifecycleItem.isGuest,
                        metadata: lifecycleItem.metadata,
                        tickId: executingTickId,
                        resolverOutputs: lifecycleItem.resolverOutputs
                    )
                    try withMutableStateSync { state in
                        try handler(&state, ctx)
                    }
                case .leave:
                    guard
                        let playerID = lifecycleItem.playerID,
                        let clientID = lifecycleItem.clientID,
                        let sessionID = lifecycleItem.sessionID,
                        let handler = definition.lifetimeHandlers.onLeave
                    else { break }
                    let ctx = makeContext(
                        playerID: playerID,
                        clientID: clientID,
                        sessionID: sessionID,
                        deviceID: lifecycleItem.deviceID,
                        isGuest: lifecycleItem.isGuest,
                        metadata: lifecycleItem.metadata,
                        tickId: executingTickId,
                        resolverOutputs: lifecycleItem.resolverOutputs
                    )
                    try withMutableStateSync { state in
                        try handler(&state, ctx)
                    }
                    // Defer sync until after pending item removal to avoid duplicate execution races.
                    shouldSyncBroadcastOnly = true
                }

                // Record lifecycle event for deterministic re-evaluation
                let resolverOutputsDict = lifecycleItem.resolverOutputs.mapValues { output in
                    ReevaluationRecordedResolverOutput(
                        typeIdentifier: String(describing: type(of: output)),
                        value: AnyCodable(output)
                    )
                }
                let recordedLifecycleEvent = ReevaluationRecordedLifecycleEvent(
                    kind: lifecycleItem.kind.rawValue,
                    sequence: lifecycleItem.sequence,
                    tickId: executingTickId,
                    playerID: lifecycleItem.playerID?.rawValue,
                    clientID: lifecycleItem.clientID?.rawValue,
                    sessionID: lifecycleItem.sessionID?.rawValue,
                    deviceID: lifecycleItem.deviceID,
                    isGuest: lifecycleItem.isGuest,
                    metadata: lifecycleItem.metadata,
                    resolverOutputs: resolverOutputsDict,
                    resolvedAtTick: lifecycleItem.resolvedAtTick
                )
                recordedLifecycleEvents.append(recordedLifecycleEvent)
            }
        }

        // Remove executed items from queue
        let executedSequences = Set(sortedItems.map { item -> Int64 in
            switch item {
            case let .action(actionItem):
                return actionItem.sequence
            case let .clientEvent(eventItem):
                return eventItem.sequence
            case let .lifecycle(lifecycleItem):
                return lifecycleItem.sequence
            }
        })

        pendingItems.removeAll { item in
            let sequence: Int64
            switch item {
            case let .action(actionItem):
                sequence = actionItem.sequence
            case let .clientEvent(eventItem):
                sequence = eventItem.sequence
            case let .lifecycle(lifecycleItem):
                sequence = lifecycleItem.sequence
            }
            return executedSequences.contains(sequence)
        }

        // Record inputs to ReevaluationRecorder
        if let recorder = reevaluationRecorder,
           !recordedActions.isEmpty || !recordedClientEvents.isEmpty || !recordedLifecycleEvents.isEmpty
        {
            // Use the tick ID that was used for processing (nextTickId - 1, since we incremented it before processing)
            let recordingTickId = nextTickId - 1
            await recorder.record(
                tickId: recordingTickId,
                actions: recordedActions,
                clientEvents: recordedClientEvents,
                lifecycleEvents: recordedLifecycleEvents
            )

            // Flush if needed
            try? await recorder.flushIfNeeded(currentTick: recordingTickId)
        }

        if shouldSyncBroadcastOnly {
            await transport?.syncBroadcastOnlyFromTransport()
        }

        // Flush deterministic outputs produced while processing pending items.
        // Only flush immediately if requested (e.g., for tickless lands).
        // In normal tick flow, flush is deferred until after tick handler to ensure
        // outputs include state changes from the tick handler.
        if flushOutputsImmediately {
            await flushOutputs(forTick: executingTickId)
        }

        return lastActionResponse
    }

    private func runTick(allowWhenNoTickTask: Bool) async {
        // Check if task was cancelled before executing tick
        // This prevents ticks from running after shutdown has started
        guard !Task.isCancelled else { return }

        guard let handler = definition.lifetimeHandlers.tickHandler else {
            // Even if there's no tick handler, we still need to process pending actions
            // processPendingActions() will automatically advance tick counter if needed
            do {
                _ = try await processPendingActions(flushOutputsImmediately: true)
            } catch {
                logger.error("Error processing pending actions", metadata: [
                    "error": .string(String(describing: error)),
                ])
            }
            return
        }

        // Double-check: if tickTask is nil, we're in shutdown, don't run (unless manually stepping)
        if !allowWhenNoTickTask {
            guard tickTask != nil else { return }
        }

        // Use tickId for deterministic replay (increments with each tick)
        // Increment BEFORE processing pending actions so they can execute in this tick
        let tickId = nextTickId
        nextTickId += 1

        // In re-evaluation mode, load actions, client events, and lifecycle events from ReevaluationSource.
        if mode == .reevaluation, let source = reevaluationSource {
            do {
                let recordedActions = try await source.getActions(for: tickId)
                let recordedClientEvents = try await source.getClientEvents(for: tickId)
                let recordedLifecycleEvents = try await source.getLifecycleEvents(for: tickId)

                // Convert recorded actions to PendingItem
                for recordedAction in recordedActions {
                    // Find the action type handler by matching type identifier
                    guard let handler = definition.actionHandlers.first(where: { handler in
                        let actionType = handler.getActionType()
                        let actionTypeName = String(describing: actionType)

                        // Direct type name match (e.g., "AddGoldAction" == "AddGoldAction")
                        if actionTypeName == recordedAction.typeIdentifier {
                            return true
                        }

                        // Match last component (e.g., "Module.AddGoldAction" == "AddGoldAction")
                        if actionTypeName.split(separator: ".").last == recordedAction.typeIdentifier.split(separator: ".").last {
                            return true
                        }

                        return false
                    }) else {
                        logger.warning("Handler not found for recorded action type", metadata: [
                            "typeIdentifier": .string(recordedAction.typeIdentifier),
                        ])
                        continue
                    }

                    // Get the action type from handler (we know it's ActionPayload.Type)
                    let actionTypeAny = handler.getActionType()
                    guard let actionType = actionTypeAny as? any ActionPayload.Type else {
                        logger.warning("Action type is not ActionPayload", metadata: [
                            "typeIdentifier": .string(recordedAction.typeIdentifier),
                        ])
                        continue
                    }

                    // Convert resolver outputs back to ResolverOutput.
                    // In re-evaluation mode, we wrap them in AnyCodableResolverOutput for lazy decoding.
                    // The actual decoding happens when accessed via LandContext.subscript
                    var resolverOutputs: [String: any ResolverOutput] = [:]
                    for (key, recordedOutput) in recordedAction.resolverOutputs {
                        resolverOutputs[key] = AnyCodableResolverOutput(
                            typeIdentifier: recordedOutput.typeIdentifier,
                            value: recordedOutput.value
                        )
                    }

                    let pendingItem = PendingItem.action(
                        PendingActionItem(
                            sequence: recordedAction.sequence,
                            action: recordedAction.payload,
                            actionType: actionType,
                            playerID: PlayerID(recordedAction.playerID),
                            clientID: ClientID(recordedAction.clientID),
                            sessionID: SessionID(recordedAction.sessionID),
                            resolverOutputs: resolverOutputs,
                            resolvedAtTick: recordedAction.resolvedAtTick
                        )
                    )
                    pendingItems.append(pendingItem)
                }

                // Convert recorded client events to PendingItem
                for recordedClientEvent in recordedClientEvents {
                    let pendingItem = PendingItem.clientEvent(
                        PendingClientEventItem(
                            sequence: recordedClientEvent.sequence,
                            event: AnyClientEvent(
                                type: recordedClientEvent.typeIdentifier,
                                payload: recordedClientEvent.payload
                            ),
                            playerID: PlayerID(recordedClientEvent.playerID),
                            clientID: ClientID(recordedClientEvent.clientID),
                            sessionID: SessionID(recordedClientEvent.sessionID),
                            resolvedAtTick: recordedClientEvent.resolvedAtTick
                        )
                    )
                    pendingItems.append(pendingItem)
                }

                // Convert recorded lifecycle events to PendingItem
                for recordedLifecycleEvent in recordedLifecycleEvents {
                    let kind = LifecycleKind(rawValue: recordedLifecycleEvent.kind) ?? .initialize

                    var resolverOutputs: [String: any ResolverOutput] = [:]
                    for (key, recordedOutput) in recordedLifecycleEvent.resolverOutputs {
                        resolverOutputs[key] = AnyCodableResolverOutput(
                            typeIdentifier: recordedOutput.typeIdentifier,
                            value: recordedOutput.value
                        )
                    }

                    let pendingItem = PendingItem.lifecycle(
                        PendingLifecycleItem(
                            sequence: recordedLifecycleEvent.sequence,
                            kind: kind,
                            playerID: recordedLifecycleEvent.playerID.map(PlayerID.init),
                            clientID: recordedLifecycleEvent.clientID.map(ClientID.init),
                            sessionID: recordedLifecycleEvent.sessionID.map(SessionID.init),
                            deviceID: recordedLifecycleEvent.deviceID,
                            isGuest: recordedLifecycleEvent.isGuest,
                            metadata: recordedLifecycleEvent.metadata,
                            resolverOutputs: resolverOutputs,
                            resolvedAtTick: recordedLifecycleEvent.resolvedAtTick
                        )
                    )
                    pendingItems.append(pendingItem)
                }
            } catch {
                logger.error("Error loading actions from ReevaluationSource", metadata: [
                    "tickId": .stringConvertible(tickId),
                    "error": .string(String(describing: error)),
                ])
            }
        }

        // Process pending actions before tick handler
        // Don't flush outputs yet - defer until after tick handler to ensure
        // outputs include state changes from the tick handler
        do {
            _ = try await processPendingActions(flushOutputsImmediately: false)
        } catch {
            logger.error("Error processing pending actions", metadata: [
                "error": .string(String(describing: error)),
            ])
        }

        let ctx = makeContext(
            playerID: systemPlayerID,
            clientID: systemClientID,
            sessionID: systemSessionID,
            tickId: tickId
        )

        // Execute handler synchronously - no copying needed
        // withMutableStateSync directly modifies state (actor isolation maintained)
        handler(&state, ctx)

        // Update lastCommittedTickId after tick execution completes
        // This represents the world state's current committed tick
        lastCommittedTickId = tickId

        // Optionally record live per-tick state hash as ground truth for deterministic re-evaluation.
        if enableLiveStateHashRecording, let recorder = reevaluationRecorder {
            let hash = ReevaluationEngine.calculateStateHash(state)
            await recorder.setStateHash(tickId: tickId, stateHash: hash)
        }

        // Flush deterministic outputs (emitted events + sync requests) for this tick.
        await flushOutputs(forTick: tickId)

        // Ensure we have a frame for every tick in live mode, even if no inputs occurred.
        if let recorder = reevaluationRecorder {
            await recorder.record(
                tickId: tickId,
                actions: [],
                clientEvents: [],
                lifecycleEvents: []
            )
        }

        // Note: Tick handler does NOT trigger automatic network sync
        // Network synchronization is handled separately by the sync mechanism
    }

    private func configureSyncLoop(interval: Duration) async {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            guard let self = self else { return }

            var nextSyncTime = ContinuousClock.now + interval

            while !Task.isCancelled {
                let now = ContinuousClock.now

                // If we're already past the scheduled time, execute immediately
                // Otherwise, sleep until the scheduled time
                if now < nextSyncTime {
                    try? await Task.sleep(until: nextSyncTime, clock: .continuous)
                }

                await self.runSync()

                // Fixed-rate scheduling: calculate next time from the scheduled time, not from now
                // This maintains a consistent sync rate even if execution takes longer than interval
                // If execution time exceeds interval, we skip ahead to maintain the rate
                nextSyncTime = nextSyncTime + interval

                // If we're still behind schedule after skipping, continue skipping
                // This prevents the loop from getting stuck if execution time consistently exceeds interval
                while nextSyncTime <= ContinuousClock.now {
                    nextSyncTime = nextSyncTime + interval
                }
            }
        }
    }

    private func runSync() async {
        // Check if task was cancelled before executing sync
        // This prevents sync from running after shutdown has started
        guard !Task.isCancelled else { return }

        // Double-check: if syncTask is nil, we're in shutdown, don't run
        guard syncTask != nil else { return }

        // Execute optional read-only callback if provided
        // This callback is read-only and should NOT modify state
        if let handler = definition.lifetimeHandlers.syncHandler {
            let ctx = makeContext(
                playerID: systemPlayerID,
                clientID: systemClientID,
                sessionID: systemSessionID,
                servicesOverride: LandServices(),
                tickId: lastCommittedTickId
            )
            // Pass state as value (read-only) to emphasize that it should not be modified
            handler(state, ctx)
        }

        // Sync is read-only: only triggers synchronization mechanism
        // It does not modify state
        await transport?.syncNowFromTransport()
    }

    private func scheduleDestroyIfNeeded() {
        guard players.isEmpty, let delay = definition.config.destroyWhenEmptyAfter else { return }
        destroyTask?.cancel()
        destroyTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.shutdownIfIdle()
        }
    }

    private func shutdownIfIdle() async {
        guard players.isEmpty else { return }

        // Cancel tick and sync tasks FIRST to prevent any new ticks/syncs from starting
        // This must be done before executing destroy handlers to ensure no ticks/syncs run after destroy
        tickTask?.cancel()
        tickTask = nil
        syncTask?.cancel()
        syncTask = nil

        destroyTask?.cancel()
        destroyTask = nil

        // Execute onDestroyWhenEmpty handler (sync, supports resolvers)
        // This is called specifically when the Land is destroyed due to being empty
        if let onDestroyWhenEmptyHandler = definition.lifetimeHandlers.onDestroyWhenEmpty {
            let ctx = makeContext(
                playerID: systemPlayerID,
                clientID: systemClientID,
                sessionID: systemSessionID
            )

            do {
                var updatedCtx = ctx

                // Execute resolvers in parallel if any are declared
                if !definition.lifetimeHandlers.onDestroyWhenEmptyResolverExecutors.isEmpty {
                    let resolverContext = ResolverContext(
                        landContext: ctx,
                        actionPayload: nil,
                        eventPayload: nil,
                        currentState: state
                    )
                    updatedCtx = try await ResolverExecutor.executeResolvers(
                        executors: definition.lifetimeHandlers.onDestroyWhenEmptyResolverExecutors,
                        resolverContext: resolverContext,
                        landContext: ctx
                    )
                }

                // Execute handler synchronously (resolvers already executed above)
                try withMutableStateSync { state in
                    try onDestroyWhenEmptyHandler(&state, updatedCtx)
                }
            } catch {
                logger.error("❌ onDestroyWhenEmpty handler failed", metadata: [
                    "error": .string(String(describing: error)),
                ])
            }
        }

        // Execute OnFinalize handler (sync, supports resolvers)
        // This is called for all destruction scenarios (including empty-room destruction)
        if let onFinalizeHandler = definition.lifetimeHandlers.onFinalize {
            let ctx = makeContext(
                playerID: systemPlayerID,
                clientID: systemClientID,
                sessionID: systemSessionID
            )

            do {
                var updatedCtx = ctx

                // Execute resolvers in parallel if any are declared
                if !definition.lifetimeHandlers.onFinalizeResolverExecutors.isEmpty {
                    let resolverContext = ResolverContext(
                        landContext: ctx,
                        actionPayload: nil,
                        eventPayload: nil,
                        currentState: state
                    )
                    updatedCtx = try await ResolverExecutor.executeResolvers(
                        executors: definition.lifetimeHandlers.onFinalizeResolverExecutors,
                        resolverContext: resolverContext,
                        landContext: ctx
                    )
                }

                // Execute handler synchronously (resolvers already executed above)
                try withMutableStateSync { state in
                    try onFinalizeHandler(&state, updatedCtx)
                }
            } catch {
                logger.error("❌ OnFinalize handler failed", metadata: [
                    "error": .string(String(describing: error)),
                ])
            }
        }

        // Execute AfterFinalize handler (async cleanup)
        if let afterFinalizeHandler = definition.lifetimeHandlers.afterFinalize {
            let snapshot = state
            let ctx = makeContext(
                playerID: systemPlayerID,
                clientID: systemClientID,
                sessionID: systemSessionID
            )
            await afterFinalizeHandler(snapshot, ctx)
        }

        // Legacy OnShutdown handler (deprecated)
        if let handler = definition.lifetimeHandlers.onShutdown {
            let snapshot = state
            await handler(snapshot)
        }

        // Notify transport that land has been destroyed
        // This allows transport layer to perform cleanup (e.g., remove from LandManager)
        // Note: tickTask and syncTask were already cancelled at the start of shutdownIfIdle
        await transport?.onLandDestroyed()
    }

    // Note: isEventAllowed is no longer needed as we use registry-based validation
}

private struct InternalPlayerSession: Sendable {
    var clientID: ClientID?
    var lastSessionID: SessionID?
    var services: LandServices
    // PlayerSession info (from join request)
    var deviceID: String?
    var isGuest: Bool
    var metadata: [String: String]

    init(services: LandServices, deviceID: String? = nil, isGuest: Bool = false, metadata: [String: String] = [:]) {
        clientID = nil
        lastSessionID = nil
        self.services = services
        self.deviceID = deviceID
        self.isGuest = isGuest
        self.metadata = metadata
    }
}
