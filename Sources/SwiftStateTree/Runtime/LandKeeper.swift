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
///
/// All state mutations are serialized through the actor, ensuring thread-safety.
public actor LandKeeper<State: StateNodeProtocol> {
    public let definition: LandDefinition<State>

    private var state: State
    private var players: [PlayerID: InternalPlayerSession] = [:]

    private var transport: LandKeeperTransport?
    private let logger: Logger
    
    /// Set the transport interface (called after TransportAdapter is created)
    public func setTransport(_ transport: LandKeeperTransport?) {
        self.transport = transport
    }

    private var tickTask: Task<Void, Never>?
    private var destroyTask: Task<Void, Never>?

    private let systemPlayerID = PlayerID("_system")
    private let systemClientID = ClientID("_system")
    private let systemSessionID = SessionID("_system")

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

        if let interval = definition.lifetimeHandlers.tickInterval,
           definition.lifetimeHandlers.tickHandler != nil {
            // Start tick loop asynchronously after initialization completes
            // The Task will execute after init returns, so self is fully initialized
            Task { [weak self] in
                guard let self = self else { return }
                await self.configureTickLoop(interval: interval)
            }
        }
    }

    /// Returns the current state snapshot.
    ///
    /// This is a read-only view of the state. Mutations should be done through action/event handlers.
    public func currentState() -> State {
        state
    }

    deinit {
        tickTask?.cancel()
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
    ) async {
        var session = players[playerID] ?? InternalPlayerSession(services: services)
        let isFirst = session.clients.isEmpty

        session.clients.insert(clientID)
        session.lastSessionID = sessionID
        session.services = services
        players[playerID] = session

        destroyTask?.cancel()
        destroyTask = nil

        guard isFirst, let handler = definition.lifetimeHandlers.onJoin else { return }
        let ctx = makeContext(
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            servicesOverride: services
        )
        await withMutableState { state in
            await handler(&state, ctx)
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
        services: LandServices = LandServices()
    ) async throws -> JoinDecision {
        // Call CanJoin handler if defined
        var decision: JoinDecision = .allow(playerID: PlayerID(session.playerID))
        
        if let canJoinHandler = definition.lifetimeHandlers.canJoin {
            let ctx = makeContext(
                playerID: PlayerID("_pending"), // Temporary ID for validation
                clientID: clientID,
                sessionID: sessionID,
                servicesOverride: services
            )
            decision = try await canJoinHandler(state, session, ctx)
        }
        
        // If denied, return early
        guard case .allow(let playerID) = decision else {
            return decision
        }
        
        // Proceed with join
        var playerSession = players[playerID] ?? InternalPlayerSession(
            services: services,
            deviceID: session.deviceID,
            metadata: session.metadata
        )
        let isFirst = playerSession.clients.isEmpty

        playerSession.clients.insert(clientID)
        playerSession.lastSessionID = sessionID
        playerSession.services = services
        // Update deviceID and metadata if provided (for reconnection scenarios)
        if let deviceID = session.deviceID {
            playerSession.deviceID = deviceID
        }
        if !session.metadata.isEmpty {
            playerSession.metadata = session.metadata
        }
        players[playerID] = playerSession

        destroyTask?.cancel()
        destroyTask = nil

        guard isFirst, let handler = definition.lifetimeHandlers.onJoin else { return decision }
        let ctx = makeContext(
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            servicesOverride: services,
            deviceID: session.deviceID,
            metadata: session.metadata
        )
        await withMutableState { state in
            await handler(&state, ctx)
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
    public func leave(playerID: PlayerID, clientID: ClientID) async {
        guard var session = players[playerID] else { return }
        session.clients.remove(clientID)

        if session.clients.isEmpty {
            let deviceID = session.deviceID
            let metadata = session.metadata
            players.removeValue(forKey: playerID)
            
            if let handler = definition.lifetimeHandlers.onLeave {
                let ctx = makeContext(
                    playerID: playerID,
                    clientID: clientID,
                    sessionID: session.lastSessionID ?? systemSessionID,
                    servicesOverride: session.services,
                    deviceID: deviceID,
                    metadata: metadata
                )
                await withMutableState { state in
                    await handler(&state, ctx)
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
        } else {
            players[playerID] = session
        }
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

        let ctx = makeContext(playerID: playerID, clientID: clientID, sessionID: sessionID)
        return try await withMutableState { state in
            try await handler.invoke(&state, action: action, ctx: ctx)
        }
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
    public func handleClientEvent(
        _ event: AnyClientEvent,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async {
        // Find handlers that can handle this event type
        let ctx = makeContext(playerID: playerID, clientID: clientID, sessionID: sessionID)
        await withMutableState { state in
            for handler in definition.eventHandlers {
                // Check if handler can handle this event type by looking up the descriptor
                if let descriptor = definition.clientEventRegistry.findDescriptor(for: event.type),
                   handler.canHandle(descriptor.type) {
                await handler.invoke(&state, event: event, ctx: ctx)
                }
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
        metadata: [String: String] = [:]
    ) -> LandContext {
        let services = servicesOverride ?? players[playerID]?.services ?? LandServices()
        let playerSession = players[playerID]
        return LandContext(
            landID: definition.id,
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            services: services,
            deviceID: deviceID ?? playerSession?.deviceID,
            metadata: metadata.isEmpty ? (playerSession?.metadata ?? [:]) : metadata,
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

    private func withMutableState<R>(
        _ body: (inout State) async throws -> R
    ) async rethrows -> R {
        var copy = state
        let result = try await body(&copy)
        state = copy
        return result
    }

    // MARK: - Tick & Lifetime

    private func configureTickLoop(interval: Duration) async {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            guard let self = self else { return }
            
            var nextTickTime = ContinuousClock.now
            
            while !Task.isCancelled {
                let now = ContinuousClock.now
                
                // If we're already past the scheduled time, execute immediately
                // Otherwise, sleep until the scheduled time
                if now < nextTickTime {
                    try? await Task.sleep(until: nextTickTime, clock: .continuous)
                }
                
                await self.runTick()
                
                // Schedule next tick at fixed interval from now
                // This prevents accumulation of delays when execution takes longer than interval
                nextTickTime = ContinuousClock.now + interval
            }
        }
    }

    private func runTick() async {
        guard let handler = definition.lifetimeHandlers.tickHandler else { return }
        let ctx = makeContext(
            playerID: systemPlayerID,
            clientID: systemClientID,
            sessionID: systemSessionID,
            servicesOverride: LandServices()
        )
        var copy = state
        handler(&copy, ctx)  // Handler itself is sync
        state = copy
        
        // Trigger sync after state changes to send diff/patch to all players
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
        destroyTask?.cancel()
        destroyTask = nil

        if let handler = definition.lifetimeHandlers.onShutdown {
            let snapshot = state
            await handler(snapshot)
        }

        tickTask?.cancel()
        tickTask = nil
    }

    // Note: isEventAllowed is no longer needed as we use registry-based validation
}

private struct InternalPlayerSession: Sendable {
    var clients: Set<ClientID> = []
    var lastSessionID: SessionID?
    var services: LandServices
    // PlayerSession info (from join request)
    var deviceID: String?
    var metadata: [String: String]
    
    init(services: LandServices, deviceID: String? = nil, metadata: [String: String] = [:]) {
        self.clients = []
        self.lastSessionID = nil
        self.services = services
        self.deviceID = deviceID
        self.metadata = metadata
    }
}
