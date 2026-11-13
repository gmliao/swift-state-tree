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
import Logging
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
import SwiftStateTreeMessagePack

/// A value whose conversion throws while `failing`: a seed of its map then fails for that field.
struct RowAddressingSeal: Sendable, Equatable, SnapshotValueConvertible {
    struct Failed: Error {}
    var failing = false

    func toSnapshotValue() throws -> SnapshotValue {
        if failing { throw Failed() }
        return .int(0)
    }
}

@StateNodeBuilder
struct RowAddressingUnit: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.broadcast) var speed: Double = 0
    @Sync(.broadcast) var note: String? = nil
    @Sync(.broadcast) var bag: [String: Int] = [:]
    @Sync(.broadcast) var seal: RowAddressingSeal = RowAddressingSeal()

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

private func rowAddressingEnv(tables: Bool, dirtyTracking: Bool = true) -> TransportEnvConfig {
    var config = TransportEnvConfig(
        enableDirtyTracking: dirtyTracking,
        useSnapshotForSync: false,
        syncStrategy: .delta,
        profilingConfig: nil
    )
    config.useSyncTables = tables
    return config
}

private let rowAddressingJoinResponse: @Sendable (PlayerID, Int32) -> Data? = { playerID, slot in
    // Sorted keys: runs compared frame by frame get the same bytes.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(TransportMessage.joinResponse(
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
        tables: Bool = true,
        dirtyTracking: Bool = true,
        recording: Bool = false,
        logger: Logger? = nil,
        initial: RowAddressingState = RowAddressingState()
    ) async throws -> RowAddressingRun {
        let script = RowAddressingScript()
        let frames = RowAddressingFrames()
        let pathHashes = try rowAddressingPathHashes()
        // No loops: each stepped tick turn runs the sync phase, and no periodic sync runs beside it.
        let keeper = LandKeeper(
            definition: rowAddressingLand(script), initialState: initial, enableLiveStateHashRecording: recording, autoStartLoops: false
        )
        let adapter = TransportAdapter<RowAddressingState>(
            keeper: keeper,
            transport: frames,
            landID: "row-addressing",
            transportEnvConfig: rowAddressingEnv(tables: tables, dirtyTracking: dirtyTracking),
            encodingConfig: encoding.config.withSyncSequence(true).withRowAddressing(rowAddressing),
            pathHashes: pathHashes,
            suppressMissingPathHashesWarning: true,
            inTurnSync: inTurnSync,
            logger: logger,
            joinsThroughRouter: joinsThroughRouter
        )
        await frames.setDelegate(adapter)
        if recording {
            // No initialize marker in the stream: the same indices in every run.
            await keeper.awaitInitialization()
        }
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

    /// Saves the record (with the adapter's sync config, as `LandManager` writes it) and replays
    /// it on a land whose ticks apply `steps`, the steps the live run ticked, in order.
    func replay(steps: [(inout RowAddressingState) -> Void], initial: RowAddressingState) async throws -> ReevaluationEngine.RunResult {
        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        let replayScript = RowAddressingScript()
        for step in steps { replayScript.queue(step) }
        let definition = rowAddressingLand(replayScript)
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: "row-addressing",
            landType: "row-addressing",
            createdAt: Date(timeIntervalSince1970: 0),
            metadata: [:],
            landDefinitionID: definition.id,
            version: ReevaluationRecordVersion.current,
            recordsSyncStream: true,
            syncConfig: adapter.syncConfigForRecord
        ))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("row-addressing-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await recorder.saveCopyForTesting(to: path)
        return try await ReevaluationEngine.run(definition: definition, initialState: initial, recordFilePath: path)
    }

    /// Steps one tick that applies `step`.
    func tick(_ step: @escaping (inout RowAddressingState) -> Void) async {
        script.queue(step)
        await keeper.stepTickOnce()
        #expect(await adapter.waitForOutboundDrain())
    }

    /// Decodes and applies the frames `name` received since the last read: their patches, in
    /// order (a state update's), and whether one was a firstSync.
    func read(_ name: String) async throws -> (patches: [StatePatch], firstSync: Bool, resync: Bool, lastSeq: UInt64?) {
        let client = try #require(clients[name])
        let all = await frames.frames(for: client.session)
        var patches: [StatePatch] = []
        var firstSync = false
        var resync = false
        var lastSeq: UInt64?
        for data in all.dropFirst(client.read) {
            if (try? JSONDecoder().decode(TransportMessage.self, from: data)) != nil { continue }
            guard let decoded = try client.decoder.decodeFrame(data, format: encoding.format) else { continue }
            lastSeq = decoded.syncSeq ?? lastSeq
            if decoded.resync {
                // A resync replaces the client's state.
                client.view = SnapshotClientView()
                resync = true
            }
            switch decoded.update {
            case .noChange: break
            case .diff(let p): try client.view.apply(p); patches += p
            case .firstSync(let p): try client.view.apply(p); patches += p; firstSync = true
            }
        }
        client.read = all.count
        return (patches, firstSync, resync, lastSeq)
    }

    /// Acks `seq` from `name`'s session.
    func ack(_ name: String, _ seq: UInt64) async throws {
        let client = try #require(clients[name])
        await adapter.onMessage(SyncAckFrame.encode(seq: seq, binary: encoding == .messagepack), from: client.session)
    }

    /// `name`'s slot bindings, as the server's table form.
    func clientSlots(_ name: String) throws -> [String: SyncRowSlotForTesting] {
        let bound = try #require(clients[name]).decoder.boundRows(ofPattern: "units.*")
        var result: [String: SyncRowSlotForTesting] = [:]
        for (slot, row) in bound { result[row.key] = SyncRowSlotForTesting(slot: Int32(slot), generation: row.generation) }
        return result
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
        #expect(TransportEncodingConfig.messagepack.rowAddressing, "on by default")
        #expect(TransportEncodingConfig.opcode.rowAddressing && TransportEncodingConfig.jsonOpcode.rowAddressing)
        #expect(TransportEncodingConfig(message: .messagepack, stateUpdate: .opcodeMessagePack).rowAddressing, "the init's default")
        #expect(!TransportEncodingConfig.json.effective(pathHashes: hashes).rowAddressing, "object state updates never carry it")
        // An encoder made straight from a preset (rows on, the sync sequence off) has no rows, as
        // `effective` says; with the sync sequence it does.
        func encoderRows(_ config: TransportEncodingConfig) -> Bool? {
            (config.makeStateUpdateEncoder(pathHashes: hashes) as? OpcodeMessagePackStateUpdateEncoder)?.rowAddressing
        }
        #expect(encoderRows(.messagepack) == false)
        #expect(encoderRows(.messagepack.withSyncSequence(true)) == true)
        #expect(StateUpdateFeature.supported.contains(StateUpdateFeature.rowAddressing))
        #expect(TransportEncodingConfig.rowAddressingFromEnvironment(environment: ["ROW_ADDRESSING": "true"]))
        #expect(TransportEncodingConfig.rowAddressingFromEnvironment(environment: [:]), "on by default")
        #expect(!TransportEncodingConfig.rowAddressingFromEnvironment(environment: ["ROW_ADDRESSING": "false"]), "the opt-out")
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
        // USE_SYNC_TABLES off: the feature turns the tables on; without it they stay off.
        let auto = try await RowAddressingRun.make(encoding: .messagepack, rowAddressing: true, tables: false)
        #expect(auto.adapter.rowAddressing)
        #expect(await auto.adapter.usesSyncTablesForTesting())
        let plain = try await RowAddressingRun.make(encoding: .messagepack, rowAddressing: false, tables: false)
        #expect(!(await plain.adapter.usesSyncTablesForTesting()))
    }

    @Test("USE_SYNC_TABLES=false with row addressing in effect: the tables stay on, with one warning that names ROW_ADDRESSING=false")
    func tablesOffIgnoredWarning() async throws {
        func warnings(rowAddressing: Bool, tables: Bool, joinsThroughRouter: Bool = true) async throws -> (warnings: [String], tables: Bool) {
            let records = RowAddressingLogRecords()
            let logger = Logger(label: "row-addressing-test") { _ in RowAddressingRecordingLogHandler(records: records) }
            let run = try await RowAddressingRun.make(
                encoding: .messagepack, rowAddressing: rowAddressing, joinsThroughRouter: joinsThroughRouter, tables: tables, logger: logger
            )
            return (records.warnings.filter { $0.contains("USE_SYNC_TABLES=false is ignored") }, await run.adapter.usesSyncTablesForTesting())
        }
        let ignored = try await warnings(rowAddressing: true, tables: false)
        #expect(ignored.warnings.count == 1)
        #expect(ignored.warnings.first?.contains("Set ROW_ADDRESSING=false too") == true)
        #expect(ignored.tables)
        #expect(try await warnings(rowAddressing: false, tables: false).warnings.isEmpty, "both off: the tables are off, nothing ignored")
        #expect(try await warnings(rowAddressing: true, tables: true).warnings.isEmpty, "the tables on: nothing ignored")
        // Requested but not in effect (a direct join): the tables really are off, so nothing is ignored.
        let direct = try await warnings(rowAddressing: true, tables: false, joinsThroughRouter: false)
        #expect(direct.warnings.isEmpty)
        #expect(!direct.tables)
    }

    @Test("Row addressing requested by default but not in effect (a replay keeper's in-turn sync off, a direct join) logs at info, not as a warning")
    func notInEffectIsInfo() async throws {
        for (inTurnSync, joinsThroughRouter) in [(false, true), (true, false)] {
            let records = RowAddressingLogRecords()
            let logger = Logger(label: "row-addressing-test") { _ in RowAddressingRecordingLogHandler(records: records) }
            let run = try await RowAddressingRun.make(
                encoding: .messagepack, rowAddressing: true, joinsThroughRouter: joinsThroughRouter, inTurnSync: inTurnSync, logger: logger
            )
            #expect(!run.adapter.rowAddressing)
            let notInEffect = records.all.filter { $0.message.contains("Row addressing requested but not in effect") }
            #expect(notInEffect.map(\.level) == [.info], "inTurnSync \(inTurnSync), router \(joinsThroughRouter)")
            #expect(records.warnings.isEmpty, "inTurnSync \(inTurnSync), router \(joinsThroughRouter): \(records.warnings)")
        }
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
                #expect(try runs[1].clientSlots(player) == server, "\(name): \(player)'s slots")
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

    @Test("On the row path, dirty tracking on and off send the same frames", arguments: RowAddressingEncoding.allCases)
    func dirtyTrackingOnAndOff(encoding: RowAddressingEncoding) async throws {
        let initial = unitsWith(["a": RowAddressingUnit(hp: 1), "b": RowAddressingUnit(hp: 2)])
        var runs = [
            try await RowAddressingRun.make(encoding: encoding, rowAddressing: true, dirtyTracking: true, initial: initial),
            try await RowAddressingRun.make(encoding: encoding, rowAddressing: true, dirtyTracking: false, initial: initial),
        ]
        for (index, dirty) in [true, false].enumerated() {
            // Each arm runs what it says: rows, the tables, and its dirty tracking.
            #expect(runs[index].adapter.rowAddressing)
            #expect(await runs[index].adapter.usesSyncTablesForTesting())
            #expect(await runs[index].adapter.dirtyTrackingEnabledForTesting() == dirty)
        }
        let steps: [(inout RowAddressingState) -> Void] = [
            { $0.units["a"]?.hp = 10; $0.units["c"] = RowAddressingUnit(hp: 3) },
            { $0.units["b"] = nil; $0.units["c"]?.bag["k"] = 1 },
            // Only `round`: with dirty tracking on, the plan skips the slot table's diff.
            { $0.round = 1 },
            { $0.units["d"] = RowAddressingUnit(hp: 4); $0.units["a"]?.note = "x" },
            { $0.units["a"]?.note = nil; $0.round = 2 },
        ]
        for index in runs.indices { try await runs[index].join("p1") }
        for (n, step) in steps.enumerated() {
            if n == 3 { for index in runs.indices { try await runs[index].join("p2") } }
            for run in runs { await run.tick(step) }
        }
        for player in ["p1", "p2"] {
            let on = await runs[0].frames.frames(for: SessionID("s-\(player)"))
            let off = await runs[1].frames.frames(for: SessionID("s-\(player)"))
            #expect(on.count > 2, "\(player) got frames")
            #expect(on == off, "\(player): the frames differ with dirty tracking off")
        }
        // Row entries were sent, in every frame the same: this is the row path, not the path-entry one.
        let rowOps = try await runs[0].rowEntryOps()
        #expect(!rowOps.isEmpty)
        #expect(try await runs[1].rowEntryOps() == rowOps)
        for index in runs.indices {
            #expect(await runs[index].adapter.dirtyTrackingEnabledForTesting() == (index == 0), "dirty tracking at the end")
        }
    }

    @Test("Opcode JSON: a row whose value does not encode is dropped from the plan; the rest of the table proceeds, and the row is retried")
    func rowDrop() async throws {
        let initial = unitsWith(["a": RowAddressingUnit(hp: 1), "ab": RowAddressingUnit(hp: 5), "b": RowAddressingUnit(hp: 2)])
        var run = try await RowAddressingRun.make(encoding: .opcodeJsonArray, rowAddressing: true, initial: initial)
        try await run.join("p1")
        _ = try await run.read("p1")
        // A column that fails (a non-finite number) and a create that fails, beside healthy changes,
        // one in a row whose key extends the dropped row's ("ab" after "a").
        await run.tick { $0.units["a"]?.speed = .nan; $0.units["a"]?.hp = 11; $0.units["ab"]?.hp = 50; $0.units["b"]?.hp = 20; $0.units["x"] = RowAddressingUnit(hp: 9, speed: .infinity); $0.units["y"] = RowAddressingUnit(hp: 10) }
        let first = try await run.read("p1")
        func under(_ row: String) -> (StatePatch) -> Bool { { $0.path == row || $0.path.hasPrefix(row + "/") } }
        #expect(!first.patches.contains(where: under("/units/a")), "the whole row a is out, its healthy hp too")
        #expect(first.patches.contains { $0.path == "/units/ab/hp" }, "a row is dropped on component boundaries")
        #expect(!first.patches.contains(where: under("/units/x")))
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
        #expect(try run.clientSlots("p1") == (try #require(await run.adapter.rowSlotsForTesting("units"))))
    }

    @Test("Opcode JSON: a row that doesn't encode in the first join's seed is left out of the seed; its slot stays free, and it is created once it encodes")
    func seedRowDrop() async throws {
        // The bad row sorts between two others: the row after the gap keeps its seed slot.
        let initial = unitsWith(["a": RowAddressingUnit(hp: 1), "x": RowAddressingUnit(hp: 2, speed: .nan), "z": RowAddressingUnit(hp: 3)])
        var run = try await RowAddressingRun.make(encoding: .opcodeJsonArray, rowAddressing: true, initial: initial)
        try await run.join("p1")
        let first = try await run.read("p1")
        #expect(first.firstSync)
        #expect(!first.patches.contains { $0.path == "/units/x" || $0.path.hasPrefix("/units/x/") })
        let slots = try #require(await run.adapter.rowSlotsForTesting("units"))
        #expect(slots["x"] == nil, "the dropped row binds no slot")
        #expect(slots["a"]?.slot == 0 && slots["z"]?.slot == 2, "the others keep their seed slots: \(slots)")
        #expect(try run.clientSlots("p1") == slots)
        #expect(await run.adapter.rowRetryFieldsForTesting() == ["units"])
        // A column of the row while it still doesn't encode, then the fix: the row arrives as a
        // create, and nothing addresses an unbound slot on the client.
        await run.tick { $0.units["x"]?.hp = 3 }
        _ = try await run.read("p1")
        await run.tick { $0.units["x"]?.speed = 1 }
        let fixed = try await run.read("p1")
        #expect(fixed.patches.contains { $0.path == "/units/x" }, "created whole")
        #expect(try run.view("p1") == (try await run.liveView()))
        #expect(try run.clientSlots("p1") == (try #require(await run.adapter.rowSlotsForTesting("units"))))
        #expect(await run.adapter.rowRetryFieldsForTesting() == [])
    }

    @Test("The row repair: a follow-up for the first three committed plans that drop a row, none after; a clean plan re-arms it; failed plans are counted apart")
    func rowRepairLimit() async throws {
        let initial = unitsWith(["a": RowAddressingUnit(hp: 1)])
        var run = try await RowAddressingRun.make(encoding: .opcodeJsonArray, rowAddressing: true, initial: initial)
        try await run.join("p1")
        var broken = initial
        broken.units["a"]?.speed = .nan
        func plan(_ state: RowAddressingState) async -> InTurnSyncResult {
            // The writer must be empty, or the plan is deferred (back-pressure): a frame of the
            // last plan may reach it after a drain returned, so a deferred plan is made again.
            var result = InTurnSyncResult.deferredBackPressure
            for _ in 0..<100 where result == .deferredBackPressure {
                _ = await run.adapter.waitForOutboundDrain()
                result = await run.adapter.runSyncPhaseInTurnIsolated(state: state, events: [], includeSync: true)
            }
            return result
        }
        func expect(_ state: RowAddressingState, _ expected: InTurnSyncResult, _ comment: String, sourceLocation: SourceLocation = #_sourceLocation) async {
            let result = await plan(state)
            #expect(result == expected, "\(comment): \(result)", sourceLocation: sourceLocation)
        }
        for repairs in 1...3 {
            await expect(broken, .committedWithRepairPending(clearDirtyFlags: true), "repair \(repairs)")
        }
        await expect(broken, .committed(clearDirtyFlags: true), "past the limit: no follow-up")
        #expect(await run.adapter.consecutiveRowRepairsForTesting() == 4)
        #expect(await run.adapter.consecutiveFailedPlansForTesting() == 0)
        var fixed = initial
        fixed.units["a"]?.speed = 2
        await expect(fixed, .committed(clearDirtyFlags: true), "fixed")
        #expect(await run.adapter.consecutiveRowRepairsForTesting() == 0)
        await expect(broken, .committedWithRepairPending(clearDirtyFlags: true), "re-armed")
        // A plan committed outside the in-turn path doesn't make the next turn a repair.
        await run.adapter.syncNow()
        await expect(fixed, .committed(clearDirtyFlags: true), "after syncNow")
    }

    @Test("The sync stream is the same with the feature off and on, and each arm's record replays to the same summary: row entries are made after the plan", arguments: RowAddressingEncoding.allCases)
    func recordStaysLogical(encoding: RowAddressingEncoding) async throws {
        let initial = unitsWith(["a": RowAddressingUnit(hp: 1), "b": RowAddressingUnit(hp: 2)])
        let steps: [(inout RowAddressingState) -> Void] = [
            // Only `round` dirty when the first player joins: the plan's broadcast diff seeds
            // `round` alone.
            { $0.round = 1 },
            { $0.units["a"]?.hp = 10; $0.units["c"] = RowAddressingUnit(hp: 3) },
            { $0.units["b"] = nil; $0.units["c"]?.bag["k"] = 1 },
            { $0.units["d"] = RowAddressingUnit(hp: 4) },
        ]
        var streams: [Data] = [], summaries: [String] = []
        for on in [false, true] {
            var run = try await RowAddressingRun.make(encoding: encoding, rowAddressing: on, recording: true, initial: initial)
            #expect(run.adapter.rowAddressing == on)
            await run.tick(steps[0])
            try await run.join("p1")
            await run.tick(steps[1])
            try await run.join("p2")
            await run.tick(steps[2])
            await run.tick(steps[3])
            // Each arm sent what it says: row entries with the feature, none without.
            #expect(try await run.rowEntryOps().isEmpty == !on, "row entries sent: \(on)")
            await run.keeper.waitForRecorderSubmissionsForTesting()
            let recorder = try #require(await run.keeper.getReevaluationRecorder())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            streams.append(try encoder.encode(await recorder.getAllFrames()))
            let result = try await run.replay(steps: steps, initial: initial)
            #expect(result.syncOutput.verdict == .passed, "rows \(on): \(result.syncOutput.summary)")
            summaries.append(result.syncOutput.summary)
        }
        #expect(streams[0] == streams[1])
        #expect(summaries[0] == summaries[1])
    }

    @Test("A map whose seed failed is diffed from nothing once it converts: the record is the same with the feature off and on", arguments: RowAddressingEncoding.allCases)
    func recordAfterAFailedSeed(encoding: RowAddressingEncoding) async throws {
        var initial = unitsWith(["a": RowAddressingUnit(hp: 1)])
        initial.units["a"]?.seal.failing = true
        var streams: [Data] = []
        for on in [false, true] {
            var run = try await RowAddressingRun.make(encoding: encoding, rowAddressing: on, recording: true, initial: initial)
            // The first join's seed: `units` throws, `round` seeds, so the tables are seeded
            // with `units` left unseeded.
            try await run.join("p1")
            #expect(await run.adapter.rowSlotsForTesting("units") == nil, "units not seeded")
            // It converts: its first diff is from nothing, for a synced recipient.
            await run.tick { $0.units["a"]?.seal.failing = false; $0.units["b"] = RowAddressingUnit(hp: 2); $0.round = 1 }
            if on {
                #expect(await run.adapter.rowSlotsForTesting("units")?.count == 2, "slot-addressed from its first diff")
            }
            await run.tick { $0.units["a"]?.hp = 5 }
            _ = try await run.read("p1")
            #expect(try run.view("p1") == (try await run.liveView()), "on: \(on)")
            await run.keeper.waitForRecorderSubmissionsForTesting()
            let recorder = try #require(await run.keeper.getReevaluationRecorder())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            streams.append(try encoder.encode(await recorder.getAllFrames()))
        }
        #expect(streams[0] == streams[1])
    }

    @Test("Opcode JSON: a row dropped in the plan that diffs a map from nothing; the remake's key-scope reset updates carry the diff, digested in the live form")
    func remakeAfterAFailedSeed() async throws {
        var initial = unitsWith(["a": RowAddressingUnit(hp: 1)])
        initial.units["a"]?.seal.failing = true
        var run = try await RowAddressingRun.make(encoding: .opcodeJsonArray, rowAddressing: true, recording: true, initial: initial)
        try await run.join("p1")
        try await run.join("p2")
        // `units` converts and is diffed from nothing, and a row in it doesn't encode: the plan is
        // made again with every key scope reset, so each update carries the broadcast diff. (A
        // digest of the wire form there fails the scope assertion in debug builds.)
        await run.tick { $0.units["a"]?.seal.failing = false; $0.units["n"] = RowAddressingUnit(hp: 2, speed: .nan) }
        #expect(await run.adapter.rowRetryFieldsForTesting() == ["units"])
        await run.tick { $0.units["n"]?.speed = 1 }
        for name in ["p1", "p2"] {
            _ = try await run.read(name)
            #expect(try run.view(name) == (try await run.liveView()), "\(name)")
            #expect(try run.clientSlots(name) == (try #require(await run.adapter.rowSlotsForTesting("units"))))
        }
        await run.keeper.waitForRecorderSubmissionsForTesting()
    }

    @Test("Merged frames: a lagging reader's resync sends the tables as {} plus creates; it ends at the live state with the server's slots, and the other reader is unaffected")
    func mergedResync() async throws {
        let initial = unitsWith(["a": RowAddressingUnit(hp: 1), "b": RowAddressingUnit(hp: 2)])
        var run = try await RowAddressingRun.make(encoding: .messagepack, rowAddressing: true, initial: initial)
        let clock = SyncLagManualClock()
        await run.adapter.setSyncLagClockForTesting { clock.now }
        await run.adapter.setSyncLagTimerIntervalForTesting(.seconds(3600))
        try await run.join("fast")
        try await run.join("slow")
        let slowFirst = try #require(try await run.read("slow").lastSeq)
        if let seq = try await run.read("fast").lastSeq { try await run.ack("fast", seq) }
        try await run.ack("slow", slowFirst)
        var step = 0
        var resynced = false
        // The slow reader keeps acking its first view while the rows change: past 3 s it is due.
        while step < 6 && !resynced {
            step += 1
            let n = step
            await run.tick { state in
                state.units["a"]?.hp = 10 + n
                state.units["k\(n)"] = RowAddressingUnit(hp: n)
                if n == 2 { state.units["b"] = nil }
            }
            clock.advance(1.5)
            if let seq = try await run.read("fast").lastSeq { try await run.ack("fast", seq) }
            try await run.ack("slow", slowFirst)
            resynced = try await run.read("slow").resync
        }
        #expect(resynced, "the slow reader was resynced")
        #expect(await run.adapter.syncLagResyncs == 1)
        let server = try #require(await run.adapter.rowSlotsForTesting("units"))
        let live = try await run.liveView()
        for name in ["fast", "slow"] {
            #expect(try run.view(name) == live, "\(name) holds the live state")
            #expect(try run.clientSlots(name) == server, "\(name)'s slots")
        }
        // After the resync, diffs again for both.
        await run.tick { $0.units["a"]?.hp = 99; $0.units["z"] = RowAddressingUnit(hp: 9) }
        for name in ["fast", "slow"] {
            _ = try await run.read(name)
            #expect(try run.view(name) == (try await run.liveView()), "\(name) after the resync")
            #expect(try run.clientSlots(name) == (try #require(await run.adapter.rowSlotsForTesting("units"))))
        }
    }

    @Test("The digest form of a map diffed from nothing is one set of the whole map, as with row entries off")
    func liveDigestFormOfAnUnseededMap() throws {
        let hasher = PathHasher(pathHashes: try rowAddressingPathHashes())
        var state = unitsWith(["a": RowAddressingUnit(hp: 1), "b": RowAddressingUnit(hp: 2)])
        state.round = 3
        func firstDiff(rowCreates: Bool) -> (patches: [StatePatch], live: [StatePatch]) {
            let tables = SyncTableBroadcastDiff<RowAddressingState>(pathCursor: hasher.rootCursor)
            tables.emitsRowCreates = rowCreates
            var drops = ExtractionDrops()
            let result = tables.diff(state, fields: nil, drops: &drops)
            return (result.patches, tables.liveDigestForm(of: result.patches, staged: result.staged))
        }
        let on = firstDiff(rowCreates: true)
        let off = firstDiff(rowCreates: false)
        #expect(on.patches.contains { $0.path == "/units/a" }, "on the wire: creates")
        #expect(sortedPatches(on.live) == sortedPatches(off.patches), "digested as today's patches")
        #expect(sortedPatches(off.live) == sortedPatches(off.patches), "off: unchanged")
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

/// Log records, in order (`RowAddressingRecordingLogHandler`).
private final class RowAddressingLogRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(level: Logger.Level, message: String)] = []

    func append(_ level: Logger.Level, _ message: String) {
        lock.withLock { records.append((level, message)) }
    }

    var all: [(level: Logger.Level, message: String)] {
        lock.withLock { records }
    }

    /// Warnings and above.
    var warnings: [String] {
        all.filter { $0.level >= .warning }.map(\.message)
    }
}

/// Records info and above.
private struct RowAddressingRecordingLogHandler: LogHandler {
    let records: RowAddressingLogRecords
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        if level >= .info { records.append(level, message.description) }
    }
}
