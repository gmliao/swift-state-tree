import Foundation
import Logging

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
    /// TODO: Performance considerations:
    /// - When Resolver mechanism is implemented and Action Handlers become synchronous,
    ///   we may be able to directly modify state without copying
    /// - Consider sync queue or debouncing for high-frequency sync scenarios
public actor LandKeeper<State: StateNodeProtocol>: LandKeeperProtocol {
    public let definition: LandDefinition<State>

    private var state: State
    private var players: [PlayerID: InternalPlayerSession] = [:]

    private var transport: LandKeeperTransport?
    private let logger: Logger
    
    /// Actual land instance ID (e.g., "counter:550e8400-...")
    /// This is different from definition.id which is just the land type (e.g., "counter")
    private var actualLandID: String?
    
    /// Set the transport interface (called after TransportAdapter is created)
    public func setTransport(_ transport: LandKeeperTransport?) {
        self.transport = transport
    }
    
    /// Set the actual land instance ID (called after LandKeeper is created)
    /// This allows LandContext to use the actual instance ID instead of just the land type
    public func setLandID(_ landID: String) {
        self.actualLandID = landID
    }

    private var tickTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var destroyTask: Task<Void, Never>?
    
    /// Next tick ID (0-based, increments with each tick) for deterministic replay.
    /// This represents the ID that will be assigned to the next tick execution.
    /// Using Int64 for long-running servers and replay compatibility.
    private var nextTickId: Int64 = 0
    
    /// Last committed tick ID (the most recent tick that has completed execution).
    /// This represents the world state's current committed tick.
    /// Action/Event handlers should use this to bind to the committed world state.
    /// Initialized to -1 to indicate no ticks have been committed yet.
    private var lastCommittedTickId: Int64 = -1

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
    ///   - transport: Optional transport interface for sending events and syncing state.
    ///                If not provided, operations will be no-ops (useful for testing).
    ///   - logger: Optional logger instance. If not provided, a default logger will be created.
    public init(
        definition: LandDefinition<State>,
        initialState: State,
        transport: LandKeeperTransport? = nil,
        logger: Logger? = nil
    ) {
        self.definition = definition
        self.state = initialState
        self.transport = transport
        let resolvedLogger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.runtime",
            scope: "LandKeeper"
                    )
        self.logger = resolvedLogger

        // Execute OnInitialize handler and then start tick loop
        // Both are async, so we use a single Task to ensure proper sequencing
        Task { [weak self] in
            guard let self = self else { return }
            
            // First, execute OnInitialize if defined
            if let onInitializeHandler = definition.lifetimeHandlers.onInitialize {
                await self.executeOnInitialize(handler: onInitializeHandler)
            }
            
            // Then, start tick and sync loops if configured (only after OnInitialize completes)
            let tickInterval = definition.lifetimeHandlers.tickInterval
            let syncInterval = definition.lifetimeHandlers.syncInterval
            
            // Start tick loop if configured
            if let interval = tickInterval,
               definition.lifetimeHandlers.tickHandler != nil {
                await self.configureTickLoop(interval: interval)
            }
            
            // Start sync loop: use configured interval, or fallback to tick interval if not configured
            let effectiveSyncInterval: Duration?
            if let sync = syncInterval {
                effectiveSyncInterval = sync
            } else if let tick = tickInterval {
                // Auto-configure sync to match tick interval if sync is not explicitly set
                effectiveSyncInterval = tick
                self.logger.warning(
                    "⚠️ Sync interval not configured for land '\(definition.id)'. Auto-configuring sync to match tick interval (\(tick)). Consider explicitly setting StateSync(every:) in Lifetime block for better control.",
                    metadata: [
                        "landID": .string(definition.id),
                        "tickInterval": .string("\(tick)"),
                        "autoSyncInterval": .string("\(tick)")
                    ]
                )
            } else {
                effectiveSyncInterval = nil
            }
            
            if let interval = effectiveSyncInterval {
                await self.configureSyncLoop(interval: interval)
            }
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
                "error": .string(String(describing: error))
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
            return nil  // Deduplication: skip concurrent sync requests
        }
        isSyncing = true
        return state  // Direct snapshot - no blocking
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

        guard isFirst, let handler = definition.lifetimeHandlers.onJoin else { return }
        var ctx = makeContext(
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            servicesOverride: services
        )
        
        // Execute resolvers in parallel if any are declared
        if !definition.lifetimeHandlers.onJoinResolverExecutors.isEmpty {
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
        }
        
        // Execute handler synchronously (resolvers already executed above)
        // withMutableStateSync is now synchronous - no await needed
        try withMutableStateSync { state in
            try handler(&state, ctx)
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
        guard case .allow(let playerID) = decision else {
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
                    "maxPlayers": .stringConvertible(maxPlayers)
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

        guard isFirst, let handler = definition.lifetimeHandlers.onJoin else { return decision }
        var ctx = makeContext(
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            servicesOverride: services,
            deviceID: session.deviceID,
            isGuest: session.isGuest,
            metadata: session.metadata
        )
        
        // Execute resolvers in parallel if any are declared
        if !definition.lifetimeHandlers.onJoinResolverExecutors.isEmpty {
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
        }
        
        // Execute handler synchronously (resolvers already executed above)
        // withMutableStateSync is now synchronous - no await needed
        try withMutableStateSync { state in
            try handler(&state, ctx)
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
        
        logger.info("Player \(playerID.rawValue) leaving, calling OnLeave handler")
        
        if let handler = definition.lifetimeHandlers.onLeave {
            var ctx = makeContext(
                playerID: playerID,
                clientID: clientID,
                sessionID: session.lastSessionID ?? systemSessionID,
                servicesOverride: session.services,
                deviceID: deviceID,
                isGuest: isGuest,
                metadata: metadata
            )
            
            // Execute resolvers in parallel if any are declared
            if !definition.lifetimeHandlers.onLeaveResolverExecutors.isEmpty {
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
            }
            
            // Execute handler synchronously (resolvers already executed above)
            // withMutableStateSync is now synchronous - no await needed
            try withMutableStateSync { state in
                try handler(&state, ctx)
            }
            // Trigger sync after OnLeave handler modifies state
            // Use syncBroadcastOnlyHandler for optimization: only syncs broadcast changes
            // (e.g., removing player from dictionary) using dirty tracking.
            // This is more efficient than syncNow() because:
            // - Only extracts/compares dirty broadcast fields (not entire state)
            // - Sends same update to all players (no per-player diff needed)
            // - Updates shared broadcast cache efficiently
            await transport?.syncBroadcastOnlyFromTransport()
        }
        scheduleDestroyIfNeeded()
    }

    // MARK: - Action & Event Handling

    /// Handles an action from a player.
    ///
    /// Finds the registered handler for the action type and executes it.
    ///
    /// - Parameters:
    ///   - action: The action payload.
    ///   - playerID: The player sending the action.
    ///   - clientID: The client instance.
    ///   - sessionID: The session identifier.
    /// - Returns: The action result (type-erased as `AnyCodable`).
    /// - Throws: `LandError.actionNotRegistered` if no handler is found.
    public func handleAction<A: ActionPayload>(
        _ action: A,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async throws -> AnyCodable {
        guard let handler = definition.actionHandlers.first(where: { $0.canHandle(A.self) }) else {
            throw LandError.actionNotRegistered
        }

        // Bind action to lastCommittedTickId for replay logging
        // This represents the world state's current committed tick (not the next tick)
        var ctx = makeContext(
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            tickId: lastCommittedTickId
        )
        
        // Execute resolvers in parallel if any are declared
        if !handler.resolverExecutors.isEmpty {
            let resolverContext = ResolverContext(
                landContext: ctx,
                actionPayload: action,
                eventPayload: nil,
                currentState: state
            )
            ctx = try await ResolverExecutor.executeResolvers(
                executors: handler.resolverExecutors,
                resolverContext: resolverContext,
                landContext: ctx
            )
        }
        
        // Execute handler synchronously (resolvers already executed above)
        // withMutableStateSync is now synchronous - no await needed
        return try withMutableStateSync { state in
            try handler.invoke(&state, action: action, ctx: ctx)
        }
    }
    
    /// Handles an action envelope by decoding and dispatching to the registered handler.
    ///
    /// This is used by transport adapters that receive type-erased `ActionEnvelope` payloads.
    public func handleActionEnvelope(
        _ envelope: ActionEnvelope,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async throws -> AnyCodable {
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
        // First, encode AnyCodable to JSON Data, then decode to the specific action type
        let payloadData = try JSONEncoder().encode(envelope.payload)
        let decodedAction = try decoder.decode(actionPayloadType, from: payloadData)
        // Bind action to lastCommittedTickId for replay logging
        // This represents the world state's current committed tick (not the next tick)
        var ctx = makeContext(
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            tickId: lastCommittedTickId
        )
        
        // Execute resolvers in parallel if any are declared
        if !handler.resolverExecutors.isEmpty {
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
        }
        
        // Execute handler synchronously (resolvers already executed above)
        // withMutableStateSync is now synchronous - no await needed
        return try withMutableStateSync { state in
            try handler.invokeErased(&state, action: decodedAction, ctx: ctx)
        }
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
    /// Checks if the event is allowed, then invokes all registered event handlers.
    ///
    /// - Parameters:
    ///   - event: The client event (type-erased).
    ///   - playerID: The player sending the event.
    ///   - clientID: The client instance.
    ///   - sessionID: The session identifier.
    /// Handles a client event by finding and invoking registered event handlers.
    ///
    /// - Parameters:
    ///   - event: The client event to handle.
    ///   - playerID: The player sending the event.
    ///   - clientID: The client instance.
    ///   - sessionID: The session identifier.
    /// - Throws: Errors from event handler execution (e.g., resolver failures)
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
        // Bind event to lastCommittedTickId for replay logging
        // This represents the world state's current committed tick (not the next tick)
        let ctx = makeContext(
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            tickId: lastCommittedTickId
        )
        
        // Check if event is registered in the client event registry
        guard let descriptor = definition.clientEventRegistry.findDescriptor(for: event.type) else {
            logger.error(
                "Client event type '\(event.type)' is not registered in ClientEvents { Register(...) }",
                metadata: [
                    "eventType": .string(event.type),
                    "landID": .string(definition.id),
                    "playerID": .string(playerID.rawValue)
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
                    "playerID": .string(playerID.rawValue)
                ]
            )
            throw LandError.eventNotRegistered
        }
        
        // Note: Event handlers don't currently support resolvers, but we prepare for it
        // If we add resolver support for events in the future, we would execute them here
        
        // withMutableStateSync is now synchronous - no await needed
        try withMutableStateSync { state in
            for handler in matchingHandlers {
                try handler.invoke(&state, event: event, ctx: ctx)
            }
        }
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
        tickId: Int64? = nil
    ) -> LandContext {
        let services = servicesOverride ?? players[playerID]?.services ?? LandServices()
        let playerSession = players[playerID]
        // Use actual land instance ID if available, otherwise fall back to definition.id (land type)
        let landID = actualLandID ?? definition.id
        return LandContext(
            landID: landID,
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            services: services,
            logger: logger,
            deviceID: deviceID ?? playerSession?.deviceID,
            isGuest: isGuest ?? playerSession?.isGuest ?? false,
            metadata: metadata.isEmpty ? (playerSession?.metadata ?? [:]) : metadata,
            tickId: tickId,
            sendEventHandler: { [transport, logger, definition] anyEvent, target in
                #if DEBUG
                if !definition.serverEventRegistry.registered.isEmpty {
                    // Check if the event type is registered by looking up the event name
                    if definition.serverEventRegistry.findDescriptor(for: anyEvent.type) == nil {
                        logger.warning(
                            "ServerEvent type '\(anyEvent.type)' was sent but not registered via ServerEvents { Register(...) } in the Land DSL. It will not be included in generated schemas.",
                            metadata: ["eventType": .string(anyEvent.type)]
                        )
                    }
                }
                #endif
                await transport?.sendEventToTransport(anyEvent, to: target)
            },
            syncHandler: { [transport] in
                await transport?.syncNowFromTransport()
            }
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
                
                await self.runTick()
                
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

    private func runTick() {
        // Check if task was cancelled before executing tick
        // This prevents ticks from running after shutdown has started
        guard !Task.isCancelled else { return }
        
        guard let handler = definition.lifetimeHandlers.tickHandler else { return }
        
        // Double-check: if tickTask is nil, we're in shutdown, don't run
        guard tickTask != nil else { return }
        
        // Use tickId for deterministic replay (increments with each tick)
        let tickId = nextTickId
        nextTickId += 1
        
        let ctx = makeContext(
            playerID: systemPlayerID,
            clientID: systemClientID,
            sessionID: systemSessionID,
            servicesOverride: LandServices(),
            tickId: tickId
        )
        
        // Execute handler synchronously - no copying needed
        // withMutableStateSync directly modifies state (actor isolation maintained)
        handler(&state, ctx)
        
        // Update lastCommittedTickId after tick execution completes
        // This represents the world state's current committed tick
        lastCommittedTickId = tickId
        
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
                    "error": .string(String(describing: error))
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
                    "error": .string(String(describing: error))
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
        self.clientID = nil
        self.lastSessionID = nil
        self.services = services
        self.deviceID = deviceID
        self.isGuest = isGuest
        self.metadata = metadata
    }
}
