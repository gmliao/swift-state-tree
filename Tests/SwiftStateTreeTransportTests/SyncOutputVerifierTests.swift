// Tests/SwiftStateTreeTransportTests/SyncOutputVerifierTests.swift
//
// The sync-output hash verifier end to end: a live land with in-turn sync records its sync
// stream, `ReevaluationEngine.run` replays it, and the shadow sync engine re-plans every output.
// Faults are injected into the live digest (standing in for a diff that sent something else)
// or into the live dirty tracking; the verifier must report them, and only them.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

/// A reference-typed value: mutating it in place does not go through `@Sync`'s setter, so the
/// live dirty tracking misses the change (a dirty-tracking miss).
final class VerifierBox: Codable, @unchecked Sendable, Equatable, SnapshotValueConvertible {
    var value = 0
    init() {}
    func toSnapshotValue() throws -> SnapshotValue { .int(value) }
    static func == (lhs: VerifierBox, rhs: VerifierBox) -> Bool { lhs.value == rhs.value }
}

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
            OnInitialize { (state: inout VerifierState, ctx: LandContext) in
                state.board["init"] = 1
                ctx.emitEvent(SyncStreamTestEvent(message: "init"), to: .all)
            }
            Tick(every: .seconds(3600)) { (state: inout VerifierState, ctx: LandContext) in
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
            HandleAction(VerifierSetAction.self) { (state: inout VerifierState, action: VerifierSetAction, ctx: LandContext) in
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

struct VerifierFixture {
    let keeper: LandKeeper<VerifierState>
    let adapter: TransportAdapter<VerifierState>
    let definition = makeVerifierLand()

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
        pathHashes: [String: UInt32]? = nil
    ) async -> VerifierFixture {
        let definition = makeVerifierLand()
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
                stateUpdateEncoder: encoder,
                inTurnSync: true
            )
        } else {
            adapter = TransportAdapter<VerifierState>(
                keeper: keeper,
                transport: transport,
                landID: "sync-output-verifier-test",
                encodingConfig: encoding.config.withPathIndex(pathIndex),
                pathHashes: encoding == .json ? nil : pathHashes ?? (pathIndex ? verifierSchemaPathHashes : verifierPathHashes),
                inTurnSync: true
            )
        }
        await transport.setDelegate(adapter)
        if initializeFirst {
            await keeper.awaitInitialization()
        }
        await keeper.setTransport(adapter)
        return VerifierFixture(keeper: keeper, adapter: adapter)
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
        try await simulateRouterJoin(
            adapter: adapter,
            keeper: keeper,
            sessionID: SessionID("s\(n)"),
            clientID: ClientID("c\(n)"),
            playerID: Self.player(n)
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
            #expect(await adapter.waitForOutboundDrain())
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
        return try await Self.replay(recordAt: path)
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

    /// Replays a saved record of the verifier land.
    static func replay(recordAt path: String) async throws -> ReevaluationEngine.RunResult {
        try await ReevaluationEngine.run(
            definition: makeVerifierLand(),
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

@Suite("Sync-output verifier", .timeLimit(.minutes(1)))
struct SyncOutputVerifierTests {
    @Test(
        "A deterministic run passes: every scope compared, nothing unverifiable",
        arguments: InTurnEncoding.allCases, [true, false]
    )
    func deterministicRunPasses(encoding: InTurnEncoding, initializeFirst: Bool) async throws {
        guard InTurnSync.isEnabled() else { return }
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

    @Test("A broadcast patch the live diff dropped is detected", arguments: InTurnEncoding.allCases)
    func droppedBroadcastPatch(encoding: InTurnEncoding) async throws {
        guard InTurnSync.isEnabled() else { return }
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
        guard InTurnSync.isEnabled() else { return }
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
        guard InTurnSync.isEnabled() else { return }
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

    #if DEBUG  // The diff fault hook exists in debug builds only.
    @Test("A diff-engine bug both sides share passes every hash and fails the apply check", arguments: InTurnEncoding.allCases)
    func diffEngineFaultIsCaughtByTheApplyCheck(encoding: InTurnEncoding) async throws {
        guard InTurnSync.isEnabled() else { return }
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
        guard InTurnSync.isEnabled() else { return }
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
        guard InTurnSync.isEnabled() else { return }
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
        guard InTurnSync.isEnabled() else { return }
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
        guard InTurnSync.isEnabled() else { return }
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
        guard InTurnSync.isEnabled() else { return }
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
        guard InTurnSync.isEnabled() else { return }
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

    @Test("One player's degraded seed leaves the broadcast and the other players compared")
    func degradedSeedIsNarrow() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await VerifierFixture.make(encoding: .json)
        try await f.join(1)
        try await f.set(1, "score", 10)
        try await f.set(1, "break")
        await f.tick()      // `fragile` stops extracting: an extraction drop on every output
        try await f.join(2) // its seed leaves `fragile` out: unverifiable
        try await f.set(1, "score", 11)
        try await f.set(2, "score", 21)
        await f.tick(2)
        let stream = ReevaluationSyncStreamEntry.stream(of: await f.keeper.getReevaluationRecorder()!.getAllFrames())
        let lastTick = try #require(stream.compactMap { if case .output(let o) = $0, o.turnKind == .tick { return o } else { return nil } }.last)
        #expect(lastTick.perPlayerUnverified == [VerifierFixture.player(2).rawValue])
        let seeds = stream.compactMap { if case .marker(let m) = $0, m.kind == .seed { return m } else { return nil } }
        #expect(seeds.map(\.viewDropFields) == [nil, ["fragile"]], "the degraded seed names the dropped field")

        let sync = try await f.replay().syncOutput
        #expect(sync.verdict == .partial, "\(sync.summary)")
        #expect(sync.broadcast.compared == 3)
        #expect(sync.broadcast.unverifiable == 0)
        #expect(sync.seed.compared == 1)
        #expect(sync.seed.unverifiable == 1)
        // Player 1 on all three ticks; player 2 on the two ticks after its seed.
        #expect(sync.perPlayer.compared == 3)
        #expect(sync.perPlayer.unverifiable == 2)
    }

    @Test("A player is verifiable again after a seed with a view hash")
    func reseedRestoresVerification() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await VerifierFixture.make(encoding: .json)
        try await f.join(1)
        try await f.set(1, "break")
        await f.tick()
        try await f.join(2)   // degraded seed
        await f.tick()
        await f.leave(2)
        try await f.set(1, "fix")
        await f.tick()
        try await f.join(2)   // seed with a view hash
        await f.tick()
        let sync = try await f.replay().syncOutput
        #expect(sync.seed.unverifiable == 1)
        #expect(sync.seed.compared == 2)
        #expect(sync.perPlayer.unverifiable == 1, "only the tick between the degraded seed and the leave")
        if case .failed(let mismatch) = sync.verdict { Issue.record("\(mismatch.summary)") }
    }

    @Test("A legacy cycle's output (a debug freeze's settle) is verified")
    func legacyCycleIsVerified() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await VerifierFixture.make(encoding: .json)
        try await f.join(1)
        await f.tick(2)
        try await f.set(1, "score", 5)
        let frozen = try await f.adapter.debugFreeze()
        _ = await f.adapter.debugResume(freezeToken: frozen.freezeToken)
        await f.tick()
        let frames = await f.keeper.getReevaluationRecorder()!.getAllFrames()
        #expect(frames.flatMap(\.syncOutputs).contains { $0.turnKind == .legacyCycle })
        let sync = try await f.replay().syncOutput
        #expect(sync.verdict == .passed, "\(sync.summary)")
    }

    @Test("A tick recorded with an unavailable state hash is unverifiable, never a match (#180)")
    func unavailableHashIsUnverifiable() async throws {
        guard InTurnSync.isEnabled() else { return }
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
        guard InTurnSync.isEnabled() else { return }
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
        guard InTurnSync.isEnabled() else { return }
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
        guard InTurnSync.isEnabled() else { return }
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
        guard InTurnSync.isEnabled() else { return }
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

    @Test("A per-player encode drop makes that player unverifiable until a verifiable seed: partial, never passed")
    func perPlayerEncodeDropIsUnverifiable() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await VerifierFixture.make(encoding: .json)
        try await f.join(1)
        try await f.join(2)
        await f.tick()
        try await f.set(1, "inf")
        await f.tick()      // player 1's frame goes out without the infinite speed
        try await f.set(1, "speed", 3)
        await f.tick()      // still diverged: its client never got the dropped value
        let ticks = try await f.stream().compactMap { if case .output(let o) = $0, o.turnKind == .tick { return o } else { return nil } }
        #expect(ticks[1].encodeDropScopes == [VerifierFixture.player(1).rawValue])
        let sync = try await f.replay().syncOutput
        #expect(sync.verdict == .partial, "\(sync.summary)")
        // Player 1: compared on tick 0, unverifiable on ticks 1 and 2. Player 2: compared on all.
        #expect(sync.perPlayer.compared == 4)
        #expect(sync.perPlayer.unverifiable == 2)
        #expect(sync.broadcast.unverifiable == 0)
    }

    @Test("Combined mode: an update that was not sent is a divergence (unverifiable), not a skip")
    func combinedUncommittedIsUnverifiable() async throws {
        guard InTurnSync.isEnabled() else { return }
        let fails = VerifierSwitch()
        let f = await VerifierFixture.make(encoding: .json, encoder: VerifierFailingEncoder(fails: fails))
        let followUps = await f.holdFailedPlanFollowUps()
        defer { followUps.open() }
        try await f.join(1)
        await f.tick()
        fails.set(true)
        await f.tick()      // no player gets its combined update; the broadcast cache is committed
        fails.set(false)
        await f.tick()
        let ticks = try await f.stream().compactMap { if case .output(let o) = $0, o.turnKind == .tick { return o } else { return nil } }
        #expect(ticks[1].perPlayerUncommitted == [VerifierFixture.player(1).rawValue])
        let sync = try await f.replay().syncOutput
        #expect(sync.verdict == .partial, "\(sync.summary)")
        #expect(sync.perPlayer.compared == 1)
        #expect(sync.perPlayer.unverifiable == 2, "the unsent tick and the one after it")
        #expect(sync.perPlayer.skipped == 0)
    }

    @Test("A gap in the stream indices is malformed")
    func streamGapIsMalformed() async throws {
        guard InTurnSync.isEnabled() else { return }
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
        guard InTurnSync.isEnabled() else { return }
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

    @Test(
        "Opcode 107: an event sent outside the merged frame (alone, or lost) makes that output's events unverifiable",
        arguments: [TransportAdapter<VerifierState>.EventEncodingFault.mergedBody, .all]
    )
    func unmergedEventIsUnverifiable(fault: TransportAdapter<VerifierState>.EventEncodingFault) async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await VerifierFixture.make(encoding: .messagepack)
        let fails = VerifierSwitch()
        await f.adapter.setEventEncodingFaultForTesting { _ in fails.isOn ? fault : nil }
        try await f.join(1)
        await f.tick()
        fails.set(true)
        await f.tick()      // its three events do not reach a merged frame
        fails.set(false)
        await f.tick()
        let ticks = try await f.stream().compactMap { if case .output(let o) = $0, o.turnKind == .tick { return o } else { return nil } }
        let unmerged = ticks.map { $0.eventsNotMerged ?? ReevaluationUnmergedEvents() }
        #expect(unmerged.map { $0.all.count } == [0, 3, 0])
        if fault == .all {
            #expect(unmerged[1].lost.count == 3 && unmerged[1].sentAlone.isEmpty)
        } else {
            #expect(unmerged[1].sentAlone.count == 3 && unmerged[1].lost.isEmpty)
        }
        #expect(ticks[1].eventsNotQueued == nil, "an event to nobody that did not encode is not merged either")
        let sync = try await f.replay().syncOutput
        #expect(sync.verdict == .partial, "\(sync.summary)")
        #expect(sync.events.compared == 2)
        #expect(sync.events.unverifiable == 1)
        #expect(sync.eventsAfterLastOutput == 0)
        #expect(fault == .all ? (sync.eventsLost, sync.eventsSentAlone) == (3, 0) : (sync.eventsLost, sync.eventsSentAlone) == (0, 3))
        #expect(sync.summary.contains(fault == .all ? "3 events lost" : "3 events sent outside the merged frame"))
    }

    @Test("Opcode 107: an unsent per-player update is a benign skip once a later comparison sees the resend")
    func resendSeenIsBenign() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await VerifierFixture.make(encoding: .messagepack)
        try await f.join(1)
        await f.tick(3)
        let sync = try await f.replay(rewrite: markingUnsent(VerifierFixture.player(1), atTick: 1)).syncOutput
        #expect(sync.verdict == .passed, "\(sync.summary)")
        #expect(sync.skipReasons == [.perPlayerResent: 1])
    }

    @Test("Opcode 107: an unsent per-player update in the last output is not benign: nothing saw the resend")
    func resendNotSeenAtTheEnd() async throws {
        guard InTurnSync.isEnabled() else { return }
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
        guard InTurnSync.isEnabled() else { return }
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

    @Test("A joiner whose whole view never encodes is not benign; a later compared seed makes it so")
    func unsentViewIsNotBenign() async throws {
        guard InTurnSync.isEnabled() else { return }
        for seedsLater in [false, true] {
            let fails = VerifierSwitch()
            let f = await VerifierFixture.make(
                encoding: .json,
                encoder: VerifierFailingEncoder(fails: fails, player: VerifierFixture.player(2))
            )
            // The failed firstSync and tick each schedule a follow-up cycle 100 ms later: run
            // during the failing window it is a second unsent view (#163), after it a seed.
            let followUps = await f.holdFailedPlanFollowUps()
            defer { followUps.open() }
            try await f.join(1)
            await f.tick()
            fails.set(true)
            try await f.join(2)  // its firstSync does not encode, not even empty
            await f.tick()       // nor does the retried full view
            fails.set(false)
            if seedsLater {
                await f.tick()   // the full view goes out now: a seed with a view hash
            }
            let outputs = try await f.stream().compactMap { if case .output(let o) = $0, o.turnKind == .tick { return o } else { return nil } }
            #expect(outputs[1].encodeDropScopes.contains(VerifierFixture.player(2).rawValue))
            #expect(outputs[1].perPlayerUncommitted == nil, "it had no committed view to leave uncommitted")
            let sync = try await f.replay().syncOutput
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
