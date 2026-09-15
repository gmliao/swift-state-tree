// Tests/SwiftStateTreeTransportTests/SyncStrategyEquivalenceTests.swift
//
// Drives one Land with the same script under both sync strategies and checks that
// every session's client-side view, rebuilt from the received patches, is identical
// after every sync — and identical to the authoritative per-player snapshot.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
private struct EquivState: StateNodeProtocol {
    @Sync(.broadcast) var tick: Int = 0
    @Sync(.broadcast) var monsters: [Int: Int] = [:]
    @Sync(.perPlayerSlice()) var inventories: [PlayerID: [String]] = [:]
    @Sync(.serverOnly) var secret: Int = 0
    init() {}
}

// Note: `@Payload` rejects `Optional` fields ("use a concrete value with a default
// instead"), so "no value" is encoded with sentinels (0 / "") rather than nil.
// Test scripts below never pass 0 as a real monster id, so this is unambiguous.
@Payload
private struct EquivStepEvent: ClientEventPayload {
    let addMonster: Int
    let removeMonster: Int
    let item: String
    /// Sentinel: when `true`, the handler removes the acting player's per-player-slice entry
    /// (`state.inventories.removeValue(forKey:)`), simulating a conditional per-player field
    /// disappearing from a still-connected player's view.
    let clearInventory: Bool
}

/// Minimal client model: a JSON-pointer patch applier over a SnapshotValue tree.
private struct ClientView: Equatable {
    var root: [String: SnapshotValue] = [:]

    mutating func apply(_ patches: [StatePatch]) {
        for patch in patches {
            let parts = patch.path.split(separator: "/").map { String($0).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
            guard !parts.isEmpty else { continue }
            switch patch.operation {
            case .set(let value): root = Self.setting(root, parts[...], value)
            case .add(let value): root = Self.setting(root, parts[...], value)
            case .delete: root = Self.deleting(root, parts[...])
            }
        }
    }

    private static func setting(_ obj: [String: SnapshotValue], _ parts: ArraySlice<String>, _ value: SnapshotValue) -> [String: SnapshotValue] {
        var obj = obj
        let key = parts[parts.startIndex]
        if parts.count == 1 { obj[key] = value; return obj }
        let child = obj[key]?.objectValue ?? [:]
        obj[key] = .object(setting(child, parts.dropFirst(), value))
        return obj
    }

    private static func deleting(_ obj: [String: SnapshotValue], _ parts: ArraySlice<String>) -> [String: SnapshotValue] {
        var obj = obj
        let key = parts[parts.startIndex]
        if parts.count == 1 { obj[key] = nil; return obj }
        guard let child = obj[key]?.objectValue else { return obj }
        obj[key] = .object(deleting(child, parts.dropFirst()))
        return obj
    }
}

private struct Harness {
    let keeper: LandKeeper<EquivState>
    let adapter: TransportAdapter<EquivState>
    let transport: SessionRecordingTransport
    var views: [SessionID: ClientView] = [:]
    var cumulativeBytes = 0

    init(strategy: SyncStrategy, useSnapshotForSync: Bool, landID: String) {
        let definition = Land(landID, using: EquivState.self) {
            ClientEvents { Register(EquivStepEvent.self) }
            Rules {
                OnJoin { (state: inout EquivState, ctx: LandContext) in
                    state.inventories[ctx.playerID] = []
                }
                OnLeave { (state: inout EquivState, ctx: LandContext) in
                    state.inventories.removeValue(forKey: ctx.playerID)
                }
                HandleEvent(EquivStepEvent.self) { (state: inout EquivState, ev: EquivStepEvent, ctx: LandContext) in
                    state.tick += 1
                    state.secret += 7
                    if ev.addMonster != 0 { state.monsters[ev.addMonster] = 100 - ev.addMonster }
                    if ev.removeMonster != 0 { state.monsters.removeValue(forKey: ev.removeMonster) }
                    if ev.clearInventory { state.inventories.removeValue(forKey: ctx.playerID) }
                    if !ev.item.isEmpty { state.inventories[ctx.playerID, default: []].append(ev.item) }
                }
            }
        }
        transport = SessionRecordingTransport()
        keeper = LandKeeper<EquivState>(definition: definition, initialState: EquivState())
        adapter = TransportAdapter<EquivState>(
            keeper: keeper,
            transport: transport,
            landID: landID,
            transportEnvConfig: TransportEnvConfig(
                enableDirtyTracking: true,
                useSnapshotForSync: useSnapshotForSync,
                syncStrategy: strategy,
                enableChangeObjectMetrics: false,
                changeObjectMetricsLogEvery: 10,
                changeObjectMetricsEmaAlpha: 0.2,
                enableAutoDirtyTracking: false,
                autoDirtyOffThreshold: 0.55,
                autoDirtyOnThreshold: 0.30,
                autoDirtyRequiredConsecutiveSamples: 30,
                profilingConfig: nil
            )
        )
    }

    func start() async { await transport.setDelegate(adapter) }

    mutating func join(_ n: Int) async throws {
        let s = SessionID("s\(n)"); let c = ClientID("c\(n)"); let p = PlayerID("p\(n)")
        await adapter.onConnect(sessionID: s, clientID: c)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: s, clientID: c, playerID: p)
        views[s] = ClientView()
    }

    func leave(_ n: Int) async {
        await adapter.onDisconnect(sessionID: SessionID("s\(n)"), clientID: ClientID("c\(n)"))
    }

    func step(_ n: Int, add: Int? = nil, remove: Int? = nil, item: String? = nil, clearInventory: Bool = false) async throws {
        try await keeper.handleClientEvent(
            AnyClientEvent(EquivStepEvent(addMonster: add ?? 0, removeMonster: remove ?? 0, item: item ?? "", clearInventory: clearInventory)),
            playerID: PlayerID("p\(n)"), clientID: ClientID("c\(n)"), sessionID: SessionID("s\(n)")
        )
        // `LandKeeper.handleClientEvent` on a tickless land (no `Lifetime { Tick(...) }` handler)
        // processes the event on a detached, un-awaited `Task` and returns immediately — see
        // `LandKeeper.handleClientEvent`'s `if definition.lifetimeHandlers.tickHandler == nil { Task { ... } }`
        // branch. Without waiting here, a `syncNow()` called right after `step()` can race ahead of
        // the mutation and observe stale (non-dirty) state, silently dropping that round's diff under
        // the delta strategy. This mirrors the wait used after `handleClientEvent` elsewhere in the
        // suite (e.g. `Tests/SwiftStateTreeTests/ActionEventSyncTests.swift`).
        try await Task.sleep(for: .milliseconds(50))
    }

    /// Drain everything the transport has sent so far into the client views.
    mutating func drain() async throws {
        try await Task.sleep(for: .milliseconds(100))
        for session in views.keys {
            for update in decodeStateUpdates(await transport.messages(for: session)) {
                switch update {
                case .firstSync(let p), .diff(let p): views[session]!.apply(p)
                case .noChange: break
                }
            }
        }
        cumulativeBytes += await totalBytes()
        await transport.clear()
    }

    func totalBytes() async -> Int { await transport.sent.reduce(0) { $0 + $1.data.count } }
}

/// Authoritative view a client should hold: broadcast fields + its per-player slice.
private func authoritativeView(_ keeper: LandKeeper<EquivState>, _ playerID: PlayerID) async throws -> [String: SnapshotValue] {
    let state = await keeper.currentState()
    return try SyncEngine().snapshot(for: playerID, from: state).values
}

/// Verify both harnesses agree with each other and with the authoritative snapshot
/// after a given phase of the script.
private func checkpoint(_ label: String, delta: inout Harness, full: inout Harness) async throws {
    try await delta.drain(); try await full.drain()
    for (session, deltaView) in delta.views {
        let fullView = full.views[session]!
        #expect(deltaView == fullView, "[\(label)] view mismatch for \(session.rawValue)")
        let playerID = PlayerID("p" + session.rawValue.dropFirst())
        let auth = try await authoritativeView(delta.keeper, playerID)
        #expect(deltaView.root == auth, "[\(label)] delta view != authoritative for \(session.rawValue)")
    }
}

@Test("delta and full-snapshot rebuild identical client views after every sync", arguments: [true, false])
func testStrategiesAreEquivalent(useSnapshotForSync: Bool) async throws {
    var delta = Harness(strategy: .delta, useSnapshotForSync: useSnapshotForSync, landID: "equiv-delta-\(useSnapshotForSync)")
    var full = Harness(strategy: .fullSnapshot, useSnapshotForSync: useSnapshotForSync, landID: "equiv-full-\(useSnapshotForSync)")
    await delta.start(); await full.start()

    // Script: same sequence applied to both harnesses.
    for n in 1...3 { try await delta.join(n); try await full.join(n) }
    try await delta.drain(); try await full.drain()

    for round in 1...5 {
        try await delta.step(1, add: round);           try await full.step(1, add: round)
        try await delta.step(2, item: "item\(round)"); try await full.step(2, item: "item\(round)")
        await delta.adapter.syncNow();                 await full.adapter.syncNow()
        try await checkpoint("round \(round)", delta: &delta, full: &full)
    }

    // Idle sync: nothing changed.
    await delta.adapter.syncNow(); await full.adapter.syncNow()
    try await checkpoint("idle", delta: &delta, full: &full)

    // Removal + leave + late join.
    try await delta.step(3, remove: 2); try await full.step(3, remove: 2)
    await delta.adapter.syncNow();      await full.adapter.syncNow()
    try await checkpoint("remove", delta: &delta, full: &full)

    // A still-connected player's conditional per-player field disappears from its own view
    // (e.g. `@Sync(.perPlayerSlice())` losing its entry for that player) and later reappears.
    // Player 1 stays connected for the whole script, so this exercises the bug this test guards
    // against without conflating it with the leave/late-join path below: under `.fullSnapshot`,
    // the diff used to be computed against an empty baseline every sync, so a top-level key that
    // is simply absent from the new per-player snapshot produced neither `.set` nor `.delete` and
    // the client kept the stale "inventories" value forever.
    try await delta.step(1, clearInventory: true); try await full.step(1, clearInventory: true)
    await delta.adapter.syncNow();                 await full.adapter.syncNow()
    try await checkpoint("slice-vanished", delta: &delta, full: &full)

    try await delta.step(1, item: "back"); try await full.step(1, item: "back")
    await delta.adapter.syncNow();         await full.adapter.syncNow()
    try await checkpoint("slice-restored", delta: &delta, full: &full)

    await delta.leave(2); await full.leave(2)
    delta.views[SessionID("s2")] = nil; full.views[SessionID("s2")] = nil
    await delta.adapter.syncNow(); await full.adapter.syncNow()
    try await checkpoint("leave", delta: &delta, full: &full)

    try await delta.join(4); try await full.join(4)
    try await delta.step(4, add: 42, item: "late"); try await full.step(4, add: 42, item: "late")
    await delta.adapter.syncNow(); await full.adapter.syncNow()
    try await checkpoint("late-join", delta: &delta, full: &full)

    // Sanity: delta never sends more than full over the whole script.
    #expect(delta.cumulativeBytes <= full.cumulativeBytes,
            "delta sent \(delta.cumulativeBytes) B, full sent \(full.cumulativeBytes) B")
}
