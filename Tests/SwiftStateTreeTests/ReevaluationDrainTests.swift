// Tests/SwiftStateTreeTests/ReevaluationDrainTests.swift
//
// A reevaluation keeper replays recorded inputs and must not run destroy handlers (DestroyWhenEmpty,
// OnFinalize, AfterFinalize): the record holds no finalize event, so there is nothing to verify
// them against, and their resolvers and AfterFinalize could reach outside services (#826).

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - State

@StateNodeBuilder
struct ReevalDrainState: StateNodeProtocol {
    @Sync(.broadcast)
    var log: [String] = []

    public init() {}
}

// MARK: - Counter box + global keyed registry

/// Mutable counter that tracks whether destroy-handler code ran.
final class ReevalDrainBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var finalizeResolverCount = 0
    var afterFinalizeRan = false

    func increment() { lock.withLock { finalizeResolverCount += 1 } }
}

/// Integer-keyed registry so the @PlainData resolver (which must be Codable) can reach a box.
private nonisolated(unsafe) var _drainBoxes: [Int: ReevalDrainBox] = [:]
private nonisolated(unsafe) var _drainBoxNext = 0
private let _drainBoxLock = NSLock()

private func registerBox(_ box: ReevalDrainBox) -> Int {
    _drainBoxLock.withLock {
        let key = _drainBoxNext
        _drainBoxNext += 1
        _drainBoxes[key] = box
        return key
    }
}
private func lookupBox(_ key: Int) -> ReevalDrainBox? {
    _drainBoxLock.withLock { _drainBoxes[key] }
}

// MARK: - Resolver

@PlainData
struct ReevalDrainOutput: ResolverOutput {
    let value: Int
}

/// Increments `box.finalizeResolverCount` when it runs.
@PlainData
struct CountingFinalizeResolver: Resolver {
    typealias Dependencies = NoServices
    typealias Output = ReevalDrainOutput

    let boxKey: Int

    func resolve(_ deps: NoServices) async throws -> ReevalDrainOutput {
        lookupBox(boxKey)?.increment()
        return ReevalDrainOutput(value: 1)
    }
}

// MARK: - Transport stub

private final class ReevalDrainTransport: LandKeeperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var destroyedCount = 0

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async { lock.withLock { destroyedCount += 1 } }
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { false }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        InTurnSyncOutput(includeSync ? .committed(clearDirtyFlags: true) : .notRequested)
    }
    func waitForWriterDrainForInTurnSync() async {}
}

// MARK: - Helpers

private func makeReevalDrainDefinition(box: ReevalDrainBox) -> LandDefinition<ReevalDrainState> {
    let key = registerBox(box)
    return Land("reeval-drain", using: ReevalDrainState.self) {
        Rules {
            OnJoin { state, ctx in
                state.log.append("join:\(ctx.playerID.rawValue)")
            }
        }
        Lifetime {
            DestroyWhenEmpty(after: .seconds(3600)) { state, _ in
                state.log.append("destroyWhenEmpty")
            }
            OnFinalize(resolvers: { _, _ in CountingFinalizeResolver(boxKey: key) }) { state, _, _ in
                state.log.append("finalize")
            }
            AfterFinalize { _, _ in
                box.afterFinalizeRan = true
            }
        }
    }
}

private func recordedJoin(player: String, sequence: Int64, tickId: Int64) -> ReevaluationRecordedLifecycleEvent {
    ReevaluationRecordedLifecycleEvent(
        kind: "join",
        sequence: sequence,
        tickId: tickId,
        playerID: player,
        clientID: "c-\(player)",
        sessionID: "s-\(player)",
        deviceID: nil,
        isGuest: nil,
        metadata: [:],
        resolverOutputs: [:],
        resolvedAtTick: tickId - 1
    )
}

private func makeLiveKeeper(
    definition: LandDefinition<ReevalDrainState>
) -> LandKeeper<ReevalDrainState> {
    LandKeeper<ReevalDrainState>(
        definition: definition,
        initialState: ReevalDrainState(),
        mode: .live,
        autoStartLoops: false,
        landID: "reeval-drain:live"
    )
}

private func makeReevalKeeper(
    definition: LandDefinition<ReevalDrainState>,
    transport: ReevalDrainTransport
) async -> LandKeeper<ReevalDrainState> {
    let metadata = ReevaluationRecordMetadata(
        landID: "reeval-drain:replay",
        landType: "reeval-drain",
        createdAt: Date(timeIntervalSince1970: 0),
        metadata: [:],
        landDefinitionID: "reeval-drain",
        version: ReevaluationRecordVersion.current
    )
    let frames: [ReevaluationTickFrame] = [
        ReevaluationTickFrame(
            tickId: 0,
            actions: [],
            clientEvents: [],
            lifecycleEvents: [recordedJoin(player: "p1", sequence: 1, tickId: 0)]
        ),
    ]
    let keeper = LandKeeper<ReevalDrainState>(
        definition: definition,
        initialState: ReevalDrainState(),
        mode: .reevaluation,
        reevaluationSource: JSONReevaluationSource(metadata: metadata, frames: frames),
        autoStartLoops: false,
        landID: "reeval-drain:replay"
    )
    await keeper.setTransport(transport)
    return keeper
}

// MARK: - Tests

@Suite("Reevaluation keeper drain runs no land code (#826)", .timeLimit(.minutes(1)))
struct ReevaluationDrainTests {
    @Test("Reevaluation keeper: OnFinalize resolver is never called")
    func finalizeResolverNotCalled() async throws {
        let box = ReevalDrainBox()
        let definition = makeReevalDrainDefinition(box: box)
        let transport = ReevalDrainTransport()
        let keeper = await makeReevalKeeper(definition: definition, transport: transport)

        await keeper.stepTickOnce()
        await keeper.forceShutdown()

        #expect(box.finalizeResolverCount == 0, "OnFinalize resolver must not run in a reevaluation keeper")
    }

    @Test("Reevaluation keeper: OnFinalize handler, DestroyWhenEmpty, and AfterFinalize do not run")
    func finalizeHandlersNotRun() async throws {
        let box = ReevalDrainBox()
        let definition = makeReevalDrainDefinition(box: box)
        let transport = ReevalDrainTransport()
        let keeper = await makeReevalKeeper(definition: definition, transport: transport)

        await keeper.stepTickOnce()
        await keeper.forceShutdown()

        let log = await keeper.currentState().log
        #expect(!log.contains("finalize"), "OnFinalize must not append 'finalize' in a reevaluation keeper")
        #expect(!log.contains("destroyWhenEmpty"), "DestroyWhenEmpty must not append in a reevaluation keeper")
        #expect(!box.afterFinalizeRan, "AfterFinalize must not run in a reevaluation keeper")
    }

    @Test("Reevaluation keeper: transport still receives onLandDestroyed after drain")
    func transportDestroyedStillFires() async throws {
        let box = ReevalDrainBox()
        let definition = makeReevalDrainDefinition(box: box)
        let transport = ReevalDrainTransport()
        let keeper = await makeReevalKeeper(definition: definition, transport: transport)

        await keeper.stepTickOnce()
        await keeper.forceShutdown()

        #expect(transport.destroyedCount == 1, "onLandDestroyed must still fire once after the keeper drains")
    }

    @Test("Reevaluation keeper: empty-room destroy path runs no land code")
    func emptyRoomDestroyRunsNoLandCode() async throws {
        let box = ReevalDrainBox()
        let definition = makeReevalDrainDefinition(box: box)
        let transport = ReevalDrainTransport()
        let keeper = await makeReevalKeeper(definition: definition, transport: transport)

        await keeper.awaitInitialization()
        try await keeper.join(playerID: PlayerID("v1"), clientID: ClientID("c-v1"), sessionID: SessionID("s-v1"))
        try await keeper.leave(playerID: PlayerID("v1"), clientID: ClientID("c-v1"))
        #expect(await keeper.destroyTimerForTesting() != nil, "empty room must arm the destroy timer")

        await keeper.runEmptyRoomShutdownForTesting()

        let log = await keeper.currentState().log
        #expect(box.finalizeResolverCount == 0, "OnFinalize resolver must not run via empty-room path in a reevaluation keeper")
        #expect(!box.afterFinalizeRan, "AfterFinalize must not run via empty-room path in a reevaluation keeper")
        #expect(!log.contains("finalize"), "OnFinalize handler must not append 'finalize' via empty-room path in a reevaluation keeper")
        #expect(!log.contains("destroyWhenEmpty"), "DestroyWhenEmpty must not append via empty-room path in a reevaluation keeper")
        #expect(transport.destroyedCount == 1, "onLandDestroyed must still fire once after empty-room shutdown")
    }

    @Test("Live keeper: forced shutdown runs all destroy handlers")
    func liveDrainStillRunsLandCode() async throws {
        let box = ReevalDrainBox()
        let definition = makeReevalDrainDefinition(box: box)
        let keeper = makeLiveKeeper(definition: definition)

        await keeper.awaitInitialization()
        await keeper.forceShutdown()

        let log = await keeper.currentState().log
        #expect(box.finalizeResolverCount == 1, "OnFinalize resolver must run on a live keeper forced shutdown")
        #expect(box.afterFinalizeRan, "AfterFinalize must run on a live keeper forced shutdown")
        #expect(log.contains("finalize"), "OnFinalize handler must append 'finalize' on a live keeper forced shutdown")
        #expect(log.contains("destroyWhenEmpty"), "DestroyWhenEmpty handler also runs on a live keeper forced shutdown")
    }
}
