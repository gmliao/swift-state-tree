// Tests/SwiftStateTreeTransportTests/SyncOutputVerifierTests.swift
//
// The sync-output hash verifier end to end: a live land with in-turn sync records its sync
// stream, `ReevaluationEngine.run` replays it, and the shadow sync engine re-plans every output.
// Faults are injected into the live digest (standing in for a diff that sent something else)
// or into the live dirty tracking; the verifier must report them, and only them.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

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
    @Sync(.broadcast) var fragile = SyncStreamFragile()
    @Sync(.broadcast) var box = VerifierBox()
    @Sync(.perPlayerSlice()) var scores: [PlayerID: Int] = [:]
    @Sync(.serverOnly) var missesDirty = false
    init() {}
}

/// "score": the caller's score is `value`; "break" / "fix": broadcast `fragile`; "miss": from
/// the next tick on, the tick also changes `box` in place.
@Payload
struct VerifierSetAction: ActionPayload {
    typealias Response = SyncStreamSetResponse
    let field: String
    let value: Int
}

/// OnInitialize writes the board and emits an event. Each tick advances `ticks`, writes one
/// board entry, emits two events to everyone and requests a sync.
private func makeVerifierLand() -> LandDefinition<VerifierState> {
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
                ctx.emitEvent(SyncStreamTestEvent(message: "a-\(state.ticks)"), to: .all)
                ctx.emitEvent(SyncStreamTestEvent(message: "b-\(state.ticks)"), to: .all)
                ctx.requestSyncNow()
            }
        }
        Rules {
            HandleAction(VerifierSetAction.self) { (state: inout VerifierState, action: VerifierSetAction, ctx: LandContext) in
                switch action.field {
                case "break": state.fragile.broken = true
                case "fix": state.fragile.broken = false
                case "miss": state.missesDirty = true
                default: state.scores[ctx.playerID] = action.value
                }
                return SyncStreamSetResponse(ok: true)
            }
        }
    }
}

private let verifierPathHashes: [String: UInt32] = Dictionary(
    uniqueKeysWithValues: ["ticks", "board", "fragile", "box", "scores", "missesDirty"].map { ($0, DeterministicHash.fnv1a32($0)) }
)

private actor VerifierTransport: Transport {
    var delegate: TransportDelegate?
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {}
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {}
}

private struct VerifierFixture {
    let keeper: LandKeeper<VerifierState>
    let adapter: TransportAdapter<VerifierState>
    let definition = makeVerifierLand()

    static func make(encoding: InTurnEncoding) async -> VerifierFixture {
        let definition = makeVerifierLand()
        let keeper = LandKeeper<VerifierState>(
            definition: definition,
            initialState: VerifierState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false
        )
        let transport = VerifierTransport()
        let adapter = TransportAdapter<VerifierState>(
            keeper: keeper,
            transport: transport,
            landID: "sync-output-verifier-test",
            encodingConfig: encoding.config,
            pathHashes: encoding == .json ? nil : verifierPathHashes,
            inTurnSync: true
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        return VerifierFixture(keeper: keeper, adapter: adapter)
    }

    static func player(_ n: Int) -> PlayerID { PlayerID("p\(n)") }

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
        try await recorder.save(to: path)
        if let rewrite {
            try VerifierRecordFile.rewrite(path, rewrite)
        }
        return try await ReevaluationEngine.run(
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
private func playScript(_ f: VerifierFixture) async throws {
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

@Suite("Sync-output verifier", .timeLimit(.minutes(1)))
struct SyncOutputVerifierTests {
    @Test("A deterministic run passes: every scope compared, nothing unverifiable", arguments: InTurnEncoding.allCases)
    func deterministicRunPasses(encoding: InTurnEncoding) async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await VerifierFixture.make(encoding: encoding)
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
        let f = await VerifierFixture.make(encoding: encoding)
        let fault = DigestFault { digest in
            guard var patches = digest.broadcastPatches, !patches.isEmpty else { return false }
            patches.removeLast()
            digest.broadcastPatches = patches
            return true
        }
        await f.adapter.setSyncOutputDigestFaultForTesting { fault.run(&$0) }
        try await playScript(f)
        #expect(fault.hasFired)
        guard case .failed(let mismatch) = try await f.replay().syncOutput.verdict else {
            Issue.record("expected a failed verdict")
            return
        }
        #expect(mismatch.scope == "broadcast")
    }

    @Test("A changed per-player value is detected", arguments: InTurnEncoding.allCases)
    func changedPerPlayerValue(encoding: InTurnEncoding) async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await VerifierFixture.make(encoding: encoding)
        let fault = DigestFault { digest in
            guard let (player, patches) = digest.perPlayerPatches.first(where: { digest.seeds[$0.key] == nil && !$0.value.isEmpty }) else {
                return false
            }
            var changed = patches
            changed[0] = StatePatch(path: changed[0].path, operation: .set(.int(999)))
            digest.perPlayerPatches[player] = changed
            return true
        }
        await f.adapter.setSyncOutputDigestFaultForTesting { fault.run(&$0) }
        try await playScript(f)
        #expect(fault.hasFired)
        guard case .failed(let mismatch) = try await f.replay().syncOutput.verdict else {
            Issue.record("expected a failed verdict")
            return
        }
        #expect(mismatch.scope == "per-player (combined)")
    }

    @Test("Opcode 107: a dropped event and two swapped events are detected", arguments: ["drop", "swap"])
    func droppedOrSwappedEvent(kind: String) async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await VerifierFixture.make(encoding: .messagepack)
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
        await f.adapter.setSyncOutputDigestFaultForTesting { fault.run(&$0) }
        try await playScript(f)
        #expect(fault.hasFired)
        guard case .failed(let mismatch) = try await f.replay().syncOutput.verdict else {
            Issue.record("expected a failed verdict")
            return
        }
        #expect(mismatch.scope == "events")
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

    @Test("A record without syncConfig (2.1) is skipped, never guessed")
    func missingSyncConfigIsSkipped() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await VerifierFixture.make(encoding: .json)
        try await playScript(f)
        let result = try await f.replay(version: "2.1", withSyncConfig: false)
        #expect(result.syncOutput.verdict == .skipped(reason: "record 2.1 predates syncConfig"))
        #expect(result.tickHashes == result.recordedStateHashes)
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
        let result = try await f.replay(version: "2.0", withSyncConfig: false) { frames in
            frames = frames.map { replacingInitialize($0, with: nil) }
        }
        #expect(result.initialize == .notRecorded)
        #expect(!result.recordedStateHashes.isEmpty)
        #expect(result.tickHashes == result.recordedStateHashes, "tick 0 still applies OnInitialize")
    }
}
