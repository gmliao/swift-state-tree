// Tests/SwiftStateTreeTransportTests/TransportAdapterSnapshotForSyncCacheTests.swift
//
// Regression test for a broadcast-cache seeding bug on the snapshotForSync path
// (USE_SNAPSHOT_FOR_SYNC, on by default): when only a per-player field is dirty,
// `extractSyncSnapshots` extracts broadcast + per-player fields together against a single
// combined dirty-field mode, excluding untouched broadcast fields from the extracted
// snapshot. If the diff is then computed with a mismatched "no filtering" mode, the
// broadcast cache gets seeded with that incomplete snapshot, and the next (truly
// unchanged) sync reports the previously-excluded broadcast fields as newly added.
//
// This reproduces with the *default* adapter configuration: USE_SNAPSHOT_FOR_SYNC is
// unset (defaults to the snapshotForSync path), so no `transportEnvConfig:` override
// is needed here.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
private struct SnapshotCacheTestState: StateNodeProtocol {
    @Sync(.broadcast) var tick: Int = 0
    @Sync(.perPlayerSlice()) var scores: [PlayerID: Int] = [:]
    init() {}
}

/// Records every send with its target so per-session streams can be reconstructed.
private actor CacheTestRecordingTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var sent: [(target: SwiftStateTreeTransport.EventTarget, data: Data)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append((target, message))
    }
    func messages(for sessionID: SessionID) -> [Data] {
        sent.compactMap { entry in
            if case .session(let id) = entry.target, id == sessionID { return entry.data }
            return nil
        }
    }
    func clear() { sent.removeAll() }
}

@Test("snapshotForSync path does not resend unchanged broadcast fields after a per-player-only dirty sync")
func testSnapshotForSyncDoesNotReplayUnchangedBroadcastFieldsAfterPerPlayerOnlyDirtySync() async throws {
    let definition = Land("snapshot-cache-test", using: SnapshotCacheTestState.self) {
        Rules {
            OnJoin { (state: inout SnapshotCacheTestState, ctx: LandContext) in
                // Only mutates a per-player field; the broadcast field ("tick") stays untouched.
                state.scores[ctx.playerID] = 0
            }
        }
    }
    let transport = CacheTestRecordingTransport()
    let keeper = LandKeeper<SnapshotCacheTestState>(definition: definition, initialState: SnapshotCacheTestState())
    // Default init: no `transportEnvConfig:` override, so USE_SNAPSHOT_FOR_SYNC's default
    // (the snapshotForSync path) is exercised, exactly as in production without env overrides.
    let adapter = TransportAdapter<SnapshotCacheTestState>(
        keeper: keeper,
        transport: transport,
        landID: "snapshot-cache-test"
    )
    await transport.setDelegate(adapter)

    let session = SessionID("s1")
    let client = ClientID("c1")
    let player = PlayerID("p1")
    await adapter.onConnect(sessionID: session, clientID: client)
    try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: player)
    try await Task.sleep(for: .milliseconds(100))

    // First regular sync after join: only "scores" (per-player) is dirty. This is where the
    // broadcast cache used to get seeded with an incomplete snapshot (missing "tick").
    await adapter.syncNow()
    try await Task.sleep(for: .milliseconds(100))
    await transport.clear()

    // Second sync: nothing changed at all.
    await adapter.syncNow()
    try await Task.sleep(for: .milliseconds(100))

    let decoder = JSONStateUpdateDecoder()
    let updates = (await transport.messages(for: session)).compactMap { try? decoder.decode(data: $0).update }
    #expect(updates.isEmpty, "unchanged sync must not resend previously-excluded broadcast fields; got \(updates)")
}
