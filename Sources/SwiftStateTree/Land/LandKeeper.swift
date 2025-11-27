import Foundation

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

    public func currentState() -> State {
        state
    }

    deinit {
        tickTask?.cancel()
        destroyTask?.cancel()
    }

    // MARK: - Player Lifecycle

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

