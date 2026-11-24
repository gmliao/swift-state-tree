// Tests/SwiftStateTreeNIOTests/Differential/DiffLand.swift
//
// The land every differential scenario runs (#555): broadcast and per-player state, an event,
// an action that replies in its turn, one whose job is answered later, one whose resolver a
// scenario holds, and two join refusals (`CanJoin` and `maxPlayers`). One definition per land
// kind: a tick land (an hourly tick, so only the runner's steps run it) and a tickless one.

#if DEBUG
import Foundation
import SwiftStateTree
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct DiffState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [String] = []
    @Sync(.broadcast)
    var counter: Int = 0
    @Sync(.broadcast)
    var ticks: Int = 0
    @Sync(.perPlayerSlice())
    var notes: [PlayerID: String] = [:]
}

/// Broadcast to every player by `DiffBumpAction`.
@Payload
struct DiffBumped: ServerEventPayload {
    let by: String
    let counter: Int
}

/// Raises the counter, notes it for the sender and broadcasts `DiffBumped`. Replies in its turn.
@Payload
struct DiffBumpAction: ActionPayload {
    typealias Response = DiffBumpResponse
    let amount: Int
}

@Payload
struct DiffBumpResponse: ResponsePayload {
    let counter: Int
}

/// An action whose resolver waits on the run's gate `key` (`DiffGates`): its job is answered
/// after its turn, by the adapter's response task.
@Payload
struct DiffHeldAction: ActionPayload {
    typealias Response = DiffHeldResponse
    let key: Int
}

@Payload
struct DiffHeldResponse: ResponsePayload {
    let key: Int
}

@PlainData
struct DiffHeldOutput: ResolverOutput {}

struct DiffHeldResolver: ContextResolver {
    typealias Output = DiffHeldOutput
    static func resolve(ctx: ResolverContext) async throws -> DiffHeldOutput {
        let key = (ctx.actionPayload as? DiffHeldAction)?.key ?? -1
        await DiffGates.gate(key).arrive()
        return DiffHeldOutput()
    }
}

/// The resolver gates of the current run, by key. Runs are serialized (both harness suites sit
/// under one serialized parent, `DifferentialHarness`), so one table is enough; the runner resets it at a run's start and opens every gate in its cleanup.
/// The keys are fixed in the scenarios, so they are the same in every run and every process.
enum DiffGates {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gates: [Int: TestGate] = [:]

    static func gate(_ key: Int) -> TestGate {
        lock.withLock {
            if let gate = gates[key] { return gate }
            let gate = TestGate()
            gates[key] = gate
            return gate
        }
    }

    static func reset() {
        lock.withLock { gates = [:] }
    }

    static func openAll() {
        let all = lock.withLock { Array(gates.values) }
        for gate in all { gate.open() }
    }
}

/// The player `CanJoin` refuses.
let diffRefusedPlayer = "refused"
/// The land admits this many players; the next join is refused by `maxPlayers`.
let diffMaxPlayers = 3

enum DiffLandKind: String, CaseIterable, Codable, Sendable, Comparable {
    case tick
    case tickless

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

let diffLandType = "differential"

func makeDiffLand(_ kind: DiffLandKind) -> LandDefinition<DiffState> {
    switch kind {
    case .tick:
        return Land(diffLandType, using: DiffState.self) {
            AccessControl { MaxPlayers(diffMaxPlayers) }
            ServerEvents { Register(DiffBumped.self) }
            Rules {
                CanJoin { _, session, _ in
                    session.playerID == diffRefusedPlayer
                        ? .deny(reason: "refused by CanJoin")
                        : .allow(playerID: PlayerID(session.playerID))
                }
                OnJoin { state, ctx in
                    state.players.append(ctx.playerID.rawValue)
                    state.notes[ctx.playerID] = "joined"
                }
                OnLeave { state, ctx in
                    state.players.removeAll { $0 == ctx.playerID.rawValue }
                    state.notes.removeValue(forKey: ctx.playerID)
                }
                HandleAction(DiffBumpAction.self) { state, action, ctx in
                    state.counter += action.amount
                    state.notes[ctx.playerID] = "bumped \(state.counter)"
                    ctx.emitEvent(DiffBumped(by: ctx.playerID.rawValue, counter: state.counter), to: .all)
                    return DiffBumpResponse(counter: state.counter)
                }
                HandleAction(DiffHeldAction.self, resolvers: { _, action, _ in DiffHeldResolver(key: action.key) }) { state, action, _, ctx in
                    state.notes[ctx.playerID] = "held \(action.key)"
                    return DiffHeldResponse(key: action.key)
                }
            }
            Lifetime {
                // Hourly: with the loops off, only the runner's steps run it.
                Tick(every: .seconds(3600)) { state, _ in
                    state.ticks += 1
                }
            }
        }
    case .tickless:
        return Land(diffLandType, using: DiffState.self) {
            AccessControl { MaxPlayers(diffMaxPlayers) }
            ServerEvents { Register(DiffBumped.self) }
            Rules {
                CanJoin { _, session, _ in
                    session.playerID == diffRefusedPlayer
                        ? .deny(reason: "refused by CanJoin")
                        : .allow(playerID: PlayerID(session.playerID))
                }
                OnJoin { state, ctx in
                    state.players.append(ctx.playerID.rawValue)
                    state.notes[ctx.playerID] = "joined"
                }
                OnLeave { state, ctx in
                    state.players.removeAll { $0 == ctx.playerID.rawValue }
                    state.notes.removeValue(forKey: ctx.playerID)
                }
                HandleAction(DiffBumpAction.self) { state, action, ctx in
                    state.counter += action.amount
                    state.notes[ctx.playerID] = "bumped \(state.counter)"
                    ctx.emitEvent(DiffBumped(by: ctx.playerID.rawValue, counter: state.counter), to: .all)
                    return DiffBumpResponse(counter: state.counter)
                }
                HandleAction(DiffHeldAction.self, resolvers: { _, action, _ in DiffHeldResolver(key: action.key) }) { state, action, _, ctx in
                    state.notes[ctx.playerID] = "held \(action.key)"
                    return DiffHeldResponse(key: action.key)
                }
            }
        }
    }
}

#endif
