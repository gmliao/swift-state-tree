// Tests/SwiftStateTreeTransportTests/RowAddressingAdapterTests.swift
//
// Row addressing in the adapter (`TransportEncodingConfig.rowAddressing`, plan
// `2026-11-10-row-addressing.md`, sections 1, 4, 7 and 15): where it is in effect, the join
// check, and the equivalence oracle. The same script runs with the feature off and on; every
// client's frames are decoded and applied. Each sync's decoded patches (sorted) and each client's
// state must equal the feature-off run's, and each client's slot bindings the server's table.
// A joiner's first view holds creates where the feature-off view has one set of the map, so first
// views are compared as states.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
import SwiftStateTreeMessagePack

@StateNodeBuilder
struct RowAddressingUnit: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.broadcast) var speed: Double = 0
    @Sync(.broadcast) var note: String? = nil
    @Sync(.broadcast) var bag: [String: Int] = [:]

    public init() {}

    init(hp: Int, speed: Double = 0) {
        self.hp = hp
        self.speed = speed
    }
}

@StateNodeBuilder
struct RowAddressingState: StateNodeProtocol {
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var units: [String: RowAddressingUnit] = [:]

    public init() {}
}

/// The script's next step, applied by each tick.
private final class RowAddressingScript: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [(inout RowAddressingState) -> Void] = []

    func queue(_ step: @escaping (inout RowAddressingState) -> Void) {
        lock.lock(); steps.append(step); lock.unlock()
    }

    func apply(_ state: inout RowAddressingState) {
        lock.lock()
        let step = steps.isEmpty ? nil : steps.removeFirst()
        lock.unlock()
        step?(&state)
    }
}

/// Records every frame with its target, in send order.
private actor RowAddressingFrames: Transport {
    var delegate: TransportDelegate?
    private(set) var frames: [(data: Data, target: SwiftStateTreeTransport.EventTarget)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) { frames.append((message, target)) }
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates { frames.append((data, target)) }
    }

    func frames(for sessionID: SessionID) -> [Data] {
        frames.compactMap { frame in
            if case .session(let s) = frame.target, s == sessionID { return frame.data }
            return nil
        }
    }
}

enum RowAddressingEncoding: String, CaseIterable, Sendable {
    /// Merged frames (opcode 107): a recipient's view holds the committed tables.
    case messagepack
    /// Combined frames: a view holds this plan's tables.
    case opcodeJsonArray

    var config: TransportEncodingConfig {
        switch self {
        case .messagepack: return .messagepack
        case .opcodeJsonArray: return .opcode
        }
    }

    var format: StateFrameFormat {
        self == .messagepack ? .messagePack : .json
    }
}

private func rowAddressingLand(_ script: RowAddressingScript) -> LandDefinition<RowAddressingState> {
    Land("row-addressing", using: RowAddressingState.self) {
        Rules {}
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout RowAddressingState, ctx: LandContext) in
                script.apply(&state)
                ctx.requestSyncNow()
            }
        }
    }
}

private func rowAddressingPathHashes() throws -> [String: UInt32] {
    let schema = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(rowAddressingLand(RowAddressingScript()))])
    return try #require(schema.lands["row-addressing"]?.pathHashes)
}

private func rowAddressingEnv(tables: Bool) -> TransportEnvConfig {
    var config = TransportEnvConfig(
        enableDirtyTracking: true,
        useSnapshotForSync: false,
        syncStrategy: .delta,
        enableChangeObjectMetrics: false,
        changeObjectMetricsLogEvery: 10,
        changeObjectMetricsEmaAlpha: 0.2,
        enableAutoDirtyTracking: false,
        autoDirtyOffThreshold: 0.55,
        autoDirtyOnThreshold: 0.30,
        autoDirtyRequiredConsecutiveSamples: 30,
        profilingConfig: nil
    )
    config.useSyncTables = tables
    return config
}

private let rowAddressingJoinResponse: @Sendable (PlayerID, Int32) -> Data? = { playerID, slot in
    try? JSONEncoder().encode(TransportMessage.joinResponse(
        requestID: "r-\(playerID.rawValue)", success: true, playerID: playerID.rawValue, playerSlot: slot, encoding: "json"
    ))
}

/// One client: its decoder, its view, and how many of its frames it has read.
private final class RowAddressingClient {
    let session: SessionID
    let decoder: OpcodeJSONStateUpdateDecoder
    var view = SnapshotClientView()
    var read = 0

    init(session: SessionID, hasher: PathHasher) {
        self.session = session
        // Atomic values arrive positional; the client reads them keyed, as the state holds them.
        self.decoder = OpcodeJSONStateUpdateDecoder(
            pathHasher: hasher, atomicLayout: AtomicLayoutTable.forState(RowAddressingState.self), pathIndex: true, syncSequence: true
        )
    }
}

private struct RowAddressingRun {
    let keeper: LandKeeper<RowAddressingState>
    let adapter: TransportAdapter<RowAddressingState>
    let frames: RowAddressingFrames
    let script: RowAddressingScript
    let encoding: RowAddressingEncoding
    let hasher: PathHasher
    var clients: [String: RowAddressingClient] = [:]

    static func make(
        encoding: RowAddressingEncoding,
        rowAddressing: Bool,
        joinsThroughRouter: Bool = true,
        inTurnSync: Bool = true,
        initial: RowAddressingState = RowAddressingState()
    ) async throws -> RowAddressingRun {
        let script = RowAddressingScript()
        let frames = RowAddressingFrames()
        let pathHashes = try rowAddressingPathHashes()
        // No loops: each stepped tick turn runs the sync phase, and no periodic sync runs beside it.
        let keeper = LandKeeper(definition: rowAddressingLand(script), initialState: initial, autoStartLoops: false)
        let adapter = TransportAdapter<RowAddressingState>(
            keeper: keeper,
            transport: frames,
            landID: "row-addressing",
            transportEnvConfig: rowAddressingEnv(tables: true),
            encodingConfig: encoding.config.withSyncSequence(true).withRowAddressing(rowAddressing),
            pathHashes: pathHashes,
            suppressMissingPathHashesWarning: true,
            inTurnSync: inTurnSync,
            joinsThroughRouter: joinsThroughRouter
        )
        await frames.setDelegate(adapter)
        await keeper.setTransport(adapter)
        return RowAddressingRun(
            keeper: keeper, adapter: adapter, frames: frames, script: script, encoding: encoding,
            hasher: PathHasher(pathHashes: pathHashes)
        )
    }

    /// Joins `name` through the in-turn path (a JoinResponse builder, as the router passes):
    /// returns once its flip committed.
    mutating func join(_ name: String) async throws {
        let session = SessionID("s-\(name)")
        let client = ClientID("c-\(name)")
        await adapter.onConnect(sessionID: session, clientID: client)
        let result = try await adapter.performJoin(
            playerSession: PlayerSession(playerID: name, deviceID: "dev", metadata: [:]),
            clientID: client,
            sessionID: session,
            authInfo: nil,
            joinResponse: rowAddressingJoinResponse
        )
        _ = try #require(result)
        #expect(await adapter.waitForOutboundDrain())
        clients[name] = RowAddressingClient(session: session, hasher: hasher)
    }

    /// Steps one tick that applies `step`.
    func tick(_ step: @escaping (inout RowAddressingState) -> Void) async {
        script.queue(step)
        await keeper.stepTickOnce()
        #expect(await adapter.waitForOutboundDrain())
    }

    /// Decodes and applies the frames `name` received since the last read: their patches, in
    /// order (a state update's), and whether one was a firstSync.
    func read(_ name: String) async throws -> (patches: [StatePatch], firstSync: Bool) {
        let client = try #require(clients[name])
        let all = await frames.frames(for: client.session)
        var patches: [StatePatch] = []
        var firstSync = false
        for data in all.dropFirst(client.read) {
            if (try? JSONDecoder().decode(TransportMessage.self, from: data)) != nil { continue }
            guard let decoded = try client.decoder.decodeFrame(data, format: encoding.format) else { continue }
            switch decoded.update {
            case .noChange: break
            case .diff(let p): patches += p
            case .firstSync(let p): patches += p; firstSync = true
            }
        }
        client.read = all.count
        try client.view.apply(patches)
        return (patches, firstSync)
    }

    /// The state every client should hold: the broadcast fields of the keeper's state.
    func liveView() async throws -> [String: SnapshotValue] {
        let state = await keeper.currentState()
        return try state.broadcastSnapshot(dirtyFields: nil).values.mapValues(numbersAsDoubles)
    }

    /// The row entry ops (6 to 9) in every frame sent so far.
    func rowEntryOps() async throws -> Set<Int> {
        var ops: Set<Int> = []
        func scan(_ entries: [Any]) {
            for case let entry as [Any] in entries where entry.count >= 3 {
                if let op = (entry[2] as? NSNumber)?.intValue, (6...9).contains(op) { ops.insert(op) }
            }
        }
        for frame in await frames.frames {
            switch encoding.format {
            case .json:
                if let array = try? JSONSerialization.jsonObject(with: frame.data) as? [Any] { scan(array) }
            case .messagePack:
                guard case .array(let packed)? = try? unpack(frame.data) else { continue }
                let state: [MessagePackValue]
                if packed.count > 1, case .array(let inner) = packed[1] { state = inner } else { state = packed }
                scan(state.map(Self.plain))
            }
        }
        return ops
    }

    private static func plain(_ value: MessagePackValue) -> Any {
        switch value {
        case .array(let items): return items.map(plain)
        case .int(let v): return NSNumber(value: v)
        case .uint(let v): return NSNumber(value: v)
        default: return NSNull()
        }
    }

    func view(_ name: String) throws -> [String: SnapshotValue] {
        try #require(clients[name]).view.fields.mapValues(numbersAsDoubles)
    }
}

/// `value` with every number as a double: a decoder reads a whole double (`0.0`) as an integer.
private func numbersAsDoubles(_ value: SnapshotValue) -> SnapshotValue {
    switch value {
    case .int(let v): return .double(Double(v))
    case .object(let fields): return .object(fields.mapValues(numbersAsDoubles))
    case .array(let items): return .array(items.map(numbersAsDoubles))
    default: return value
    }
}

/// A patch as compared across two runs: its path, and its value (nil for a delete).
private struct ComparedPatch: Equatable, CustomStringConvertible {
    let path: String
    let value: SnapshotValue?
    var description: String { "\(path) \(value.map { "= \($0)" } ?? "-")" }
}

/// Patches by path, for comparing the content of two runs' syncs.
private func sortedPatches(_ patches: [StatePatch]) -> [ComparedPatch] {
    patches.map { patch -> ComparedPatch in
        switch patch.operation {
        case .set(let value), .add(let value): return ComparedPatch(path: patch.path, value: numbersAsDoubles(value))
        case .delete: return ComparedPatch(path: patch.path, value: nil)
        }
    }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
}

private func unitsWith(_ rows: [String: RowAddressingUnit]) -> RowAddressingState {
    var state = RowAddressingState()
    state.units = rows
    return state
}

@Suite(
    "Row addressing in the adapter",
    .enabled(if: InTurnSync.isEnabled(), "IN_TURN_SYNC=false: row addressing needs in-turn sync")
)
struct RowAddressingAdapterTests {
    @Test("The config: rowAddressing needs path hashes, pathIndex, syncSequence and an opcode encoding")
    func configRequirements() throws {
        let hashes: [String: UInt32] = ["a": 1]
        let on = TransportEncodingConfig.messagepack.withSyncSequence(true).withRowAddressing(true)
        #expect(on.effective(pathHashes: hashes).rowAddressing)
        #expect(on.effective(pathHashes: hashes).stateUpdateFeatures == ["pathIndex", "fieldMerge", "rowAddressing", "syncSequence"])
        #expect(!on.effective(pathHashes: nil).rowAddressing)
        #expect(!on.withPathIndex(false).effective(pathHashes: hashes).rowAddressing)
        #expect(!on.withSyncSequence(false).effective(pathHashes: hashes).rowAddressing)
        #expect(!TransportEncodingConfig.json.withSyncSequence(true).withRowAddressing(true).effective(pathHashes: hashes).rowAddressing)
        #expect(TransportEncodingConfig.messagepack.rowAddressing == false, "off by default")
        #expect(StateUpdateFeature.supported.contains(StateUpdateFeature.rowAddressing))
        #expect(TransportEncodingConfig.rowAddressingFromEnvironment(environment: ["ROW_ADDRESSING": "true"]))
        #expect(!TransportEncodingConfig.rowAddressingFromEnvironment(environment: [:]))
    }

    @Test("In effect only with in-turn sync and joins through the router; it turns the sync tables on")
    func whereInEffect() async throws {
        let inEffect = try await RowAddressingRun.make(encoding: .messagepack, rowAddressing: true)
        #expect(inEffect.adapter.rowAddressing)
        #expect(inEffect.adapter.stateUpdateFeatures.contains(StateUpdateFeature.rowAddressing))
        let delegate = try await RowAddressingRun.make(encoding: .messagepack, rowAddressing: true, joinsThroughRouter: false)
        #expect(!delegate.adapter.rowAddressing, "the adapter's own (delegate) join sends a standalone firstSync")
        #expect(!delegate.adapter.stateUpdateFeatures.contains(StateUpdateFeature.rowAddressing))
        let legacy = try await RowAddressingRun.make(encoding: .messagepack, rowAddressing: true, inTurnSync: false)
        #expect(!legacy.adapter.rowAddressing, "in-turn sync off: joins don't complete in a turn")
        let off = try await RowAddressingRun.make(encoding: .messagepack, rowAddressing: false)
        #expect(!off.adapter.stateUpdateFeatures.contains(StateUpdateFeature.rowAddressing))
    }

    @Test("The oracle: each sync decodes to the feature-off run's patches, every client reaches the live state, slots match the server's", arguments: RowAddressingEncoding.allCases)
    func oracle(encoding: RowAddressingEncoding) async throws {
        let initial = unitsWith(["a": RowAddressingUnit(hp: 1), "b": RowAddressingUnit(hp: 2), "": RowAddressingUnit(hp: 3)])
        var runs = [
            try await RowAddressingRun.make(encoding: encoding, rowAddressing: false, initial: initial),
            try await RowAddressingRun.make(encoding: encoding, rowAddressing: true, initial: initial),
        ]
        #expect(runs[1].adapter.rowAddressing)
        let steps: [(String, (inout RowAddressingState) -> Void)] = [
            ("update and create", { $0.units["a"]?.hp = 10; $0.units["c"] = RowAddressingUnit(hp: 4); $0.units["d"] = RowAddressingUnit(hp: 5) }),
            ("delete and update", { $0.units["b"] = nil; $0.units["d"]?.speed = 1.5 }),
            ("join"         , { _ in }),
            ("reuse a slot" , { $0.units["e"] = RowAddressingUnit(hp: 6); $0.units["a"]?.note = "x" }),
            ("optional to nil, a value map inside a row", { $0.units["a"]?.note = nil; $0.units["e"]?.bag["k"] = 1 }),
            ("value map entry, a root value", { $0.units["e"]?.bag["k"] = 2; $0.units["e"]?.bag["j"] = 3; $0.round = 1 }),
            ("delete most", { state in state.units = state.units.filter { $0.key == "e" } }),
            ("create again", { $0.units["a"] = RowAddressingUnit(hp: 7); $0.units["z"] = RowAddressingUnit(hp: 8) }),
        ]
        for index in runs.indices {
            try await runs[index].join("p1")
            try await runs[index].join("p2")
        }
        var joined = ["p1", "p2"]
        for (name, step) in steps {
            if name == "join" {
                for index in runs.indices { try await runs[index].join("p3") }
                joined.append("p3")
            } else {
                for run in runs { await run.tick(step) }
            }
            for player in joined {
                let off = try await runs[0].read(player)
                let on = try await runs[1].read(player)
                #expect(off.firstSync == on.firstSync, "\(name): \(player)")
                if !on.firstSync {
                    #expect(sortedPatches(on.patches) == sortedPatches(off.patches), "\(name): \(player)'s patches")
                }
                let live = try await runs[1].liveView()
                let onView = try runs[1].view(player), offView = try runs[0].view(player)
                #expect(onView == live, "\(name): \(player) holds the live state: \(onView) vs \(live)")
                #expect(offView == live, "\(name): \(player) holds the live state (off): \(offView) vs \(live)")
                // The client's bindings are the server's table.
                let server = try #require(await runs[1].adapter.rowSlotsForTesting("units"))
                let bound = try #require(runs[1].clients[player]).decoder.boundRows(ofPattern: "units.*")
                var client: [String: SyncRowSlotForTesting] = [:]
                for (slot, row) in bound { client[row.key] = SyncRowSlotForTesting(slot: Int32(slot), generation: row.generation) }
                #expect(client == server, "\(name): \(player)'s slots")
            }
        }
        // The feature-on frames held every row entry form except the column clear (no key leaves
        // a value's object in this script); the feature-off frames none.
        #expect(try await runs[1].rowEntryOps() == [6, 7, 8])
        #expect(try await runs[0].rowEntryOps() == [])
        // The slot of the deleted "b" was taken again, with the next generation.
        let slots = try #require(await runs[1].adapter.rowSlotsForTesting("units"))
        #expect(slots.values.contains { $0.generation > 0 }, "a slot was reused")
    }

    @Test("Opcode JSON: a row whose value does not encode is dropped from the plan; the rest of the table proceeds, and the row is retried")
    func rowDrop() async throws {
        let initial = unitsWith(["a": RowAddressingUnit(hp: 1), "b": RowAddressingUnit(hp: 2)])
        var run = try await RowAddressingRun.make(encoding: .opcodeJsonArray, rowAddressing: true, initial: initial)
        try await run.join("p1")
        _ = try await run.read("p1")
        // A column that fails (a non-finite number) and a create that fails, beside healthy changes.
        await run.tick { $0.units["a"]?.speed = .nan; $0.units["a"]?.hp = 11; $0.units["b"]?.hp = 20; $0.units["x"] = RowAddressingUnit(hp: 9, speed: .infinity); $0.units["y"] = RowAddressingUnit(hp: 10) }
        let first = try await run.read("p1")
        #expect(!first.patches.contains { $0.path.hasPrefix("/units/a") }, "the whole row a is out, its healthy hp too")
        #expect(!first.patches.contains { $0.path.hasPrefix("/units/x") })
        #expect(first.patches.contains { $0.path == "/units/b/hp" })
        #expect(first.patches.contains { $0.path == "/units/y" })
        let slots = try #require(await run.adapter.rowSlotsForTesting("units"))
        #expect(slots["x"] == nil, "a dropped create takes no slot")
        #expect(slots["y"] != nil)
        #expect(await run.adapter.rowRetryFieldsForTesting() == ["units"])
        #expect(await run.adapter.consecutiveRowRepairsForTesting() == 1)
        var view = try run.view("p1")
        // The client holds what last-sent holds for a: the old row.
        guard case .object(let units)? = view["units"], case .object(let a)? = units["a"] else {
            Issue.record("no row a"); return
        }
        #expect(a["hp"] == .double(1))
        // Another field changes only: the retry set still diffs units, and the row is dropped again.
        await run.tick { $0.round = 1 }
        _ = try await run.read("p1")
        #expect(await run.adapter.rowRetryFieldsForTesting() == ["units"])
        #expect(await run.adapter.consecutiveRowRepairsForTesting() == 2)
        // The values are fixed: both rows reach the client, and the set empties.
        await run.tick { $0.units["a"]?.speed = 2; $0.units["x"]?.speed = 3 }
        _ = try await run.read("p1")
        #expect(await run.adapter.rowRetryFieldsForTesting() == [])
        #expect(await run.adapter.consecutiveRowRepairsForTesting() == 0)
        view = try run.view("p1")
        #expect(view == (try await run.liveView()))
    }

    @Test("A dropped row takes the patches below it on component boundaries only: /units/a, not /units/ab")
    func componentBoundaries() {
        let row = SyncRowRef(StatePatch(path: "/units/a/hp", operation: .set(.int(1)), split: nil))
        #expect(row == nil, "a patch without a row split names no row")
        let rows = RowAddressingRefProbe.ref(path: "/units/a/hp", slot: 0)
        #expect(rows.rootPath == "/units")
        #expect(rows.rowPath == "/units/a")
        #expect(rows.covers("/units/a"))
        #expect(rows.covers("/units/a/bag/k"))
        #expect(!rows.covers("/units/ab"))
        #expect(!rows.covers("/units/ab/hp"))
    }
}

/// Builds a `SyncRowRef` from a path with a row split, through the land's own hasher.
private enum RowAddressingRefProbe {
    static func ref(path: String, slot: Int32) -> SyncRowRef {
        let hasher = PathHasher(pathHashes: (try? rowAddressingPathHashes()) ?? [:])
        var cursor = hasher.rootCursor
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            cursor = cursor.descending(component)!
            if index == 1 { cursor = cursor.asRow(slot) }
        }
        return SyncRowRef(StatePatch(path: path, operation: .set(.int(1)), split: cursor.split))!
    }
}
