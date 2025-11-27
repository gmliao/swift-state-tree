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
    var ticked = false
    for _ in 0..<10 {
        let snapshot = await keeper.currentState()
        if snapshot.ticks > 0 {
            ticked = true
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(ticked)
}

