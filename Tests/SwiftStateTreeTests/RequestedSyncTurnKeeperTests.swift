// Tests/SwiftStateTreeTests/RequestedSyncTurnKeeperTests.swift
//
// The keeper's requested sync turns (#546 L2a), against a fake in-turn transport: a committed
// phase that reports events still queued (`keepsEvents`) gets one sync-only turn right after
// its turn on a land without periodic sync, and none on a land with periodic sync. The
// adapter's in-turn phase reads its event queue synchronously, so no adapter test reaches this
// rule; the legacy follow-up it preserves is pinned on the off adapter
// (`TransportAdapterPendingEventsAcrossCyclesTests`, tests 7 and 7c).

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct RequestedSyncTurnKeeperState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0

    public init() {}
}

private func requestedSyncTurnKeeperLand(periodic: Bool) -> LandDefinition<RequestedSyncTurnKeeperState> {
    if periodic {
        return Land("requested-sync-turn-keeper", using: RequestedSyncTurnKeeperState.self) {
            Lifetime {
                StateSync(every: .seconds(3600)) { (_: RequestedSyncTurnKeeperState, _: LandContext) in }
            }
        }
    }
    return Land("requested-sync-turn-keeper", using: RequestedSyncTurnKeeperState.self) {
        Rules {}
    }
}

/// In-turn transport whose first `keptPhases` committed phases report events still queued.
private final class KeptEventsReportingTransport: LandKeeperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var keptLeft: Int
    private var phases = 0

    init(keptPhases: Int) { keptLeft = keptPhases }

    /// Sync phases the keeper ran.
    var phaseCount: Int { lock.withLock { phases } }

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
        let kept: Bool = lock.withLock {
            phases += 1
            guard keptLeft > 0 else { return false }
            keptLeft -= 1
            return true
        }
        return InTurnSyncOutput(.committed(clearDirtyFlags: true), syncStream: [], keepsEvents: kept)
    }
}

@Suite("The keeper's requested sync turns (#546 L2a)", .timeLimit(.minutes(1)))
struct RequestedSyncTurnKeeperTests {
    @Test("A commit that keeps events gets one sync-only turn after it, without periodic sync only", arguments: [false, true])
    func keptEventsRequestOneTurn(periodic: Bool) async throws {
        let transport = KeptEventsReportingTransport(keptPhases: 1)
        let keeper = LandKeeper<RequestedSyncTurnKeeperState>(
            definition: requestedSyncTurnKeeperLand(periodic: periodic),
            initialState: RequestedSyncTurnKeeperState(),
            // A sync loop that doesn't start isn't periodic sync; hourly, it never fires here.
            autoStartLoops: periodic
        )
        await keeper.setTransport(transport)
        #expect(await keeper.hasPeriodicSync == periodic)

        #expect(await keeper.syncTurnNow(via: transport, reason: .syncNow) == .committed(clearDirtyFlags: true))
        await keeper.waitForRequestedSyncTurnsForTesting()
        let kept = await keeper.requestedSyncTurnsForTesting[.keptEvents, default: 0]
        if periodic {
            // The next periodic phase delivers them: no request.
            #expect(kept == 0)
            #expect(transport.phaseCount == 1)
        } else {
            // One more phase, which keeps nothing: no further request.
            #expect(kept == 1)
            #expect(transport.phaseCount == 2)
        }
        #expect(await !keeper.hasRequestedSyncWorkForTesting)
    }

    @Test("A request through a port that isn't the keeper's binding runs nothing")
    func requestThroughAnotherPortIsSkipped() async throws {
        let bound = KeptEventsReportingTransport(keptPhases: 0)
        let other = KeptEventsReportingTransport(keptPhases: 0)
        let keeper = LandKeeper<RequestedSyncTurnKeeperState>(
            definition: requestedSyncTurnKeeperLand(periodic: false),
            initialState: RequestedSyncTurnKeeperState(),
            autoStartLoops: false
        )
        await keeper.setTransport(bound)
        #expect(await keeper.syncTurnNow(via: other, reason: .syncNow) == .skipped)
        #expect(other.phaseCount == 0)
        #expect(await keeper.syncTurnNow(via: bound, reason: .syncNow) == .committed(clearDirtyFlags: true))
        #expect(bound.phaseCount == 1)
    }
}
