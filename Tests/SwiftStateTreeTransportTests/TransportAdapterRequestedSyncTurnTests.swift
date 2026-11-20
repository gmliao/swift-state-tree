// Tests/SwiftStateTreeTransportTests/TransportAdapterRequestedSyncTurnTests.swift
//
// Requested sync turns (#546 L2a): on an in-turn adapter, `syncNow()` and the adapter's other
// sync requests are one sync-only turn on the keeper, through the port the keeper is bound to.
// These tests pin the binding (attached transport, or the first requester of a keeper never
// attached), the ticket of a delayed request, the freeze checked before back-pressure, and a
// request on a failed land.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct RequestedSyncTurnState: StateNodeProtocol {
    @Sync(.broadcast) var stamp: Int = 0
    init() {}
}

@Payload
struct RequestedSyncTurnSetAction: ActionPayload {
    typealias Response = RequestedSyncTurnSetResponse
    let stamp: Int
}

@Payload
struct RequestedSyncTurnSetResponse: ResponsePayload {
    let ok: Bool
}

private func requestedSyncTurnLand() -> LandDefinition<RequestedSyncTurnState> {
    Land("requested-sync-turn", using: RequestedSyncTurnState.self) {
        Rules {
            HandleAction(RequestedSyncTurnSetAction.self) { (state: inout RequestedSyncTurnState, action: RequestedSyncTurnSetAction, _: LandContext) in
                state.stamp = action.stamp
                return RequestedSyncTurnSetResponse(ok: true)
            }
        }
    }
}

private struct RequestedSyncTurnFixture {
    let keeper: LandKeeper<RequestedSyncTurnState>
    let adapter: TransportAdapter<RequestedSyncTurnState>
    let transport: BlockingTransport
    let session = SessionID("rst-session")
    let client = ClientID("rst-client")
    let player = PlayerID("rst-player")

    /// `attached`: the keeper gets the adapter as its transport; otherwise it is never attached,
    /// and its first sync request binds it.
    static func make(attached: Bool) async throws -> RequestedSyncTurnFixture {
        let transport = BlockingTransport()
        let keeper = LandKeeper<RequestedSyncTurnState>(definition: requestedSyncTurnLand(), initialState: RequestedSyncTurnState())
        let adapter = makeAdapter(keeper: keeper, transport: transport)
        if attached { await keeper.setTransport(adapter) }
        await transport.setDelegate(adapter)
        let f = RequestedSyncTurnFixture(keeper: keeper, adapter: adapter, transport: transport)
        await adapter.onConnect(sessionID: f.session, clientID: f.client)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: f.session, clientID: f.client, playerID: f.player)
        await adapter.waitForOutboundIdleForTesting()
        return f
    }

    static func makeAdapter(
        keeper: LandKeeper<RequestedSyncTurnState>,
        transport: BlockingTransport
    ) -> TransportAdapter<RequestedSyncTurnState> {
        TransportAdapter<RequestedSyncTurnState>(
            keeper: keeper,
            transport: transport,
            landID: "requested-sync-turn",
            transportEnvConfig: TransportEnvConfig(
                enableDirtyTracking: true,
                useSnapshotForSync: true,
                syncStrategy: .delta,
                profilingConfig: nil
            ),
            encodingConfig: .json,
            inTurnSync: true
        )
    }

    func set(_ stamp: Int) async throws {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: RequestedSyncTurnSetAction.self),
            payload: AnyCodable(RequestedSyncTurnSetAction(stamp: stamp))
        )
        _ = try await keeper.handleActionEnvelope(envelope, playerID: player, clientID: client, sessionID: session)
    }
}

@Suite("Requested sync turns (#546 L2a)", .timeLimit(.minutes(1)))
struct TransportAdapterRequestedSyncTurnTests {
    // MARK: The binding

    @Test("a keeper never attached syncs through its first requester only")
    func firstRequesterBindsAnUnattachedKeeper() async throws {
        let f = try await RequestedSyncTurnFixture.make(attached: false)
        try await f.set(1)
        #expect(await f.adapter.syncNowReportingOutcome() == .committed(clearDirtyFlags: true))
        // A second in-turn adapter of the same keeper is not its port.
        let other = RequestedSyncTurnFixture.makeAdapter(keeper: f.keeper, transport: BlockingTransport())
        #expect(await other.syncNowReportingOutcome() == .skipped)
        #expect(await f.keeper.syncTurnTicket(via: other) == nil)
        // The first one still is.
        #expect(await f.keeper.syncTurnTicket(via: f.adapter) != nil)
    }

    @Test("an attached keeper syncs through its transport only")
    func attachedKeeperRejectsAnotherAdapter() async throws {
        let f = try await RequestedSyncTurnFixture.make(attached: true)
        let other = RequestedSyncTurnFixture.makeAdapter(keeper: f.keeper, transport: BlockingTransport())
        #expect(await other.syncNowReportingOutcome() == .skipped)
        try await f.set(1)
        #expect(await f.adapter.syncNowReportingOutcome() == .committed(clearDirtyFlags: true))
    }

    @Test("a ticket taken before the binding changed is stale, also after A → B → A")
    func ticketIsStaleAcrossARebind() async throws {
        let f = try await RequestedSyncTurnFixture.make(attached: true)
        let ticket = try #require(await f.keeper.syncTurnTicket(via: f.adapter))
        let other = RequestedSyncTurnFixture.makeAdapter(keeper: f.keeper, transport: BlockingTransport())
        await f.keeper.setTransport(other)
        await f.keeper.setTransport(f.adapter)
        try await f.set(1)
        #expect(await f.keeper.syncTurnNow(via: f.adapter, reason: .lagTimer, ticket: ticket) == .skipped)
        let fresh = try #require(await f.keeper.syncTurnTicket(via: f.adapter))
        #expect(await f.keeper.syncTurnNow(via: f.adapter, reason: .lagTimer, ticket: fresh) == .committed(clearDirtyFlags: true))
    }

    @Test("a writer-drain retry armed under an older binding doesn't block the current binding's")
    func olderBindingsRetryDoesNotBlockTheCurrentOne() async throws {
        let f = try await RequestedSyncTurnFixture.make(attached: true)
        // A defers with its writer held: its retry waits on A's writer.
        await f.adapter.setWriterBackPressureOverrideForTesting { true }
        try await f.set(1)
        #expect(await f.adapter.syncNowReportingOutcome() == .deferredBackPressure)
        let bindingA = await f.keeper.syncBindingForTesting
        #expect(await f.keeper.inTurnDrainRetryBindingForTesting == bindingA)

        // B is bound and joins a player of its own.
        let transportB = BlockingTransport()
        let b = RequestedSyncTurnFixture.makeAdapter(keeper: f.keeper, transport: transportB)
        await transportB.setDelegate(b)
        await f.keeper.setTransport(b)
        let sessionB = SessionID("rst-session-b")
        await b.onConnect(sessionID: sessionB, clientID: ClientID("rst-client-b"))
        try await simulateRouterJoin(
            adapter: b, keeper: f.keeper, sessionID: sessionB, clientID: ClientID("rst-client-b"), playerID: PlayerID("rst-player-b")
        )
        await b.waitForOutboundIdleForTesting()

        // B defers too, while A's retry is still waiting: B arms its own retry.
        await b.setWriterBackPressureOverrideForTesting { true }
        try await f.set(2)
        #expect(await b.syncNowReportingOutcome() == .deferredBackPressure)
        let bindingB = await f.keeper.syncBindingForTesting
        #expect(bindingB != bindingA)
        #expect(await f.keeper.inTurnDrainRetryBindingForTesting == bindingB, "B's retry is armed")

        // B's writer drains: B's retry delivers stamp 2 while A's writer is still held.
        await b.setWriterBackPressureOverrideForTesting(nil)
        // B's retry retires (A's stays pending), then its frames reach B's transport.
        await f.keeper.waitForRequestedSyncTurnsForTesting(atMost: 1)
        await b.waitForOutboundIdleForTesting()
        #expect(
            transportB.frames(for: sessionB).contains { String(decoding: $0, as: UTF8.self).contains(#"stamp","value":2"#) },
            "B's deferred sync was delivered by B's retry"
        )

        // A's stale retry retires without a turn and without clearing B's mark.
        await f.adapter.setWriterBackPressureOverrideForTesting(nil)
        await f.adapter.waitForKeeperRequestedSyncWorkForTesting()
        #expect(await !f.adapter.keeperHasRequestedSyncWorkForTesting())
        #expect(await f.keeper.inTurnDrainRetryBindingForTesting == nil)
    }

    // MARK: The freeze before back-pressure

    @Test("frozen with the writer backed up: the phase leaves its sync to the resume, not to the drain retry")
    func freezeIsCheckedBeforeBackPressure() async throws {
        let f = try await RequestedSyncTurnFixture.make(attached: true)
        // Inputs wait while frozen: the change goes in first (the settle then sends it).
        try await f.set(1)
        let token = try await f.adapter.debugFreeze().freezeToken
        await f.adapter.setWriterBackPressureOverrideForTesting { true }
        let backlogBefore = await f.adapter.syncSkipCounts().outboundBacklog
        #expect(await f.adapter.syncNowReportingOutcome() == .skipped)
        #expect(await f.adapter.syncSkipCounts().outboundBacklog == backlogBefore, "not counted as a backlog skip")
        #expect(await f.adapter.debugFreezeState.deferredSyncNow, "the resume owns the sync")
        #expect(await !f.adapter.keeperHasRequestedSyncWorkForTesting(), "no writer-drain retry was armed")

        await f.adapter.setWriterBackPressureOverrideForTesting(nil)
        let resumesBefore = await f.keeper.requestedSyncTurnsForTesting[.resume, default: 0]
        _ = await f.adapter.debugResume(freezeToken: token)
        await f.adapter.waitForBackgroundSyncsForTesting()
        await f.adapter.waitForOutboundIdleForTesting()
        #expect(await f.adapter.debugFreezeState.deferredSyncNow == false, "the resume ran the deferred sync")
        // The resume requested its turn: the flag alone is cleared before it requests. (The
        // settle already sent stamp 1, and inputs wait while frozen, so no frame tells them apart.)
        #expect(await f.keeper.requestedSyncTurnsForTesting[.resume, default: 0] == resumesBefore + 1)
    }

    // MARK: A failed land

    @Test("a land that fails with a writer-drain retry armed ends the retry's wait and retires it")
    func teardownEndsAnArmedRetry() async throws {
        let f = try await RequestedSyncTurnFixture.make(attached: true)
        await f.adapter.setWriterBackPressureOverrideForTesting { true }
        try await f.set(1)
        #expect(await f.adapter.syncNowReportingOutcome() == .deferredBackPressure)
        #expect(await f.adapter.keeperHasRequestedSyncWorkForTesting(), "the retry is armed")
        await f.keeper.submitLandFailure(LandFailure(
            kind: .syncEncode, detail: "test failure", position: LandFailurePosition(stage: .syncPhase)
        ))
        #expect(await f.keeper.waitForFailureForTesting())
        // The teardown ends the writer's consumer, so the retry's wait returns and the retry
        // retires without a turn.
        await f.adapter.setWriterBackPressureOverrideForTesting(nil)
        await f.adapter.waitForKeeperRequestedSyncWorkForTesting()
        #expect(await !f.adapter.keeperHasRequestedSyncWorkForTesting())
        #expect(await f.keeper.inTurnDrainRetryBindingForTesting == nil)
    }

    @Test("a keeper never attached closes its bound adapter's output when the land fails; later requests retire")
    func failureReachesTheBoundRequester() async throws {
        let f = try await RequestedSyncTurnFixture.make(attached: false)
        #expect(await f.adapter.syncNowReportingOutcome() != .skipped, "the first request binds the keeper")
        #expect(!f.adapter.outputGate.isClosed)
        await f.keeper.submitLandFailure(LandFailure(
            kind: .syncEncode, detail: "test failure", position: LandFailurePosition(stage: .syncPhase)
        ))
        #expect(await f.keeper.waitForFailureForTesting())
        #expect(f.adapter.outputGate.isClosed, "the failure closed the bound adapter's output")
        #expect(await f.adapter.syncNowReportingOutcome() == .skipped)
        await f.adapter.waitForBackgroundSyncsForTesting()
        #expect(await !f.adapter.keeperHasRequestedSyncWorkForTesting())
    }
}
