import Foundation
import SwiftStateTree
import SwiftStateTreeMessagePack
import SwiftStateTurns
import Testing
@testable import SwiftStateTreeTransport

/// Every type the adapter's sync and lag state holds, stored in one plain-data value: the state a
/// turn machine takes over (#546). `@PlainData` checks each field's type at compile time, so a
/// type that isn't plain data fails this file's build, before any machine stores it.
///
/// Configuration and tools stay out: the encoders, the writer, the per-player and broadcast
/// tables, the layout table and the sync-stream draft builders.
@PlainData
private struct AdapterSyncStateInventory {
    // The sync state.
    var syncSkips: SyncSkipCounts
    var lastSyncSeq: UInt64
    var planSyncSeq: UInt64?
    var planResyncPlayers: Set<PlayerID>
    var syncEngine: SyncEngine.Caches
    var pendingEventManager: PendingEventManager
    var carriedDirtyFields: Set<String>
    var keyScopeResetPending: Bool
    var broadcastKeysMayBeDefined: Bool
    var syncPhaseCommits: UInt64
    // The sync stream's sets.
    var syncStreamSeededPlayers: Set<PlayerID>
    var syncStreamUnverifiedPlayers: Set<PlayerID>
    var syncStreamViewPlayers: Set<PlayerID>
    var syncStreamUnqueuedEvents: [Int64]
    var syncStreamUnmergedEvents: ReevaluationUnmergedEvents
    // The lag state.
    var syncLag: [SessionID: SyncLagSession]
    var syncLagTimerSyncRequestedEpoch: UInt64?
    // What the lag and the event queues hold, named so a change of their storage can't hide one.
    var lagEntry: SyncLagSession.Entry
    var lagPhase: SyncLagSession.Phase
    var targetedEvent: PendingEventManager.TargetedEvent
    var stamp: MembershipStamp
    var target: SwiftStateTree.EventTarget
    var digest: CanonicalSyncEvent
    var body: MessagePackValue
    var snapshot: StateSnapshot
    var snapshotValue: SnapshotValue
    var client: ClientID
    var bytes: Data
    var instant: TurnInstant
}

@Suite("The adapter's sync state is plain data")
struct AdapterStateInventoryTests {
    /// The check is the build; this pins that the inventory conforms, so the file can't be
    /// dropped from the target without a test going missing.
    @Test("The inventory of the sync and lag state conforms to PlainData")
    func inventoryIsPlainData() {
        func isPlain<T: PlainData>(_: T.Type) -> Bool { true }
        #expect(isPlain(AdapterSyncStateInventory.self))
        #expect(isPlain(SyncEngine.Caches.self))
        #expect(isPlain(SyncLagSession.self))
        #expect(isPlain(PendingEventManager.self))
    }
}
