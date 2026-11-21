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

/// A tickless land with two actions: `UntypedResponseAction`, whose answer doesn't encode on a
/// compressed encoding, and `ClosedGateOkAction`, which answers normally and requests a sync.
func makeClosedGateLand() -> LandDefinition<UntypedPayloadState> {
    let untyped = AnyActionHandler<UntypedPayloadState>(
        type: UntypedResponseAction.self,
        responseType: UntypedResponseReply.self,
        invoke: { state, _, _ in
            state.round += 1
            return AnyCodable(["hp": 3] as [String: Int])
        },
        resolverExecutors: []
    )
    return Land("closed-gate", using: UntypedPayloadState.self) {
        ServerEvents { Register(UntypedPayloadTypedEvent.self) }
        Rules {
            untyped
            HandleAction(ClosedGateOkAction.self) {
                (state: inout UntypedPayloadState, action: ClosedGateOkAction, ctx: LandContext) in
                state.round += action.amount
                ctx.requestSyncNow()
                return ClosedGateOkReply(ok: true)
            }
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
    @Test("an answer completed after another answer's failure closed the gate doesn't reach the transport (#696)", arguments: UntypedPayloadEncoding.compressed)
    func replyAfterAdapterCloseIsDropped(encoding: UntypedPayloadEncoding) async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGateLand(), encoding: encoding)
        await land.adapter.waitForOutboundIdleForTesting()
        let (submit, failing) = try await holdAtFailureSubmit(land, "\(encoding)") {
            try await land.sendAction(requestID: "a")
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

    @Test("a turn after a noted answer failure ends the land with it: its caller gets landClosed and no sync phase runs (#704)", arguments: UntypedPayloadEncoding.compressed)
    func turnAfterTheNoteEndsTheLand(encoding: UntypedPayloadEncoding) async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGateLand(), encoding: encoding)
        await land.adapter.waitForOutboundIdleForTesting()
        // A sync phase that ran would throw, and report `syncPlan` as the first cause.
        await land.adapter.setSyncPlanFaultForTesting { throw ClosedGatePhaseRan() }
        let (submit, failing) = try await holdAtFailureSubmit(land, "\(encoding)") {
            try await land.sendAction(requestID: "a")
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
            try await land.sendAction(requestID: "a")
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

    @Test("a batch [A, a failure item, B]: A applied but gets landClosed, B is dropped with landClosed (#704)")
    func failureItemInTheBatchClosesEveryCaller() async throws {
        let land = try await UntypedPayloadLand.make(makeClosedGateLand(), encoding: .messagepack)
        await land.adapter.waitForOutboundIdleForTesting()
        let drain = TestGate()
        await land.keeper.installHolds(HoldRegistry.at(.inputDrain) { await drain.arrive() })
        let a = Task { try await land.okActionThroughKeeper(amount: 1) }
        try #require(await drain.waitForArrivals(1), "the drain holds before its first turn")
        await land.keeper.submitLandFailure(LandFailure(
            kind: .responseEncode, detail: "test", position: LandFailurePosition(stage: .actionResponse)))
        let b = Task { try await land.okActionThroughKeeper(amount: 2) }
        // B is queued behind the failure item before the drain goes on.
        while await land.keeper.pendingItemCountForTesting < 3 { await Task.yield() }
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
