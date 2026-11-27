// Tests/SwiftStateTreeTransportTests/SyncOutputVerifierTests.swift
//
// The sync-output hash verifier end to end: a live land with in-turn sync records its sync
// stream, `ReevaluationEngine.run` replays it, and the shadow sync engine re-plans every output.
// Faults are injected into the live digest (standing in for a diff that sent something else)
// or into the live dirty tracking; the verifier must report them, and only them.

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeTestSupport
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

/// A value whose number lives outside it, in a slot of `verifierBoxSlots` that every copy
/// shares: setting it doesn't go through `@Sync`'s setter, so the live dirty tracking misses the
/// change (a dirty-tracking miss). Synced state can't hold a class (#464); this struct
/// conforms to `SnapshotValueConvertible`, which promises value semantics, and breaks that
/// promise on purpose.
@PlainData
struct VerifierBox: Codable, Sendable, Equatable, SnapshotValueConvertible {
    private let slot: Int

    init() { slot = verifierBoxSlots.allocate(0) }

    var value: Int {
        get { verifierBoxSlots[slot] }
        nonmutating set { verifierBoxSlots[slot] = newValue }
    }

    init(from decoder: any Decoder) throws {
        slot = verifierBoxSlots.allocate(try decoder.singleValueContainer().decode(Int.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    func toSnapshotValue() throws -> SnapshotValue { .int(value) }
    static func == (lhs: VerifierBox, rhs: VerifierBox) -> Bool { lhs.value == rhs.value }
}

/// The numbers behind every `VerifierBox`, one slot each.
private final class VerifierBoxSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func allocate(_ value: Int) -> Int {
        lock.withLock {
            values.append(value)
            return values.count - 1
        }
    }

    subscript(slot: Int) -> Int {
        get { lock.withLock { values[slot] } }
        set { lock.withLock { values[slot] = newValue } }
    }
}

private let verifierBoxSlots = VerifierBoxSlots()

@StateNodeBuilder
struct VerifierState: StateNodeProtocol {
    @Sync(.broadcast) var ticks: Int = 0
    @Sync(.broadcast) var board: [String: Int] = [:]
    @Sync(.broadcast) var fragile: SyncStreamFragile = SyncStreamFragile()
    @Sync(.broadcast) var box: VerifierBox = VerifierBox()
    @Sync(.perPlayerSlice()) var scores: [PlayerID: Int] = [:]
    @Sync(.perPlayerSlice()) var speeds: [PlayerID: Double] = [:]
    @Sync(.perPlayerSlice()) var boxes: [PlayerID: VerifierBox] = [:]
    @Sync(.serverOnly) var missesDirty: Bool = false
    @Sync(.serverOnly) var missesPerPlayerDirty: Bool = false
    @Sync(.serverOnly) var quiet: Bool = false
    init() {}
}

/// "score": the caller's score is `value`; "break" / "fix": broadcast `fragile`; "miss": from
/// the next tick on, the tick also changes `box` in place; "box": the caller gets a box;
/// "missPerPlayer": the tick changes every player's box in place and rewrites `scores`
/// unchanged (dirty, no patch); "inf": the caller's speed is infinity (json cannot encode it);
/// "speed": the caller's speed is `value`; "nan": the caller's speed is NaN; "quiet": ticks stop
/// requesting a sync; "burst": `value` events to the caller and `value` to everyone, in the
/// action's turn; "keys": `board` gets the keys "a/b", "t~1" and "x[1]" (escaped paths, and a
/// key that looks like an index), set to `value`.
///
/// The golden recordings (`SyncOutputGoldenTests`) replay against this land: a change to it
/// that changes its sync output needs them regenerated.
@Payload
struct VerifierSetAction: ActionPayload {
    typealias Response = SyncStreamSetResponse
    let field: String
    let value: Int
}

/// OnInitialize writes the board and emits an event. Each tick advances `ticks`, writes one
/// board entry, emits two events to everyone and one to nobody (never queued), and requests a
/// sync.
func makeVerifierLand() -> LandDefinition<VerifierState> {
    Land("sync-output-verifier-test", using: VerifierState.self) {
        ServerEvents { Register(SyncStreamTestEvent.self) }
        Lifetime {
            OnInitialize { state, ctx in
                state.board["init"] = 1
                ctx.emitEvent(SyncStreamTestEvent(message: "init"), to: .all)
            }
            Tick(every: .seconds(3600)) { state, ctx in
                state.ticks += 1
                state.board["t\(state.ticks)"] = state.ticks
                if state.missesDirty {
                    state.box.value += 1
                }
                if state.missesPerPlayerDirty {
                    let boxes = state.boxes
                    for box in boxes.values { box.value += 1 }
                    state.scores = state.scores
                }
                ctx.emitEvent(SyncStreamTestEvent(message: "a-\(state.ticks)"), to: .all)
                ctx.emitEvent(SyncStreamTestEvent(message: "nobody-\(state.ticks)"), to: .players([]))
                ctx.emitEvent(SyncStreamTestEvent(message: "b-\(state.ticks)"), to: .all)
                if !state.quiet {
                    ctx.requestSyncNow()
                }
            }
        }
        Rules {
            HandleAction(VerifierSetAction.self) { state, action, ctx in
                switch action.field {
                case "break": state.fragile.broken = true
                case "fix": state.fragile.broken = false
                case "miss": state.missesDirty = true
                case "missPerPlayer": state.missesPerPlayerDirty = true
                case "box": state.boxes[ctx.playerID] = VerifierBox()
                case "inf": state.speeds[ctx.playerID] = .infinity
                case "speed": state.speeds[ctx.playerID] = Double(action.value)
                case "nan": state.speeds[ctx.playerID] = .nan
                case "quiet": state.quiet = true
                case "keys":
                    for key in ["a/b", "t~1", "x[1]"] { state.board[key] = action.value }
                case "burst":
                    for n in 0..<action.value {
                        ctx.emitEvent(SyncStreamTestEvent(message: "to-\(ctx.playerID.rawValue)-\(n)"), to: .player(ctx.playerID))
                        ctx.emitEvent(SyncStreamTestEvent(message: "all-\(n)"), to: .all)
                    }
                default: state.scores[ctx.playerID] = action.value
                }
                return SyncStreamSetResponse(ok: true)
            }
        }
    }
}

let verifierPathHashes: [String: UInt32] = Dictionary(
    uniqueKeysWithValues: ["ticks", "board", "fragile", "box", "scores", "speeds", "boxes", "missesDirty", "missesPerPlayerDirty", "quiet"].map { ($0, DeterministicHash.fnv1a32($0)) }
)

/// The verifier land's full schema path hashes. `verifierPathHashes` holds only the top-level
/// fields, so a nested path such as `/board/t1` takes the fallback hash; with the path index on
/// that path has no index, so path-index fixtures use the schema's table.
let verifierSchemaPathHashes: [String: UInt32] = {
    let definition = makeVerifierLand()
    let schema = try! SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(definition)])
    return schema.lands[definition.id]!.pathHashes!
}()

actor VerifierTransport: Transport {
    var delegate: TransportDelegate?
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {}
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {}
}

/// The verifier land with server events on its second tick only, and none in OnInitialize: in a
/// hybrid configuration (#521 D10) every event goes alone, so the outputs around that tick carry
/// no events and stay compared.
func makeGatedVerifierLand() -> LandDefinition<VerifierState> {
    Land("sync-output-verifier-test", using: VerifierState.self) {
        ServerEvents { Register(SyncStreamTestEvent.self) }
        Lifetime {
            Tick(every: .seconds(3600)) { state, ctx in
                state.ticks += 1
                state.board["t\(state.ticks)"] = state.ticks
                if state.ticks == 2 {
                    ctx.emitEvent(SyncStreamTestEvent(message: "a-\(state.ticks)"), to: .all)
                    ctx.emitEvent(SyncStreamTestEvent(message: "nobody-\(state.ticks)"), to: .players([]))
                    ctx.emitEvent(SyncStreamTestEvent(message: "b-\(state.ticks)"), to: .all)
                }
                ctx.requestSyncNow()
            }
        }
    }
}

struct VerifierFixture {
    let keeper: LandKeeper<VerifierState>
    let adapter: TransportAdapter<VerifierState>
    /// The land the fixture records, and its replay rebuilds.
    var definition = makeVerifierLand()
    /// Joins go through the adapter's in-turn router path (`performJoin`), as a hosted land's do.
    var throughRouter = false

    /// With `encoder`, the adapter encodes json through it (it ignores `encoding`).
    ///
    /// `initializeFirst` waits for OnInitialize before attaching the adapter, so the stream has
    /// no initialize marker and its indices are the same in every run. Without it, OnInitialize
    /// may run before or after the adapter is attached (with or without a marker).
    static func make(
        encoding: InTurnEncoding,
        encoder: (any StateUpdateEncoder)? = nil,
        initializeFirst: Bool = true,
        pathIndex: Bool = false,
        pathHashes: [String: UInt32]? = nil,
        fieldMerge: Bool = false,
        syncSequence: Bool = false,
        definition: LandDefinition<VerifierState> = makeVerifierLand()
    ) async -> VerifierFixture {
        let keeper = LandKeeper<VerifierState>(
            definition: definition,
            initialState: VerifierState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false
        )
        let transport = VerifierTransport()
        let adapter: TransportAdapter<VerifierState>
        if let encoder {
            adapter = TransportAdapter<VerifierState>(
                keeper: keeper,
                transport: transport,
                landID: "sync-output-verifier-test",
                stateUpdateEncoder: encoder
            )
        } else {
            adapter = TransportAdapter<VerifierState>(
                keeper: keeper,
                transport: transport,
                landID: "sync-output-verifier-test",
                encodingConfig: encoding.config.withPathIndex(pathIndex).withFieldMerge(fieldMerge).withSyncSequence(syncSequence),
                pathHashes: encoding == .json ? nil : pathHashes ?? (pathIndex ? verifierSchemaPathHashes : verifierPathHashes)
            )
        }
        await transport.setDelegate(adapter)
        if initializeFirst {
            await keeper.awaitInitialization()
        }
        await keeper.setTransport(adapter)
        // The adapter link is a cycle until the drain: the suite's trait drains it (#910).
        FixtureKeepers.register(keeper)
        return VerifierFixture(keeper: keeper, adapter: adapter, definition: definition)
    }

    /// A land as a hosted server runs it: joins through the router (`performJoin`), the sync
    /// sequence, the schema's path hashes with the path index and field merge, in-turn sync, and
    /// the sync tables on with the delta strategy. The env config is given, not read, so the
    /// fixture is the same in a run with `USE_SYNC_TABLES=false`. `rowAddressing` is the only
    /// knob: with it on, row addressing is in effect (the caller asserts it). `perPlayerTables`
    /// sets `PER_PLAYER_SYNC_TABLES` (#514); nil takes the environment's.
    static func makeThroughRouter(encoding: InTurnEncoding, rowAddressing: Bool, perPlayerTables: Bool? = nil) async -> VerifierFixture {
        let keeper = LandKeeper<VerifierState>(
            definition: makeVerifierLand(),
            initialState: VerifierState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false
        )
        var env = TransportEnvConfig(enableDirtyTracking: true, useSnapshotForSync: false, syncStrategy: .delta, profilingConfig: nil)
        env.useSyncTables = true
        if let perPlayerTables { env.perPlayerSyncTables = perPlayerTables }
        let transport = VerifierTransport()
        let adapter = TransportAdapter<VerifierState>(
            keeper: keeper,
            transport: transport,
            landID: "sync-output-verifier-test",
            transportEnvConfig: env,
            encodingConfig: encoding.config.withPathIndex(true).withFieldMerge(true).withSyncSequence(true).withRowAddressing(rowAddressing),
            pathHashes: verifierSchemaPathHashes,
            suppressMissingPathHashesWarning: true,
            joinsThroughRouter: true
        )
        await transport.setDelegate(adapter)
        await keeper.awaitInitialization()
        await keeper.setTransport(adapter)
        // The adapter link is a cycle until the drain: the suite's trait drains it (#910).
        FixtureKeepers.register(keeper)
        return VerifierFixture(keeper: keeper, adapter: adapter, throughRouter: true)
    }

    static func player(_ n: Int) -> PlayerID { PlayerID("p\(n)") }

    /// Holds every failed plan's delayed follow-up cycle (`startDelayedFollowUpSync`) until the
    /// returned gate opens, so the recorded outputs follow from the test's own steps, not from
    /// whether a 100 ms timer fired first. Open it when the test is done with the record.
    func holdFailedPlanFollowUps() async -> TestGate {
        let gate = TestGate()
        await adapter.installHolds(HoldRegistry.at(.failedPlanFollowUp) { await gate.arrive() })
        return gate
    }

    func join(_ n: Int) async throws {
        await adapter.onConnect(sessionID: SessionID("s\(n)"), clientID: ClientID("c\(n)"))
        if throughRouter {
            // The same join metadata in every run: records keep it.
            let result = try await adapter.performJoin(
                playerSession: PlayerSession(playerID: Self.player(n).rawValue, deviceID: "dev", metadata: [:]),
                clientID: ClientID("c\(n)"),
                sessionID: SessionID("s\(n)"),
                authInfo: nil,
                joinResponse: { playerID, slot in
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    return try? encoder.encode(TransportMessage.joinResponse(
                        requestID: "r-\(playerID.rawValue)", success: true, playerID: playerID.rawValue, playerSlot: slot, encoding: "json"
                    ))
                }
            )
            _ = try #require(result)
            await adapter.waitForOutboundIdleForTesting()
            return
        }
        try await simulateRouterJoin(
            adapter: adapter,
            keeper: keeper,
            sessionID: SessionID("s\(n)"),
            clientID: ClientID("c\(n)"),
            playerID: Self.player(n),
            waitsByEvent: true
        )
    }

    func leave(_ n: Int) async {
        await adapter.onDisconnect(sessionID: SessionID("s\(n)"), clientID: ClientID("c\(n)"))
    }

    func set(_ n: Int, _ field: String, _ value: Int = 0) async throws {
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: VerifierSetAction.self),
                payload: AnyCodable(VerifierSetAction(field: field, value: value))
            ),
            playerID: Self.player(n),
            clientID: ClientID("c\(n)"),
            sessionID: SessionID("s\(n)")
        )
    }

    /// The recorded sync stream so far.
    func stream() async throws -> [ReevaluationSyncStreamEntry] {
        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        return ReevaluationSyncStreamEntry.stream(of: await recorder.getAllFrames())
    }

    func tick(_ count: Int = 1) async {
        for _ in 0 ..< count {
            await keeper.stepTickOnce()
            await adapter.waitForOutboundIdleForTesting()
        }
    }

    /// Saves the record (with the adapter's sync config, as `LandManager` writes it) and replays
    /// it. `rewrite` edits the saved record first.
    func replay(
        version: String = ReevaluationRecordVersion.current,
        withSyncConfig: Bool = true,
        rewrite: ((inout [ReevaluationTickFrame]) -> Void)? = nil
    ) async throws -> ReevaluationEngine.RunResult {
        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: "sync-output-verifier-test",
            landType: "sync-output-verifier-test",
            createdAt: Date(),
            metadata: [:],
            landDefinitionID: definition.id,
            version: version,
            recordsSyncStream: true,
            syncConfig: withSyncConfig ? adapter.syncConfigForRecord : nil
        ))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-output-verifier-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await recorder.saveCopyForTesting(to: path)
        if version != ReevaluationRecordVersion.current {
            try relabelRecordVersion(atPath: path, to: version)
        }
        if let rewrite {
            try VerifierRecordFile.rewrite(path, rewrite)
        }
        return try await Self.replay(recordAt: path, definition: definition)
    }

    /// Replays the record as a copy of the live recorder (`ReevaluationRecorder.encode()`, the
    /// copy the admin download serves): its footer is incomplete, and the reader leaves out the
    /// newest tick.
    /// `rewrite` edits the copy's log records (footer kept incomplete) before the replay.
    func replayLiveCopy(rewrite: ((inout [ReevaluationLogRecord]) -> Void)? = nil) async throws -> ReevaluationEngine.RunResult {
        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: "sync-output-verifier-test",
            landType: "sync-output-verifier-test",
            createdAt: Date(),
            metadata: [:],
            landDefinitionID: definition.id,
            version: ReevaluationRecordVersion.current,
            recordsSyncStream: true,
            syncConfig: adapter.syncConfigForRecord
        ))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-output-verifier-live-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var bytes = Array(try await recorder.encode())
        if let rewrite {
            var records: [ReevaluationLogRecord] = []
            var offset = ReevaluationRecordLog.preamble.count
            while offset < bytes.count {
                let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                records.append(try CanonicalMessagePack.decode(ReevaluationLogRecord.self, from: Array(bytes[(offset + 4)..<(offset + 4 + length)])))
                offset += 4 + length
            }
            rewrite(&records)
            bytes = ReevaluationRecordLog.preamble
            for record in records { bytes += try ReevaluationRecordLog.framed(record) }
        }
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return try await Self.replay(recordAt: path, definition: definition)
    }

    /// Saves the record as `replay` does, to `path`.
    func saveRecord(to path: String) async throws {
        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: "sync-output-verifier-test",
            landType: "sync-output-verifier-test",
            createdAt: Date(timeIntervalSince1970: 0),
            metadata: [:],
            landDefinitionID: definition.id,
            version: ReevaluationRecordVersion.current,
            recordsSyncStream: true,
            syncConfig: adapter.syncConfigForRecord
        ))
        try await recorder.saveCopyForTesting(to: path)
    }

    /// Replays a saved record of the verifier land (or of `definition`).
    static func replay(
        recordAt path: String,
        definition: LandDefinition<VerifierState> = makeVerifierLand()
    ) async throws -> ReevaluationEngine.RunResult {
        try await ReevaluationEngine.run(
            definition: definition,
            initialState: VerifierState(),
            recordFilePath: path
        )
    }
}

private struct VerifierRecordFile: Codable {
    var recordMetadata: ReevaluationRecordMetadata
    var tickFrames: [ReevaluationTickFrame]

    static func rewrite(_ path: String, _ edit: (inout [ReevaluationTickFrame]) -> Void) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try ReevaluationRecordFile.convertToJSONViewForTesting(atPath: path)
        var file = try decoder.decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        edit(&file.tickFrames)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: URL(fileURLWithPath: path))
    }
}

/// A frame with its initialize record replaced (the type has no setters).
private func replacingInitialize(_ frame: ReevaluationTickFrame, with initialize: ReevaluationRecordedInitialize?) -> ReevaluationTickFrame {
    ReevaluationTickFrame(
        tickId: frame.tickId,
        stateHash: frame.stateHash,
        actions: frame.actions,
        clientEvents: frame.clientEvents,
        lifecycleEvents: frame.lifecycleEvents,
        serverEvents: frame.serverEvents,
        sequenceBeforeInputs: frame.sequenceBeforeInputs,
        sequenceBeforeTickHandler: frame.sequenceBeforeTickHandler,
        syncOutputs: frame.syncOutputs,
        syncMarkers: frame.syncMarkers,
        initialize: initialize
    )
}

/// The record with the tick output observed at `tickId` marked as not sent to `player` (opcode
/// 107: `perPlayerUncommitted`, an encode drop, and the player left out of `perPlayerHash`,
/// whose update there must have no patches).
private func markingUnsent(_ player: PlayerID, atTick tickId: Int64) -> (inout [ReevaluationTickFrame]) -> Void {
    { frames in
        for (frameIndex, frame) in frames.enumerated() {
            guard let outputIndex = frame.syncOutputs.firstIndex(where: { $0.turnKind == .tick && $0.observedTickId == tickId }) else { continue }
            var outputs = frame.syncOutputs
            let output = outputs[outputIndex]
            #expect(output.perPlayerHash == CanonicalPatchList.combinedHash([]), "no per-player change at tick \(tickId)")
            outputs[outputIndex] = ReevaluationRecordedSyncOutput(
                index: output.index,
                turnKind: output.turnKind,
                observedTickId: output.observedTickId,
                streamIndex: output.streamIndex,
                sequence: output.sequence,
                broadcastHash: output.broadcastHash,
                perPlayerHash: output.perPlayerHash,
                perPlayerUnverified: output.perPlayerUnverified,
                perPlayerUncommitted: [player.rawValue],
                perPlayerHashes: output.perPlayerHashes,
                eventsHash: output.eventsHash,
                eventsThroughSequence: output.eventsThroughSequence,
                eventsNotQueued: output.eventsNotQueued,
                eventsNotMerged: output.eventsNotMerged,
                resetsKeyScopes: output.resetsKeyScopes,
                extractionDrops: output.extractionDrops,
                encodeDropScopes: (output.encodeDropScopes + [player.rawValue]).sorted(),
                patches: output.patches
            )
            frames[frameIndex] = ReevaluationTickFrame(
                tickId: frame.tickId,
                stateHash: frame.stateHash,
                actions: frame.actions,
                clientEvents: frame.clientEvents,
                lifecycleEvents: frame.lifecycleEvents,
                serverEvents: frame.serverEvents,
                sequenceBeforeInputs: frame.sequenceBeforeInputs,
                sequenceBeforeTickHandler: frame.sequenceBeforeTickHandler,
                syncOutputs: outputs,
                syncMarkers: frame.syncMarkers,
                initialize: frame.initialize
            )
            return
        }
        Issue.record("no tick output at \(tickId)")
    }
}

/// Faults applied to the first digest they fit, once.
private final class DigestFault: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let apply: (inout SyncOutputDigestInput) -> Bool

    init(_ apply: @escaping (inout SyncOutputDigestInput) -> Bool) { self.apply = apply }

    var hasFired: Bool { lock.lock(); defer { lock.unlock() }; return fired }

    func run(_ digest: inout SyncOutputDigestInput) {
        lock.lock(); defer { lock.unlock() }
        guard !fired else { return }
        fired = apply(&digest)
    }
}

/// Two players, a score each, a few ticks, a third player joining mid-run and one leaving.
func playScript(_ f: VerifierFixture) async throws {
    try await f.join(1)
    try await f.join(2)
    try await f.set(1, "score", 10)
    await f.tick(2)
    try await f.set(2, "score", 20)
    try await f.join(3)
    await f.tick(2)
    await f.leave(1)
    await f.tick()
}

/// The first entry where a faulted run's stream differs from a clean run of the same script:
/// where the fault fired, which is where the verifier must report it.
private func faultLocation(
    encoding: InTurnEncoding,
    fault: DigestFault,
    detail: SyncStreamRecordingDetail = [],
    script: (VerifierFixture) async throws -> Void = playScript
) async throws -> (mismatch: SyncOutputMismatch?, expected: ReevaluationSyncStreamEntry) {
    let clean = await VerifierFixture.make(encoding: encoding)
    try await script(clean)
    let faulted = await VerifierFixture.make(encoding: encoding)
    await faulted.adapter.setSyncStreamDetail(detail)
    await faulted.adapter.setSyncOutputDigestFaultForTesting { fault.run(&$0) }
    try await script(faulted)
    #expect(fault.hasFired)
    let cleanStream = try await clean.stream()
    let faultedStream = try await faulted.stream()
    #expect(cleanStream.count == faultedStream.count)
    let index = try #require(faultedStream.indices.first { $0 >= cleanStream.count || cleanStream[$0] != faultedStream[$0] })
    let result = try await faulted.replay()
    guard case .failed(let mismatch) = result.syncOutput.verdict else {
        Issue.record("expected a failed verdict, got \(result.syncOutput.summary)")
        return (nil, faultedStream[index])
    }
    return (mismatch, faultedStream[index])
}

private func position(_ entry: ReevaluationSyncStreamEntry) -> (streamIndex: UInt64, observedTickId: Int64?) {
    switch entry {
    case .output(let output): return (output.streamIndex, output.observedTickId)
    case .marker(let marker): return (marker.streamIndex, marker.observedTickId)
    }
}

/// JSON, except that every per-player update (of `player`, if set) fails while `fails` is on,
/// even an empty one.
private struct VerifierFailingEncoder: StateUpdateEncoderWithScope {
    let inner = JSONStateUpdateEncoder()
    let fails: VerifierSwitch
    var player: PlayerID?

    var encoding: StateUpdateEncoding { inner.encoding }

    func encode(update: StateUpdate, landID: String, playerID: PlayerID) throws -> Data {
        try encode(update: update, landID: landID, playerID: playerID, playerSlot: nil, scope: .perPlayer)
    }

    func encode(update: StateUpdate, landID: String, playerID: PlayerID, playerSlot: Int32?) throws -> Data {
        try encode(update: update, landID: landID, playerID: playerID, playerSlot: playerSlot, scope: .perPlayer)
    }

    func encode(update: StateUpdate, landID: String, playerID: PlayerID, playerSlot: Int32?, scope: StateUpdateKeyScope) throws -> Data {
        if case .perPlayer = scope, fails.isOn, player == nil || player == playerID { throw SyncStreamFault() }
        return try inner.encode(update: update, landID: landID, playerID: playerID, playerSlot: playerSlot)
    }
}

private final class VerifierSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool { lock.lock(); defer { lock.unlock() }; return on }
    func set(_ value: Bool) { lock.lock(); on = value; lock.unlock() }
}

@Suite("Sync-output verifier", .timeLimit(.minutes(1)), .drainsFixtureKeepers)
struct SyncOutputVerifierTests {
    @Test(
        "A deterministic run passes: every scope compared, nothing unverifiable",
        arguments: InTurnEncoding.allCases, [true, false]
    )
    func deterministicRunPasses(encoding: InTurnEncoding, initializeFirst: Bool) async throws {
        let f = await VerifierFixture.make(encoding: encoding, initializeFirst: initializeFirst)
        try await playScript(f)
        let result = try await f.replay()
        let sync = result.syncOutput
        #expect(sync.verdict == .passed, "\(sync.summary)")
        #expect(sync.broadcast.compared > 0)
        #expect(sync.perPlayer.compared > 0)
        #expect(sync.seed.compared == 3)
        #expect(sync.eventsApplicable == (encoding == .messagepack))
        if encoding == .messagepack {
            #expect(sync.events.compared > 0)
        }
        #expect(result.initialize == .passed)
        #expect(result.serverEventVerification == .passed)
    }

    @Test("An in-place resync replays: its rejoin seed's view verifies, every output passes (#332)", arguments: InTurnEncoding.allCases)
    func resyncReplays(encoding: InTurnEncoding) async throws {
        let f = await VerifierFixture.make(encoding: encoding, syncSequence: true)
        let clock = SyncLagManualClock()
        await f.adapter.setSyncLagClockForTesting { clock.now }
        try await f.join(1)
        try await f.join(2)
        // Both read everything so far.
        await f.adapter.onSyncAck(.max >> 1, from: SessionID("s1"))
        await f.adapter.onSyncAck(.max >> 1, from: SessionID("s2"))
        try await f.set(1, "score", 10)
        await f.tick(2)
        // Past 3 s: p1 still acks, but never past what it had; p2 keeps up.
        clock.advance(3.5)
        await f.adapter.onSyncAck(0, from: SessionID("s1"))
        await f.adapter.onSyncAck(.max >> 1, from: SessionID("s2"))
        try await f.set(2, "score", 20)
        await f.tick()
        #expect(await f.adapter.syncLagResyncs == 1)
        await f.adapter.onSyncAck(.max >> 1, from: SessionID("s1"))
        try await f.set(1, "score", 11)
        await f.tick(2)
        let seeds = try await f.stream().compactMap { entry -> ReevaluationRecordedSyncMarker? in
            if case .marker(let marker) = entry, marker.kind == .seed { return marker } else { return nil }
        }
        #expect(seeds.map(\.rejoin) == [false, false, true])
        let result = try await f.replay()
        let sync = result.syncOutput
        #expect(sync.verdict == .passed, "\(sync.summary)")
        #expect(sync.seed.compared == 3, "the resync's seed is verified like a join's")
        #expect(sync.perPlayer.compared > 0)
        #expect(result.serverEventVerification == .passed)
        #expect(result.serverEventMismatches.isEmpty)
    }

    @Test("A broadcast patch the live diff dropped is detected", arguments: InTurnEncoding.allCases)
    func droppedBroadcastPatch(encoding: InTurnEncoding) async throws {
        let fault = DigestFault { digest in
            guard var patches = digest.broadcastPatches, !patches.isEmpty else { return false }
            patches.removeLast()
            digest.broadcastPatches = patches
            return true
        }
        let (mismatch, expected) = try await faultLocation(encoding: encoding, fault: fault)
        #expect(mismatch?.check == .hash)
        #expect(mismatch?.scope == "broadcast")
        #expect(mismatch?.streamIndex == position(expected).streamIndex)
        #expect(mismatch?.observedTickId == position(expected).observedTickId)
        #expect(mismatch?.detail?.contains(EnvKeys.Reevaluation.recordSyncPatches) == true, "\(mismatch?.detail ?? "")")
    }

    @Test("A changed per-player value is detected", arguments: InTurnEncoding.allCases)
    func changedPerPlayerValue(encoding: InTurnEncoding) async throws {
        let fault = DigestFault { digest in
            guard let (player, patches) = digest.perPlayerPatches.first(where: { digest.seeds[$0.key] == nil && !$0.value.isEmpty }) else {
                return false
            }
            var changed = patches
            changed[0] = StatePatch(path: changed[0].path, operation: .set(.int(999)))
            digest.perPlayerPatches[player] = changed
            return true
        }
        let (mismatch, expected) = try await faultLocation(encoding: encoding, fault: fault)
        #expect(mismatch?.scope == "per-player (combined)")
        #expect(mismatch?.streamIndex == position(expected).streamIndex)
        #expect(mismatch?.observedTickId == position(expected).observedTickId)
        #expect(mismatch?.detail?.contains(EnvKeys.Reevaluation.recordSyncDetails) == true, "\(mismatch?.detail ?? "")")
    }

    @Test("Recorded per-player hashes and patches name the player and the first differing patch")
    func recordingDetailLocatesTheMismatch() async throws {
        let perPlayer = DigestFault { digest in
            guard let (player, patches) = digest.perPlayerPatches.first(where: { digest.seeds[$0.key] == nil && !$0.value.isEmpty }) else {
                return false
            }
            digest.perPlayerPatches[player] = patches.map { StatePatch(path: $0.path, operation: .set(.int(999))) }
            return true
        }
        let (playerMismatch, _) = try await faultLocation(encoding: .json, fault: perPlayer, detail: [.perPlayerHashes, .patches])
        let playerDetail = try #require(playerMismatch?.detail)
        #expect(playerDetail.hasPrefix("player p"), "\(playerDetail)")
        #expect(playerDetail.contains("first differing patch #0 at /"), "\(playerDetail)")

        let hashesOnly = DigestFault { digest in
            guard let (player, patches) = digest.perPlayerPatches.first(where: { digest.seeds[$0.key] == nil && !$0.value.isEmpty }) else {
                return false
            }
            digest.perPlayerPatches[player] = patches.map { StatePatch(path: $0.path, operation: .set(.int(999))) }
            return true
        }
        let (hashMismatch, _) = try await faultLocation(encoding: .json, fault: hashesOnly, detail: [.perPlayerHashes])
        let hashDetail = try #require(hashMismatch?.detail)
        #expect(hashDetail.hasPrefix("player p"), "\(hashDetail)")
        #expect(hashDetail.contains(EnvKeys.Reevaluation.recordSyncPatches), "\(hashDetail)")

        let broadcast = DigestFault { digest in
            guard var patches = digest.broadcastPatches, !patches.isEmpty else { return false }
            patches = CanonicalPatchList(patches).patches
            patches.removeLast()
            digest.broadcastPatches = patches
            return true
        }
        let (broadcastMismatch, _) = try await faultLocation(encoding: .messagepack, fault: broadcast, detail: [.patches])
        let broadcastDetail = try #require(broadcastMismatch?.detail)
        #expect(broadcastDetail.contains("first differing patch #"), "\(broadcastDetail)")
    }

    /// #446: this build writes keys and IDs in NFC, so the digests of an older record that
    /// holds another spelling cannot be reproduced. Unlike #175 (2.3), which changed no path,
    /// the sync-output digests hash the same keys as the state hash does. Such a record (3.2)
    /// has no schema fingerprint, so replay refuses it before the first step (#521 D15); the
    /// reason it would carry is checked directly (`NFCKeyTests`).
    @Test("A sync-output mismatch in a current record holding non-NFC text fails; a record older than 3.3 is refused")
    func olderRecordWithNonNFCTextIsRefused() async throws {
        let fault = DigestFault { digest in
            guard var patches = digest.broadcastPatches, !patches.isEmpty else { return false }
            patches = CanonicalPatchList(patches).patches
            patches.removeLast()
            digest.broadcastPatches = patches
            return true
        }
        let f = await VerifierFixture.make(encoding: .messagepack)
        await f.adapter.setSyncOutputDigestFaultForTesting { fault.run(&$0) }
        try await f.join(1)
        // An action payload with an NFD string: the record holds text that is not NFC.
        try await f.set(1, "e\u{301}")
        try await playScript(f)
        #expect(fault.hasFired)

        let current = try await f.replay()
        guard case .failed = current.syncOutput.verdict else {
            Issue.record("a current record: expected a failed verdict, got \(current.syncOutput.summary)")
            return
        }
        do {
            _ = try await f.replay(version: "3.2")
            Issue.record("a 3.2 record: expected it to be refused")
        } catch ReevaluationRecordFingerprintError.missing(let recorded) {
            #expect(recorded == "3.2")
        }
    }

    #if DEBUG  // The diff fault hook exists in debug builds only.
    @Test("A diff-engine bug both sides share passes every hash and fails the apply check", arguments: InTurnEncoding.allCases)
    func diffEngineFaultIsCaughtByTheApplyCheck(encoding: InTurnEncoding) async throws {
        // A wrong value for `ticks` in every diff against a previous value, live and replay alike.
        let fault: @Sendable (StateSnapshot, [StatePatch]) -> [StatePatch] = { old, patches in
            guard old.values["ticks"] != nil else { return patches }
            return patches.map { $0.path == "/ticks" ? StatePatch(path: $0.path, operation: .set(.string("wrong"))) : $0 }
        }
        let result = try await SyncEngineDiffFaultForTesting.$current.withValue(fault) {
            let f = await VerifierFixture.make(encoding: encoding)
            try await playScript(f)
            return try await f.replay()
        }
        guard case .failed(let mismatch) = result.syncOutput.verdict else {
            Issue.record("expected a failed verdict, got \(result.syncOutput.summary)")
            return
        }
        #expect(mismatch.check == .apply)
        #expect(mismatch.scope == "broadcast")
        #expect(mismatch.turnKind == .tick)
        #expect(mismatch.detail == "first differing path: /ticks")
        #expect(result.syncOutput.broadcast.compared > 0, "the hashes matched up to the failing output")
    }

    /// The fault reaches the per-player diff on both paths: the per-player tables (#514) and,
    /// with `PER_PLAYER_SYNC_TABLES=false`, today's snapshot diff.
    @Test("A diff-engine bug in the per-player diff both sides share fails the apply check", arguments: InTurnEncoding.allCases)
    func perPlayerDiffEngineFaultIsCaughtByTheApplyCheck(encoding: InTurnEncoding) async throws {
        // A wrong value for `scores` in every per-player diff. The slice has no value for a
        // player before its first score, so the patch is a diff from an absent field.
        let fault: @Sendable (StateSnapshot, [StatePatch]) -> [StatePatch] = { _, patches in
            patches.map { $0.path.hasPrefix("/scores") ? StatePatch(path: $0.path, operation: .set(.string("wrong"))) : $0 }
        }
        let result = try await SyncEngineDiffFaultForTesting.$current.withValue(fault) {
            let f = await VerifierFixture.make(encoding: encoding)
            try await playScript(f)
            return try await f.replay()
        }
        guard case .failed(let mismatch) = result.syncOutput.verdict else {
            Issue.record("expected a failed verdict, got \(result.syncOutput.summary)")
            return
        }
        #expect(mismatch.check == .apply)
        #expect(mismatch.scope.hasPrefix("per-player"), "\(mismatch.scope)")
        #expect(mismatch.detail?.hasPrefix("first differing path: /scores") == true, "\(mismatch.detail ?? "")")
    }
    #endif

    @Test("The JSON-safe form keeps a non-finite double distinct from the string with its name")
    func nonFiniteFormIsTagged() {
        for (value, name) in [(Double.nan, "NaN"), (.infinity, "Infinity"), (-.infinity, "-Infinity")] {
            #expect(SnapshotValue.double(value).jsonSafe == .object([SnapshotValue.nonFiniteTag: .string(name)]))
            #expect(SnapshotValue.double(value).jsonSafe != SnapshotValue.string(name).jsonSafe)
        }
        #expect(SnapshotValue.double(1.5).jsonSafe == .double(1.5))
    }

    @Test("A NaN in the state verifies: an unchanged NaN is not resent, and the view equals itself")
    func nanPassesTheApplyCheck() async throws {
        let f = await VerifierFixture.make(encoding: .messagepack)
        try await f.join(1)
        await f.tick()
        try await f.set(1, "nan")
        await f.tick()
        await f.tick()
        let sync = try await f.replay().syncOutput
        #expect(sync.verdict == .passed, "\(sync.summary)")
    }

    @Test("Recorded patch lists with non-finite values still save, and still match")
    func nonFinitePatchesSave() async throws {
        let f = await VerifierFixture.make(encoding: .messagepack)
        await f.adapter.setSyncStreamDetail([.perPlayerHashes, .patches])
        try await f.join(1)
        await f.tick()
        try await f.set(1, "inf")
        await f.tick()
        try await f.set(1, "nan")
        await f.tick()
        let player = VerifierFixture.player(1).rawValue
        let sent = try await f.stream().flatMap { entry -> [StatePatch] in
            if case .output(let o) = entry { return o.patches?[player] ?? [] } else { return [] }
        }
        let json = String(decoding: try JSONEncoder().encode(sent), as: UTF8.self)
        #expect(json.contains("{\"$nonFinite\":\"Infinity\"}"), "\(json)")
        #expect(json.contains("{\"$nonFinite\":\"NaN\"}"), "\(json)")
        let sync = try await f.replay().syncOutput  // saves the record as JSON first
        #expect(sync.verdict == .passed, "\(sync.summary)")
    }

    @Test("Without a fault, the apply check runs on every seed and diffed scope", arguments: InTurnEncoding.allCases)
    func applyCheckRuns(encoding: InTurnEncoding) async throws {
        let f = await VerifierFixture.make(encoding: encoding)
        try await playScript(f)
        let sync = try await f.replay().syncOutput
        #expect(sync.verdict == .passed, "\(sync.summary)")
        // Every seed, every broadcast diff after the first, and every seeded player's diff.
        #expect(sync.apply.compared >= sync.seed.compared + sync.broadcast.compared - 1 + sync.perPlayer.compared)
        #expect(sync.apply.unverifiable == 0)
        #expect(sync.summary.contains("apply \(sync.apply.compared)/0/0"))
    }

    @Test("Opcode 107: a dropped event and two swapped events are detected", arguments: ["drop", "swap"])
    func droppedOrSwappedEvent(kind: String) async throws {
        let fault = DigestFault { digest in
            guard var events = digest.events, events.count >= 2 else { return false }
            if kind == "drop" {
                events.removeLast()
            } else {
                // The second event's content under the first one's sequence, and the reverse.
                let (first, second) = (events[0], events[1])
                events[0] = CanonicalSyncEvent(sequence: first.sequence, type: second.type, payload: second.payload)
                events[1] = CanonicalSyncEvent(sequence: second.sequence, type: first.type, payload: first.payload)
            }
            digest.events = events
            return true
        }
        let (mismatch, expected) = try await faultLocation(encoding: .messagepack, fault: fault)
        #expect(mismatch?.scope == "events")
        #expect(mismatch?.streamIndex == position(expected).streamIndex)
        #expect(mismatch?.observedTickId == position(expected).observedTickId)
    }

    @Test("Patches on unrelated paths in another order are not a mismatch", arguments: InTurnEncoding.allCases)
    func unrelatedPathReorderPasses(encoding: InTurnEncoding) async throws {
        let f = await VerifierFixture.make(encoding: encoding)
        let fault = DigestFault { digest in
            guard let patches = digest.broadcastPatches, patches.count >= 2 else { return false }
            digest.broadcastPatches = patches.reversed()
            return true
        }
        await f.adapter.setSyncOutputDigestFaultForTesting { fault.run(&$0) }
        try await playScript(f)
        #expect(fault.hasFired)
        let sync = try await f.replay().syncOutput
        #expect(sync.verdict == .passed, "\(sync.summary)")
    }

    @Test("A dirty-tracking miss is detected: the replay extracts every field", arguments: InTurnEncoding.allCases)
    func dirtyTrackingMiss(encoding: InTurnEncoding) async throws {
        let f = await VerifierFixture.make(encoding: encoding)
        try await f.join(1)
        await f.tick()
        try await f.set(1, "miss")
        await f.tick(2)  // `box` changes in place: the live plan diffs only the dirty `ticks` and `board`
        let result = try await f.replay()
        #expect(result.tickHashes == result.recordedStateHashes, "the state itself replays identically")
        guard case .failed(let mismatch) = result.syncOutput.verdict else {
            Issue.record("expected a failed verdict, got \(result.syncOutput.summary)")
            return
        }
        #expect(mismatch.scope == "broadcast")
        #expect(mismatch.observedTickId == 1, "the action and the tick handler run in tick 1's turn")
    }

    @Test("A debug freeze settle's sync-only output is verified")
    func settleSyncTurnIsVerified() async throws {
        let f = await VerifierFixture.make(encoding: .json)
        try await f.join(1)
        await f.tick(2)
        try await f.set(1, "score", 5)
        let settleIndex = UInt64(try await f.stream().count)
        let frozen = try await f.adapter.debugFreeze()
        _ = await f.adapter.debugResume(freezeToken: frozen.freezeToken)
        await f.tick()
        let settle = try await f.stream().first { $0.streamIndex == settleIndex }
        guard case .output(let output) = try #require(settle, "the settle recorded an entry") else {
            Issue.record("the settle's entry is not an output")
            return
        }
        #expect(output.turnKind == .syncOnly, "the settle is a sync-only turn (#546 L2d-1)")
        #expect(output.observedTickId == frozen.tickId)
        let sync = try await f.replay().syncOutput
        #expect(sync.verdict == .passed, "\(sync.summary)")
    }

    @Test("A tick recorded with an unavailable state hash is unverifiable, never a match (#180)")
    func unavailableHashIsUnverifiable() async throws {
        let f = await VerifierFixture.make(encoding: .json)
        try await playScript(f)
        let result = try await f.replay { frames in
            guard let index = frames.firstIndex(where: { $0.tickId == 1 && $0.stateHash != nil }) else { return }
            frames[index] = frames[index].replacing(stateHash: .some(ReevaluationEngine.unavailableHash(SyncError.unsupportedKey("collision"))))
        }
        #expect(result.unverifiableStateHashes.keys.sorted() == [1])
        #expect(result.unverifiableStateHashes[1]?.contains("unavailable: ") == true)
        let legacy = try await f.replay { frames in
            guard let index = frames.firstIndex(where: { $0.tickId == 1 && $0.stateHash != nil }) else { return }
            frames[index] = frames[index].replacing(stateHash: .some("error"))
        }
        #expect(legacy.unverifiableStateHashes.keys.sorted() == [1], "an older build's \"error\" is not a match either")
        let clean = try await f.replay()
        #expect(clean.unverifiableStateHashes.isEmpty)
        #expect(clean.hashDefinition == .fullState)
    }

    @Test("A 2.1 record (before syncConfig) is rejected as unsupported, never guessed (#154)")
    func missingSyncConfigIsSkipped() async throws {
        let f = await VerifierFixture.make(encoding: .json)
        try await playScript(f)
        await #expect(throws: ReevaluationRecordVersionError.unsupported(recorded: "2.1", minimum: "2.5")) {
            _ = try await f.replay(version: "2.1", withSyncConfig: false)
        }
        let unrelabeled = try await f.replay(withSyncConfig: false)
        #expect(unrelabeled.tickHashes == unrelabeled.recordedStateHashes)
    }

    @Test("A tampered initialize record fails the initialize check")
    func tamperedInitialize() async throws {
        let f = await VerifierFixture.make(encoding: .json)
        try await f.join(1)
        await f.tick()
        let result = try await f.replay { frames in
            guard let index = frames.firstIndex(where: { $0.tickId == 0 }), let record = frames[index].initialize else { return }
            frames[index] = replacingInitialize(frames[index], with: ReevaluationRecordedInitialize(
                sequence: record.sequence,
                serverEvents: [],
                stateHash: record.stateHash
            ))
        }
        guard case .failed = result.initialize else {
            Issue.record("expected a failed initialize check, got \(result.initialize)")
            return
        }
    }

    @Test("A record without an initialize record replays OnInitialize in tick 0, as before")
    func noInitializeRecordKeepsTickZero() async throws {
        let f = await VerifierFixture.make(encoding: .json)
        try await f.join(1)
        await f.tick(2)
        let result = try await f.replay(withSyncConfig: false) { frames in
            frames = frames.map { replacingInitialize($0, with: nil) }
        }
        #expect(result.initialize == .notRecorded)
        #expect(!result.recordedStateHashes.isEmpty)
        #expect(result.tickHashes == result.recordedStateHashes, "tick 0 still applies OnInitialize")
    }

    @Test("Opcode 107: a per-player dirty-tracking miss in an output with no other per-player change is detected")
    func perPlayerDirtyTrackingMiss() async throws {
        let f = await VerifierFixture.make(encoding: .messagepack)
        try await f.join(1)
        try await f.set(1, "box")
        await f.tick()
        try await f.set(1, "missPerPlayer")
        await f.tick()  // every box changes in place; `scores` is dirty but unchanged
        let tick = try #require(try await f.stream().compactMap {
            if case .output(let o) = $0, o.turnKind == .tick, o.observedTickId == 1 { return o } else { return nil }
        }.first)
        #expect(tick.perPlayerHash == CanonicalPatchList.combinedHash([]), "the live plan saw no per-player change")
        let result = try await f.replay()
        #expect(result.tickHashes == result.recordedStateHashes)
        guard case .failed(let mismatch) = result.syncOutput.verdict else {
            Issue.record("expected a failed verdict, got \(result.syncOutput.summary)")
            return
        }
        #expect(mismatch.scope == "per-player (combined)")
        #expect(mismatch.streamIndex == tick.streamIndex)
        #expect(mismatch.observedTickId == 1)
    }

    @Test("Combined mode: a player's update that doesn't encode at all ends the land; no later tick is recorded (#535 row 10)")
    func combinedUnencodableEndsTheLand() async throws {
        let fails = VerifierSwitch()
        let f = await VerifierFixture.make(encoding: .json, encoder: VerifierFailingEncoder(fails: fails))
        let followUps = await f.holdFailedPlanFollowUps()
        defer { followUps.open() }
        try await f.join(1)
        await f.tick()
        fails.set(true)
        await f.tick()      // no player's combined update encodes: the land fails
        #expect(f.keeper.failure?.kind == .syncEncode)
        fails.set(false)
        await f.tick()      // a failed land runs no further tick
        let ticks = try await f.stream().compactMap { if case .output(let o) = $0, o.turnKind == .tick { return o } else { return nil } }
        #expect(ticks.count == 1, "only the tick before the failure committed sync output")
    }

    @Test("A gap in the stream indices is malformed")
    func streamGapIsMalformed() async throws {
        let f = await VerifierFixture.make(encoding: .json)
        try await playScript(f)
        let result = try await f.replay { frames in
            guard let index = frames.firstIndex(where: { !$0.syncOutputs.isEmpty }) else { return }
            let frame = frames[index]
            frames[index] = ReevaluationTickFrame(
                tickId: frame.tickId,
                stateHash: frame.stateHash,
                actions: frame.actions,
                clientEvents: frame.clientEvents,
                lifecycleEvents: frame.lifecycleEvents,
                serverEvents: frame.serverEvents,
                sequenceBeforeInputs: frame.sequenceBeforeInputs,
                sequenceBeforeTickHandler: frame.sequenceBeforeTickHandler,
                syncOutputs: Array(frame.syncOutputs.dropFirst()),
                syncMarkers: frame.syncMarkers,
                initialize: frame.initialize
            )
        }
        guard case .malformed(let reason) = result.syncOutput.verdict else {
            Issue.record("expected malformed, got \(result.syncOutput.summary)")
            return
        }
        #expect(reason.contains("not 0..<"))
    }

    @Test("Opcode 107: events after the last output are reported; events nobody receives are not expected")
    func eventsAfterLastOutputAreReported() async throws {
        let f = await VerifierFixture.make(encoding: .messagepack)
        try await f.join(1)
        await f.tick(2)
        try await f.set(1, "quiet")
        await f.tick()  // three events, no sync after them
        let outputs = try await f.stream().compactMap { if case .output(let o) = $0 { return o } else { return nil } }
        #expect(outputs.allSatisfy { $0.eventsNotQueued?.count == 1 }, "each tick's event to nobody")
        let sync = try await f.replay().syncOutput
        // `passed` does not vouch for events no output covers.
        #expect(sync.verdict == .partial, "\(sync.summary)")
        #expect(sync.events.unverifiable == 0)
        #expect(sync.skipReasons.isEmpty)
        // The last tick's two queued events, and its event to nobody: only an output lists the
        // events that were never queued, and none follows it.
        #expect(sync.eventsAfterLastOutput == 3)
        #expect(sync.summary.contains("3 events after the last output"))
    }

    @Test("Opcode 107: in a live copy, events after the last recorded output are a tail, reported without failing (#306)")
    func liveCopyTailEventsPass() async throws {
        let f = await VerifierFixture.make(encoding: .messagepack)
        try await f.join(1)
        await f.tick(2)
        try await f.set(1, "quiet")
        await f.tick()  // three events; the next tick's output would carry them
        await f.tick()  // the newest tick: the live copy leaves it out
        let result = try await f.replayLiveCopy()
        #expect(!result.recordCompleteness.isComplete)
        let sync = result.syncOutput
        #expect(sync.verdict == .passed, "\(sync.summary)")
        #expect(sync.tailEventsNotSynced == 3)
        #expect(sync.eventsAfterLastOutput == 0)
        #expect(sync.summary.contains("3 tail events not yet synced (incomplete record)"))
    }

    @Test("Opcode 107: the same tail in a complete record keeps the verdict partial (#306)")
    func completeRecordTailStaysPartial() async throws {
        let f = await VerifierFixture.make(encoding: .messagepack)
        try await f.join(1)
        await f.tick(2)
        try await f.set(1, "quiet")
        await f.tick()
        await f.tick()
        await f.tick()  // the complete record ends here; this tick's own events have no output after them
        let result = try await f.replay()
        #expect(result.recordCompleteness.isComplete)
        let sync = result.syncOutput
        #expect(sync.verdict == .partial, "\(sync.summary)")
        #expect(sync.tailEventsNotSynced == 0)
        #expect(sync.eventsAfterLastOutput > 0)
    }

    @Test("Opcode 107: only events emitted after the newest output read state are a tail (#306)")
    func tailIsBoundedByTheLastOutput() {
        typealias Driver = SyncOutputReplayDriver<VerifierState>
        // Incomplete record; the newest output read state with the keeper's next sequence at 20.
        #expect(Driver.splitUnconsumed(sequences: [20, 23], recordIsComplete: false, lastOutputSequence: 20) == (0, 2))
        // An event emitted before that read (the same tick or earlier) was that output's to
        // carry: it stays unmatched, incomplete record or not.
        #expect(Driver.splitUnconsumed(sequences: [19, 23], recordIsComplete: false, lastOutputSequence: 20) == (1, 1))
        // A complete record, or one with no output, has no tail.
        #expect(Driver.splitUnconsumed(sequences: [20, 23], recordIsComplete: true, lastOutputSequence: 20) == (2, 0))
        #expect(Driver.splitUnconsumed(sequences: [0], recordIsComplete: false, lastOutputSequence: nil) == (1, 0))
    }

    @Test("Opcode 107: in a live copy, an event the last recorded output should have carried keeps the verdict partial (#306)")
    func liveCopyEventMissingFromTheLastOutputStaysPartial() async throws {
        let f = await VerifierFixture.make(encoding: .messagepack)
        try await f.join(1)
        await f.tick(2)
        try await f.set(1, "quiet")
        await f.tick()  // three events
        await f.tick()
        await f.tick()  // the newest tick: the live copy leaves it out
        // The last output the copy keeps consumed events. Record it as if the live adapter had
        // lost them unlisted: nothing consumed, the empty events hash, nothing not queued.
        var dropped: [Int64] = []
        let result = try await f.replayLiveCopy { records in
            let newest = records.compactMap(\.tickId).max() ?? 0
            let kept = records.indices.filter { (records[$0].tickId ?? newest) < newest }
            let last = kept.flatMap { i in (records[i].syncOutputs ?? []).indices.map { (i, $0) } }
                .max { records[$0.0].syncOutputs![$0.1].streamIndex < records[$1.0].syncOutputs![$1.1].streamIndex }
            guard let (i, j) = last else { return }
            let o = records[i].syncOutputs![j]
            dropped = (records[i].serverEvents ?? []).map(\.sequence).filter { $0 <= (o.eventsThroughSequence ?? -1) }
            records[i].syncOutputs![j] = ReevaluationRecordedSyncOutput(
                index: o.index, turnKind: o.turnKind, observedTickId: o.observedTickId, streamIndex: o.streamIndex,
                sequence: o.sequence, broadcastHash: o.broadcastHash, perPlayerHash: o.perPlayerHash,
                perPlayerUnverified: o.perPlayerUnverified, perPlayerUncommitted: o.perPlayerUncommitted,
                perPlayerHashes: o.perPlayerHashes, eventsHash: CanonicalSyncEvent.hash([]), eventsThroughSequence: nil,
                eventsNotQueued: nil, eventsNotMerged: o.eventsNotMerged, resetsKeyScopes: o.resetsKeyScopes,
                extractionDrops: o.extractionDrops, encodeDropScopes: o.encodeDropScopes, patches: o.patches
            )
        }
        #expect(!dropped.isEmpty, "the last kept output consumed events of its own tick")
        #expect(!result.recordCompleteness.isComplete)
        let sync = result.syncOutput
        #expect(sync.verdict == .partial, "\(sync.summary)")
        // Exactly the lost events count against the verdict; the later ticks' events, emitted
        // after that output read state, are still the tail.
        #expect(sync.eventsAfterLastOutput == dropped.count, "\(sync.summary) dropped \(dropped)")
        #expect(sync.tailEventsNotSynced > 0, "\(sync.summary)")
    }

    @Test("Opcode 107 with JSON messages (hybrid): an event sent alone, outside the merged frame, makes that output's events unverifiable")
    func unmergedEventIsUnverifiable() async throws {
        // JSON messages with opcodeMessagePack state updates; events on the second tick only.
        let f = await VerifierFixture.make(
            encoding: .json, encoder: OpcodeMessagePackStateUpdateEncoder(), definition: makeGatedVerifierLand()
        )
        try await f.join(1)
        await f.tick()
        await f.tick()      // its three events can't merge; each goes alone
        await f.tick()
        let ticks = try await f.stream().compactMap { if case .output(let o) = $0, o.turnKind == .tick { return o } else { return nil } }
        try #require(ticks.count == 3)
        let unmerged = ticks.map { $0.eventsNotMerged ?? ReevaluationUnmergedEvents() }
        #expect(unmerged.map { $0.all.count } == [0, 3, 0])
        #expect(unmerged[1].sentAlone.count == 3 && unmerged[1].lost.isEmpty)
        #expect(ticks[1].eventsNotQueued == nil, "an event to nobody that did not encode is not merged either")
        let sync = try await f.replay().syncOutput
        #expect(sync.verdict == .partial, "\(sync.summary)")
        #expect(sync.events.compared == 2)
        #expect(sync.events.unverifiable == 1)
        #expect(sync.eventsAfterLastOutput == 0)
        #expect((sync.eventsLost, sync.eventsSentAlone) == (0, 3))
        #expect(sync.summary.contains("3 events sent outside the merged frame"))
    }

    @Test(
        "An event emitted in a turn that reaches no frame ends the land: with opcode 107 (body and own frame fail) and without it (immediate mode) (#535 row 17)",
        arguments: InTurnEncoding.allCases
    )
    func lostEventEndsTheLand(encoding: InTurnEncoding) async throws {
        let f = await VerifierFixture.make(encoding: encoding)
        let fails = VerifierSwitch()
        await f.adapter.setEventEncodingFaultForTesting { _ in fails.isOn ? .all : nil }
        try await f.join(1)
        await f.tick()
        fails.set(true)
        await f.tick()      // the first event's frame fails (opcode 107: its body too)
        #expect(f.keeper.failure?.kind == .eventEncode, "\(encoding)")
        #expect(f.keeper.failure?.position.stage == .syncPhase, "\(encoding): the in-turn flush")
        #expect(f.adapter.outputGate.isClosed, "\(encoding)")
        let ticks = try await f.stream().compactMap { if case .output(let o) = $0, o.turnKind == .tick { return o } else { return nil } }
        #expect(ticks.count == 1, "\(encoding): the failing tick commits no sync output")
    }

    @Test("Opcode 107: an unsent per-player update is a benign skip once a later comparison sees the resend")
    func resendSeenIsBenign() async throws {
        let f = await VerifierFixture.make(encoding: .messagepack)
        try await f.join(1)
        await f.tick(3)
        let sync = try await f.replay(rewrite: markingUnsent(VerifierFixture.player(1), atTick: 1)).syncOutput
        #expect(sync.verdict == .passed, "\(sync.summary)")
        #expect(sync.skipReasons == [.perPlayerResent: 1])
    }

    @Test("Opcode 107: an unsent per-player update in the last output is not benign: nothing saw the resend")
    func resendNotSeenAtTheEnd() async throws {
        let f = await VerifierFixture.make(encoding: .messagepack)
        try await f.join(1)
        await f.tick(3)
        let sync = try await f.replay(rewrite: markingUnsent(VerifierFixture.player(1), atTick: 2)).syncOutput
        #expect(sync.verdict == .partial, "\(sync.summary)")
        #expect(sync.skipReasons == [.perPlayerResendNotSeen: 1])
        #expect(sync.summary.contains(SyncOutputSkipReason.perPlayerResendNotSeen.rawValue))
    }

    @Test("Opcode 107: an unsent per-player update is not benign when the player leaves before the resend")
    func resendNotSeenAfterLeave() async throws {
        let f = await VerifierFixture.make(encoding: .messagepack)
        try await f.join(1)
        try await f.join(2)
        await f.tick(2)
        await f.leave(1)
        await f.tick()
        let sync = try await f.replay(rewrite: markingUnsent(VerifierFixture.player(1), atTick: 1)).syncOutput
        #expect(sync.verdict == .partial, "\(sync.summary)")
        #expect(sync.skipReasons == [.perPlayerResendNotSeen: 1])
    }
}

/// Rewrites a saved record's `recordMetadata.version`, to build an older-format record from a
/// live recording: the recorder always stamps the version this build writes.
func relabelRecordVersion(atPath path: String, to version: String?) throws {
    try ReevaluationRecordFile.convertToJSONViewForTesting(atPath: path)
    let url = URL(fileURLWithPath: path)
    var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var metadata = try #require(root["recordMetadata"] as? [String: Any])
    metadata["version"] = version
    root["recordMetadata"] = metadata
    try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]).write(to: url)
}

// MARK: - Records made before #535 PR 2a

/// A tick output with some fields replaced. Live runs no longer record extraction or encode
/// drops (every conversion or encode failure ends the land, #535), but records made before can
/// hold them, so these rewrites build such records from a live recording.
private func editingTickOutputs(
    _ edit: @escaping (ReevaluationRecordedSyncOutput) -> (
        perPlayerHash: UInt64?, perPlayerUnverified: [String]?, extractionDrops: [String: [String]], encodeDropScopes: [String]
    )?
) -> (inout [ReevaluationTickFrame]) -> Void {
    { frames in
        for (frameIndex, frame) in frames.enumerated() {
            var changed = false
            let outputs = frame.syncOutputs.map { output -> ReevaluationRecordedSyncOutput in
                guard output.turnKind == .tick, let fields = edit(output) else { return output }
                changed = true
                return ReevaluationRecordedSyncOutput(
                    index: output.index,
                    turnKind: output.turnKind,
                    observedTickId: output.observedTickId,
                    streamIndex: output.streamIndex,
                    sequence: output.sequence,
                    afterPass: output.afterPass,
                    broadcastHash: output.broadcastHash,
                    perPlayerHash: fields.perPlayerHash,
                    perPlayerUnverified: fields.perPlayerUnverified,
                    perPlayerUncommitted: output.perPlayerUncommitted,
                    perPlayerHashes: output.perPlayerHashes,
                    eventsHash: output.eventsHash,
                    eventsThroughSequence: output.eventsThroughSequence,
                    eventsNotQueued: output.eventsNotQueued,
                    eventsNotMerged: output.eventsNotMerged,
                    resetsKeyScopes: output.resetsKeyScopes,
                    extractionDrops: fields.extractionDrops,
                    encodeDropScopes: fields.encodeDropScopes,
                    patches: output.patches
                )
            }
            guard changed else { continue }
            frames[frameIndex] = replacingSync(frame, outputs: outputs, markers: frame.syncMarkers)
        }
    }
}

/// The first seed marker of `player` made degraded: its view dropped `fragile`, so it carries
/// no view hash (a record made before #535 PR 2a).
private func degradingFirstSeed(of player: PlayerID) -> (inout [ReevaluationTickFrame]) -> Void {
    { frames in
        for (frameIndex, frame) in frames.enumerated() {
            guard let markerIndex = frame.syncMarkers.firstIndex(where: { $0.kind == .seed && $0.playerID == player.rawValue }) else { continue }
            var markers = frame.syncMarkers
            let marker = markers[markerIndex]
            #expect(marker.viewHash != nil)
            markers[markerIndex] = ReevaluationRecordedSyncMarker(
                kind: marker.kind,
                playerID: marker.playerID,
                observedTickId: marker.observedTickId,
                streamIndex: marker.streamIndex,
                sequence: marker.sequence,
                afterPass: marker.afterPass,
                rejoin: marker.rejoin,
                viewHash: nil,
                viewDrops: [.extraction],
                viewDropFields: ["fragile"]
            )
            frames[frameIndex] = replacingSync(frame, outputs: frame.syncOutputs, markers: markers)
            return
        }
        Issue.record("no seed of \(player.rawValue)")
    }
}

private func replacingSync(
    _ frame: ReevaluationTickFrame, outputs: [ReevaluationRecordedSyncOutput], markers: [ReevaluationRecordedSyncMarker]
) -> ReevaluationTickFrame {
    ReevaluationTickFrame(
        tickId: frame.tickId,
        stateHash: frame.stateHash,
        actions: frame.actions,
        clientEvents: frame.clientEvents,
        lifecycleEvents: frame.lifecycleEvents,
        serverEvents: frame.serverEvents,
        sequenceBeforeInputs: frame.sequenceBeforeInputs,
        sequenceBeforeTickHandler: frame.sequenceBeforeTickHandler,
        syncOutputs: outputs,
        syncMarkers: markers,
        initialize: frame.initialize
    )
}

@Suite("Sync output verifier: drops in records made before #535 PR 2a", .timeLimit(.minutes(1)), .drainsFixtureKeepers)
struct SyncOutputVerifierOldDropTests {
    private func tickOutputs(_ f: VerifierFixture) async throws -> [ReevaluationRecordedSyncOutput] {
        try await f.stream().compactMap { if case .output(let o) = $0, o.turnKind == .tick { return o } else { return nil } }
    }

    @Test("An extraction drop is replayed with the cached value: the recorded hash without the dropped field compares")
    func extractionDropIsSubstituted() async throws {
        // The hash the live engine would have recorded with `scores` dropped: a run where it
        // doesn't change.
        let unchanged = await VerifierFixture.make(encoding: .json)
        try await unchanged.join(1)
        await unchanged.tick(2)
        let droppedHash = try #require(try await tickOutputs(unchanged).last).perPlayerHash

        for substituted in [true, false] {
            let f = await VerifierFixture.make(encoding: .json)
            try await f.join(1)
            await f.tick()
            try await f.set(1, "score", 7)
            await f.tick()
            let player = VerifierFixture.player(1).rawValue
            #expect(try await tickOutputs(f).last?.perPlayerHash != droppedHash, "the score change is in the live hash")
            let sync = try await f.replay(rewrite: editingTickOutputs { output in
                guard output.observedTickId == 1 else { return nil }
                return (droppedHash, output.perPlayerUnverified, substituted ? [player: ["scores"]] : [:], output.encodeDropScopes)
            }).syncOutput
            if substituted {
                #expect(sync.verdict == .passed, "\(sync.summary)")
                #expect(sync.perPlayer.compared == 2)
            } else {
                guard case .failed = sync.verdict else {
                    Issue.record("without the recorded drop the replayed score change must not compare: \(sync.summary)")
                    continue
                }
            }
        }
    }

    @Test("A degraded seed leaves the broadcast and the other players compared; a later seed with a view hash restores the player")
    func degradedSeed() async throws {
        // Live left an unverified player out of `perPlayerHash`: the hash of player 1 alone, from
        // a run without player 2.
        let alone = await VerifierFixture.make(encoding: .json)
        try await alone.join(1)
        await alone.tick(3)
        var aloneHashes: [Int64: UInt64?] = [:]
        for output in try await tickOutputs(alone) {
            if let tick = output.observedTickId { aloneHashes[tick] = output.perPlayerHash }
        }
        let f = await VerifierFixture.make(encoding: .json)
        try await f.join(1)
        await f.tick()
        try await f.join(2)  // degraded below
        await f.tick(2)
        await f.leave(2)
        await f.tick()
        try await f.join(2)  // a seed with a view hash
        await f.tick()
        let player2 = VerifierFixture.player(2).rawValue
        let degraded = degradingFirstSeed(of: VerifierFixture.player(2))
        // Live listed the player in `perPlayerUnverified` while its view was unverifiable.
        let listed = editingTickOutputs { output in
            guard let tick = output.observedTickId, tick == 1 || tick == 2, let hash = aloneHashes[tick] else { return nil }
            return (hash, [player2], output.extractionDrops, output.encodeDropScopes)
        }
        let sync = try await f.replay(rewrite: { frames in degraded(&frames); listed(&frames) }).syncOutput
        #expect(sync.verdict == .partial, "\(sync.summary)")
        #expect(sync.seed.compared == 2)
        #expect(sync.seed.unverifiable == 1)
        #expect(sync.perPlayer.unverifiable == 2, "the two ticks between the degraded seed and the leave")
        #expect(sync.broadcast.unverifiable == 0)
    }

    @Test("A per-player encode drop makes a seeded player unverifiable until a seed with a view hash")
    func encodeDropDiverges() async throws {
        let f = await VerifierFixture.make(encoding: .json)
        try await f.join(1)
        try await f.join(2)
        await f.tick(3)
        let player1 = VerifierFixture.player(1).rawValue
        let sync = try await f.replay(rewrite: editingTickOutputs { output in
            guard output.observedTickId == 1 else { return nil }
            return (output.perPlayerHash, output.perPlayerUnverified, output.extractionDrops, [player1])
        }).syncOutput
        #expect(sync.verdict == .partial, "\(sync.summary)")
        // Player 1: compared on tick 0, unverifiable on ticks 1 and 2. Player 2: compared on all.
        #expect(sync.perPlayer.compared == 4)
        #expect(sync.perPlayer.unverifiable == 2)
    }

    @Test("A joiner whose whole view never encoded is viewNotSent; a later compared seed makes it the benign viewSentLater", arguments: [false, true])
    func unsentView(seedsLater: Bool) async throws {
        let f = await VerifierFixture.make(encoding: .json)
        try await f.join(1)
        await f.tick(2)
        if seedsLater {
            try await f.join(2)
            await f.tick()
        }
        let player2 = VerifierFixture.player(2).rawValue
        let sync = try await f.replay(rewrite: editingTickOutputs { output in
            // Tick 1, before player 2 has a seed: its full view did not encode.
            guard output.observedTickId == 1 else { return nil }
            return (output.perPlayerHash, output.perPlayerUnverified, output.extractionDrops, output.encodeDropScopes + [player2])
        }).syncOutput
        if seedsLater {
            #expect(sync.verdict == .passed, "\(sync.summary)")
            #expect(sync.skipReasons[.viewSentLater] == 1)
            #expect(sync.skipReasons[.viewNotSent] == nil)
        } else {
            #expect(sync.verdict == .partial, "\(sync.summary)")
            #expect(sync.skipReasons[.viewNotSent] == 1)
        }
    }
}

@Suite("Debug freeze settle: a sync failure ends the land (#535)", .timeLimit(.minutes(1)), .drainsFixtureKeepers)
struct DebugFreezeSettleFailureTests {
    @Test("A settle whose plan throws ends the land in the settle's turn: the gate closes and the freeze throws the failure")
    func settleFailureEndsTheLand() async throws {
        let f = await VerifierFixture.make(encoding: .json)
        try await f.join(1)
        await f.tick()
        // Quiet ticks request no sync: the broken field is first planned by the settle.
        try await f.set(1, "quiet")
        await f.tick()
        try await f.set(1, "break")
        await f.tick()
        #expect(f.keeper.failure == nil, "no plan has met the throw yet")
        let settleIndex = UInt64(try await f.stream().count)
        do {
            _ = try await f.adapter.debugFreeze()
            Issue.record("the freeze succeeded")
        } catch let failure as LandFailure {
            #expect(failure.kind == .syncConversion)
        } catch {
            Issue.record("the freeze threw \(error), not the land failure")
        }
        // Ended in the settle's turn (#546 L2d-1): no later turn applies it.
        #expect(f.adapter.outputGate.isClosed, "closed when the freeze throws")
        #expect(f.keeper.failure?.kind == .syncConversion)
        #expect(f.keeper.failure?.field == "fragile")
        // Earlier sync-only outputs may exist: only the settle's index and later are checked.
        let late = try await f.stream().filter { $0.streamIndex >= settleIndex }
        #expect(late.allSatisfy { if case .output = $0 { false } else { true } }, "the failed settle committed nothing: \(late)")
    }

    @Test("A settle failure on a tick land is recorded in the last committed tick's frame, without ending inputs; the record replays")
    func tickSettleFailureRecord() async throws {
        let f = await VerifierFixture.make(encoding: .json)
        try await f.join(1)
        await f.tick()
        try await f.set(1, "quiet")
        await f.tick()
        try await f.set(1, "break")
        await f.tick()
        let settleIndex = UInt64(try await f.stream().count)
        _ = try? await f.adapter.debugFreeze()
        let lastTick = await f.keeper.debugLastCommittedTickId()
        await f.keeper.waitForRecorderSubmissionsForTesting()
        let frames = await f.keeper.getReevaluationRecorder()!.getAllFrames()
        let failing = try #require(frames.first { $0.landFailure != nil }, "the failure is recorded")
        #expect(frames.filter { $0.landFailure != nil }.count == 1)
        #expect(failing.tickId == lastTick, "the last committed tick's frame")
        #expect(failing.landFailure?.position.tickId == lastTick)
        #expect(failing.landFailure?.position.endsInputs == nil, "the failure ends no input batch")
        // The committed-output prefix: every output is before the settle.
        let outputs = ReevaluationSyncStreamEntry.stream(of: frames).filter { if case .output = $0 { true } else { false } }
        #expect(!outputs.isEmpty)
        #expect(outputs.allSatisfy { $0.streamIndex < settleIndex })
        let result = try await f.replay()
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        #expect(result.liveFailure?.kind == .syncConversion)
        for (tickId, hash) in result.recordedStateHashes where tickId < lastTick {
            #expect(result.tickHashes[tickId] == hash, "state hash of tick \(tickId)")
        }
    }

    @Test("A settle failure on a tickless land shares the last pass, without ending inputs; the record replays")
    func ticklessSettleFailureRecord() async throws {
        let f = await VerifierFixture.make(encoding: .json, definition: makeTicklessVerifierLand())
        try await f.join(1)
        try await f.set(1, "score", 3)
        try await f.set(1, "break")
        #expect(f.keeper.failure == nil, "no plan has met the throw yet")
        await f.keeper.waitForRecorderSubmissionsForTesting()
        let passes = Int64(await f.keeper.getReevaluationRecorder()!.getAllFrames().flatMap(\.passes).count)
        try #require(passes > 0)
        let settleIndex = UInt64(try await f.stream().count)
        _ = try? await f.adapter.debugFreeze()
        #expect(f.keeper.failure?.kind == .syncConversion, "ended in the settle's turn")
        await f.keeper.waitForRecorderSubmissionsForTesting()
        let frames = await f.keeper.getReevaluationRecorder()!.getAllFrames()
        let failure = try #require(frames.compactMap(\.landFailure).first, "the failure is recorded")
        #expect(failure.position.pass.map(Int64.init) == passes, "the last pass")
        #expect(failure.position.tickId == nil)
        #expect(failure.position.endsInputs == nil, "the failure ends no input batch")
        #expect(frames.flatMap(\.passes).count == Int(passes), "the settle adds no pass")
        let outputs = ReevaluationSyncStreamEntry.stream(of: frames).filter { if case .output = $0 { true } else { false } }
        #expect(outputs.allSatisfy { $0.streamIndex < settleIndex })
        let result = try await f.replay()
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        #expect(result.liveFailure?.kind == .syncConversion)
    }
}

/// The verifier land without a tick: inputs run in passes. "score" asks for a sync; "break"
/// doesn't, so the broken `fragile` is first planned by a debug freeze settle.
func makeTicklessVerifierLand() -> LandDefinition<VerifierState> {
    Land("sync-output-verifier-tickless-test", using: VerifierState.self) {
        ServerEvents { Register(SyncStreamTestEvent.self) }
        Rules {
            HandleAction(VerifierSetAction.self) { state, action, ctx in
                switch action.field {
                case "break": state.fragile.broken = true
                default:
                    state.scores[ctx.playerID] = action.value
                    ctx.requestSyncNow()
                }
                return SyncStreamSetResponse(ok: true)
            }
        }
    }
}

/// Records made by an earlier build, kept frozen (never regenerated), that must stay replayable
/// after a change to how the live run records the same scenario (#546 L2d-1). See
/// Fixtures/ReplayCompatibility/README.md.
@Suite("Replay of records made by an earlier build", .timeLimit(.minutes(1)), .drainsFixtureKeepers)
struct ReplayCompatibilityRecordTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ReplayCompatibility")

    static func path(_ name: String) -> String {
        directory.appendingPathComponent("\(name).reeval.sstr").path
    }

    /// Replays an upgraded copy of the record at `path`: from 3.7 replay refuses a record whose
    /// payloads are trees (#700 K1a, K1-Q1 (a)), and these records are never regenerated.
    static func replayUpgraded(
        _ path: String, definition: LandDefinition<VerifierState> = makeVerifierLand()
    ) async throws -> ReevaluationEngine.RunResult {
        let copy = try LegacyRecordUpgrader.upgradedCopy(ofRecordAt: path)
        defer { try? FileManager.default.removeItem(atPath: copy) }
        return try await VerifierFixture.replay(recordAt: copy, definition: definition)
    }

    @Test("Each frozen record's payloads decode to the same value from their canonical JSON as from their tree (the upgrader's premise)")
    func upgraderPremiseHolds() throws {
        var checked = 0
        for (name, definition) in [
            ("freeze-resume-legacy-cycle-messagepack", makeVerifierLand()),
            ("settle-failure-queued-tick", makeVerifierLand()),
            (PortlessInitializeScenario.name(tick: true), PortlessInitializeScenario.definition(tick: true)),
            (PortlessInitializeScenario.name(tick: false), PortlessInitializeScenario.definition(tick: false)),
        ] {
            let result = try LegacyRecordUpgrader.premiseViolations(ofRecordAt: Self.path(name), definition: definition)
            #expect(result.violations == [], "\(name)")
            checked += result.checked
        }
        let hybrid = try LegacyRecordUpgrader.premiseViolations(
            ofRecordAt: HybridEventFrameGoldenTests.recordPath, definition: makeHybridGoldenLand()
        )
        #expect(hybrid.violations == [], "hybrid-record")
        checked += hybrid.checked
        // The records hold payloads, so the check ran on some.
        #expect(checked > 0)
    }

    @Test("A freeze settle recorded as a legacy cycle replays with every hash reproduced")
    func legacyCycleSettleReplays() async throws {
        let path = Self.path("freeze-resume-legacy-cycle-messagepack")
        let source = try ReevaluationRecordFile.openSource(filePath: path)
        let stream = try #require(try await source.getSyncStream())
        #expect(stream.contains { if case .output(let o) = $0 { o.turnKind == .legacyCycle } else { false } }, "the record holds the legacy-cycle settle")
        let result = try await Self.replayUpgraded(path)
        #expect(result.tickHashes == result.recordedStateHashes, "state hashes")
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        #expect(result.initialize == .passed)
    }

    @Test("A settle failure recorded as applied by the next tick, which ends its inputs, replays with every hash reproduced")
    func queuedSettleFailureReplays() async throws {
        let path = Self.path("settle-failure-queued-tick")
        let source = try ReevaluationRecordFile.openSource(filePath: path)
        let recorded = try #require(try await source.getLandFailure(), "the record holds the land failure")
        #expect(recorded.failure.kind == .syncConversion)
        #expect(recorded.failure.position.endsInputs == true, "the queued failure ended the next tick's inputs")
        let result = try await Self.replayUpgraded(path)
        // The replay may run past the last recorded tick to the one that applied the failure:
        // every recorded hash is reproduced.
        #expect(!result.recordedStateHashes.isEmpty)
        for (tickId, hash) in result.recordedStateHashes {
            #expect(result.tickHashes[tickId] == hash, "state hash of tick \(tickId)")
        }
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        #expect(result.liveFailure?.kind == .syncConversion)
    }
}
