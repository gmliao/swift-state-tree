import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct DemoLandState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]

    @Sync(.broadcast)
    var readyPlayers: Set<PlayerID> = []

    @Sync(.broadcast)
    var ticks: Int = 0
    
    @Sync(.broadcast)
    var spawnedTaskCount: Int = 0
}

@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResult
    let name: String
}

@Payload
struct JoinResult: ResponsePayload {
    let ok: Bool
}

@Payload
struct DemoReadyEvent: ClientEventPayload {
    public init() {}
}

@Payload
struct DemoChatEvent: ClientEventPayload {
    let message: String
    public init(message: String) {
        self.message = message
    }
}

@Payload
struct DemoMessageEvent: ServerEventPayload {
    let message: String
    public init(message: String) {
        self.message = message
    }
}

@Test("Land builder collects access control and allowed events")
func testLandBuilderCollectsNodes() {
    let definition = Land(
        "demo",
        using: DemoLandState.self
    ) {
        AccessControl {
            AllowPublic(false)
            MaxPlayers(4)
        }

        ClientEvents {
            Register(DemoReadyEvent.self)
            Register(DemoChatEvent.self)
        }
        
        ServerEvents {
            Register(DemoMessageEvent.self)
        }

        Rules {
            HandleAction(JoinAction.self) { (state: inout DemoLandState, action: JoinAction, ctx: LandContext) in
                state.players[ctx.playerID] = action.name
                return JoinResult(ok: true)
            }

            HandleEvent(DemoReadyEvent.self) { (state: inout DemoLandState, event: DemoReadyEvent, ctx: LandContext) in
                    state.readyPlayers.insert(ctx.playerID)
            }
        }

        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.destroyWhenEmptyAfter = .seconds(5)
            config.tickInterval = .milliseconds(50)
            config.tickHandler = { state, _ in
                state.ticks += 1
            }
        }
    }

    #expect(definition.config.allowPublic == false)
    #expect(definition.config.maxPlayers == 4)
    // Note: AllowedClientEvents is no longer used with registry-based events
    #expect(definition.lifetimeHandlers.tickInterval == .milliseconds(50))
    #expect(definition.lifetimeHandlers.destroyWhenEmptyAfter == .seconds(5))
}

@Test("LandKeeper handles joins, actions, and events")
func testLandKeeperLifecycle() async throws {
    let definition = Land(
        "demo-lifecycle",
        using: DemoLandState.self
    ) {
        ClientEvents {
            Register(DemoReadyEvent.self)
        }
        
        ServerEvents {
            Register(DemoMessageEvent.self)
        }
        
        Rules {
            OnJoin { (state: inout DemoLandState, ctx: LandContext) in
                state.players[ctx.playerID] = "Guest"
            }

            OnLeave { (state: inout DemoLandState, ctx: LandContext) in
                state.players.removeValue(forKey: ctx.playerID)
            }

            HandleAction(JoinAction.self) { (state: inout DemoLandState, action: JoinAction, ctx: LandContext) in
                state.players[ctx.playerID] = action.name
                return JoinResult(ok: true)
            }

            HandleEvent(DemoReadyEvent.self) { (state: inout DemoLandState, event: DemoReadyEvent, ctx: LandContext) in
                    state.readyPlayers.insert(ctx.playerID)
            }
        }
    }

    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices()
    )
    let playerID = PlayerID("alice")
    let clientID = ClientID("device-1")
    let sessionID = SessionID("session-1")

    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)

    let action = JoinAction(name: "Alice")
    let envelope = ActionEnvelope(
        typeIdentifier: "JoinAction",
        payload: AnyCodable(action)
    )
    let joinResponse = try await keeper.handleActionEnvelope(
        envelope,
        playerID: playerID,
        clientID: clientID,
        sessionID: sessionID
    )

    let result = joinResponse.base as? JoinResult
    #expect(result?.ok == true)

    let readyEvent = AnyClientEvent(DemoReadyEvent())
    try await keeper.handleClientEvent(readyEvent, playerID: playerID, clientID: clientID, sessionID: sessionID)

    try await keeper.leave(playerID: playerID, clientID: clientID)

    let state = await keeper.currentState()
    #expect(state.players[playerID] == nil)
    #expect(state.readyPlayers.contains(playerID))
}

@Test("LandKeeper enforces allowed client events")
func testLandKeeperAllowedEvents() async throws {
    let definition = Land(
        "allowed-events",
        using: DemoLandState.self
    ) {
        ClientEvents {
            Register(DemoReadyEvent.self)
            Register(DemoChatEvent.self)
        }
        
        ServerEvents {
            Register(DemoMessageEvent.self)
        }
        
        Rules {
            HandleEvent(DemoReadyEvent.self) { (state: inout DemoLandState, event: DemoReadyEvent, ctx: LandContext) in
                // Synchronous handler: mutate state directly
                state.spawnedTaskCount += 1
            }
        }
    }

    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices()
    )
    let playerID = PlayerID("player")
    let clientID = ClientID("client")
    let sessionID = SessionID("session")

    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)

    let chatEvent = AnyClientEvent(DemoChatEvent(message: "hi"))
    try? await keeper.handleClientEvent(chatEvent, playerID: playerID, clientID: clientID, sessionID: sessionID)
    #expect((await keeper.currentState()).spawnedTaskCount == 0)

    let readyEvent = AnyClientEvent(DemoReadyEvent())
    try? await keeper.handleClientEvent(readyEvent, playerID: playerID, clientID: clientID, sessionID: sessionID)
    await waitFor("Ready event handler to run") {
        (await keeper.currentState()).spawnedTaskCount == 1
    }
    #expect((await keeper.currentState()).spawnedTaskCount == 1)
}

// Helper for async assertions
func waitFor(
    _ description: String,
    timeout: Duration = .seconds(2),
    interval: Duration = .milliseconds(10),
    condition: () async throws -> Bool
) async {
    let start = ContinuousClock.now
    while start.duration(to: .now) < timeout {
        do {
            if try await condition() {
                return
            }
        } catch {
            // Ignore errors during polling, just wait
        }
        try? await Task.sleep(for: interval)
    }
    Issue.record("Timeout waiting for: \(description)")
}

@Test("Tick handler runs on interval")
func testLandKeeperTickHandler() async throws {
    let definition = Land(
        "tick-land",
        using: DemoLandState.self
    ) {
        Rules { }

        Lifetime {
            Tick(every: .milliseconds(10)) { (state: inout DemoLandState, _) in
                state.ticks += 1
            }
            StateSync(every: .milliseconds(10)) { (_: DemoLandState, _: LandContext) in
                // Read-only sync callback
            }
        }
    }

    // Stepped by hand: the handler runs once per tick, with no wait on the scheduler (#264).
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices(),
        autoStartLoops: false
    )
    for _ in 0..<3 { await keeper.stepTickOnce() }
    #expect((await keeper.currentState()).ticks == 3)
}

// NEW TESTS FOR ASYNC FEATURES

@Test("CanJoin handler allows valid joins")
func testCanJoinAllows() async throws {
    let definition = Land(
        "can-join-test",
        using: DemoLandState.self
    ) {
        Rules {
            CanJoin { (state: DemoLandState, session: PlayerSession, _: LandContext) in
                // Allow if room not full
                guard state.players.count < 2 else {
                    throw JoinError.roomIsFull
                }
                return .allow(playerID: PlayerID(session.playerID))
            }
            
            OnJoin { (state: inout DemoLandState, ctx: LandContext) in
                state.players[ctx.playerID] = "Player"
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices()
    )
    
    let session1 = PlayerSession(playerID: "user1")
    let decision1 = try await keeper.join(
        session: session1,
        clientID: ClientID("client1"),
        sessionID: SessionID("session1"),
        services: LandServices()
    )
    
    guard case .allow(let playerID) = decision1 else {
        Issue.record("Expected join to be allowed")
        return
    }
    
    #expect(playerID.rawValue == "user1")
    let state = await keeper.currentState()
    #expect(state.players.count == 1)
}

@Test("CanJoin handler denies invalid joins")
func testCanJoinDenies() async throws {
    let definition = Land(
        "can-join-deny-test",
        using: DemoLandState.self
    ) {
        Rules {
            CanJoin { (state: DemoLandState, session: PlayerSession, _: LandContext) in
                // Room full
                guard state.players.count < 1 else {
                    throw JoinError.roomIsFull
                }
                return .allow(playerID: PlayerID(session.playerID))
            }
            
            OnJoin { (state: inout DemoLandState, ctx: LandContext) in
                state.players[ctx.playerID] = "Player"
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices()
    )

    let session1 = PlayerSession(playerID: "user1")

    _ = try await keeper.join(
        session: session1,
        clientID: ClientID("client1"),
        sessionID: SessionID("session1"),
        services: LandServices()
    )
    
    // Second join should fail
    let session2 = PlayerSession(playerID: "user2")
    do {
        _ = try await keeper.join(
            session: session2,
            clientID: ClientID("client2"),
            sessionID: SessionID("session2"),
            services: LandServices()
        )
        Issue.record("Expected join to throw JoinError.roomIsFull")
    } catch JoinError.roomIsFull {
        // Expected
    } catch {
        Issue.record("Expected JoinError.roomIsFull, got \(error)")
    }
    
    let state = await keeper.currentState()
    #expect(state.players.count == 1)
}

@Test("ctx.emitEvent queues and flushes deterministically")
func testCtxEmitEventQueuesAndFlushes() async throws {
    actor RecordingTransport: LandKeeperTransport {
        var events: [AnyServerEvent] = []
        func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async { events.append(event) }
        func syncNowFromTransport() async {}
        func syncBroadcastOnlyFromTransport() async {}
        func onLandDestroyed() async {}
    }
    let transport = RecordingTransport()
    
    let definition = Land(
        "emit-event-test",
        using: DemoLandState.self
    ) {
        ServerEvents { Register(DemoMessageEvent.self) }
        Lifetime {
            Tick(every: .milliseconds(10)) { (state: inout DemoLandState, ctx: LandContext) in
                state.ticks += 1
                ctx.emitEvent(DemoMessageEvent(message: "tick-\(state.ticks)"), to: .all)
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices(),
        autoStartLoops: false
    )
    await keeper.setTransport(transport)

    // `RecordingTransport` keeps the default `runsSyncPhaseInTurn` (false), so this runs the
    // legacy tick path with in-turn sync on or off.
    // One stepped tick emits one event, flushed to the transport by the end of the tick (#264).
    await keeper.stepTickOnce()
    #expect(await transport.events.count == 1)
    await keeper.stepTickOnce()
    #expect(await transport.events.count == 2)
}

@Test("OnTick is synchronous and does not block")
func testOnTickSynchronous() async throws {
    let definition = Land(
        "sync-tick-test",
        using: DemoLandState.self
    ) {
        Lifetime {
            Tick(every: .milliseconds(5)) { (state: inout DemoLandState, _: LandContext) in
                // This is synchronous - no await allowed
                state.ticks += 1
            }
            StateSync(every: .milliseconds(5)) { (_: DemoLandState, _: LandContext) in
                // Read-only sync callback
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices(),
        autoStartLoops: false
    )
    for _ in 0..<3 { await keeper.stepTickOnce() }
    #expect((await keeper.currentState()).ticks == 3)
}

// MARK: - Event Registration Tests

@Test("ClientEvents Register collects event types")
func testClientEventsRegister() {
    @Payload
    struct TestEvent1: ClientEventPayload {
        let value: Int
        public init(value: Int) { self.value = value }
    }
    
    @Payload
    struct TestEvent2: ClientEventPayload {
        let message: String
        public init(message: String) { self.message = message }
    }
    
    let definition = Land(
        "test-register",
        using: DemoLandState.self
    ) {
        ClientEvents {
            Register(TestEvent1.self)
            Register(TestEvent2.self)
        }
        Rules { }
    }
    
    // Verify client events are registered
    #expect(definition.clientEventRegistry.registered.count == 2)
    
    let eventNames = definition.clientEventRegistry.registered.map { $0.eventName }
    #expect(eventNames.contains("TestEvent1"))
    #expect(eventNames.contains("TestEvent2"))
    
    // Verify all registered events are client events
    for descriptor in definition.clientEventRegistry.registered {
        #expect(descriptor.direction == .client)
    }
}

@Test("ServerEvents Register collects event types")
func testServerEventsRegister() {
    @Payload
    struct TestServerEvent1: ServerEventPayload {
        let value: Int
        public init(value: Int) { self.value = value }
    }
    
    @Payload
    struct TestServerEvent2: ServerEventPayload {
        let message: String
        public init(message: String) { self.message = message }
    }
    
    let definition = Land(
        "test-server-register",
        using: DemoLandState.self
    ) {
        ServerEvents {
            Register(TestServerEvent1.self)
            Register(TestServerEvent2.self)
        }
        Rules { }
    }
    
    // Verify server events are registered
    #expect(definition.serverEventRegistry.registered.count == 2)
    
    let eventNames = definition.serverEventRegistry.registered.map { $0.eventName }
    #expect(eventNames.contains("TestServerEvent1"))
    #expect(eventNames.contains("TestServerEvent2"))
    
    // Verify all registered events are server events
    for descriptor in definition.serverEventRegistry.registered {
        #expect(descriptor.direction == .server)
    }
}

@Test("EventRegistry findDescriptor works correctly")
func testEventRegistryFindDescriptor() {
    @Payload
    struct TestFindEvent: ServerEventPayload {
        let id: String
        public init(id: String) { self.id = id }
    }
    
    let definition = Land(
        "test-find",
        using: DemoLandState.self
    ) {
        ServerEvents {
            Register(TestFindEvent.self)
        }
        Rules { }
    }
    
    // Test finding by event name (event name now removes "Event" suffix to match schema)
    let descriptor = definition.serverEventRegistry.findDescriptor(for: "TestFind")
    #expect(descriptor != nil)
    #expect(descriptor?.eventName == "TestFind")
    #expect(descriptor?.direction == .server)
    
    // Test finding non-existent event
    let notFound = definition.serverEventRegistry.findDescriptor(for: "NonExistentEvent")
    #expect(notFound == nil)
}

@Test("EventRegistry isRegistered works correctly")
func testEventRegistryIsRegistered() {
    @Payload
    struct TestRegisteredEvent: ClientEventPayload {
        public init() {}
    }
    
    @Payload
    struct TestUnregisteredEvent: ClientEventPayload {
        public init() {}
    }
    
    let definition = Land(
        "test-is-registered",
        using: DemoLandState.self
    ) {
        ClientEvents {
            Register(TestRegisteredEvent.self)
        }
        Rules { }
    }
    
    // Test registered event
    #expect(definition.clientEventRegistry.isRegistered(TestRegisteredEvent.self))
    
    // Test unregistered event
    #expect(definition.clientEventRegistry.isRegistered(TestUnregisteredEvent.self) == false)
}

@Test("ClientEvents and ServerEvents can be registered together")
func testBothClientAndServerEvents() {
    @Payload
    struct ClientEvent: ClientEventPayload {
        public init() {}
    }
    
    @Payload
    struct ServerEvent: ServerEventPayload {
        public init() {}
    }
    
    let definition = Land(
        "test-both",
        using: DemoLandState.self
    ) {
        ClientEvents {
            Register(ClientEvent.self)
        }
        ServerEvents {
            Register(ServerEvent.self)
        }
        Rules { }
    }
    
    // Verify both registries are populated
    #expect(definition.clientEventRegistry.registered.count == 1)
    #expect(definition.serverEventRegistry.registered.count == 1)
    
    #expect(definition.clientEventRegistry.registered.first?.eventName == "Client")
    #expect(definition.serverEventRegistry.registered.first?.eventName == "Server")
}

// MARK: - Lifecycle Handler Tests

@Test("OnInitialize executes when Land is created")
func testOnInitialize() async throws {
    let definition = Land(
        "init-test",
        using: DemoLandState.self
    ) {
        Lifetime {
            OnInitialize { (state: inout DemoLandState, ctx: LandContext) in
                state.ticks = 42  // Set initial value
                state.spawnedTaskCount += 1
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices()
    )
    
    // The initialization runs on creation; wait for it directly, not on the clock (#264).
    await keeper.awaitInitialization()

    let state = await keeper.currentState()
    #expect(state.ticks == 42, "OnInitialize should set ticks to 42")
    #expect(state.spawnedTaskCount == 1, "OnInitialize should be called once")
}

@Test("OnInitialize with resolver loads data before handler executes")
func testOnInitializeWithResolver() async throws {
    struct ConfigInfo: ResolverOutput {
        let maxPlayers: Int
        let gameMode: String
    }
    
    struct ConfigResolver: ContextResolver {
        typealias Output = ConfigInfo
        
        static func resolve(ctx: ResolverContext) async throws -> ConfigInfo {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            return ConfigInfo(maxPlayers: 8, gameMode: "battle-royale")
        }
    }
    
    let definition = Land(
        "init-resolver-test",
        using: DemoLandState.self
    ) {
        Lifetime {
            OnInitialize(resolvers: ConfigResolver.self) { (state: inout DemoLandState, ctx: LandContext) in
                // Access resolver output (ConfigResolver -> config)
                if let config: ConfigInfo = ctx.config {
                    state.ticks = config.maxPlayers
                }
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices()
    )
    
    // The initialization, resolver included, awaited directly rather than polled (#264).
    await keeper.awaitInitialization()

    let state = await keeper.currentState()
    #expect(state.ticks == 8, "OnInitialize should use resolver output to set ticks to 8")
}

@Test("OnFinalize executes before Land is destroyed")
func testOnFinalize() async throws {
    let definition = Land(
        "finalize-test",
        using: DemoLandState.self
    ) {
        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.onFinalize = { (state: inout DemoLandState, ctx: LandContext) in
                state.ticks = 999  // Set final value
                state.spawnedTaskCount += 1
            }
            config.destroyWhenEmptyAfter = .milliseconds(10)
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices()
    )
    
    // Join and then leave to trigger shutdown
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    let timer = try await leaveAndCaptureDestroyTimer(keeper, playerID: playerID, clientID: clientID)
    await timer.value

    let state = await keeper.currentState()
    #expect(state.ticks == 999, "OnFinalize should set ticks to 999")
    #expect(state.spawnedTaskCount == 1, "OnFinalize should be called once")
}

@Test("AfterFinalize executes after OnFinalize")
func testAfterFinalize() async throws {
    actor FinalizeOrder {
        var afterFinalizeCalled = false
        func markAfterFinalize() { afterFinalizeCalled = true }
        func getStatus() -> Bool { afterFinalizeCalled }
    }
    let order = FinalizeOrder()
    
    let definition = Land(
        "after-finalize-test",
        using: DemoLandState.self
    ) {
        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.onFinalize = { (state: inout DemoLandState, ctx: LandContext) in
                // OnFinalize is sync, mark it in state
                state.ticks = 100  // Mark that OnFinalize ran
                state.spawnedTaskCount += 1
            }
            config.afterFinalize = { (state: DemoLandState, ctx: LandContext) in
                // Verify OnFinalize already ran (state.ticks should be 100)
                #expect(state.ticks == 100, "OnFinalize should have set ticks to 100")
                #expect(state.spawnedTaskCount == 1, "OnFinalize should have been called before AfterFinalize")
                await order.markAfterFinalize()
            }
            config.destroyWhenEmptyAfter = .milliseconds(10)
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices()
    )
    
    // Join and then leave to trigger shutdown
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    let timer = try await leaveAndCaptureDestroyTimer(keeper, playerID: playerID, clientID: clientID)
    await timer.value
    
    #expect(await order.getStatus(), "AfterFinalize should be called")
    
    // Verify state was modified by OnFinalize
    let finalState = await keeper.currentState()
    #expect(finalState.ticks == 100, "OnFinalize should have modified state")
}

// MARK: - DestroyWhenEmpty Tests

@Test("DestroyWhenEmpty destroys Land after delay when empty")
func testDestroyWhenEmptyDestroysAfterDelay() async throws {
    actor DestroyTracker {
        var afterFinalizeCalled = false
        func markAfterFinalize() { afterFinalizeCalled = true }
        func getStatus() -> Bool { afterFinalizeCalled }
    }
    let tracker = DestroyTracker()
    
    let definition = Land(
        "destroy-test",
        using: DemoLandState.self
    ) {
        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.onFinalize = { (state: inout DemoLandState, ctx: LandContext) in
                state.ticks = 999  // Mark that OnFinalize ran
                state.spawnedTaskCount += 1
            }
            config.afterFinalize = { (state: DemoLandState, ctx: LandContext) in
                // Verify OnFinalize already ran
                #expect(state.ticks == 999, "OnFinalize should have set ticks to 999")
                #expect(state.spawnedTaskCount == 1, "OnFinalize should have been called before AfterFinalize")
                await tracker.markAfterFinalize()
            }
            config.destroyWhenEmptyAfter = .milliseconds(50)
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices()
    )
    
    // Join and then leave to trigger shutdown
    let playerID = PlayerID("test-player")

    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    let timer = try await leaveAndCaptureDestroyTimer(keeper, playerID: playerID, clientID: clientID)
    await timer.value
    
    #expect(await tracker.getStatus(), "AfterFinalize should be called after destroy delay")
    
    // Verify state was modified by OnFinalize
    let finalState = await keeper.currentState()
    #expect(finalState.ticks == 999, "OnFinalize should have modified state")
    #expect(finalState.spawnedTaskCount == 1, "OnFinalize should have been called once")
}

@Test("DestroyWhenEmpty cancels destroy timer when new player joins")
func testDestroyWhenEmptyCancelsOnJoin() async throws {
    let definition = Land(
        "cancel-destroy-test",
        using: DemoLandState.self
    ) {
        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.onFinalize = { (state: inout DemoLandState, ctx: LandContext) in
                state.ticks = 999
                state.spawnedTaskCount += 1
            }
            // Never fires in the test: the join cancels it, checked on the timer itself (#264).
            config.destroyWhenEmptyAfter = .seconds(3600)
        }
        Rules {
            OnJoin { (state: inout DemoLandState, ctx: LandContext) in
                state.players[ctx.playerID] = ctx.playerID.rawValue
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices()
    )
    
    let player1ID = PlayerID("player-1")
    let client1ID = ClientID("client-1")
    let session1ID = SessionID("session-1")
    
    let player2ID = PlayerID("player-2")
    let client2ID = ClientID("client-2")
    let session2ID = SessionID("session-2")
    
    // Join and leave player 1 to start destroy timer
    try await keeper.join(playerID: player1ID, clientID: client1ID, sessionID: session1ID)
    try await keeper.leave(playerID: player1ID, clientID: client1ID)
    let timer = try #require(await keeper.destroyTimerForTesting(), "leaving the last player arms the timer")

    // Join player 2 before destroy timer expires - this should cancel the timer
    try await keeper.join(playerID: player2ID, clientID: client2ID, sessionID: session2ID)
    // Required, not expected: awaiting an uncancelled 1 h timer would hang the test.
    try #require(timer.isCancelled)
    #expect(await keeper.destroyTimerForTesting() == nil)
    await timer.value  // a cancelled timer ends without destroying
    
    // OnFinalize should NOT have been called because player 2 joined
    let stateAfter = await keeper.currentState()
    #expect(stateAfter.spawnedTaskCount == 0, "OnFinalize should NOT be called when new player joins before destroy delay")
    
    // Verify player 2 is still in the land
    let state = await keeper.currentState()
    #expect(state.players[player2ID] != nil, "Player 2 should still be in the land")
}

@Test("DestroyWhenEmpty resets timer when last player leaves again")
func testDestroyWhenEmptyResetsTimerOnRejoin() async throws {
    let definition = Land(
        "reset-timer-test",
        using: DemoLandState.self
    ) {
        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.onFinalize = { (state: inout DemoLandState, ctx: LandContext) in
                state.spawnedTaskCount += 1
            }
            // Never fires in the test: the timers themselves are checked, not the clock (#264).
            // Firing after the delay is covered by the OnFinalize/AfterFinalize tests above.
            config.destroyWhenEmptyAfter = .seconds(3600)
        }
    }

    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices()
    )

    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")

    // First cycle: join and leave arms a timer.
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    try await keeper.leave(playerID: playerID, clientID: clientID)
    let first = try #require(await keeper.destroyTimerForTesting())

    // Rejoin cancels it.
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    // Required, not expected: `first.value` is awaited below, and an uncancelled 1 h timer
    // would hang the test.
    try #require(first.isCancelled)
    #expect(await keeper.destroyTimerForTesting() == nil)

    // Leaving again starts a new timer from the full delay, not the first one.
    try await keeper.leave(playerID: playerID, clientID: clientID)
    let second = try #require(await keeper.destroyTimerForTesting())
    #expect(second != first)
    #expect(!second.isCancelled)
    await first.value
    #expect((await keeper.currentState()).spawnedTaskCount == 0, "the cancelled timer destroyed nothing")
}

@Test("DestroyWhenEmpty does not destroy when players are present")
func testDestroyWhenEmptyDoesNotDestroyWithPlayers() async throws {
    let definition = Land(
        "no-destroy-with-players-test",
        using: DemoLandState.self
    ) {
        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.onFinalize = { (state: inout DemoLandState, ctx: LandContext) in
                state.spawnedTaskCount += 1
            }
            config.destroyWhenEmptyAfter = .milliseconds(50)
        }
        Rules {
            OnJoin { (state: inout DemoLandState, ctx: LandContext) in
                state.players[ctx.playerID] = ctx.playerID.rawValue
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices()
    )
    
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    // Join a player
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)

    // No timer is armed while a player is present (#264: checked directly, not by sleeping).
    #expect(await keeper.destroyTimerForTesting() == nil)
    
    // OnFinalize should NOT be called because player is still present
    let stateAfter = await keeper.currentState()
    #expect(stateAfter.spawnedTaskCount == 0, "OnFinalize should NOT be called when players are present")
    
    // Verify player is still in the land
    let state = await keeper.currentState()
    #expect(state.players[playerID] != nil, "Player should still be in the land")
}

@Test("CanJoin with resolver loads data before validation")
func testCanJoinWithResolver() async throws {
    struct UserLevelInfo: ResolverOutput {
        let userID: String
        let level: Int
    }
    
    struct UserLevelResolver: ContextResolver {
        typealias Output = UserLevelInfo
        
        static func resolve(ctx: ResolverContext) async throws -> UserLevelInfo {
            // Extract userID from session via actionPayload (in this case, we'll use playerID from context)
            let userID = ctx.playerID.rawValue
            // Simulate async lookup
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            return UserLevelInfo(userID: userID, level: 5)
        }
    }
    
    let definition = Land(
        "can-join-resolver-test",
        using: DemoLandState.self
    ) {
        Rules {
            CanJoin(resolvers: UserLevelResolver.self) { (state: DemoLandState, session: PlayerSession, ctx: LandContext) in
                // Check resolver output (UserLevelResolver -> userLevel)
                guard let userLevel: UserLevelInfo = ctx.userLevel else {
                    throw JoinError.custom("Failed to load user level")
                }
                
                // Only allow level 5+ users
                guard userLevel.level >= 5 else {
                    throw JoinError.custom("Level too low")
                }
                
                return .allow(playerID: PlayerID(session.playerID))
            }
            
            OnJoin { (state: inout DemoLandState, ctx: LandContext) in
                state.players[ctx.playerID] = "Player"
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices()
    )
    
    let session = PlayerSession(playerID: "user1")
    let decision = try await keeper.join(
        session: session,
        clientID: ClientID("client1"),
        sessionID: SessionID("session1"),
        services: LandServices()
    )
    
    guard case .allow(let playerID) = decision else {
        Issue.record("Expected join to be allowed")
        return
    }
    
    #expect(playerID.rawValue == "user1")
    let state = await keeper.currentState()
    #expect(state.players.count == 1)
}

/// Leaves, with the destruction held at its start, and returns the destroy timer the leave armed.
/// The hold keeps the timer from firing and clearing itself before it is read, however short its
/// delay; it is released before returning, so awaiting the timer runs the whole destruction.
private func leaveAndCaptureDestroyTimer<State: StateNodeProtocol>(
    _ keeper: LandKeeper<State>,
    playerID: PlayerID,
    clientID: ClientID
) async throws -> Task<Void, Never> {
    let drain = WatermarkGate()
    await keeper.installHolds(HoldRegistry.at(.drainStart) { await drain.enterAndWait() })
    defer { drain.release() }
    try await keeper.leave(playerID: playerID, clientID: clientID)
    return try #require(await keeper.destroyTimerForTesting(), "leaving the last player arms the timer")
}

private struct InitOrderOutput: ResolverOutput {
    let value: Int
}

/// Holds OnInitialize until the test releases `gate`.
private struct InitOrderGatedResolver: ContextResolver {
    typealias Output = InitOrderOutput
    static let gate = WatermarkGate()

    static func resolve(ctx: ResolverContext) async throws -> InitOrderOutput {
        await gate.enterAndWait()
        return InitOrderOutput(value: 1)
    }
}

@Test("OnInitialize completes before tick starts")
func testOnInitializeBeforeTick() async throws {
    let definition = Land(
        "init-tick-order-test",
        using: DemoLandState.self
    ) {
        Lifetime {
            OnInitialize(resolvers: InitOrderGatedResolver.self) { (state: inout DemoLandState, ctx: LandContext) in
                // -1 marks a clean init; a tick that ran before it would have left ticks != 0.
                state.ticks = state.ticks == 0 ? -1 : -1000
            }

            // Hourly: the loop starts (after OnInitialize) but never fires in the test, which
            // steps the first tick itself (#264: no waiting on the clock).
            Tick(every: .seconds(3600)) { (state: inout DemoLandState, ctx: LandContext) in
                // Tick should only increment if OnInitialize already set ticks to -1
                // If ticks is still 0, it means tick started before OnInitialize
                if state.ticks == -1 {
                    state.ticks = 1  // First tick after init
                } else {
                    state.ticks += 1
                }
            }
            StateSync(every: .milliseconds(100)) { (_: DemoLandState, _: LandContext) in
                // Read-only sync callback
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState(),
        services: LandServices()
    )
    
    // While OnInitialize is held in its resolver, the tick loop hasn't started.
    await InitOrderGatedResolver.gate.waitUntilEntered()
    #expect(await keeper.hasTickLoopForTesting() == false, "the tick loop starts only after OnInitialize")
    InitOrderGatedResolver.gate.release()
    await keeper.awaitInitialization()
    #expect(await keeper.hasTickLoopForTesting(), "and it does start then")

    // The first tick: `stepTickOnce` runs one tick turn after the initialization.
    await keeper.stepTickOnce()

    let state = await keeper.currentState()
    #expect(state.ticks == 1, "OnInitialize ran first (-1), then exactly one tick saw its marker")
}
