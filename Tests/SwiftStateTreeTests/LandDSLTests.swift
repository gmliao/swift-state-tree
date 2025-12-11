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

    await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)

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

    await keeper.leave(playerID: playerID, clientID: clientID)

    let state = await keeper.currentState()
    #expect(state.players[playerID] == nil)
    #expect(state.readyPlayers.contains(playerID))
}

@Test("LandKeeper enforces allowed client events")
func testLandKeeperAllowedEvents() async {
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

    await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)

    let chatEvent = AnyClientEvent(DemoChatEvent(message: "hi"))
    try? await keeper.handleClientEvent(chatEvent, playerID: playerID, clientID: clientID, sessionID: sessionID)
    #expect(await counter.current() == 0)

    let readyEvent = AnyClientEvent(DemoReadyEvent())
    try? await keeper.handleClientEvent(readyEvent, playerID: playerID, clientID: clientID, sessionID: sessionID)
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
            CanJoin { (state: DemoLandState, session: PlayerSession, _: LandContext) async throws in
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
            CanJoin { (state: DemoLandState, session: PlayerSession, _: LandContext) async throws in
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
