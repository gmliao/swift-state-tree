// Tests/SwiftStateTreeTransportTests/TransportAdapterSyncStrategyTests.swift

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
private struct StrategyTestState: StateNodeProtocol {
    @Sync(.broadcast) var tick: Int = 0
    @Sync(.broadcast) var label: String = "idle"
    @Sync(.perPlayerSlice()) var scores: [PlayerID: Int] = [:]
    init() {}
}

/// Records every send with its target so per-session streams can be reconstructed.
actor SessionRecordingTransport: Transport {
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

/// Decode JSON-encoded state updates; non-state frames (events) are skipped.
func decodeStateUpdates(_ frames: [Data]) -> [StateUpdate] {
    let decoder = JSONStateUpdateDecoder()
    return frames.compactMap { try? decoder.decode(data: $0).update }
}

private func makeEnvConfig(strategy: SyncStrategy, useSnapshotForSync: Bool) -> TransportEnvConfig {
    TransportEnvConfig(
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
}

@Test("full-snapshot strategy sends the complete view every sync, even with no change", arguments: [true, false])
func testFullSnapshotSendsEverySync(useSnapshotForSync: Bool) async throws {
    let definition = Land("strategy-test", using: StrategyTestState.self) {
        Rules {
            OnJoin { (state: inout StrategyTestState, ctx: LandContext) in
                state.scores[ctx.playerID] = 0
            }
        }
    }
    let transport = SessionRecordingTransport()
    let keeper = LandKeeper<StrategyTestState>(definition: definition, initialState: StrategyTestState())
    let adapter = TransportAdapter<StrategyTestState>(
        keeper: keeper,
        transport: transport,
        landID: "strategy-test",
        transportEnvConfig: makeEnvConfig(strategy: .fullSnapshot, useSnapshotForSync: useSnapshotForSync)
    )
    await transport.setDelegate(adapter)

    let session = SessionID("s1")
    let client = ClientID("c1")
    let player = PlayerID("p1")
    await adapter.onConnect(sessionID: session, clientID: client)
    try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: player)
    try await Task.sleep(for: .milliseconds(100))
    await transport.clear()

    // Two syncs with no state change at all.
    await adapter.syncNow()
    try await Task.sleep(for: .milliseconds(100))
    await adapter.syncNow()
    try await Task.sleep(for: .milliseconds(100))

    let updates = decodeStateUpdates(await transport.messages(for: session))
    #expect(updates.count == 2, "full-snapshot must send on every sync; got \(updates.count)")
    for update in updates {
        guard case .diff(let patches) = update else {
            Issue.record("expected .diff, got \(update)")
            continue
        }
        let paths = Set(patches.map(\.path))
        #expect(paths.contains("/tick"))
        #expect(paths.contains("/label"))
        #expect(paths.contains("/scores"))
        #expect(patches.allSatisfy { if case .set = $0.operation { return true } else { return false } })
    }
}

@Test("delta strategy (default) sends nothing when nothing changed", arguments: [true, false])
func testDeltaSendsNothingWhenUnchanged(useSnapshotForSync: Bool) async throws {
    let definition = Land("strategy-test-delta", using: StrategyTestState.self) {
        Rules {
            OnJoin { (state: inout StrategyTestState, ctx: LandContext) in
                state.scores[ctx.playerID] = 0
            }
        }
    }
    let transport = SessionRecordingTransport()
    let keeper = LandKeeper<StrategyTestState>(definition: definition, initialState: StrategyTestState())
    let adapter = TransportAdapter<StrategyTestState>(
        keeper: keeper,
        transport: transport,
        landID: "strategy-test-delta",
        transportEnvConfig: makeEnvConfig(strategy: .delta, useSnapshotForSync: useSnapshotForSync)
    )
    await transport.setDelegate(adapter)

    let session = SessionID("s1")
    let client = ClientID("c1")
    await adapter.onConnect(sessionID: session, clientID: client)
    try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: PlayerID("p1"))
    try await Task.sleep(for: .milliseconds(100))
    // First regular sync after join may emit firstSync bookkeeping; drain it.
    await adapter.syncNow()
    try await Task.sleep(for: .milliseconds(100))
    await transport.clear()

    await adapter.syncNow()
    try await Task.sleep(for: .milliseconds(100))
    let updates = decodeStateUpdates(await transport.messages(for: session))
    #expect(updates.isEmpty, "delta must not send when unchanged; got \(updates)")
}
