import Foundation

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
public actor LandKeeper<State, ClientE, ServerE>
where State: StateNodeProtocol,
      ClientE: ClientEventPayload,
      ServerE: ServerEventPayload {
    public let definition: LandDefinition<State, ClientE, ServerE>

    private var state: State
    private var players: [PlayerID: PlayerSession] = [:]

    private let sendEventHandler: @Sendable (any ServerEventPayload, EventTarget) async -> Void
    private let syncNowHandler: @Sendable () async -> Void

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
    ///   - sendEvent: Closure for sending server events to clients (injected by transport layer).
    ///   - syncNow: Closure for triggering immediate state synchronization (injected by transport layer).
    public init(
        definition: LandDefinition<State, ClientE, ServerE>,
        initialState: State,
        sendEvent: @escaping @Sendable (any ServerEventPayload, EventTarget) async -> Void = { _, _ in },
        syncNow: @escaping @Sendable () async -> Void = {}
    ) {
        self.definition = definition
        self.state = initialState
        self.sendEventHandler = sendEvent
        self.syncNowHandler = syncNow

        if let interval = definition.lifetimeHandlers.tickInterval,
           definition.lifetimeHandlers.tickHandler != nil {
            Task { [weak self] in
                await self?.configureTickLoop(interval: interval)
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

    /// Handles a player joining the Land.
    ///
    /// If this is the player's first connection, the `OnJoin` handler is called.
    /// Multiple clients/sessions for the same player are tracked.
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
        var session = players[playerID] ?? PlayerSession(services: services)
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
            players.removeValue(forKey: playerID)
            if let handler = definition.lifetimeHandlers.onLeave {
                let ctx = makeContext(
                    playerID: playerID,
                    clientID: clientID,
                    sessionID: session.lastSessionID ?? systemSessionID,
                    servicesOverride: session.services
                )
                await withMutableState { state in
                    await handler(&state, ctx)
                }
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
    ///   - event: The client event payload.
    ///   - playerID: The player sending the event.
    ///   - clientID: The client instance.
    ///   - sessionID: The session identifier.
    public func handleClientEvent(
        _ event: ClientE,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async {
        guard isEventAllowed(event) else {
            return
        }

        let ctx = makeContext(playerID: playerID, clientID: clientID, sessionID: sessionID)
        await withMutableState { state in
            for handler in definition.eventHandlers {
                await handler.invoke(&state, event: event, ctx: ctx)
            }
        }
    }

    // MARK: - Helpers

    private func makeContext(
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        servicesOverride: LandServices? = nil
    ) -> LandContext {
        let services = servicesOverride ?? players[playerID]?.services ?? LandServices()
        return LandContext(
            landID: definition.id,
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            services: services,
            sendEventHandler: sendEventHandler,
            syncHandler: syncNowHandler
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

    private func configureTickLoop(interval: Duration) {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self.runTick()
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
        await withMutableState { state in
            await handler(&state, ctx)
        }
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

    private func isEventAllowed(_ event: ClientE) -> Bool {
        guard !definition.config.allowedClientEvents.isEmpty else {
            return true
        }
        guard let hashableEvent = event as? AnyHashable else {
            return false
        }
        return definition.config.allowedClientEvents.contains(
            AllowedEventIdentifier(anyHashable: hashableEvent)
        )
    }
}

private struct PlayerSession: Sendable {
    var clients: Set<ClientID> = []
    var lastSessionID: SessionID?
    var services: LandServices
}

