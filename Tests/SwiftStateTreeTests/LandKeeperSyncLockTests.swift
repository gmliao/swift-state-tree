// Tests/SwiftStateTreeTests/LandKeeperSyncLockTests.swift
//
// The dirty flags around a sync phase (#68): a committed sync-only turn clears the live state's
// dirty flags in its own turn when its plan diffed every field, the phase sees the flags of
// everything changed since the previous clearing phase, and a mutation after the turn stays
// dirty for the next one. Every sync phase runs inside a keeper turn (#546 L2d), so these drive
// sync-only turns through an in-turn fake transport (`syncTurnNow`).

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test Actions

@Payload
struct IncrementCounterAction: ActionPayload {
    typealias Response = IncrementCounterResponse

    let amount: Int
    let modifier: String
}

@Payload
struct IncrementCounterResponse: ResponsePayload {
    let success: Bool
    let newValue: Int
}

// MARK: - Dirty Flags Clear Tests

@StateNodeBuilder
struct DirtyFlagsTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var round: Int = 0

    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]

    @Sync(.broadcast)
    var score: Int = 0

    public init() {}
}

@StateNodeBuilder
struct NestedDirtyFlagsTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var nestedValue: Int = 0

    public init() {}
}

@StateNodeBuilder
struct ParentDirtyFlagsTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var parentValue: Int = 0

    @Sync(.broadcast)
    var nested: NestedDirtyFlagsTestState = NestedDirtyFlagsTestState()

    public init() {}
}

private func makeDirtyFlagsKeeper() -> LandKeeper<DirtyFlagsTestState> {
    let definition = Land(
        "dirty-flags-test",
        using: DirtyFlagsTestState.self
    ) {
        Rules {
            HandleAction(IncrementCounterAction.self) { (state: inout DirtyFlagsTestState, action: IncrementCounterAction, ctx: LandContext) in
                state.round += action.amount
                state.players[ctx.playerID] = "Player \(action.amount)"
                state.score += action.amount * 10
                return IncrementCounterResponse(success: true, newValue: state.round)
            }
        }
    }
    return LandKeeper<DirtyFlagsTestState>(
        definition: definition,
        initialState: DirtyFlagsTestState()
    )
}

/// An in-turn transport whose sync phase records the dirty fields of the state it was handed and
/// commits with `clearDirtyFlags` (a plan that diffed every synced field, or not).
private final class DirtyFlagsPhaseSpy: LandKeeperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Set<String>] = []
    let clearDirtyFlags: Bool

    init(clearDirtyFlags: Bool = true) { self.clearDirtyFlags = clearDirtyFlags }

    /// The dirty fields of the state each sync phase was handed, in order.
    var dirtyFieldsSeen: [Set<String>] { lock.withLock { seen } }

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
        guard includeSync else { return InTurnSyncOutput(.notRequested) }
        lock.withLock { seen.append(state.getDirtyFields()) }
        return InTurnSyncOutput(.committed(clearDirtyFlags: clearDirtyFlags))
    }
    func waitForWriterDrainForInTurnSync() async {}
}

/// One sync-only turn through `spy`, which must commit.
private func syncOnce<S: StateNodeProtocol>(_ keeper: LandKeeper<S>, via spy: DirtyFlagsPhaseSpy) async {
    let result = await keeper.syncTurnNow(via: spy, reason: .syncNow)
    #expect(result == .committed(clearDirtyFlags: spy.clearDirtyFlags))
}

private func incrementDirtyFlagsState(_ keeper: LandKeeper<DirtyFlagsTestState>, amount: Int) async throws {
    let envelope = ActionEnvelope(
        typeIdentifier: String(describing: IncrementCounterAction.self),
        payload: AnyCodable(IncrementCounterAction(amount: amount, modifier: "test"))
    )
    _ = try await keeper.handleActionEnvelope(
        envelope,
        playerID: PlayerID("player1"),
        clientID: ClientID("client1"),
        sessionID: SessionID("session1")
    )
}

@Test("A committed sync-only turn clears the live dirty flags in its turn; a later mutation stays dirty")
func syncTurnClearsDirtyFlagsAndLaterMutationsStayDirty() async throws {
    let keeper = makeDirtyFlagsKeeper()
    let spy = DirtyFlagsPhaseSpy()
    await keeper.setTransport(spy)
    try await incrementDirtyFlagsState(keeper, amount: 5)
    #expect(await keeper.currentState().getDirtyFields() == ["round", "players", "score"])

    await syncOnce(keeper, via: spy)
    // The phase saw every field changed since the previous clearing phase.
    #expect(spy.dirtyFieldsSeen == [["round", "players", "score"]])
    // The live state is clean once the turn committed.
    #expect(await keeper.currentState().isDirty() == false)

    // A mutation after the turn is for the next phase: it stays dirty.
    try await incrementDirtyFlagsState(keeper, amount: 1)
    #expect(await keeper.currentState().getDirtyFields() == ["round", "players", "score"])
}

@Test("A phase that doesn't diff every field (clearDirtyFlags: false) leaves the dirty flags")
func phaseWithoutClearingLeavesDirtyFlags() async throws {
    let keeper = makeDirtyFlagsKeeper()
    let spy = DirtyFlagsPhaseSpy(clearDirtyFlags: false)
    await keeper.setTransport(spy)
    try await incrementDirtyFlagsState(keeper, amount: 5)

    await syncOnce(keeper, via: spy)
    #expect(spy.dirtyFieldsSeen == [["round", "players", "score"]])
    #expect(await keeper.currentState().getDirtyFields() == ["round", "players", "score"], "live dirty flags must be untouched")
}

@Test("Multiple sync rounds keep all dirty flags cleared")
func multipleSyncRoundsKeepFlagsCleared() async throws {
    let keeper = makeDirtyFlagsKeeper()
    let spy = DirtyFlagsPhaseSpy()
    await keeper.setTransport(spy)
    for round in 1...10 {
        try await incrementDirtyFlagsState(keeper, amount: 5)
        #expect(await keeper.currentState().isDirty() == true, "dirty after the mutation (round \(round))")
        await syncOnce(keeper, via: spy)
        let state = await keeper.currentState()
        #expect(state.isDirty() == false, "clean after the sync turn (round \(round))")
        #expect(state.getDirtyFields().isEmpty, "no dirty fields after the sync turn (round \(round))")
    }
    #expect(spy.dirtyFieldsSeen.count == 10)
}

private func makeNestedDirtyFlagsKeeper() -> LandKeeper<ParentDirtyFlagsTestState> {
    let definition = Land(
        "nested-dirty-flags-test",
        using: ParentDirtyFlagsTestState.self
    ) {
        Rules {
            HandleAction(IncrementCounterAction.self) { (state: inout ParentDirtyFlagsTestState, action: IncrementCounterAction, ctx: LandContext) in
                state.parentValue += action.amount
                state.nested.nestedValue += action.amount * 10
                return IncrementCounterResponse(success: true, newValue: state.parentValue)
            }
        }
    }
    return LandKeeper<ParentDirtyFlagsTestState>(
        definition: definition,
        initialState: ParentDirtyFlagsTestState()
    )
}

private func incrementNested(_ keeper: LandKeeper<ParentDirtyFlagsTestState>) async throws {
    let envelope = ActionEnvelope(
        typeIdentifier: String(describing: IncrementCounterAction.self),
        payload: AnyCodable(IncrementCounterAction(amount: 5, modifier: "test"))
    )
    _ = try await keeper.handleActionEnvelope(
        envelope,
        playerID: PlayerID("player1"),
        clientID: ClientID("client1"),
        sessionID: SessionID("session1")
    )
}

@Test("A sync turn recursively clears nested StateNode dirty flags")
func syncTurnRecursivelyClearsNestedStateNode() async throws {
    let keeper = makeNestedDirtyFlagsKeeper()
    let spy = DirtyFlagsPhaseSpy()
    await keeper.setTransport(spy)
    try await incrementNested(keeper)

    let before = await keeper.currentState()
    #expect(before.getDirtyFields().contains("parentValue"))
    #expect(before.getDirtyFields().contains("nested"))
    #expect(before.nested.getDirtyFields().contains("nestedValue"))

    await syncOnce(keeper, via: spy)
    let after = await keeper.currentState()
    #expect(after.isDirty() == false, "parent clean after the sync turn")
    #expect(after.getDirtyFields().isEmpty)
    #expect(after.nested.isDirty() == false, "nested clean after the sync turn")
    #expect(after.nested.getDirtyFields().isEmpty)
}

@Test("Multiple sync rounds with nested StateNode should recursively clear all dirty flags")
func multipleSyncRoundsClearNestedFlags() async throws {
    let keeper = makeNestedDirtyFlagsKeeper()
    let spy = DirtyFlagsPhaseSpy()
    await keeper.setTransport(spy)
    for round in 1...5 {
        try await incrementNested(keeper)
        let before = await keeper.currentState()
        #expect(before.isDirty() == true, "parent dirty (round \(round))")
        #expect(before.nested.isDirty() == true, "nested dirty (round \(round))")
        await syncOnce(keeper, via: spy)
        let after = await keeper.currentState()
        #expect(after.isDirty() == false, "parent clean (round \(round))")
        #expect(after.nested.isDirty() == false, "nested clean (round \(round))")
        #expect(after.nested.getDirtyFields().isEmpty, "nested has no dirty fields (round \(round))")
    }
}
