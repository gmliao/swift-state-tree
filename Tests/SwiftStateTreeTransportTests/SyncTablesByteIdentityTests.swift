// Tests/SwiftStateTreeTransportTests/SyncTablesByteIdentityTests.swift
//
// The broadcast diff on the typed sync tables (`TransportEnvConfig.useSyncTables`) replaces the
// snapshot extraction and tree diff of the broadcast fields, and nothing else: each recipient must
// get the same frames, byte for byte and in order, with the switch on and off, on every encoding,
// with dirty tracking on and off and with the one-pass extraction on and off.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

private func syncTablesConfig(tables: Bool, dirtyTracking: Bool, snapshotForSync: Bool, typedLeafValues: Bool = false) -> TransportEnvConfig {
    var config = TransportEnvConfig(
        enableDirtyTracking: dirtyTracking,
        useSnapshotForSync: snapshotForSync,
        syncStrategy: .delta,
        profilingConfig: nil
    )
    config.useSyncTables = tables
    config.typedLeafValues = typedLeafValues
    return config
}

/// Every encoding with dirty tracking and the one-pass extraction each on and off, without the
/// schema's path hashes (string paths) and with them, the path index on and off. With path hashes
/// the typed diff's patches carry their split, which the opcode encoders take.
private let syncTablesCells: [String] = dirtyIdentityEncodings.flatMap { encoding in
    [true, false].flatMap { dirty in
        [true, false].flatMap { onePass in
            ["paths", "hashes", "index"].map { schema in "\(encoding.0)|\(dirty)|\(onePass)|\(schema)" }
        }
    }
}

extension DirtyIdentityRun {
    /// More of the key space than the shared script: negative `Int` keys in a node map and a
    /// value map, created, changed and removed.
    func runNegativeKeys() async throws {
        try await step(1, add: -5, addUnit: -3)
        await sync()
        try await step(3, hitUnit: -3, moveBoss: 1)
        try await step(1, add: -6)
        await sync()
        try await step(1, remove: -5, removeUnit: -3)
        await sync()
        // A player that left comes back (the shared script's `leave(2)`): its whole view again.
        try await join(2)
        try await step(2, move: 2, item: "again", hitUnit: 1)
        await sync()
        await leave(2)
        try await step(1, title: "after")
        await sync()
    }
}

@Suite("The broadcast diff on the typed tables sends the same frames", .timeLimit(.minutes(1)))
struct SyncTablesByteIdentityTests {
    @Test("The same script sends the same frames with the tables on and off, and with typed leaves on", arguments: syncTablesCells)
    func onAndOffSendIdenticalFrames(cell: String) async throws {
        let parts = cell.split(separator: "|").map(String.init)
        let encoding = try #require(dirtyIdentityEncodings.first { $0.0 == parts[0] }?.1)
        let dirtyTracking = parts[1] == "true", onePass = parts[2] == "true"
        let pathHashes = parts[3] == "paths" ? nil : try dirtyIdentityPathHashes()
        let wire = encoding.withPathIndex(parts[3] == "index")
        let on = await DirtyIdentityRun(
            envConfig: syncTablesConfig(tables: true, dirtyTracking: dirtyTracking, snapshotForSync: onePass),
            encoding: wire,
            pathHashes: pathHashes
        )
        let off = await DirtyIdentityRun(
            envConfig: syncTablesConfig(tables: false, dirtyTracking: dirtyTracking, snapshotForSync: onePass),
            encoding: wire,
            pathHashes: pathHashes
        )
        // The tables with leaf fields converted by their typed form (`TYPED_LEAF_VALUES`).
        let leaf = await DirtyIdentityRun(
            envConfig: syncTablesConfig(tables: true, dirtyTracking: dirtyTracking, snapshotForSync: onePass, typedLeafValues: true),
            encoding: wire,
            pathHashes: pathHashes
        )
        #expect(await leaf.adapter.usesTypedLeafValuesForTesting())
        #expect(await !on.adapter.usesTypedLeafValuesForTesting())
        try await on.runScript()
        try await on.runNegativeKeys()
        try await off.runScript()
        try await off.runNegativeKeys()
        try await leaf.runScript()
        try await leaf.runNegativeKeys()
        let onFrames = await on.transport.sent
        let offFrames = await off.transport.sent
        #expect(onFrames.count > 20, "the script sends frames")
        expectSameFrames(onFrames, offFrames, cell)
        expectSameFrames(await leaf.transport.sent, offFrames, "\(cell), typed leaves")

        // Last-sent ends equal too: the tables, as a snapshot, against the broadcast cache.
        let tablesLastSent = await on.adapter.lastSentBroadcastSnapshotForTesting()
        let cache = await off.adapter.lastSentBroadcastSnapshotForTesting()
        #expect(tablesLastSent != nil, "the tables are seeded")
        #expect(tablesLastSent == cache, "\(cell): last-sent")
        // With the tables on, the engine's broadcast cache is never written.
        #expect(await on.adapter.syncEngineForTesting().cachedBroadcastSnapshotForTesting == nil)
    }

    @Test("A config built with init takes USE_SYNC_TABLES (on by default), so a whole test run can be switched")
    func initTakesTheEnvironment() async throws {
        let config = TransportEnvConfig(
            enableDirtyTracking: true,
            useSnapshotForSync: true,
            syncStrategy: .delta,
            profilingConfig: nil
        )
        let expected = EnvHelpers.getEnvBool(key: "USE_SYNC_TABLES", defaultValue: true)
        #expect(config.useSyncTables == expected)
        // The adapter follows the config: its engine's broadcast cache stays empty on the tables.
        let run = await DirtyIdentityRun(envConfig: config, encoding: .messagepack)
        #expect(await run.adapter.usesSyncTablesForTesting() == expected)
        try await run.runScript()
        let cache = await run.adapter.syncEngineForTesting().cachedBroadcastSnapshotForTesting
        #expect((cache == nil) == expected)
        #expect(await run.adapter.lastSentBroadcastSnapshotForTesting() != nil)
    }

    @Test("A config built with init takes TYPED_LEAF_VALUES (on by default), which applies only where the tables do")
    func initTakesTypedLeafValues() async throws {
        let expected = EnvHelpers.getEnvBool(key: "TYPED_LEAF_VALUES", defaultValue: true)
        var config = syncTablesConfig(tables: false, dirtyTracking: true, snapshotForSync: true)
        config.typedLeafValues = expected
        #expect(TransportEnvConfig(
            enableDirtyTracking: true, useSnapshotForSync: true, syncStrategy: .delta, profilingConfig: nil
        ).typedLeafValues == expected)
        // Tables off: the switch is ignored.
        let off = await DirtyIdentityRun(envConfig: config, encoding: .messagepack)
        #expect(await !off.adapter.usesTypedLeafValuesForTesting())
        // Tables on: the adapter follows the switch.
        config.useSyncTables = true
        let on = await DirtyIdentityRun(envConfig: config, encoding: .messagepack)
        #expect(await on.adapter.usesTypedLeafValuesForTesting() == expected)
    }

    @Test("The dirty-tracking land's broadcast fields are typed")
    func kinds() {
        // Otherwise the cells would compare the snapshot diff with itself.
        let tables = SyncTableBroadcastDiff<DirtyIdentityState>()
        #expect(tables.kinds == [
            "round": .value, "title": .value, "monsters": .value, "positions": .value,
            "units": .nodeMap, "boss": .node,
        ])
        #expect(tables.fallbackReasons.isEmpty, "\(tables.fallbackReasons)")
        #expect(!tables.alwaysSorts)
    }

    @Test("The full-snapshot strategy keeps today's path")
    func fullSnapshotKeepsTheCache() async throws {
        var config = TransportEnvConfig(
            enableDirtyTracking: true,
            useSnapshotForSync: true,
            syncStrategy: .fullSnapshot,
            profilingConfig: nil
        )
        config.useSyncTables = true
        let run = await DirtyIdentityRun(envConfig: config, encoding: .messagepack)
        try await run.runScript()
        #expect(await run.adapter.syncEngineForTesting().cachedBroadcastSnapshotForTesting != nil)
    }
}

/// Seeding follows today's broadcast cache: a diff that finds nothing seeded seeds the plan's
/// fields only and sends nothing, a late join in the same plan seeds every field over it, and a
/// field left out of a committed seed is set whole by its first diff.
@Suite("Seeding the typed tables")
struct SyncTablesSeedingTests {
    private func changedState() -> (seedState: DirtyIdentityState, later: DirtyIdentityState) {
        var state = DirtyIdentityState()
        state.round = 1
        state.monsters[5] = 50
        var later = state
        later.round = 2
        later.monsters[6] = 60
        return (state, later)
    }

    @Test("A dirty-only seed and a joiner's full seed in one plan: every field is seeded")
    func partialSeedThenJoinerInOnePlan() {
        let (state, later) = changedState()
        let tables = SyncTableBroadcastDiff<DirtyIdentityState>()
        var drops = ExtractionDrops()
        var staged = SyncTableStaged()
        // The plan's broadcast diff: only `round` is dirty.
        #expect(tables.planDiff(state, fields: ["round"], drops: &drops, into: &staged).isEmpty)
        #expect(staged.holdsBroadcastDiff)
        // Its joiner: the tables are still unseeded (nothing is committed), so it seeds all.
        #expect(tables.isSeeded == false)
        tables.stageSeed(state, fields: nil, drops: &drops, into: &staged)
        #expect(tables.lastSentSnapshot == nil, "nothing is written before the commit")
        tables.apply(staged)
        #expect(tables.isSeeded)
        #expect(tables.lastSentSnapshot(of: "monsters") == .object(["5": .int(50)]))

        let patches = tables.diff(later, fields: nil, drops: &drops).patches
        #expect(Set(patches.map(\.path)) == ["/round", "/monsters/6"], "an incremental diff, no whole set")
    }

    @Test("A committed dirty-only seed leaves the other fields to be set whole by their first diff")
    func committedPartialSeed() {
        let (state, later) = changedState()
        let tables = SyncTableBroadcastDiff<DirtyIdentityState>()
        var drops = ExtractionDrops()
        var staged = SyncTableStaged()
        #expect(tables.planDiff(state, fields: ["round"], drops: &drops, into: &staged).isEmpty)
        tables.apply(staged)
        #expect(tables.isSeeded, "a later late join doesn't seed again")
        #expect(tables.lastSentSnapshot(of: "round") == .int(1))
        #expect(tables.lastSentSnapshot(of: "monsters") == nil)

        var next = SyncTableStaged()
        let patches = tables.planDiff(later, fields: nil, drops: &drops, into: &next)
        #expect(patches.contains(StatePatch(path: "/round", operation: .set(.int(2)))))
        #expect(
            patches.contains(StatePatch(path: "/monsters", operation: .set(.object(["5": .int(50), "6": .int(60)])))),
            "the unseeded field is set whole"
        )
        #expect(!patches.contains { $0.path == "/monsters/6" })
    }

    @Test("A discarded plan leaves the tables unseeded")
    func discardedSeed() {
        let (state, _) = changedState()
        let tables = SyncTableBroadcastDiff<DirtyIdentityState>()
        var drops = ExtractionDrops()
        var staged = SyncTableStaged()
        _ = tables.planDiff(state, fields: nil, drops: &drops, into: &staged)
        #expect(!staged.isEmpty)
        // The plan failed: `staged` is dropped, not applied.
        #expect(tables.isSeeded == false)
        #expect(tables.lastSentSnapshot == nil)
    }
}
