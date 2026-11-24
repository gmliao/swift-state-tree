// A closed output gate stops every frame of the land (#696), and a failure found outside a keeper
// turn reaches the keeper's next step before anything of that step goes out (#704). The callers
// of a turn that ends the land get `landClosed` (#704, #716).
//
// Every test forces its interleaving with a hold point (`.failureSubmit` between an adapter's
// note and its submit, `.landFailedTeardown` between `failLand` and `landDidFail`), never timing.

import Foundation
import Testing
import SwiftStateTreeTestSupport
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

// MARK: - Fixtures

/// Counts one label of the keeper's in-turn probe, so a test waits for that point instead of
/// polling state. The probe runs synchronously on the keeper at the point it names.
final class ClosedGateProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let label: String
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(label: String) { self.label = label }

    var probe: @Sendable (String) -> Void { { [self] seen in if seen == label { signal() } } }

    private func signal() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            count += 1
            let ready = waiters.filter { $0.0 <= count }.map(\.1)
            waiters.removeAll { $0.0 <= count }
            return ready
        }
        ready.forEach { $0.resume() }
    }

    /// Returns once the label was seen `count` times. Bound it with `withinHangBound`.
    func wait(count target: Int) async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                if count >= target { return true }
                waiters.append((target, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }
}

/// Lets only the first arrival at a hold wait for `gate`; later arrivals pass.
final class FirstArrivalOnly: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = 0
    func isFirst() -> Bool { lock.withLock { arrived += 1; return arrived == 1 } }
}

/// Thrown by a sync plan that a test expects never to run.
struct ClosedGatePhaseRan: Error {}

@Payload
struct ClosedGateOkAction: ActionPayload {
    typealias Response = ClosedGateOkReply
    let amount: Int
}

@Payload
struct ClosedGateOkReply: ResponsePayload {
    let ok: Bool
}

/// A tickless land with two actions: `UnencodableResponseAction`, whose answer doesn't encode,
/// and `ClosedGateOkAction`, which answers normally and requests a sync.
func makeClosedGateLand() -> LandDefinition<UntypedPayloadState> {
    Land("closed-gate", using: UntypedPayloadState.self) {
        ServerEvents { Register(UntypedPayloadTypedEvent.self) }
        Rules {
            unencodableResponseHandler()
            HandleAction(ClosedGateOkAction.self) {
                (state: inout UntypedPayloadState, action: ClosedGateOkAction, ctx: LandContext) in
                state.round += action.amount
                ctx.requestSyncNow()
                return ClosedGateOkReply(ok: true)
            }
        }
    }
}

/// The failure another closer notes in a test.
let notedFailure = LandFailure(
    kind: .responseEncode, detail: "another closer", position: LandFailurePosition(stage: .actionResponse))

/// A tick land (hourly) with `HooksPingAction`, whose resolver makes each ping a pending job:
/// the adapter answers it from a response task, through `.actionResponse`.
func makeClosedGatePendingLand() -> LandDefinition<UntypedPayloadState> {
    Land("closed-gate-pending", using: UntypedPayloadState.self) {
        Rules {
            HandleAction(HooksPingAction.self, resolvers: HooksPingResolver.self) {
                (_: inout UntypedPayloadState, action: HooksPingAction, _: LandContext) in
                HooksPingResponse(tag: action.tag)
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { (_: inout UntypedPayloadState, _: LandContext) in }
        }
    }
}

/// A tick land (hourly, so its loop never fires in a test) whose tick handler emits an event and
/// writes the state, so a test can see whether that tick's handler ran.
func makeClosedGateTickLand() -> LandDefinition<UntypedPayloadState> {
    Land("closed-gate-tick", using: UntypedPayloadState.self) {
        ServerEvents { Register(UntypedPayloadTypedEvent.self) }
        Rules {}
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout UntypedPayloadState, ctx: LandContext) in
                state.round += 1
                ctx.emitEvent(UntypedPayloadTypedEvent(hp: 9), to: .all)
            }
        }
    }
}

extension UntypedPayloadLand {
    /// Sends one `ClosedGateOkAction` from the session, as a client frame.
    func sendOkAction(requestID: String, amount: Int = 1) async throws {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: ClosedGateOkAction.self),
            payload: AnyCodable(ClosedGateOkAction(amount: amount))
        )
        let frame = try encoding.config.makeCodec().encode(TransportMessage.action(requestID: requestID, action: envelope))
        await adapter.onMessage(frame, from: Self.session)
    }

    /// Calls the keeper with one `ClosedGateOkAction` directly, so the test sees its caller's outcome.
    func okActionThroughKeeper(amount: Int = 1) async throws -> AnyCodable {
        try await keeper.handleActionEnvelope(
            ActionEnvelope(typeIdentifier: String(describing: ClosedGateOkAction.self),
                           payload: AnyCodable(ClosedGateOkAction(amount: amount))),
            playerID: Self.player, clientID: ClientID("c1"), sessionID: Self.session
        )
    }
}

/// Starts `fail` and returns once it holds at `.failureSubmit`: the adapter has closed the gate
/// and noted the failure, and the keeper hasn't been sent it yet. `submit.open()` releases it.
func holdAtFailureSubmit(
    _ land: UntypedPayloadLand,
    _ label: String,
    fail: @escaping @Sendable () async throws -> Void
) async throws -> (TestGate, Task<Void, any Error>) {
    let submit = TestGate()
    await land.adapter.installHolds(HoldRegistry.at(.failureSubmit) { await submit.arrive() })
    let failing = Task { try await fail() }
    try #require(await submit.waitForArrivals(1), "\(label): the failure holds before its submit")
    #expect(land.adapter.outputGate.isClosed, "\(label): the gate closed")
    #expect(land.keeper.pendingFailureForTesting != nil, "\(label): the failure is noted on the keeper")
    return (submit, failing)
}

/// Releases the hold and waits for the land to end.
func releaseAndDrain(_ land: UntypedPayloadLand, _ submit: TestGate, _ failing: Task<Void, any Error>) async throws {
    submit.open()
    try await failing.value
    await land.adapter.installHolds(nil)
    _ = await land.keeper.waitForFailureForTesting()
    await land.keeper.waitUntilDrained()
}

// MARK: - Tests

@Suite("A closed gate stops every frame, and the keeper sees a failure noted outside a turn (#696, #704)", .serialized, .timeLimit(.minutes(1)))
struct ClosedGatePendingFailureTests {
    @Test("an answer completed after another answer's failure closed the gate doesn't reach the transport (#696)", arguments: UntypedPayloadEncoding.allCases)
    func replyAfterAdapterCloseIsDropped(encoding: UntypedPayloadEncoding) async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGateLand(), encoding: encoding)
        await land.adapter.waitForOutboundIdleForTesting()
        let (submit, failing) = try await holdAtFailureSubmit(land, "\(encoding)") {
            try await land.sendUnencodableAction(requestID: "a")
        }
        let sentBefore = await land.transport.sends
        let droppedBefore = await land.adapter.framesDroppedLandFailed
        try await land.sendOkAction(requestID: "b")
        await land.adapter.waitForOutboundIdleForTesting()
        #expect(await land.transport.sends == sentBefore, "\(encoding): B's reply doesn't go out")
        #expect(await land.adapter.framesDroppedLandFailed > droppedBefore, "\(encoding): the gate counted the drop")
        try await releaseAndDrain(land, submit, failing)
        #expect(land.keeper.failure?.kind == .responseEncode, "\(encoding): A's failure is the cause")
        #expect(await land.transport.closes == [SessionClose.Code.landFailed], "\(encoding): the 4016 close still goes out")
    }

    @Test("an action sent between the keeper's failLand and its teardown gets no error reply (#696)")
    func errorReplyInTheTeardownWindowIsDropped() async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGateLand(), encoding: .messagepack)
        await land.adapter.waitForOutboundIdleForTesting()
        let teardown = TestGate()
        await land.keeper.installHolds(HoldRegistry.at(.landFailedTeardown) { await teardown.arrive() })
        await land.keeper.failLandForTesting(LandFailure(
            kind: .syncPlan, detail: "test", position: LandFailurePosition(stage: .syncPhase)))
        try #require(await teardown.waitForArrivals(1), "the teardown holds")
        let sentBefore = await land.transport.sends
        try await land.sendOkAction(requestID: "late")
        await land.adapter.waitForOutboundIdleForTesting()
        #expect(await land.transport.sends == sentBefore, "the refusal's error reply doesn't go out")
        teardown.open()
        await land.keeper.installHolds(nil)
        await land.keeper.waitUntilDrained()
        #expect(await land.transport.closes == [SessionClose.Code.landFailed], "the 4016 close still goes out")
    }

    @Test("a turn after a noted answer failure ends the land with it: its caller gets landClosed and no sync phase runs (#704)", arguments: UntypedPayloadEncoding.allCases)
    func turnAfterTheNoteEndsTheLand(encoding: UntypedPayloadEncoding) async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGateLand(), encoding: encoding)
        await land.adapter.waitForOutboundIdleForTesting()
        // A sync phase that ran would throw, and report `syncPlan` as the first cause.
        await land.adapter.setSyncPlanFaultForTesting { throw ClosedGatePhaseRan() }
        let (submit, failing) = try await holdAtFailureSubmit(land, "\(encoding)") {
            try await land.sendUnencodableAction(requestID: "a")
        }
        // B's handler returns its reply, but its turn ends the land with A's noted failure.
        await #expect(throws: LandInputRejection.landClosed) { _ = try await land.okActionThroughKeeper() }
        #expect(land.keeper.failure?.kind == .responseEncode, "\(encoding): A's failure, not a sync phase's: \(String(describing: land.keeper.failure))")
        #expect(land.keeper.failure?.position.stage == .actionResponse, "\(encoding)")
        #expect(land.keeper.failure?.position.endsInputs == true, "\(encoding): it ended the turn's inputs, in its apply")
        try await releaseAndDrain(land, submit, failing)
        #expect(land.keeper.failure?.kind == .responseEncode, "\(encoding): the first cause stays after the submit")
    }

    @Test("a sendEvent whose event doesn't encode notes its failure: the next turn ends the land with eventEncode (#704)")
    func sendEventNotesItsFailure() async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGateLand(), encoding: .messagepack)
        await land.adapter.waitForOutboundIdleForTesting()
        await land.adapter.setSyncPlanFaultForTesting { throw ClosedGatePhaseRan() }
        let event = AnyServerEvent(type: "Untyped", payload: UntypedPayloadKind.dictionary.payload)
        let (submit, failing) = try await holdAtFailureSubmit(land, "sendEvent") {
            await land.adapter.sendEvent(event, to: .all)
        }
        await #expect(throws: LandInputRejection.landClosed) { _ = try await land.okActionThroughKeeper() }
        #expect(land.keeper.failure?.kind == .eventEncode, "\(String(describing: land.keeper.failure))")
        try await releaseAndDrain(land, submit, failing)
    }

    @Test("with no turn due, the awaited submit ends the land with the noted failure (#704)")
    func submitEndsALandWithNoTurnDue() async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGateLand(), encoding: .messagepack)
        await land.adapter.waitForOutboundIdleForTesting()
        let (submit, failing) = try await holdAtFailureSubmit(land, "no turn") {
            try await land.sendUnencodableAction(requestID: "a")
        }
        #expect(land.keeper.failure == nil, "no keeper step ran during the hold")
        try await releaseAndDrain(land, submit, failing)
        #expect(land.keeper.failure?.kind == .responseEncode)
        #expect(await land.transport.closes == [SessionClose.Code.landFailed])
    }

    @Test("on a tick land, a tick after a noted failure ends the land before its handler: no event of that tick goes out (#704)")
    func tickAfterTheNoteSkipsTheHandler() async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGateTickLand(), encoding: .messagepack)
        await land.adapter.waitForOutboundIdleForTesting()
        await land.adapter.setSyncPlanFaultForTesting { throw ClosedGatePhaseRan() }
        let event = AnyServerEvent(type: "Untyped", payload: UntypedPayloadKind.dictionary.payload)
        let (submit, failing) = try await holdAtFailureSubmit(land, "tick") {
            await land.adapter.sendEvent(event, to: .all)
        }
        let sentBefore = await land.transport.sends
        await land.keeper.stepTickOnce()
        #expect(land.keeper.failure?.kind == .eventEncode, "\(String(describing: land.keeper.failure))")
        #expect(land.keeper.failure?.position.endsInputs == true, "the failure ended the tick's inputs")
        #expect(await land.keeper.currentState().round == 0, "the tick handler didn't run")
        await land.adapter.waitForOutboundIdleForTesting()
        #expect(await land.transport.sends == sentBefore, "no frame of that tick goes out")
        try await releaseAndDrain(land, submit, failing)
    }

    @Test("a sync-only turn after a noted failure ends the land before its phase (#704)")
    func syncOnlyTurnAfterTheNoteRunsNoPhase() async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGateTickLand(), encoding: .messagepack)
        await land.adapter.waitForOutboundIdleForTesting()
        await land.adapter.setSyncPlanFaultForTesting { throw ClosedGatePhaseRan() }
        let event = AnyServerEvent(type: "Untyped", payload: UntypedPayloadKind.dictionary.payload)
        let (submit, failing) = try await holdAtFailureSubmit(land, "sync-only") {
            await land.adapter.sendEvent(event, to: .all)
        }
        await land.keeper.runSyncLoopIterationForTesting()
        #expect(land.keeper.failure?.kind == .eventEncode, "the noted failure, not the phase's: \(String(describing: land.keeper.failure))")
        try await releaseAndDrain(land, submit, failing)
    }

    @Test("the keeper's failure mailbox keeps the first failure noted")
    func mailboxKeepsTheFirstFailure() {
        let mailbox = LandFailureMailbox()
        #expect(mailbox.failure == nil)
        mailbox.note(LandFailure(kind: .responseEncode, detail: "first", position: LandFailurePosition(stage: .actionResponse)))
        mailbox.note(LandFailure(kind: .eventEncode, detail: "second", position: LandFailurePosition(stage: .eventFlush)))
        #expect(mailbox.failure?.detail == "first")
    }

    @Test("with the gate closed, a join gets no reply, and a router frame through the adapter is dropped (#696, plan test 3)")
    func joinAndRouterFramesAfterTheClose() async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGateLand(), encoding: .messagepack)
        await land.adapter.waitForOutboundIdleForTesting()
        let (submit, failing) = try await holdAtFailureSubmit(land, "join") {
            try await land.sendUnencodableAction(requestID: "a")
        }
        let sentBefore = await land.transport.sends
        let droppedBefore = await land.adapter.framesDroppedLandFailed
        // The router reaches a joined session through `enqueueOutbound` (its JoinResponse, its
        // later errors).
        await land.adapter.enqueueOutbound(Data("router frame".utf8), to: UntypedPayloadLand.session)
        // A second session's join: its turn ends the land with the noted failure, so neither a
        // JoinResponse nor a join error goes out.
        let s2 = SessionID("s2"), c2 = ClientID("c2")
        await land.adapter.onConnect(sessionID: s2, clientID: c2)
        _ = try? await land.adapter.performJoin(
            playerSession: PlayerSession(playerID: "p2", deviceID: "dev", metadata: [:]),
            clientID: c2, sessionID: s2, authInfo: nil,
            joinResponse: { _, _ in Data("join response".utf8) }
        )
        await land.adapter.waitForOutboundIdleForTesting()
        #expect(await land.transport.sends == sentBefore, "no router frame, JoinResponse or join error goes out")
        #expect(await land.adapter.framesDroppedLandFailed > droppedBefore, "the gate counted the drops")
        try await releaseAndDrain(land, submit, failing)
    }

    @Test("with the gate closed, a session's final frame and its close still go out (#696, plan test 4)")
    func finalFrameStillGoesOut() async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGateLand(), encoding: .messagepack)
        await land.adapter.waitForOutboundIdleForTesting()
        let (submit, failing) = try await holdAtFailureSubmit(land, "final frame") {
            try await land.sendUnencodableAction(requestID: "a")
        }
        let sentBefore = await land.transport.sends
        // The door a join ended before its admission, an inbound overflow after the join and the
        // router's join failure use (`endJoinBeforeAdmission`, TA:1789 and :2390, LR:1420).
        await land.adapter.sendFinalFrameAndClose(Data("final".utf8), to: UntypedPayloadLand.session)
        await land.adapter.waitForOutboundIdleForTesting()
        #expect(await land.transport.sends == sentBefore + 1, "the final frame goes out")
        #expect(await land.transport.plainCloses == [UntypedPayloadLand.session], "the close behind it goes out")
        try await releaseAndDrain(land, submit, failing)
    }

    @Test("a second closer's submit that reaches the keeper first doesn't replace the noted first cause (#704)")
    func laterSubmitKeepsTheNotedFirstCause() async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGateLand(), encoding: .messagepack)
        await land.adapter.waitForOutboundIdleForTesting()
        // A notes and holds before its submit; B, the second closer, notes (the mailbox keeps A)
        // and submits at once, so B's failure item reaches the keeper first.
        let submit = TestGate(), first = FirstArrivalOnly()
        await land.adapter.installHolds(HoldRegistry.at(.failureSubmit) { if first.isFirst() { await submit.arrive() } })
        let a = Task { try await land.sendUnencodableAction(requestID: "a") }
        try #require(await submit.waitForArrivals(1), "A holds before its submit")
        let b = LandFailure(kind: .eventEncode, detail: "the second closer", position: LandFailurePosition(stage: .eventFlush))
        await land.adapter.failOutsideTurn(b)
        _ = await land.keeper.waitForFailureForTesting()
        #expect(land.keeper.failure?.kind == .responseEncode, "A's noted failure stays the cause: \(String(describing: land.keeper.failure))")
        submit.open()
        try await a.value
        await land.adapter.installHolds(nil)
        await land.keeper.waitUntilDrained()
        #expect(land.keeper.failure?.kind == .responseEncode)
    }

    @Test("a response completed before the gate closed but enqueued after it doesn't go out (#696)")
    func completedResponseMeetsTheClosedGate() async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGatePendingLand(), encoding: .messagepack)
        await land.adapter.waitForOutboundIdleForTesting()
        // B, a pending job (its action has a resolver, on a tick land): its answer holds after
        // its turn, before its ticket check and enqueue.
        let answer = TestGate()
        await land.adapter.installHolds(HoldRegistry.at(.actionResponse) { await answer.arrive() })
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: HooksPingAction.self),
            payload: AnyCodable(HooksPingAction(tag: "b"))
        )
        let frame = try land.encoding.config.makeCodec().encode(TransportMessage.action(requestID: "b", action: envelope))
        await land.adapter.onMessage(frame, from: UntypedPayloadLand.session)
        await land.keeper.stepTickOnce()
        try #require(await answer.waitForArrivals(1), "B's answer holds before its enqueue")
        // Another closer closes the gate.
        await land.adapter.failOutsideTurn(notedFailure)
        await land.adapter.waitForOutboundIdleForTesting()
        let sentBefore = await land.transport.sends
        let droppedBefore = await land.adapter.framesDroppedLandFailed
        answer.open()
        await land.adapter.installHolds(nil)
        #expect(await withinHangBound { await land.adapter.waitForActionResponsesFinishedForTesting(1) }, "B's answer finished")
        await land.adapter.waitForOutboundIdleForTesting()
        #expect(await land.transport.sends == sentBefore, "B's completed response doesn't go out")
        #expect(await land.adapter.framesDroppedLandFailed > droppedBefore, "the gate counted it")
        await land.keeper.stepTickOnce()
        #expect(land.keeper.failure?.kind == .responseEncode)
        await land.keeper.waitUntilDrained()
    }

    @Test("a freeze's settle after a noted failure ends the land with it before its phase (#704, #546 L2d-1)")
    func settleAfterTheNoteEndsTheLand() async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGateLand(), encoding: .messagepack)
        await land.adapter.waitForOutboundIdleForTesting()
        let (submit, failing) = try await holdAtFailureSubmit(land, "settle") {
            try await land.sendUnencodableAction(requestID: "a")
        }
        // The settle's keeper turn reads the mailbox first: the land ends with A's failure while
        // A's submit is still held, and the settle doesn't freeze.
        let froze = (try? await land.adapter.debugFreeze()) != nil
        #expect(!froze, "the settle doesn't freeze a land that ended")
        #expect(land.keeper.failure?.kind == .responseEncode,
                "the noted failure, in the settle's turn: \(String(describing: land.keeper.failure))")
        try await releaseAndDrain(land, submit, failing)
    }

    @Test("a batch [A, a failure item, B]: A applied but gets landClosed, B is dropped with landClosed (#704)")
    func failureItemInTheBatchClosesEveryCaller() async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGateLand(), encoding: .messagepack)
        await land.adapter.waitForOutboundIdleForTesting()
        let queued = ClosedGateProbeCounter(label: "action-queued")
        await land.keeper.setInTurnProbeForTesting(queued.probe)
        let drain = TestGate()
        await land.keeper.installHolds(HoldRegistry.at(.inputDrain) { await drain.arrive() })
        let a = Task { try await land.okActionThroughKeeper(amount: 1) }
        try #require(await drain.waitForArrivals(1), "the drain holds before its first turn")
        await land.keeper.submitLandFailure(LandFailure(
            kind: .responseEncode, detail: "test", position: LandFailurePosition(stage: .actionResponse)))
        let b = Task { try await land.okActionThroughKeeper(amount: 2) }
        // B is queued behind the failure item before the drain goes on.
        try #require(await withinHangBound { await queued.wait(count: 2) }, "B was queued")
        let sentBefore = await land.transport.sends
        drain.open()
        await land.keeper.installHolds(nil)
        await #expect(throws: LandInputRejection.landClosed) { _ = try await a.value }
        await #expect(throws: LandInputRejection.landClosed) { _ = try await b.value }
        #expect(land.keeper.failure?.kind == .responseEncode)
        await land.keeper.waitUntilDrained()
        #expect(await land.transport.sends == sentBefore, "no frame of the failing turn goes out")
    }
}
