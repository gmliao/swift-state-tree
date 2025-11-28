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

struct JoinAction: ActionPayload {
    typealias Response = JoinResult
    let name: String
}

struct JoinResult: Codable, Sendable {
    let ok: Bool
}

enum DemoClientEvents: ClientEventPayload, Hashable {
    case ready
    case chat(String)
}

enum DemoServerEvents: ServerEventPayload {
    case message(String)
}

@Test("Land builder collects access control and allowed events")
func testLandBuilderCollectsNodes() {
    let definition = Land(
        "demo",
        using: DemoLandState.self,
        clientEvents: DemoClientEvents.self,
        serverEvents: DemoServerEvents.self
    ) {
        AccessControl {
            AllowPublic(false)
            MaxPlayers(4)
        }

        Rules {
            AllowedClientEvents {
                DemoClientEvents.ready
            }

            Action(JoinAction.self) { (state: inout DemoLandState, action: JoinAction, ctx: LandContext) in
                state.players[ctx.playerID] = action.name
                return JoinResult(ok: true)
            }

            On(DemoClientEvents.self) { (state: inout DemoLandState, event: DemoClientEvents, ctx: LandContext) in
                if case .ready = event {
                    state.readyPlayers.insert(ctx.playerID)
                }
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
    #expect(definition.config.allowedClientEvents.count == 1)
    #expect(definition.lifetimeHandlers.tickInterval == .milliseconds(50))
    #expect(definition.lifetimeHandlers.destroyWhenEmptyAfter == .seconds(5))
}

@Test("LandKeeper handles joins, actions, and events")
func testLandKeeperLifecycle() async throws {
    let definition = Land(
        "demo-lifecycle",
        using: DemoLandState.self,
        clientEvents: DemoClientEvents.self,
        serverEvents: DemoServerEvents.self
    ) {
        Rules {
            OnJoin { (state: inout DemoLandState, ctx: LandContext) in
                state.players[ctx.playerID] = "Guest"
            }

            OnLeave { (state: inout DemoLandState, ctx: LandContext) in
                state.players.removeValue(forKey: ctx.playerID)
            }

            Action(JoinAction.self) { (state: inout DemoLandState, action: JoinAction, ctx: LandContext) in
                state.players[ctx.playerID] = action.name
                return JoinResult(ok: true)
            }

            On(DemoClientEvents.self) { (state: inout DemoLandState, event: DemoClientEvents, ctx: LandContext) in
                if case .ready = event {
                    state.readyPlayers.insert(ctx.playerID)
                }
            }
        }
    }

    let keeper = LandKeeper<DemoLandState, DemoClientEvents, DemoServerEvents>(
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

    await keeper.handleClientEvent(DemoClientEvents.ready, playerID: playerID, clientID: clientID, sessionID: sessionID)

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
        using: DemoLandState.self,
        clientEvents: DemoClientEvents.self,
        serverEvents: DemoServerEvents.self
    ) {
        Rules {
            AllowedClientEvents {
                DemoClientEvents.ready
            }

            On(DemoClientEvents.self) { (_: inout DemoLandState, event: DemoClientEvents, _: LandContext) in
                if case .ready = event {
                    await counter.increment()
                }
            }
        }
    }

    let keeper = LandKeeper<DemoLandState, DemoClientEvents, DemoServerEvents>(
        definition: definition,
        initialState: DemoLandState()
    )
    let playerID = PlayerID("player")
    let clientID = ClientID("client")
    let sessionID = SessionID("session")

    await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)

    await keeper.handleClientEvent(DemoClientEvents.chat("hi"), playerID: playerID, clientID: clientID, sessionID: sessionID)
    #expect(await counter.current() == 0)

    await keeper.handleClientEvent(DemoClientEvents.ready, playerID: playerID, clientID: clientID, sessionID: sessionID)
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
        using: DemoLandState.self,
        clientEvents: DemoClientEvents.self,
        serverEvents: DemoServerEvents.self
    ) {
        Rules { }

        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.tickInterval = .milliseconds(10)
            config.tickHandler = { state, _ in
                state.ticks += 1
            }
        }
    }

    let keeper = LandKeeper<DemoLandState, DemoClientEvents, DemoServerEvents>(
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
        using: DemoLandState.self,
        clientEvents: DemoClientEvents.self,
        serverEvents: DemoServerEvents.self
    ) {
        Rules {
            CanJoin { (state: DemoLandState, session: PlayerSession, _: LandContext) async throws in
                // Allow if room not full
                guard state.players.count < 2 else {
                    throw JoinError.roomIsFull
                }
                return .allow(playerID: PlayerID(session.userID))
            }
            
            OnJoin { (state: inout DemoLandState, ctx: LandContext) in
                state.players[ctx.playerID] = "Player"
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState, DemoClientEvents, DemoServerEvents>(
        definition: definition,
        initialState: DemoLandState()
    )
    
    let session1 = PlayerSession(userID: "user1")
    let decision1 = try await keeper.join(
        session: session1,
        clientID: ClientID("client1"),
        sessionID: SessionID("session1")
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
        using: DemoLandState.self,
        clientEvents: DemoClientEvents.self,
        serverEvents: DemoServerEvents.self
    ) {
        Rules {
            CanJoin { (state: DemoLandState, session: PlayerSession, _: LandContext) async throws in
                // Room full
                guard state.players.count < 1 else {
                    throw JoinError.roomIsFull
                }
                return .allow(playerID: PlayerID(session.userID))
            }
            
            OnJoin { (state: inout DemoLandState, ctx: LandContext) in
                state.players[ctx.playerID] = "Player"
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState, DemoClientEvents, DemoServerEvents>(
        definition: definition,
        initialState: DemoLandState()
    )
    
    // First join succeeds
    let session1 = PlayerSession(userID: "user1")
    _ = try await keeper.join(
        session: session1,
        clientID: ClientID("client1"),
        sessionID: SessionID("session1")
    )
    
    // Second join should fail
    let session2 = PlayerSession(userID: "user2")
    do {
        _ = try await keeper.join(
            session: session2,
            clientID: ClientID("client2"),
            sessionID: SessionID("session2")
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
        using: DemoLandState.self,
        clientEvents: DemoClientEvents.self,
        serverEvents: DemoServerEvents.self
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
    
    let keeper = LandKeeper<DemoLandState, DemoClientEvents, DemoServerEvents>(
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
        using: DemoLandState.self,
        clientEvents: DemoClientEvents.self,
        serverEvents: DemoServerEvents.self
    ) {
        Lifetime { (config: inout LifetimeConfig<DemoLandState>) in
            config.tickInterval = .milliseconds(5)
            config.tickHandler = { (state: inout DemoLandState, _: LandContext) in
                // This is synchronous - no await allowed
                state.ticks += 1
            }
        }
    }
    
    let keeper = LandKeeper<DemoLandState, DemoClientEvents, DemoServerEvents>(
        definition: definition,
        initialState: DemoLandState()
    )
    
    await waitFor("Ticks should accumulate") {
        let state = await keeper.currentState()
        return state.ticks >= 3
    }
}
