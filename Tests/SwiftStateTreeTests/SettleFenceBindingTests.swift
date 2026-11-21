// Tests/SwiftStateTreeTests/SettleFenceBindingTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

/// A settle port that runs in turn for any keeper and answers an empty settle.
private final class SettlePortFake: LandKeeperSettlePort, @unchecked Sendable {
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S, events: [InTurnServerEvent], includeSync: Bool, recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        InTurnSyncOutput(includeSync ? .committed(clearDirtyFlags: true) : .notRequested)
    }
    func runSettlePhaseInTurn<S: StateNodeProtocol>(
        state: S, settle: InTurnSettle, recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        InTurnSyncOutput(.notRequested, syncStream: [], settle: .empty(membershipEpoch: 0))
    }
}

private func isSettled(_ outcome: LandKeeper<RoutingPinState>.SettleTurnOutcome) -> Bool {
    if case .settled = outcome { return true }
    return false
}

/// On a keeper never attached, a settle binds the sync requester only once its whole fence has
/// passed (#546 L2d-2): a refused settle changes nothing, so the port that settles next isn't
/// excluded by a binding the refused one left.
@Suite("Settle fence: a refused settle binds no requester (#546 L2d-2)", .timeLimit(.minutes(1)))
struct SettleFenceBindingTests {
    private static func frozenNeverAttachedKeeper() async -> LandKeeper<RoutingPinState> {
        let keeper = LandKeeper<RoutingPinState>(
            definition: makeRoutingPinLand(tick: false), initialState: RoutingPinState(), autoStartLoops: false
        )
        await keeper.awaitInitialization()
        #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(10)))
        return keeper
    }

    private static let fence = LandKeeper<RoutingPinState>.SettleFence(
        generation: 1, deadline: ContinuousClock.now + .seconds(3600)
    )

    @Test("A port that runs in turn but isn't a settle port is refused and leaves no binding")
    func nonSettlePortLeavesNoBinding() async {
        let keeper = await Self.frozenNeverAttachedKeeper()
        // Both ports live to the end: the keeper holds its requester weakly, so a released port
        // would drop a stale binding by itself.
        let notSettle = RoutingPinPort(), settle = SettlePortFake()
        guard case .refused(.notCurrent) = await keeper.settleTurn(via: notSettle, fence: Self.fence) else {
            Issue.record("a port that isn't a settle port settled"); return
        }
        #expect(isSettled(await keeper.settleTurn(via: settle, fence: Self.fence)))
        withExtendedLifetime(notSettle) {}
    }

    @Test("A settle refused for a held sync flag leaves no binding")
    func syncInFlightLeavesNoBinding() async {
        let keeper = await Self.frozenNeverAttachedKeeper()
        let first = SettlePortFake(), second = SettlePortFake()
        _ = await keeper.beginSync(clearDirtyFlags: false)
        guard case .refused(.syncInFlight) = await keeper.settleTurn(via: first, fence: Self.fence) else {
            Issue.record("the settle wasn't refused for the held sync flag"); return
        }
        await keeper.endSync()
        #expect(isSettled(await keeper.settleTurn(via: second, fence: Self.fence)))
        withExtendedLifetime(first) {}
    }
}
