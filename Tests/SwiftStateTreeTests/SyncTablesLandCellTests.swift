// Tests/SwiftStateTreeTests/SyncTablesLandCellTests.swift
//
// The broadcast diff on the typed sync tables (`TransportEnvConfig.useSyncTables`) must send the
// frames today's snapshot diff sends. Two lands run one script on an adapter with the switch on
// and on one with it off, and each recipient must get the same frames, byte for byte and in
// order, in every encoding, with string paths, path hashes and the path index:
//
// - the shape matrix state: atomic values, nested optionals, arrays, value maps with odd keys;
// - the nested-policy state: node maps by `String`, `PlayerID` and `Int`, nodes held directly,
//   optionally, in an array and two levels deep, with masked and server-only fields inside rows
//   and per-player fields beside them.
//
// The scripts add, change and remove entries, use escaped, NFC/NFD and negative keys, and have
// players join mid-run, leave and come back. Failed plans, key scope resets, encode drops, a
// throwing field and a forced resync are compared across the switch in the transport tests,
// where their fixtures are.
//
// The diff and the sends iterate dictionaries, whose order Swift seeds per process: run the
// suite in several processes to cover more orders.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
import SwiftStateTreeDeterministicMath

/// One scripted mutation: `op` picks it, `n` varies it.
@Payload
struct LandCellStep: ClientEventPayload {
    let op: Int
    let n: Int
}

/// Every frame sent, in order, with its target.
private actor LandCellTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var sent: [(target: String, data: Data)] = []
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append(("\(target)", message))
    }
}

/// `autoDirty`: the change-object metric and the auto switch on, switching after
/// `autoDirtySamples` samples (2 by default, so short scripts switch). `metricsFromRows`: `TransportEnvConfig.changeMetricsFromRows`.
private func landCellConfig(tables: Bool, dirtyTracking: Bool, autoDirty: Bool = false, autoDirtySamples: Int = 2, metricsFromRows: Bool = true) -> TransportEnvConfig {
    var config = TransportEnvConfig(
        enableDirtyTracking: dirtyTracking,
        useSnapshotForSync: true,
        syncStrategy: .delta,
        enableChangeObjectMetrics: false,
        changeObjectMetricsLogEvery: 10,
        changeObjectMetricsEmaAlpha: autoDirty ? 0.5 : 0.2,
        enableAutoDirtyTracking: autoDirty,
        autoDirtyOffThreshold: 0.55,
        autoDirtyOnThreshold: 0.30,
        autoDirtyRequiredConsecutiveSamples: autoDirty ? autoDirtySamples : 30,
        profilingConfig: nil
    )
    config.useSyncTables = tables
    config.changeMetricsFromRows = metricsFromRows
    return config
}

/// A land and its adapter, driven one step at a time.
private struct LandCellRun<State: StateNodeProtocol> {
    let keeper: LandKeeper<State>
    let adapter: TransportAdapter<State>
    let transport: LandCellTransport

    init(
        definition: LandDefinition<State>,
        landID: String,
        tables: Bool,
        dirtyTracking: Bool,
        encoding: TransportEncodingConfig,
        pathHashes: [String: UInt32]?,
        autoDirty: Bool = false,
        autoDirtySamples: Int = 2,
        metricsFromRows: Bool = true
    ) async {
        transport = LandCellTransport()
        // No sync loop: syncs happen only where the script asks, so runs are comparable.
        keeper = LandKeeper<State>(definition: definition, initialState: State(), autoStartLoops: false)
        adapter = TransportAdapter<State>(
            keeper: keeper,
            transport: transport,
            landID: landID,
            transportEnvConfig: landCellConfig(tables: tables, dirtyTracking: dirtyTracking, autoDirty: autoDirty, autoDirtySamples: autoDirtySamples, metricsFromRows: metricsFromRows),
            encodingConfig: encoding,
            pathHashes: pathHashes,
            suppressMissingPathHashesWarning: true
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
    }

    func join(_ name: String) async throws {
        let session = SessionID("s-\(name)"), client = ClientID("c-\(name)")
        await adapter.onConnect(sessionID: session, clientID: client)
        _ = try await adapter.performJoin(
            playerSession: PlayerSession(playerID: name),
            clientID: client,
            sessionID: session,
            authInfo: nil
        )
        await adapter.syncStateForNewPlayer(playerID: PlayerID(name), sessionID: session)
        await keeper.waitForInFlightWorkForTesting()
    }

    func leave(_ name: String) async {
        await adapter.onDisconnect(sessionID: SessionID("s-\(name)"), clientID: ClientID("c-\(name)"))
        await keeper.waitForInFlightWorkForTesting()
    }

    func step(_ op: Int, _ n: Int = 0, as name: String = "alice") async throws {
        try await keeper.handleClientEvent(
            AnyClientEvent(LandCellStep(op: op, n: n)),
            playerID: PlayerID(name), clientID: ClientID("c-\(name)"), sessionID: SessionID("s-\(name)")
        )
        await keeper.waitForInFlightWorkForTesting()
    }

    func sync() async {
        await adapter.syncNow()
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
    }

    /// The script: `ops` in order, a sync every `syncEvery` steps, with joins, a leave and a
    /// return spread over it, and idle syncs.
    func runScript(ops: [(op: Int, n: Int)], syncEvery: Int = 3, afterSync: (() async -> Void)? = nil) async throws {
        try await join("alice")
        try await join("bob")
        await sync()
        await afterSync?()
        for (index, step) in ops.enumerated() {
            try await self.step(step.op, step.n)
            if index % syncEvery == syncEvery - 1 {
                await sync()
                await afterSync?()
            }
            if index == ops.count / 4 { try await join("carol") }
            if index == ops.count / 2 { await leave("bob") }
            if index == ops.count * 3 / 4 { try await join("bob") }
        }
        await sync()
        await afterSync?()
        await sync()
        await afterSync?()
    }

    /// The change-object metric after the last sync, as one comparable line: changed objects,
    /// total, the EMA and its samples, and the dirty tracking mode.
    func metricLine() async -> String {
        let metrics = await adapter.lastChangeMetricsForTesting()
        let ema = await adapter.changeRateEmaForTesting()
        let dirty = await adapter.dirtyTrackingEnabledForTesting()
        return "\(metrics.map { "\($0.changed)/\($0.total)" } ?? "-") ema \(ema.ema) n \(ema.samples) dirty \(dirty)"
    }
}

/// A frame for a failure message: JSON text as is, MessagePack in hex.
private func landFrameText(_ data: Data) -> String {
    if let first = data.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
        return String(decoding: data, as: UTF8.self)
    }
    return data.map { String(format: "%02x", $0) }.joined()
}

/// Each recipient got the same frames, in order.
private func expectSameLandFrames(
    _ on: [(target: String, data: Data)],
    _ off: [(target: String, data: Data)],
    _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let left = Dictionary(grouping: on, by: \.target).mapValues { $0.map(\.data) }
    let right = Dictionary(grouping: off, by: \.target).mapValues { $0.map(\.data) }
    #expect(Set(left.keys) == Set(right.keys), "\(label): recipients", sourceLocation: sourceLocation)
    for target in left.keys.sorted() {
        let mine = left[target] ?? [], theirs = right[target] ?? []
        guard mine.count == theirs.count else {
            let first = zip(mine, theirs).enumerated().first { $0.element.0 != $0.element.1 }
            let detail = first.map { "; first difference at frame \($0.offset): \(landFrameText($0.element.0)) vs \(landFrameText($0.element.1))" } ?? ""
            Issue.record("\(label): \(target) got \(mine.count) vs \(theirs.count) frames\(detail)", sourceLocation: sourceLocation)
            continue
        }
        for (index, (one, other)) in zip(mine, theirs).enumerated() where one != other {
            Issue.record(
                "\(label): \(target) frame \(index) differs: \(landFrameText(one)) vs \(landFrameText(other))",
                sourceLocation: sourceLocation
            )
            break
        }
    }
}

private let landCellEncodings: [(String, TransportEncodingConfig)] = [
    ("json", .json),
    ("jsonOpcode", .jsonOpcode),
    ("messagepack", .messagepack),
]

/// Every encoding with dirty tracking on and off, with string paths, path hashes and the path
/// index.
private let landCells: [String] = landCellEncodings.flatMap { encoding in
    [true, false].flatMap { dirty in
        ["paths", "hashes", "index"].map { schema in "\(encoding.0)|\(dirty)|\(schema)" }
    }
}

// MARK: - The shape matrix land

private let shapeKeys = ["a", "a/b", "t~x", "", "e\u{301}", "\u{e9}", "-1"]

private func makeShapeMatrixCellLand() -> LandDefinition<ShapeMatrixState> {
    Land("shape-matrix-cell", using: ShapeMatrixState.self) {
        ClientEvents { Register(LandCellStep.self) }
        Rules {
            HandleEvent(LandCellStep.self) { (state: inout ShapeMatrixState, step: LandCellStep, _: LandContext) in
                let n = step.n
                let at = Position2(x: Float(n), y: Float(-n))
                let key = shapeKeys[abs(n) % shapeKeys.count]
                switch step.op {
                case 0: state.pos = at
                case 1: state.angle = Angle(degrees: Float(n * 15))
                case 2: state.maybePos = n % 2 == 0 ? nil : at
                case 3: state.holder = n % 3 == 0 ? nil : ShapeHolder(
                    inner: n % 3 == 1 ? nil : ShapeInner(at: n % 2 == 0 ? at : nil, heading: Angle(degrees: Float(n))),
                    tag: n
                )
                case 4: state.wrapper = ShapeWrapper(at: at)
                case 5: state.mark = ShapeMark(x: Int32(n), y: Int32(n * 2))
                case 6: state.fixed = ShapeFixed(at: at, label: "l\(n)")
                case 7: state.points.append(at)
                case 8: if !state.points.isEmpty { state.points.removeFirst() }
                case 9: state.maybePoints = n % 2 == 0 ? nil : [at, at]
                case 10: state.angles = (0..<(abs(n) % 3)).map { Angle(degrees: Float($0 * n)) }
                case 11: state.byKey[key] = at
                case 12: state.byKey.removeValue(forKey: key)
                case 13: state.maybeByKey = n % 2 == 0 ? nil : [key: at]
                case 14: state.marks[key] = ShapeMark(x: Int32(n), y: 0)
                case 15: state.marks.removeValue(forKey: key)
                case 16: state.wrappers[key] = ShapeWrapper(at: at)
                default: state.wrappers.removeValue(forKey: key)
                }
            }
        }
    }
}

// MARK: - The nested-policy land

private let probeKeys = ["k", "a/b", "t~x", "e\u{301}", "\u{e9}", "z"]

private func makeNestedPolicyCellLand() -> LandDefinition<PlainProbeRoot> {
    Land("nested-policy-cell", using: PlainProbeRoot.self) {
        ClientEvents { Register(LandCellStep.self) }
        Rules {
            HandleEvent(LandCellStep.self) { (state: inout PlainProbeRoot, step: LandCellStep, _: LandContext) in
                let n = step.n
                let key = probeKeys[abs(n) % probeKeys.count]
                var node = PlainProbeNode()
                node.shown = n
                switch step.op {
                case 0: state.tick += 1
                case 1: state.byString[key] = node
                case 2: state.byString[key]?.shown += 1
                case 3: state.byString[key]?.secret += 1
                case 4: state.byString[key]?.masked += 1
                case 5: state.byString.removeValue(forKey: key)
                case 6: state.byPlayer[PlayerID(key)] = node
                case 7: state.byPlayer[PlayerID(key)]?.shown += 1
                case 8: state.byPlayer.removeValue(forKey: PlayerID(key))
                case 9: state.byInt[n - 3] = node
                case 10: state.byInt[n - 3]?.masked -= 1
                case 11: state.byInt.removeValue(forKey: n - 3)
                case 12: state.array.append(node)
                case 13: if !state.array.isEmpty { state.array[0].shown += 1 }
                case 14: if state.array.count > 1 { state.array.removeLast() }
                case 15: state.optional = n % 2 == 0 ? nil : node
                case 16: state.optional?.shown += 1
                case 17: state.single.shown += 1
                case 18: state.single.secret += 1
                case 19: state.deep["h"]?.inner[key] = node
                case 20: state.deep["h"]?.inner[key]?.shown += 1
                case 21: state.deep[key] = PlainProbeHolder()
                case 22: state.deep.removeValue(forKey: key)
                case 23: state.perPlayerMap[key] = PlainPerPlayerProbeNode()
                case 24: state.perPlayerMap[key]?.ppShown += 1
                default: state.slice[PlayerID("alice")]?.aliceOnly += 1
                }
            }
        }
    }
}

/// `count` steps over `opCount` mutations: every mutation several times, with varying `n`, in a
/// fixed order (the same in both runs and in every process).
private func scriptedOps(opCount: Int, count: Int) -> [(op: Int, n: Int)] {
    (0..<count).map { index in (op: (index * 7 + index / opCount) % opCount, n: index % 11 - 2) }
}

private func landCellPathHashes<State: StateNodeProtocol>(_ definition: LandDefinition<State>, landID: String) throws -> [String: UInt32] {
    let schema = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(definition)])
    return try #require(schema.lands[landID]?.pathHashes)
}

@Suite("The typed tables on and off send the same frames: land cells", .timeLimit(.minutes(2)))
struct SyncTablesLandCellTests {
    private func compare<State: StateNodeProtocol>(
        cell: String,
        landID: String,
        definition: @escaping () -> LandDefinition<State>,
        opCount: Int
    ) async throws {
        let parts = cell.split(separator: "|").map(String.init)
        let encoding = try #require(landCellEncodings.first { $0.0 == parts[0] }?.1).withPathIndex(parts[2] == "index")
        let dirtyTracking = parts[1] == "true"
        let pathHashes = parts[2] == "paths" ? nil : try landCellPathHashes(definition(), landID: landID)
        let ops = scriptedOps(opCount: opCount, count: opCount * 6)
        var frames: [[(target: String, data: Data)]] = []
        var lastSent: [StateSnapshot?] = []
        for tables in [true, false] {
            let run = await LandCellRun<State>(
                definition: definition(), landID: landID, tables: tables, dirtyTracking: dirtyTracking,
                encoding: encoding, pathHashes: pathHashes
            )
            try await run.runScript(ops: ops)
            frames.append(await run.transport.sent)
            lastSent.append(await run.adapter.lastSentBroadcastSnapshotForTesting())
            #expect(await run.adapter.syncFailedPlans == 0, "\(cell): no plan failed")
        }
        #expect(frames[0].count > 40, "\(cell): the script sends frames")
        expectSameLandFrames(frames[0], frames[1], cell)
        #expect(lastSent[0] != nil, "\(cell): the tables are seeded")
        #expect(lastSent[0] == lastSent[1], "\(cell): last-sent")
    }

    /// The cells compare the tables with the snapshot path only where a field is typed: a field
    /// on the fallback is the snapshot diff on both sides. These pin which fields are which.
    @Test("The cells' states are diffed by the typed tables, field by field")
    func kinds() {
        // The shape matrix: 14 broadcast fields, all values (atomic values, plain structs and
        // collections of them), none on the fallback.
        let shapes = SyncTableBroadcastDiff<ShapeMatrixState>()
        #expect(shapes.kinds.count == 14)
        #expect(shapes.kinds.values.allSatisfy { $0 == .value }, "\(shapes.kinds)")
        #expect(shapes.fallbackReasons.isEmpty, "\(shapes.fallbackReasons)")
        #expect(!shapes.alwaysSorts)
        // The nested-policy root: node maps by String, PlayerID and Int and two levels deep, a
        // node held directly and optionally; only the array of nodes takes the fallback.
        let probe = SyncTableBroadcastDiff<PlainProbeRoot>()
        #expect(probe.kinds == [
            "byString": .nodeMap, "byPlayer": .nodeMap, "byInt": .nodeMap, "deep": .nodeMap,
            "optional": .optionalNode, "single": .node, "tick": .value, "array": .fallback,
        ])
        #expect(Set(probe.fallbackReasons.keys) == ["array"])
        #expect(probe.fallbackReasons["array"]?.contains("holds a state node") == true)
    }

    @Test("The shape matrix land", arguments: landCells)
    func shapeMatrix(cell: String) async throws {
        try await compare(cell: cell, landID: "shape-matrix-cell", definition: makeShapeMatrixCellLand, opCount: 18)
    }

    @Test("The nested-policy land", arguments: landCells)
    func nestedPolicy(cell: String) async throws {
        try await compare(cell: cell, landID: "nested-policy-cell", definition: makeNestedPolicyCellLand, opCount: 26)
    }
}

// MARK: - The change-object metric from rows

/// A value whose conversion throws while `broken` is set.
struct MetricRowsFragile: Codable, Sendable, Equatable, SnapshotValueConvertible {
    var broken = false
    var value = 0
    func toSnapshotValue() throws -> SnapshotValue {
        if broken { throw MetricRowsFault() }
        return .int(value)
    }
}

struct MetricRowsFault: Error {}

@StateNodeBuilder
struct MetricRowsUnit: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.broadcast) var pos: Int = 0
    @Sync(.broadcast) var fragile: MetricRowsFragile = MetricRowsFragile()
    init() {}
}

/// Root dictionaries of nodes (by `String`, with the empty key and a key named after a node
/// field, and by `Int`) beside a value field.
@StateNodeBuilder
struct MetricRowsState: StateNodeProtocol {
    @Sync(.broadcast) var units: [String: MetricRowsUnit] = [:]
    @Sync(.broadcast) var byInt: [Int: MetricRowsUnit] = [:]
    @Sync(.broadcast) var score: Int = 0
    init() {}
}

private let metricRowsKeys = ["", "hp", "a/b", "t~x", "e\u{301}", "\u{e9}", "pos"]

private func makeMetricRowsLand() -> LandDefinition<MetricRowsState> {
    Land("metric-rows-cell", using: MetricRowsState.self) {
        ClientEvents { Register(LandCellStep.self) }
        Rules {
            HandleEvent(LandCellStep.self) { (state: inout MetricRowsState, step: LandCellStep, _: LandContext) in
                let n = step.n
                let key = metricRowsKeys[abs(n) % metricRowsKeys.count]
                switch step.op {
                case 0: state.units[key, default: MetricRowsUnit()].hp = n
                case 1: state.units[key, default: MetricRowsUnit()].pos = n
                case 2: state.units.removeValue(forKey: key)
                case 3: state.units.removeAll()
                case 4: state.units[key, default: MetricRowsUnit()].fragile.broken = true
                case 5: state.units[key]?.fragile.broken = false
                case 6: state.score = n
                case 7: state.byInt[n % 3, default: MetricRowsUnit()].hp = n
                default: state.byInt.removeValue(forKey: n % 3)
                }
            }
        }
    }
}

@Suite("The change-object metric from rows equals the full snapshot's", .timeLimit(.minutes(2)))
struct ChangeMetricsFromRowsTests {
    /// The metric after every sync of `script`, with the metric from rows and with the full
    /// snapshot (the oracle), on the tables with the auto switch on.
    private func traces<State: StateNodeProtocol>(
        definition: @escaping () -> LandDefinition<State>,
        landID: String,
        dirtyTracking: Bool,
        script: (LandCellRun<State>, @escaping () async -> Void) async throws -> Void
    ) async throws -> [[String]] {
        var result: [[String]] = []
        for fromRows in [true, false] {
            let run = await LandCellRun<State>(
                definition: definition(), landID: landID, tables: true, dirtyTracking: dirtyTracking,
                encoding: .messagepack, pathHashes: try landCellPathHashes(definition(), landID: landID),
                autoDirty: true, metricsFromRows: fromRows
            )
            let lines = LandCellLines()
            try await script(run) { await lines.append(await run.metricLine()) }
            result.append(await lines.lines)
        }
        return result
    }

    @Test("The nested-policy land, sync by sync", arguments: [true, false])
    func nestedPolicy(dirtyTracking: Bool) async throws {
        let ops = scriptedOps(opCount: 26, count: 26 * 6)
        let t = try await traces(definition: makeNestedPolicyCellLand, landID: "nested-policy-cell", dirtyTracking: dirtyTracking) { run, after in
            try await run.runScript(ops: ops, afterSync: after)
        }
        #expect(t[0].count > 40)
        #expect(t[0] == t[1], "\(zip(t[0], t[1]).enumerated().filter { $0.element.0 != $0.element.1 }.prefix(3))")
        // Starting off, the auto switch turns dirty tracking on during the script (starting on,
        // this land's change rate stays under the off threshold).
        if dirtyTracking {
            #expect(t[0].allSatisfy { $0.hasSuffix("dirty true") }, "\(t[0])")
        } else {
            #expect(Set(t[0].map { $0.hasSuffix("dirty true") }).count == 2, "\(t[0])")
        }
    }

    @Test("Root dictionaries of nodes: the empty key, escaped and respelled keys, emptying, throws", arguments: [true, false])
    func explicitCases(dirtyTracking: Bool) async throws {
        // `n` picks the key (`n % 7`) and is the value written: 7 is the empty key with a value
        // that differs from the default 0.
        let empty = 7, hp = 1, slash = 2, tilde = 3, nfd = 4, nfc = 5
        let t = try await traces(definition: makeMetricRowsLand, landID: "metric-rows-cell", dirtyTracking: dirtyTracking) { run, after in
            // A throw before the first seed: the row converts nowhere, `units` is unseeded.
            try await run.step(4, empty)
            try await run.join("alice")
            await run.sync(); await after()
            try await run.step(5, empty)
            await run.sync(); await after()
            // The empty key's row changed beside a row named after a node field.
            try await run.step(0, empty)
            try await run.step(1, empty)
            try await run.step(0, hp)
            await run.sync(); await after()
            // Only the empty key's row: two nested fields, two keys today (`/units/hp`,
            // `/units/pos`), whatever the row's own key.
            try await run.step(0, empty + 7)
            try await run.step(1, empty + 7)
            await run.sync(); await after()
            // A throw after the seed: `units` takes last-sent.
            try await run.step(4, hp)
            try await run.step(0, slash)
            await run.sync(); await after()
            try await run.step(5, hp)
            await run.sync(); await after()
            // The empty key's row deleted, then every row.
            try await run.step(2, empty)
            await run.sync(); await after()
            try await run.step(3, 0)
            await run.sync(); await after()
            try await run.step(0, slash)
            try await run.step(0, tilde)
            try await run.step(0, nfd)
            await run.sync(); await after()
            try await run.step(2, nfc)
            try await run.step(0, nfc)
            try await run.step(6, 9)
            await run.sync(); await after()
            // A second player joins: its firstSync is its own plan, outside the metric (the
            // view that reaches the metric is tested in `unsyncedRecipientView`).
            try await run.join("bob")
            await run.sync(); await after()
            for n in 0..<24 {
                try await run.step(n % 9, n)
                if n % 2 == 1 { await run.sync(); await after() }
            }
        }
        #expect(t[0].count > 15)
        #expect(t[0] == t[1], "\(zip(t[0], t[1]).enumerated().filter { $0.element.0 != $0.element.1 }.prefix(3))")
    }
}

extension ChangeMetricsFromRowsTests {
    /// A recipient whose firstSync failed gets its whole view inside the next sync, and that view
    /// is one of the metric's updates. With dirty tracking on, the sync's mode holds only the
    /// changed `score`, so `units` is out of the mode (its view patches key as `/units`); with it
    /// off, `units` is in it with two rows (one key per row).
    @Test("An unsynced recipient's view reaches the metric, its node map in and out of the mode", arguments: [true, false])
    func unsyncedRecipientView(dirtyTracking: Bool) async throws {
        var lines: [[String]] = []
        var changed: [Int] = []
        for (fromRows, failFirstSync) in [(true, true), (false, true), (true, false)] {
            let run = await LandCellRun<MetricRowsState>(
                definition: makeMetricRowsLand(), landID: "metric-rows-cell", tables: true, dirtyTracking: dirtyTracking,
                encoding: .messagepack, pathHashes: try landCellPathHashes(makeMetricRowsLand(), landID: "metric-rows-cell"),
                // The metric runs; the mode holds for this short script.
                autoDirty: true, autoDirtySamples: 1000, metricsFromRows: fromRows
            )
            try await run.join("alice")
            try await run.step(0, 2)
            try await run.step(0, 3)
            await run.sync()
            if failFirstSync {
                let once = MetricRowsFailOnce()
                await run.adapter.setFirstSyncPlanFaultForTesting { try once.fire() }
                try await run.join("bob")
                #expect(once.didFire)
                await run.adapter.setFirstSyncPlanFaultForTesting(nil)
            } else {
                try await run.join("bob")
            }
            try await run.step(6, 5)
            await run.sync()
            lines.append([await run.metricLine()])
            changed.append(try #require(await run.adapter.lastChangeMetricsForTesting()).changed)
        }
        #expect(lines[0] == lines[1], "rows \(lines[0]), oracle \(lines[1])")
        #expect(lines[0][0].hasSuffix("dirty \(dirtyTracking)"), "\(lines[0])")
        // The control (bob synced) counts the broadcast `score` patch alone. The view adds
        // `/units` with `units` out of the mode, or a key per row with it in the mode, besides
        // the view's other fields.
        #expect(changed[2] == 1, "control \(changed)")
        #expect(changed[0] > changed[2], "\(changed)")
        let unitKeys = dirtyTracking ? 1 : 2
        #expect(changed[0] - changed[2] >= unitKeys, "\(changed)")
    }
}

/// Throws on its first call only.
final class MetricRowsFailOnce: @unchecked Sendable {
    struct Fault: Error {}
    private let lock = NSLock()
    private var fired = false
    var didFire: Bool { lock.withLock { fired } }
    func fire() throws {
        let first = lock.withLock { () -> Bool in
            defer { fired = true }
            return !fired
        }
        if first { throw Fault() }
    }
}

/// Lines collected across `await`s.
private actor LandCellLines {
    var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}
