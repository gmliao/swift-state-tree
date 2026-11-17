// Tests/SwiftStateTreeTests/HandlerWriteTests.swift
//
// #535 §3.7 (#87, D5 (a)): an input handler that throws after mutable access to a `@Sync` field
// ends the land with `.handlerWrite` at stage `.input` and the input's sequence; one that throws
// before any access fails alone, as before.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Land

@StateNodeBuilder
struct HandlerWriteItem: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    init() {}
}

@StateNodeBuilder
struct HandlerWriteState: StateNodeProtocol {
    @Sync(.broadcast) var total: Int = 0
    @Sync(.broadcast) var tags: [String] = []
    @Sync(.broadcast) var item: HandlerWriteItem = HandlerWriteItem()
    /// What ran, in order.
    @Sync(.broadcast) var log: [String] = []
    init() {}
}

/// `kind`: "ok" adds `amount`; "root", "container" and "nested" write that way, then throw;
/// "replace" replaces the whole state, then throws; "validate" throws before any access.
@Payload
struct HandlerWriteAction: ActionPayload {
    typealias Response = HandlerWriteAck
    let kind: String
    let amount: Int
}

@Payload
struct HandlerWriteAck: ResponsePayload {
    let amount: Int
}

struct HandlerWriteError: Error {}

private func makeHandlerWriteLand(tick: Bool) -> LandDefinition<HandlerWriteState> {
    let rules = Rules {
        OnJoin { (state: inout HandlerWriteState, ctx: LandContext) in
            state.log.append("join:\(ctx.playerID.rawValue)")
        }
        OnLeave { (state: inout HandlerWriteState, ctx: LandContext) in
            state.log.append("leave:\(ctx.playerID.rawValue)")
            if ctx.playerID.rawValue == "leaver" { throw HandlerWriteError() }
        }
        HandleAction(HandlerWriteAction.self) {
            (state: inout HandlerWriteState, action: HandlerWriteAction, _: LandContext) in
            switch action.kind {
            case "root":
                state.total += action.amount
                throw HandlerWriteError()
            case "container":
                state.tags.append("t\(action.amount)")
                throw HandlerWriteError()
            case "nested":
                state.item.hp += action.amount
                throw HandlerWriteError()
            case "replace":
                state = HandlerWriteState()
                throw HandlerWriteError()
            case "validate":
                throw HandlerWriteError()
            default:
                state.total += action.amount
                state.log.append("ok:\(action.amount)")
                return HandlerWriteAck(amount: action.amount)
            }
        }
    }
    if tick {
        return Land("handler-write-tick", using: HandlerWriteState.self) {
            rules
            Lifetime {
                // Stepped by hand.
                Tick(every: .seconds(3600)) { (state: inout HandlerWriteState, _: LandContext) in
                    state.log.append("tick")
                }
            }
        }
    }
    return Land("handler-write", using: HandlerWriteState.self) { rules }
}

/// Reports in-turn sync and commits each requested sync phase.
private final class HandlerWriteInTurnTransport: LandKeeperTransport, @unchecked Sendable {
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        InTurnSyncOutput(includeSync ? .committed(clearDirtyFlags: true) : .notRequested)
    }
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")

private func makeKeeper(tick: Bool, inTurn: Bool) async throws -> LandKeeper<HandlerWriteState> {
    let keeper = LandKeeper<HandlerWriteState>(
        definition: makeHandlerWriteLand(tick: tick),
        initialState: HandlerWriteState(),
        autoStartLoops: false,
        transport: inTurn ? HandlerWriteInTurnTransport() : nil
    )
    #expect(await keeper.isUsingInTurnSync() == inTurn)
    try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
    return keeper
}

/// Sends the action and describes its outcome: "ok <amount>", "threw", "closed" or the error.
private func send(_ keeper: LandKeeper<HandlerWriteState>, _ kind: String, _ amount: Int = 1) async -> String {
    do {
        let response = try await keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: HandlerWriteAction.self),
                payload: AnyCodable(HandlerWriteAction(kind: kind, amount: amount))
            ),
            playerID: p1, clientID: c1, sessionID: s1
        )
        let ack = (response.base as? HandlerWriteAck) ?? ((response.base as? AnyCodable)?.base as? HandlerWriteAck)
        return "ok \(ack.map { String($0.amount) } ?? "-")"
    } catch is HandlerWriteError {
        return "threw"
    } catch LandInputRejection.landClosed {
        return "closed"
    } catch {
        return "error \(error)"
    }
}

// MARK: - Keeper

@Suite("A handler that throws after writing synced state ends the land (#535 §3.7)", .timeLimit(.minutes(1)))
struct HandlerWriteTests {
    @Test(
        "a throw after a root, an in-place container or a nested node write ends the land at that input (ON and OFF)",
        arguments: ["root", "container", "nested"], [false, true]
    )
    func writeThenThrowEndsTheLand(kind: String, inTurn: Bool) async throws {
        let keeper = try await makeKeeper(tick: false, inTurn: inTurn)
        #expect(await send(keeper, "ok", 2) == "ok 2")
        #expect(await send(keeper, kind, 3) == "threw", "the failing input's caller gets its error")
        let failure = try #require(keeper.failure)
        #expect(failure.kind == .handlerWrite)
        #expect(failure.position.stage == .input)
        let sequence = try #require(failure.position.sequence)
        #expect(sequence > 0)
        #expect(failure.detail.contains("action \(String(describing: HandlerWriteAction.self))"), "\(failure.detail)")
        #expect(await send(keeper, "ok", 5) == "closed", "the land is closed after it")
    }

    @Test("a throw before any access fails alone; the inputs after it apply (ON and OFF)", arguments: [false, true])
    func throwBeforeAccessFailsAlone(inTurn: Bool) async throws {
        let keeper = try await makeKeeper(tick: false, inTurn: inTurn)
        #expect(await send(keeper, "ok", 2) == "ok 2")
        #expect(await send(keeper, "validate") == "threw")
        #expect(await send(keeper, "ok", 3) == "ok 3")
        #expect(keeper.failure == nil)
        #expect(await keeper.currentState().total == 5)
    }

    @Test("the named gap: a whole-state replacement before the throw isn't counted; the input fails alone (ON and OFF)", arguments: [false, true])
    func wholeStateReplacementIsTheGap(inTurn: Bool) async throws {
        let keeper = try await makeKeeper(tick: false, inTurn: inTurn)
        #expect(await send(keeper, "ok", 2) == "ok 2")
        #expect(await send(keeper, "replace") == "threw")
        #expect(keeper.failure == nil)
        #expect(await keeper.currentState().total == 0, "the replacement is kept, as before")
        #expect(await send(keeper, "ok", 3) == "ok 3")
    }

    @Test("a throwing OnLeave that wrote ends the land (ON and OFF)", arguments: [false, true])
    func throwingOnLeaveEndsTheLand(inTurn: Bool) async throws {
        let keeper = try await makeKeeper(tick: false, inTurn: inTurn)
        let leaver = PlayerID("leaver"), lc = ClientID("lc"), ls = SessionID("ls")
        try await keeper.join(playerID: leaver, clientID: lc, sessionID: ls)
        await #expect(throws: HandlerWriteError.self) {
            try await keeper.leave(playerID: leaver, clientID: lc, sessionID: ls)
        }
        let failure = try #require(keeper.failure)
        #expect(failure.kind == .handlerWrite && failure.position.stage == .input)
        #expect(failure.detail.hasPrefix("OnLeave"), "\(failure.detail)")
    }

    @Test("tick land: the batch's later inputs aren't applied and the tick handler doesn't run (ON and OFF)", arguments: [false, true])
    func tickBatchEndsAtTheFailingInput(inTurn: Bool) async throws {
        let keeper = try await makeKeeper(tick: true, inTurn: inTurn)
        await keeper.stepTickOnce()
        // A tick land queues each action (its caller gets an ACK); one tick applies them in order.
        _ = await send(keeper, "ok", 1)
        _ = await send(keeper, "root", 10)
        _ = await send(keeper, "ok", 2)
        await keeper.stepTickOnce()

        let failure = try #require(keeper.failure)
        #expect(failure.kind == .handlerWrite && failure.position.stage == .input)
        #expect(failure.position.endsInputs == true)
        let state = await keeper.currentState()
        #expect(state.log == ["join:p1", "tick", "ok:1"], "no ok:2 and no second tick: \(state.log)")
        #expect(state.total == 11, "1, then the failing input's write")
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().log == state.log, "no tick handler after it")
        #expect(await send(keeper, "ok", 3) == "closed")
    }

    @Test("tick land: a throw before any access fails alone; the batch and the tick handler continue (ON and OFF)", arguments: [false, true])
    func tickBatchContinuesPastAThrowBeforeAccess(inTurn: Bool) async throws {
        let keeper = try await makeKeeper(tick: true, inTurn: inTurn)
        await keeper.stepTickOnce()
        _ = await send(keeper, "ok", 1)
        _ = await send(keeper, "validate")
        _ = await send(keeper, "ok", 2)
        await keeper.stepTickOnce()

        #expect(keeper.failure == nil)
        #expect(await keeper.currentState().log == ["join:p1", "tick", "ok:1", "ok:2", "tick"])
    }
}

// MARK: - A manual conformance

/// Storage without `@Sync`: a write isn't counted (the named gap).
struct HandlerWriteManualState: StateNodeProtocol {
    var count: Int = 0

    init() {}
    func getSyncFields() -> [SyncFieldInfo] { [] }
    static func getFieldMetadata() -> [FieldMetadata] { [] }
    func validateSyncFields() -> Bool { true }
    func snapshot(for _: PlayerID?, dirtyFields _: Set<String>?) throws -> StateSnapshot { StateSnapshot() }
    func broadcastSnapshot(dirtyFields _: Set<String>?) throws -> StateSnapshot { StateSnapshot() }
    func fullStateSnapshot() throws -> StateSnapshot { StateSnapshot() }
    func isDirty() -> Bool { false }
    func getDirtyFields() -> Set<String> { [] }
    mutating func clearDirty() {}
}

@Suite("A manual conformance keeps today's behavior (#535 §3.7 gap)", .timeLimit(.minutes(1)))
struct HandlerWriteManualConformanceTests {
    @Test("a write to storage without @Sync, then a throw: the input fails alone and the write stays")
    func manualConformance() async throws {
        let land = Land("handler-write-manual", using: HandlerWriteManualState.self) {
            Rules {
                HandleAction(HandlerWriteAction.self) {
                    (state: inout HandlerWriteManualState, action: HandlerWriteAction, _: LandContext) in
                    state.count += action.amount
                    if action.kind != "ok" { throw HandlerWriteError() }
                    return HandlerWriteAck(amount: action.amount)
                }
            }
        }
        let keeper = LandKeeper<HandlerWriteManualState>(
            definition: land,
            initialState: HandlerWriteManualState(),
            autoStartLoops: false
        )
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        func act(_ kind: String, _ amount: Int) async throws {
            _ = try await keeper.handleActionEnvelope(
                ActionEnvelope(
                    typeIdentifier: String(describing: HandlerWriteAction.self),
                    payload: AnyCodable(HandlerWriteAction(kind: kind, amount: amount))
                ),
                playerID: p1, clientID: c1, sessionID: s1
            )
        }
        await #expect(throws: HandlerWriteError.self) { try await act("root", 3) }
        #expect(keeper.failure == nil)
        try await act("ok", 4)
        #expect(await keeper.currentState().count == 7)
    }
}

// MARK: - The thread-local count

@Suite("The @Sync access count is per thread and per call (#535 D5)")
struct SyncWriteAccessTests {
    @Test("a write outside a counted call isn't counted, and leaves nothing installed")
    func outsideACall() throws {
        var state = HandlerWriteState()
        state.total = 1
        #expect(!SyncWriteAccess.isInstalledForTesting)
    }

    @Test("two calls in turn on one thread: the second starts from a clean count")
    func twoCallsInTurn() throws {
        var a = HandlerWriteState()
        var b = HandlerWriteState()
        let first = try accessedThrow {
            a.total = 1
            throw HandlerWriteError()
        }
        #expect(first)
        let second = try accessedThrow {
            _ = b.total
            throw HandlerWriteError()
        }
        #expect(!second, "a read isn't access, and the first call's count is gone")
        b.total = 2
        #expect(!SyncWriteAccess.isInstalledForTesting)
    }

    @Test("a nested call restores the outer count")
    func nestedCall() throws {
        var state = HandlerWriteState()
        let outer = try accessedThrow {
            state.total = 1
            // The inner call accesses nothing and returns; the outer still counts its access.
            let previous = SyncWriteAccess.install()
            #expect(!SyncWriteAccess.accessedSinceInstall())
            SyncWriteAccess.restore(previous)
            throw HandlerWriteError()
        }
        #expect(outer)
        let outerWithoutAccess = try accessedThrow {
            _ = try? accessedThrow {
                state.total = 2
                throw HandlerWriteError()
            }
            throw HandlerWriteError()
        }
        #expect(!outerWithoutAccess, "the inner call's access is its own")
    }

    @Test("the pinned false positive: a temporary @Sync value's write counts")
    func temporarySyncCounts() throws {
        let accessed = try accessedThrow {
            var scratch = HandlerWriteState()
            scratch.total = 1
            throw HandlerWriteError()
        }
        #expect(accessed)
    }
}

/// Runs `body`, which must throw, with the count installed, as `LandKeeper` does: whether it
/// took mutable access first.
private func accessedThrow(_ body: () throws -> Void) throws -> Bool {
    let previous = SyncWriteAccess.install()
    defer { SyncWriteAccess.restore(previous) }
    do {
        try body()
        Issue.record("the body didn't throw")
        return false
    } catch {
        #expect(error is HandlerWriteError)
        return SyncWriteAccess.accessedSinceInstall()
    }
}
