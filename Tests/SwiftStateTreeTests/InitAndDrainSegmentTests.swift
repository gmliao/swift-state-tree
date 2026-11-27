// Tests/SwiftStateTreeTests/InitAndDrainSegmentTests.swift
//
// #700 K2-1b: the initialization and the destroy drain, held at each of their awaits. While the
// keeper is parked, a re-entrant call checks the state the segment before the await left; after
// the release, the end state is today's. They pin the current behavior, so they pass before and
// after the flows become segments; the mutants in the plan prove they bite.

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct SegmentState: StateNodeProtocol {
    /// What ran, in order: "init:<output>", "join:<player>", "input", "tick",
    /// "destroyWhenEmpty", "finalize:<the value its resolver read>".
    @Sync(.broadcast)
    var log: [String] = []

    /// Written by OnDestroyWhenEmpty, read by OnFinalize's resolver builder.
    @Sync(.broadcast)
    var value: Int = 0

    public init() {}
}

@PlainData
struct SegmentOutput: ResolverOutput {
    let value: Int
}

@Payload
struct SegmentInput: ServerInputPayload {
    let n: Int
}

struct SegmentResolverFailure: Error {}

/// One gate per test, keyed by the number in the land ID ("seg-<phase>:<key>"). Only the step
/// named by `<phase>` waits on it: "init" and "initfail" (OnInitialize's resolver; the second
/// throws after the release), "dwe" (OnDestroyWhenEmpty's resolver), "fin" (OnFinalize's
/// resolver), "after" (AfterFinalize). Any other phase passes every step.
private let segmentGates = KeyedGates<Int, WatermarkGate>(firstKey: 12_000) { WatermarkGate() }

private func segmentGate(_ landID: String, phase: String) -> WatermarkGate? {
    let parts = landID.split(separator: ":")
    guard parts.count == 2, parts[0] == "seg-\(phase)", let key = Int(parts[1]) else { return nil }
    return segmentGates.registeredGate(key)
}

/// A fresh land ID for `phase`, with its gate registered.
private func segmentLandID(_ phase: String) -> (landID: String, gate: WatermarkGate) {
    let key = segmentGates.freshKey()
    return ("seg-\(phase):\(key)", segmentGates.gate(key))
}

@PlainData
struct SegmentInitResolver: Resolver {
    typealias Dependencies = NoServices
    typealias Output = SegmentOutput
    let landID: String

    func resolve(_ deps: NoServices) async throws -> SegmentOutput {
        if let gate = segmentGate(landID, phase: "init") { await gate.enterAndWait() }
        if let gate = segmentGate(landID, phase: "initfail") {
            await gate.enterAndWait()
            throw SegmentResolverFailure()
        }
        return SegmentOutput(value: 1)
    }
}

@PlainData
struct SegmentFinalizeResolver: Resolver {
    typealias Dependencies = NoServices
    typealias Output = SegmentOutput
    let landID: String
    /// `state.value` when the resolver was built.
    let seen: Int

    func resolve(_ deps: NoServices) async throws -> SegmentOutput {
        if let gate = segmentGate(landID, phase: "fin") { await gate.enterAndWait() }
        return SegmentOutput(value: seen)
    }
}

/// OnDestroyWhenEmpty's resolver: the DSL has no resolver form for it, so the definition sets
/// its executors directly, as ReevaluationDrainTests does.
private final class SegmentDestroyExecutor: AnyResolverExecutor, @unchecked Sendable {
    let resolverName: String = "SegmentDestroyExecutor"

    func execute(ctx: ResolverContext) async throws -> (String, any ResolverOutput) {
        if let gate = segmentGate(ctx.landID, phase: "dwe") { await gate.enterAndWait() }
        return ("segmentDestroy", SegmentOutput(value: 0))
    }
}

private func makeSegmentDefinition(tick: Bool) -> LandDefinition<SegmentState> {
    var definition: LandDefinition<SegmentState>
    if tick {
        definition = Land("seg", using: SegmentState.self) {
            Rules {
                OnJoin { state, ctx in state.log.append("join:\(ctx.playerID.rawValue)") }
                HandleServerInput(SegmentInput.self) { (state: inout SegmentState, _: SegmentInput, _: LandContext) in
                    state.log.append("input")
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { state, _ in state.log.append("tick") }
                OnInitialize(resolvers: { _, ctx in SegmentInitResolver(landID: ctx.landID) }) { state, output, _ in
                    state.log.append("init:\(output?.value ?? -1)")
                }
                DestroyWhenEmpty(after: .seconds(3600)) { state, _ in
                    state.log.append("destroyWhenEmpty")
                    state.value = 7
                }
                OnFinalize(resolvers: { state, ctx in SegmentFinalizeResolver(landID: ctx.landID, seen: state.value) }) { state, output, _ in
                    state.log.append("finalize:\(output?.value ?? -1)")
                }
                AfterFinalize { _, ctx in
                    if let gate = segmentGate(ctx.landID, phase: "after") { await gate.enterAndWait() }
                }
            }
        }
    } else {
        definition = Land("seg", using: SegmentState.self) {
            Rules {
                OnJoin { state, ctx in state.log.append("join:\(ctx.playerID.rawValue)") }
                HandleServerInput(SegmentInput.self) { (state: inout SegmentState, _: SegmentInput, _: LandContext) in
                    state.log.append("input")
                }
            }
            Lifetime {
                OnInitialize(resolvers: { _, ctx in SegmentInitResolver(landID: ctx.landID) }) { state, output, _ in
                    state.log.append("init:\(output?.value ?? -1)")
                }
                DestroyWhenEmpty(after: .seconds(3600)) { state, _ in
                    state.log.append("destroyWhenEmpty")
                    state.value = 7
                }
                OnFinalize(resolvers: { state, ctx in SegmentFinalizeResolver(landID: ctx.landID, seen: state.value) }) { state, output, _ in
                    state.log.append("finalize:\(output?.value ?? -1)")
                }
                AfterFinalize { _, ctx in
                    if let gate = segmentGate(ctx.landID, phase: "after") { await gate.enterAndWait() }
                }
            }
        }
    }
    definition.lifetimeHandlers.onDestroyWhenEmptyResolverExecutors = [SegmentDestroyExecutor()]
    return definition
}

private func makeSegmentKeeper(
    tick: Bool,
    landID: String,
    recording: Bool = false,
    autoStartLoops: Bool = false,
    transport: (any LandKeeperTransport)? = nil
) -> LandKeeper<SegmentState> {
    LandKeeper<SegmentState>(
        definition: makeSegmentDefinition(tick: tick),
        initialState: SegmentState(),
        enableLiveStateHashRecording: recording,
        autoStartLoops: autoStartLoops,
        enableLoopPhaseOffset: false,
        landID: landID,
        transport: transport
    )
}

/// A transport that commits every in-turn sync phase and sends nothing. With a gate, its
/// `onLandDestroyed` waits on it. Counts its `onLandDestroyed` calls.
private final class SegmentTransport: LandKeeperTransport, @unchecked Sendable {
    let gate: WatermarkGate?
    private let lock = NSLock()
    private var destroyed = 0

    init(gate: WatermarkGate? = nil) { self.gate = gate }

    var destroyedCount: Int { lock.withLock { destroyed } }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {
        lock.withLock { destroyed += 1 }
        await gate?.enterAndWait()
    }
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
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

/// Holds the first `.turnRecord` arrival on `gate`, and logs each `.drainStart` arrival. With
/// `holdsStarter`, also holds the initialization's starter after its task ended, on `starter`.
private final class SegmentHolds: @unchecked Sendable {
    let gate = WatermarkGate()
    let starter = WatermarkGate()
    let log = EventLog()
    var holdsStarter = false
    private let lock = NSLock()
    private var records = 0

    func install(on keeper: LandKeeper<SegmentState>) async {
        await keeper.installHolds { [self] point in
            switch point {
            case .turnRecord:
                let first = lock.withLock { records += 1; return records == 1 }
                if first { await gate.enterAndWait() }
            case .drainStart:
                log.append("drainStart")
            case .initializationStarterResumed:
                if holdsStarter { await starter.enterAndWait() }
            default:
                break
            }
        }
    }
}

private let segP1 = PlayerID("p1")
private let segC1 = ClientID("c1")
private let segS1 = SessionID("s1")

/// A recording, auto-starting keeper whose initialization is held at its record. Its
/// initialization starts at creation, so OnInitialize's resolver is held first, and the record
/// hold is installed before it is released. `nil` holds when a hold was never reached.
private func keeperHeldAtInitializeRecord(tick: Bool, holdingStarter: Bool = false) async -> (LandKeeper<SegmentState>, SegmentHolds?) {
    let (landID, resolverGate) = segmentLandID("init")
    let keeper = makeSegmentKeeper(tick: tick, landID: landID, recording: true, autoStartLoops: true)
    guard await resolverGate.waitUntilEntered("OnInitialize's resolver") else { return (keeper, nil) }
    let holds = SegmentHolds()
    holds.holdsStarter = holdingStarter
    await holds.install(on: keeper)
    resolverGate.release()
    guard await holds.gate.waitUntilEntered("the initialization's record") else { return (keeper, nil) }
    return (keeper, holds)
}

@Suite("Initialization and drain held at each await (#700 K2-1b)", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct InitAndDrainSegmentTests {
    // MARK: Initialization

    @Test("T1: held in OnInitialize's resolvers, the state is the initial one, didInitialize is false and a join waits", arguments: [false, true])
    func heldInInitializeResolvers(tick: Bool) async throws {
        let (landID, gate) = segmentLandID("init")
        // The keeper starts its initialization at creation; the test never adds a waiter of
        // its own before the one it counts.
        let keeper = makeSegmentKeeper(tick: tick, landID: landID)
        guard await gate.waitUntilEntered("OnInitialize's resolver") else { return }

        #expect(await keeper.currentState().log.isEmpty, "OnInitialize hasn't applied")
        #expect(await keeper.lifecycleFlagsForTesting().didInitialize == false)
        let join = Task { try await keeper.join(playerID: segP1, clientID: segC1, sessionID: segS1) }
        #expect(await keeper.waitForInitializationWaitersForTesting(1), "the join waits for the initialization")

        gate.release()
        try await join.value
        #expect(await keeper.currentState().log.first == "init:1")
        #expect(await keeper.lifecycleFlagsForTesting().didInitialize)
        await keeper.forceShutdown()
    }

    @Test("T2: held at the initialization's record, OnInitialize is applied, didInitialize is false and no loop is configured yet", arguments: [false, true])
    func heldAtInitializeRecord(tick: Bool) async throws {
        let (keeper, holds) = await keeperHeldAtInitializeRecord(tick: tick)
        guard let holds else { return }

        #expect(await keeper.currentState().log == ["init:1"])
        let held = await keeper.lifecycleFlagsForTesting()
        #expect(held.didInitialize == false)
        #expect(held.tickLoopConfigured == false, "the loops start after the record")

        holds.gate.release()
        await keeper.awaitInitialization()
        let done = await keeper.lifecycleFlagsForTesting()
        #expect(done.didInitialize)
        #expect(done.tickLoopConfigured == tick, "a tick land's loop is configured after the record")
        await keeper.forceShutdown()
    }

    @Test("T2b: a land that fails while its initialization is held at the record configures no loop")
    func failedAtInitializeRecordStartsNoLoop() async throws {
        let (keeper, holds) = await keeperHeldAtInitializeRecord(tick: true)
        guard let holds else { return }

        await keeper.failLandForTesting(LandFailure(kind: .syncPlan, detail: "test", position: LandFailurePosition(stage: .syncPhase)))
        #expect(keeper.isDraining)

        holds.gate.release()
        await keeper.awaitInitialization()
        #expect(await keeper.lifecycleFlagsForTesting().tickLoopConfigured == false, "the drain began during the record: no loop")
        #expect(await pollUntil { await keeper.lifecycleFlagsForTesting().destructionFinished }, "the failure's teardown ends")
        #expect(await keeper.lifecycleFlagsForTesting().tickLoopConfigured == false)
    }

    @Test("T3: OnInitialize's resolver throws (.failLand) after the hold: the initialization fails and the waiting join gets landShuttingDown", arguments: [false, true])
    func initializeResolverFailsAfterTheHold(tick: Bool) async throws {
        let (landID, gate) = segmentLandID("initfail")
        let keeper = makeSegmentKeeper(tick: tick, landID: landID)
        guard await gate.waitUntilEntered("OnInitialize's resolver") else { return }

        let join = Task { () -> (any Error)? in
            do {
                try await keeper.join(playerID: segP1, clientID: segC1, sessionID: segS1)
                return nil
            } catch {
                return error
            }
        }
        #expect(await keeper.waitForInitializationWaitersForTesting(1))
        #expect(await keeper.lifecycleFlagsForTesting().initializationFailed == false, "nothing failed before the release")

        gate.release()
        let error = await join.value
        if case .landShuttingDown? = error as? JoinError {} else {
            Issue.record("the join got \(String(describing: error)), not landShuttingDown")
        }
        let flags = await keeper.lifecycleFlagsForTesting()
        #expect(flags.initializationFailed)
        #expect(flags.didInitialize)
        #expect(await keeper.currentState().log.isEmpty, "OnInitialize never ran")
        #expect(await pollUntil { await keeper.lifecycleFlagsForTesting().destructionFinished }, "the teardown ends")
    }

    @Test("T9: a waiter the initialization resumes sees it done and the tick loop configured, before the starter resumes (#934); so does a join right after")
    func initializationWaiterSeesTheLoop() async throws {
        let (keeper, holds) = await keeperHeldAtInitializeRecord(tick: true, holdingStarter: true)
        guard let holds else { return }

        let waiter = Task { () -> LandKeeper<SegmentState>.LifecycleFlagsForTesting in
            await keeper.awaitInitialization()
            return await keeper.lifecycleFlagsForTesting()
        }
        #expect(await keeper.waitForInitializationWaitersForTesting(1))
        holds.gate.release()

        // The starter is held after the task ended, so the waiter reads the flags first. The
        // initialization's own last segment set `didInitialize`, after the loops (#934: the
        // starter used to set it after its wake, so a waiter that resumed first read false).
        guard await holds.starter.waitUntilEntered("the initialization's starter") else { return }
        let seen = await waiter.value
        #expect(seen.didInitialize, "a waiter sees the initialization done (#934)")
        #expect(seen.tickLoopConfigured, "the waiter wakes after the loops are configured")
        holds.starter.release()
        try await keeper.join(playerID: segP1, clientID: segC1, sessionID: segS1)
        #expect(await keeper.lifecycleFlagsForTesting().tickLoopConfigured)
        await keeper.forceShutdown()
    }

    // MARK: Drain

    @Test("T4: a drain waiting for a tick in flight has closed intake and keeps the pending inputs until the tick ends")
    func drainHeldOnTickInFlight() async throws {
        let (landID, _) = segmentLandID("tick")
        let keeper = makeSegmentKeeper(tick: true, landID: landID)
        await keeper.awaitInitialization()
        let holds = SegmentHolds()
        await holds.install(on: keeper)

        // The tick runs its handler, then is held at its record: still in flight.
        let tickTask = Task { await keeper.stepTickOnce() }
        guard await holds.gate.waitUntilEntered("the tick's record") else { return }
        guard case .accepted = await keeper.submitServerInput(SegmentInput(n: 1)) else {
            Issue.record("the server input wasn't queued")
            return
        }

        let drain = Task { await keeper.runEmptyRoomShutdownForTesting() }
        // The hook runs at the drain's first await; the segment up to the tick wait follows
        // it with no await, so the next keeper call runs once the drain is parked there.
        #expect(await holds.log.waitFor("drainStart"))
        let held = await keeper.lifecycleFlagsForTesting()
        #expect(keeper.isDraining)
        #expect(held.pendingInputs == 1, "the pending input is dropped only after the tick")
        #expect(held.destroyHandlersStarted == false)
        #expect(await keeper.submitServerInput(SegmentInput(n: 2)) == .refused(.draining))

        holds.gate.release()
        await tickTask.value
        await drain.value
        let done = await keeper.lifecycleFlagsForTesting()
        #expect(done.pendingInputs == 0)
        #expect(done.destructionFinished)
        #expect(await keeper.currentState().log == ["init:1", "tick", "destroyWhenEmpty", "finalize:7"], "the queued input is never applied")
    }

    @Test("T5: held in OnDestroyWhenEmpty's resolvers, the handlers have started, nothing is pending, and the state is the one before the handler")
    func heldInDestroyWhenEmptyResolvers() async throws {
        let (landID, gate) = segmentLandID("dwe")
        let keeper = makeSegmentKeeper(tick: false, landID: landID)
        await keeper.awaitInitialization()
        let drain = Task { await keeper.forceShutdown() }
        guard await gate.waitUntilEntered("OnDestroyWhenEmpty's resolver") else { return }

        let held = await keeper.lifecycleFlagsForTesting()
        #expect(held.destroyHandlersStarted)
        #expect(held.pendingInputs == 0)
        #expect(await keeper.currentState().log == ["init:1"])
        #expect(await keeper.currentState().value == 0)

        gate.release()
        await drain.value
        #expect(await keeper.currentState().log == ["init:1", "destroyWhenEmpty", "finalize:7"])
    }

    @Test("T6: held in OnFinalize's resolvers, OnDestroyWhenEmpty's write is applied and OnFinalize's isn't; its resolver read the written value")
    func heldInFinalizeResolvers() async throws {
        let (landID, gate) = segmentLandID("fin")
        let keeper = makeSegmentKeeper(tick: false, landID: landID)
        await keeper.awaitInitialization()
        let drain = Task { await keeper.forceShutdown() }
        guard await gate.waitUntilEntered("OnFinalize's resolver") else { return }

        #expect(await keeper.currentState().log == ["init:1", "destroyWhenEmpty"])
        #expect(await keeper.currentState().value == 7)

        gate.release()
        await drain.value
        #expect(await keeper.currentState().log == ["init:1", "destroyWhenEmpty", "finalize:7"], "OnFinalize's resolver was built from the state after OnDestroyWhenEmpty")
    }

    @Test("T7: held in AfterFinalize, OnFinalize is applied, the destruction hasn't finished and the transport is still attached")
    func heldInAfterFinalize() async throws {
        let (landID, gate) = segmentLandID("after")
        let transport = SegmentTransport()
        let keeper = makeSegmentKeeper(tick: false, landID: landID, transport: transport)
        await keeper.awaitInitialization()
        let drain = Task { await keeper.forceShutdown() }
        guard await gate.waitUntilEntered("AfterFinalize") else { return }

        #expect(await keeper.currentState().log == ["init:1", "destroyWhenEmpty", "finalize:7"])
        #expect(await keeper.lifecycleFlagsForTesting().destructionFinished == false)
        #expect((await keeper.transportForTesting as AnyObject?) === transport)
        #expect(transport.destroyedCount == 0)

        gate.release()
        await drain.value
        #expect(await keeper.lifecycleFlagsForTesting().destructionFinished)
        #expect(transport.destroyedCount == 1)
        #expect(await keeper.transportForTesting is ReleasedLandTransport)
    }

    @Test("T8: a transport attached during onLandDestroyed is replaced by the released stand-in and never told the land was destroyed")
    func attachDuringOnLandDestroyed() async throws {
        let (landID, gate) = segmentLandID("destroyed")
        let transport = SegmentTransport(gate: gate)
        let keeper = makeSegmentKeeper(tick: false, landID: landID, transport: transport)
        await keeper.awaitInitialization()
        let drain = Task { await keeper.forceShutdown() }
        guard await gate.waitUntilEntered("onLandDestroyed") else { return }

        #expect(await keeper.lifecycleFlagsForTesting().destructionFinished == false)
        let late = SegmentTransport()
        await keeper.setTransport(late)
        #expect((await keeper.transportForTesting as AnyObject?) === late, "attached: the destruction hasn't finished")

        gate.release()
        await drain.value
        #expect(await keeper.lifecycleFlagsForTesting().destructionFinished)
        #expect(await keeper.transportForTesting is ReleasedLandTransport, "the destruction wins")
        #expect(late.destroyedCount == 0, "the late transport never hears of the destruction (#698)")
        #expect(transport.destroyedCount == 1)
    }

    @Test("T8b: a keeper with no transport tells its bound requester, which stays bound until onLandDestroyed returns")
    func boundRequesterClearedAfterOnLandDestroyed() async throws {
        let (landID, gate) = segmentLandID("destroyed")
        let keeper = makeSegmentKeeper(tick: false, landID: landID)
        await keeper.awaitInitialization()
        let port = SegmentTransport(gate: gate)
        _ = await keeper.syncTurnNow(via: port, reason: .syncNow)
        #expect(await keeper.lifecycleFlagsForTesting().hasBoundRequester, "the sync request bound the port")

        let drain = Task { await keeper.forceShutdown() }
        guard await gate.waitUntilEntered("the bound port's onLandDestroyed") else { return }
        let held = await keeper.lifecycleFlagsForTesting()
        #expect(held.destructionFinished == false)
        #expect(held.hasBoundRequester)

        gate.release()
        await drain.value
        let done = await keeper.lifecycleFlagsForTesting()
        #expect(done.destructionFinished)
        #expect(done.hasBoundRequester == false)
        #expect(port.destroyedCount == 1)
    }
}
