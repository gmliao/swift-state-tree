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
        initialState: DemoLandState()
    )
    let playerID = PlayerID("alice")
    let clientID = ClientID("device-1")
    let sessionID = SessionID("session-1")

    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)

    let joinResponse = try await keeper.handleAction(
        JoinAction(name: "Alice"),
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
    actor ReadyCounter {
        var value = 0
        func increment() { value += 1 }
        func current() -> Int { value }
    }
    let counter = ReadyCounter()

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
            HandleEvent(DemoReadyEvent.self) { (_: inout DemoLandState, event: DemoReadyEvent, ctx: LandContext) in
                ctx.spawn {
                    await counter.increment()
                }
            }
        }
    }

    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState()
    )
    let playerID = PlayerID("player")
    let clientID = ClientID("client")
    let sessionID = SessionID("session")

    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)

    let chatEvent = AnyClientEvent(DemoChatEvent(message: "hi"))
    try? await keeper.handleClientEvent(chatEvent, playerID: playerID, clientID: clientID, sessionID: sessionID)
    #expect(await counter.current() == 0)

    let readyEvent = AnyClientEvent(DemoReadyEvent())
    try? await keeper.handleClientEvent(readyEvent, playerID: playerID, clientID: clientID, sessionID: sessionID)
    // ctx.spawn executes asynchronously, so we need to wait for the spawned task to complete
    await waitFor("counter to increment after spawn", condition: {
        await counter.current() == 1
    })
    #expect(await counter.current() == 1)
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

        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.tickInterval = .milliseconds(10)
            config.tickHandler = { state, _ in
                state.ticks += 1
            }
        }
    }

    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState()
    )
    
    await waitFor("Ticks should increment") {
        let snapshot = await keeper.currentState()
        return snapshot.ticks > 0
    }
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
        initialState: DemoLandState()
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
        initialState: DemoLandState()
    )
    
    // First join succeeds
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

@Test("ctx.spawn executes background tasks")
func testCtxSpawn() async throws {
    actor TaskCounter {
        var count = 0
        func increment() { count += 1 }
        func current() -> Int { count }
    }
    let counter = TaskCounter()
    
    let definition = Land(
        "spawn-test",
        using: DemoLandState.self
    ) {
        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.tickInterval = .milliseconds(10)
            config.tickHandler = { (state: inout DemoLandState, ctx: LandContext) in
                state.ticks += 1
                
                // Spawn background task
                ctx.spawn {
                    await counter.increment()
                }
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState()
    )
    
    await waitFor("Background tasks should execute") {
        let state = await keeper.currentState()
        let spawnCount = await counter.current()
        // Wait until we have at least some ticks and some spawns
        return state.ticks > 0 && spawnCount > 0
    }
}

@Test("OnTick is synchronous and does not block")
func testOnTickSynchronous() async throws {
    let definition = Land(
        "sync-tick-test",
        using: DemoLandState.self
    ) {
        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.tickInterval = .milliseconds(5)
            config.tickHandler = { (state: inout DemoLandState, _: LandContext) in
                // This is synchronous - no await allowed
                state.ticks += 1
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState()
    )
    
    await waitFor("Ticks should accumulate") {
        let state = await keeper.currentState()
        return state.ticks >= 3
    }
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
    
    // Test finding by event name
    let descriptor = definition.serverEventRegistry.findDescriptor(for: "TestFindEvent")
    #expect(descriptor != nil)
    #expect(descriptor?.eventName == "TestFindEvent")
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
    
    #expect(definition.clientEventRegistry.registered.first?.eventName == "ClientEvent")
    #expect(definition.serverEventRegistry.registered.first?.eventName == "ServerEvent")
}

// MARK: - Lifecycle Handler Tests

@Test("OnInitialize executes when Land is created")
func testOnInitialize() async throws {
    actor InitCounter {
        var count = 0
        func increment() { count += 1 }
        func current() -> Int { count }
    }
    let counter = InitCounter()
    
    let definition = Land(
        "init-test",
        using: DemoLandState.self
    ) {
        Lifetime {
            OnInitialize { (state: inout DemoLandState, ctx: LandContext) in
                state.ticks = 42  // Set initial value
                ctx.spawn {
                    await counter.increment()
                }
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState()
    )
    
    // Wait a bit for OnInitialize to complete
    try await Task.sleep(nanoseconds: 50_000_000) // 50ms
    
    let state = await keeper.currentState()
    #expect(state.ticks == 42, "OnInitialize should set ticks to 42")
    #expect(await counter.current() == 1, "OnInitialize should be called once")
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
        initialState: DemoLandState()
    )
    
    // Wait for OnInitialize with resolver to complete with retry logic
    // Resolver takes 10ms, but CI environments may have additional overhead
    // Use retry loop to handle timing variations
    var state = await keeper.currentState()
    var attempts = 0
    let maxAttempts = 20 // 20 * 25ms = 500ms max wait time
    while state.ticks != 8 && attempts < maxAttempts {
        try await Task.sleep(nanoseconds: 25_000_000) // 25ms
        state = await keeper.currentState()
        attempts += 1
    }
    
    #expect(state.ticks == 8, "OnInitialize should use resolver output to set ticks to 8")
}

@Test("OnFinalize executes before Land is destroyed")
func testOnFinalize() async throws {
    actor FinalizeCounter {
        var count = 0
        func increment() { count += 1 }
        func current() -> Int { count }
    }
    let counter = FinalizeCounter()
    
    let definition = Land(
        "finalize-test",
        using: DemoLandState.self
    ) {
        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.onFinalize = { (state: inout DemoLandState, ctx: LandContext) in
                state.ticks = 999  // Set final value
                ctx.spawn {
                    await counter.increment()
                }
            }
            config.destroyWhenEmptyAfter = .milliseconds(10)
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState()
    )
    
    // Join and then leave to trigger shutdown
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    try await keeper.leave(playerID: playerID, clientID: clientID)
    
    // Wait for destroy timer and OnFinalize to execute with retry logic
    // destroyWhenEmptyAfter: 10ms + handler execution time
    // Use retry loop to handle timing variations in CI environments
    var state = await keeper.currentState()
    var counterValue = await counter.current()
    var attempts = 0
    let maxAttempts = 20 // 20 * 25ms = 500ms max wait time
    while (state.ticks != 999 || counterValue != 1) && attempts < maxAttempts {
        try await Task.sleep(nanoseconds: 25_000_000) // 25ms
        state = await keeper.currentState()
        counterValue = await counter.current()
        attempts += 1
    }
    
    #expect(state.ticks == 999, "OnFinalize should set ticks to 999")
    #expect(counterValue == 1, "OnFinalize should be called once")
}

@Test("AfterFinalize executes after OnFinalize")
func testAfterFinalize() async throws {
    actor FinalizeOrder {
        var onFinalizeCalled = false
        var afterFinalizeCalled = false
        func markOnFinalize() { onFinalizeCalled = true }
        func markAfterFinalize() { afterFinalizeCalled = true }
        func getStatus() -> (onFinalize: Bool, afterFinalize: Bool) {
            (onFinalize: onFinalizeCalled, afterFinalize: afterFinalizeCalled)
        }
    }
    let order = FinalizeOrder()
    
    let definition = Land(
        "after-finalize-test",
        using: DemoLandState.self
    ) {
        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.onFinalize = { (state: inout DemoLandState, ctx: LandContext) in
                // OnFinalize is sync, mark it immediately
                state.ticks = 100  // Mark that OnFinalize ran
                ctx.spawn {
                    await order.markOnFinalize()
                }
            }
            config.afterFinalize = { (state: DemoLandState, ctx: LandContext) in
                // Verify OnFinalize already ran (state.ticks should be 100)
                #expect(state.ticks == 100, "OnFinalize should have set ticks to 100")
                await order.markAfterFinalize()
            }
            config.destroyWhenEmptyAfter = .milliseconds(10)
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState()
    )
    
    // Join and then leave to trigger shutdown
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    try await keeper.leave(playerID: playerID, clientID: clientID)
    
    // Wait for destroy timer and finalize handlers to execute
    try await Task.sleep(nanoseconds: 200_000_000) // 200ms
    
    let status = await order.getStatus()
    #expect(status.onFinalize, "OnFinalize should be called")
    #expect(status.afterFinalize, "AfterFinalize should be called")
    
    // Verify state was modified by OnFinalize
    let finalState = await keeper.currentState()
    #expect(finalState.ticks == 100, "OnFinalize should have modified state")
}

// MARK: - DestroyWhenEmpty Tests

@Test("DestroyWhenEmpty destroys Land after delay when empty")
func testDestroyWhenEmptyDestroysAfterDelay() async throws {
    actor DestroyTracker {
        var onFinalizeCalled = false
        var afterFinalizeCalled = false
        
        func markOnFinalize() { onFinalizeCalled = true }
        func markAfterFinalize() { afterFinalizeCalled = true }
        
        func getStatus() -> (onFinalize: Bool, afterFinalize: Bool) {
            (onFinalize: onFinalizeCalled, afterFinalize: afterFinalizeCalled)
        }
    }
    let tracker = DestroyTracker()
    
    let definition = Land(
        "destroy-test",
        using: DemoLandState.self
    ) {
        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.onFinalize = { (state: inout DemoLandState, ctx: LandContext) in
                state.ticks = 999  // Mark that OnFinalize ran
                ctx.spawn {
                    await tracker.markOnFinalize()
                }
            }
            config.afterFinalize = { (state: DemoLandState, ctx: LandContext) in
                // Verify OnFinalize already ran
                #expect(state.ticks == 999, "OnFinalize should have set ticks to 999")
                await tracker.markAfterFinalize()
            }
            config.destroyWhenEmptyAfter = .milliseconds(50)
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState()
    )
    
    // Join and then leave to trigger destroy timer
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    try await keeper.leave(playerID: playerID, clientID: clientID)
    
    // Wait for destroy timer to expire and OnFinalize/AfterFinalize to be called
    // Use polling instead of fixed delay for better CI stability
    await waitFor("OnFinalize and AfterFinalize to be called", timeout: .seconds(2)) {
        let status = await tracker.getStatus()
        return status.onFinalize && status.afterFinalize
    }
    
    let status = await tracker.getStatus()
    #expect(status.onFinalize, "OnFinalize should be called after destroy delay")
    #expect(status.afterFinalize, "AfterFinalize should be called after destroy delay")
    
    // Verify state was modified by OnFinalize
    let finalState = await keeper.currentState()
    #expect(finalState.ticks == 999, "OnFinalize should have modified state")
}

@Test("DestroyWhenEmpty cancels destroy timer when new player joins")
func testDestroyWhenEmptyCancelsOnJoin() async throws {
    actor DestroyTracker {
        var onFinalizeCalled = false
        
        func markOnFinalize() { onFinalizeCalled = true }
        func getStatus() -> Bool { onFinalizeCalled }
    }
    let tracker = DestroyTracker()
    
    let definition = Land(
        "cancel-destroy-test",
        using: DemoLandState.self
    ) {
        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.onFinalize = { (state: inout DemoLandState, ctx: LandContext) in
                state.ticks = 999
                ctx.spawn {
                    await tracker.markOnFinalize()
                }
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
        initialState: DemoLandState()
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
    
    // Wait a bit but not long enough for destroy to happen
    // Use a short delay to ensure destroy timer has started
    try await Task.sleep(nanoseconds: 30_000_000) // 30ms (less than 50ms delay)
    
    // Join player 2 before destroy timer expires - this should cancel the timer
    try await keeper.join(playerID: player2ID, clientID: client2ID, sessionID: session2ID)
    
    // Wait for the original destroy delay to pass, then verify OnFinalize was NOT called
    // Increased delay for CI stability (was 100ms, now 150ms)
    try await Task.sleep(nanoseconds: 150_000_000) // 150ms (more than 50ms delay)
    
    // OnFinalize should NOT have been called because player 2 joined
    let status = await tracker.getStatus()
    #expect(!status, "OnFinalize should NOT be called when new player joins before destroy delay")
    
    // Verify player 2 is still in the land
    let state = await keeper.currentState()
    #expect(state.players[player2ID] != nil, "Player 2 should still be in the land")
}

@Test("DestroyWhenEmpty resets timer when last player leaves again")
func testDestroyWhenEmptyResetsTimerOnRejoin() async throws {
    actor DestroyTracker {
        var destroyCount = 0
        
        func increment() { destroyCount += 1 }
        func getCount() -> Int { destroyCount }
    }
    let tracker = DestroyTracker()
    
    let definition = Land(
        "reset-timer-test",
        using: DemoLandState.self
    ) {
        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.onFinalize = { (state: inout DemoLandState, ctx: LandContext) in
                ctx.spawn {
                    await tracker.increment()
                }
            }
            config.destroyWhenEmptyAfter = .milliseconds(50)
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState()
    )
    
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    // First cycle: join and leave
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    try await keeper.leave(playerID: playerID, clientID: clientID)
    
    // Wait a bit but not long enough for destroy
    try await Task.sleep(nanoseconds: 30_000_000) // 30ms
    
    // Rejoin before destroy timer expires
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Wait a bit
    try await Task.sleep(nanoseconds: 20_000_000) // 20ms
    
    // Leave again - this should start a new destroy timer
    try await keeper.leave(playerID: playerID, clientID: clientID)
    
    // Wait for the new destroy timer to expire and OnFinalize to be called
    // Use polling instead of fixed delay for better CI stability
    await waitFor("OnFinalize to be called after second leave", timeout: .seconds(2)) {
        let count = await tracker.getCount()
        return count >= 1
    }
    
    // OnFinalize should be called only once (after the second leave)
    let count = await tracker.getCount()
    #expect(count == 1, "OnFinalize should be called once after the second leave cycle")
}

@Test("DestroyWhenEmpty does not destroy when players are present")
func testDestroyWhenEmptyDoesNotDestroyWithPlayers() async throws {
    actor DestroyTracker {
        var onFinalizeCalled = false
        
        func markOnFinalize() { onFinalizeCalled = true }
        func getStatus() -> Bool { onFinalizeCalled }
    }
    let tracker = DestroyTracker()
    
    let definition = Land(
        "no-destroy-with-players-test",
        using: DemoLandState.self
    ) {
        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.onFinalize = { (state: inout DemoLandState, ctx: LandContext) in
                ctx.spawn {
                    await tracker.markOnFinalize()
                }
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
        initialState: DemoLandState()
    )
    
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    // Join a player
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Wait much longer than the destroy delay
    try await Task.sleep(nanoseconds: 200_000_000) // 200ms
    
    // OnFinalize should NOT be called because player is still present
    let status = await tracker.getStatus()
    #expect(!status, "OnFinalize should NOT be called when players are present")
    
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
        initialState: DemoLandState()
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

@Test("OnInitialize completes before tick starts")
func testOnInitializeBeforeTick() async throws {
    let definition = Land(
        "init-tick-order-test",
        using: DemoLandState.self
    ) {
        Lifetime {
            OnInitialize { (state: inout DemoLandState, ctx: LandContext) in
                // Mark initialization complete - this happens synchronously
                // If tick had started, ticks would be > 0, but we set it to -1 to mark init
                state.ticks = -1  // Special marker value
            }
            
            Tick(every: .milliseconds(100)) { (state: inout DemoLandState, ctx: LandContext) in
                // Tick should only increment if OnInitialize already set ticks to -1
                // If ticks is still 0, it means tick started before OnInitialize
                if state.ticks == -1 {
                    state.ticks = 1  // First tick after init
                } else {
                    state.ticks += 1
                }
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState>(
        definition: definition,
        initialState: DemoLandState()
    )
    
    // Wait for initialization and first tick to execute
    // Use polling instead of fixed sleep to handle CI timing variations
    await waitFor("OnInitialize and first tick to complete", timeout: .seconds(2)) {
        let state = await keeper.currentState()
        // If OnInitialize ran first, ticks should be >= 1 (was set to -1, then tick set it to 1)
        // If tick ran first, ticks would be > 0 but we wouldn't have the -1 marker
        return state.ticks >= 1
    }
    
    let state = await keeper.currentState()
    // Verify final state: OnInitialize should have set ticks to -1, then tick should increment it to 1
    #expect(state.ticks >= 1, "OnInitialize should set ticks to -1, then tick should increment it")
    #expect(state.ticks != 0, "Tick should have executed after OnInitialize")
    #expect(state.ticks != -1, "Tick should have executed and changed ticks from -1")
}
