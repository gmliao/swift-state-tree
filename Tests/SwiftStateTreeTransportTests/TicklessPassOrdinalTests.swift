// Record format 3.4: a tickless land's passes are numbered, and its sync outputs and seeds are
// located by the pass they read after (#563); the failure that ended a land is recorded and
// replay stops there (#535 D9).

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct OrdinalState: StateNodeProtocol {
    @Sync(.broadcast) var total: Int = 0
    @Sync(.perPlayerSlice()) var marks: [PlayerID: Int] = [:]

    public init() {}
}

@Payload
struct OrdinalAddAction: ActionPayload {
    typealias Response = SyncStreamSetResponse
    let amount: Int
}

/// No tick: inputs run in passes. The action changes state, asks for a sync and emits no event,
/// so its output reads at the sequence its own pass started at (the #563 tie).
func makeOrdinalLand() -> LandDefinition<OrdinalState> {
    Land("tickless-pass-ordinal-test", using: OrdinalState.self) {
        Rules {
            HandleAction(OrdinalAddAction.self) { (state: inout OrdinalState, action: OrdinalAddAction, ctx: LandContext) in
                state.total += action.amount
                state.marks[ctx.playerID] = state.total
                ctx.requestSyncNow()
                return SyncStreamSetResponse(ok: true)
            }
        }
    }
}

struct OrdinalFixture {
    let keeper: LandKeeper<OrdinalState>
    let adapter: TransportAdapter<OrdinalState>

    static func make() async -> OrdinalFixture {
        let keeper = LandKeeper<OrdinalState>(
            definition: makeOrdinalLand(),
            initialState: OrdinalState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false
        )
        let transport = VerifierTransport()
        let adapter = TransportAdapter<OrdinalState>(
            keeper: keeper,
            transport: transport,
            landID: "tickless-pass-ordinal-test",
            encodingConfig: InTurnEncoding.json.config,
            inTurnSync: true
        )
        await transport.setDelegate(adapter)
        await keeper.awaitInitialization()
        await keeper.setTransport(adapter)
        return OrdinalFixture(keeper: keeper, adapter: adapter)
    }

    static func player(_ n: Int) -> PlayerID { PlayerID("p\(n)") }

    func join(_ n: Int) async throws {
        try await simulateRouterJoin(
            adapter: adapter, keeper: keeper,
            sessionID: SessionID("s\(n)"), clientID: ClientID("c\(n)"), playerID: Self.player(n)
        )
    }

    func add(_ n: Int, _ amount: Int) async throws {
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: OrdinalAddAction.self),
                payload: AnyCodable(OrdinalAddAction(amount: amount))
            ),
            playerID: Self.player(n),
            clientID: ClientID("c\(n)"),
            sessionID: SessionID("s\(n)")
        )
    }

    func frames() async throws -> [ReevaluationTickFrame] {
        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        return await recorder.getAllFrames()
    }

    /// Saves the record as `version`, after `rewrite`, and replays it.
    func replay(
        version: String = ReevaluationRecordVersion.current,
        rewrite: ((inout [ReevaluationTickFrame]) -> Void)? = nil
    ) async throws -> ReevaluationEngine.RunResult {
        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: "tickless-pass-ordinal-test",
            landType: "tickless-pass-ordinal-test",
            createdAt: Date(timeIntervalSince1970: 0),
            metadata: [:],
            landDefinitionID: makeOrdinalLand().id,
            version: version,
            recordsSyncStream: true,
            syncConfig: adapter.syncConfigForRecord
        ))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pass-ordinal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("record.json").path
        try await recorder.saveCopyForTesting(to: path)
        if version != ReevaluationRecordVersion.current {
            try relabelRecordVersion(atPath: path, to: version)
        }
        if let rewrite {
            try ReevaluationRecordFile.convertToJSONViewForTesting(atPath: path)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var file = try decoder.decode(OrdinalRecordFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            rewrite(&file.tickFrames)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(file).write(to: URL(fileURLWithPath: path))
        }
        return try await ReevaluationEngine.run(
            definition: makeOrdinalLand(),
            initialState: OrdinalState(),
            recordFilePath: path
        )
    }
}

private struct OrdinalRecordFile: Codable {
    var recordMetadata: ReevaluationRecordMetadata
    var tickFrames: [ReevaluationTickFrame]
}

/// The script: two joins and event-free actions. Each action's output reads at the sequence its
/// own pass started at: the tie that read sequences can't break (#563).
private func playTies(_ f: OrdinalFixture) async throws {
    try await f.join(1)
    try await f.add(1, 2)
    try await f.add(1, 3)
    try await f.join(2)
    try await f.add(2, 4)
    #expect(await f.adapter.waitForOutboundDrain())
}

@Suite("Tickless pass ordinals (#563) and the recorded land failure (#535 D9)", .timeLimit(.minutes(1)))
struct TicklessPassOrdinalTests {
    @Test("Each pass is numbered from 1, and every output and seed records the pass it read after")
    func passesAndEntriesAreNumbered() async throws {
        let f = await OrdinalFixture.make()
        try await playTies(f)
        let frames = try await f.frames()
        let passes = frames.flatMap(\.passes)
        #expect(!passes.isEmpty)
        #expect(passes.map(\.ordinal) == (1 ... Int64(passes.count)).map { Optional($0) })
        // Without in-turn sync the stream isn't recorded (the legacy sync path).
        guard InTurnSync.isEnabled() else { return }
        let stream = ReevaluationSyncStreamEntry.stream(of: frames)
        var readsAfter: [Int64] = []
        for entry in stream {
            switch entry {
            case .output(let output): readsAfter.append(try #require(output.afterPass, "output \(output.streamIndex)"))
            case .marker(let marker) where marker.kind == .seed: readsAfter.append(try #require(marker.afterPass, "seed \(marker.streamIndex)"))
            case .marker: break
            }
        }
        #expect(!readsAfter.isEmpty)
        #expect(readsAfter == readsAfter.sorted(), "a later entry never reads before an earlier one")
        #expect(readsAfter.allSatisfy { $0 >= 0 && $0 <= Int64(passes.count) })
        // The tie #563 is about.
        let outputs = stream.compactMap { if case .output(let o) = $0 { return o } else { return nil } }
        // An event-free pass's output reads at the sequence its own pass started at, so the
        // sequence alone can't say whether it read before or after that pass.
        var startByOrdinal: [Int64: Int64] = [:]
        for pass in passes {
            if let ordinal = pass.ordinal { startByOrdinal[ordinal] = pass.sequenceBefore }
        }
        let tied = outputs.contains { (output: ReevaluationRecordedSyncOutput) -> Bool in
            guard let after = output.afterPass, let start = startByOrdinal[after] else { return false }
            return start == output.sequence
        }
        #expect(tied, "the script produces a sequence tie: passes \(passes.map { "\($0.ordinal ?? -1):\($0.sequenceBefore):\($0.inputs)" }), outputs \(outputs.map { "\($0.afterPass ?? -1)@\($0.sequence)" })")
    }

    @Test("A 3.4 tickless record's sync outputs and seeds verify against the pass they read after")
    func ticklessRecordVerifies() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await OrdinalFixture.make()
        try await playTies(f)
        let result = try await f.replay()
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        #expect(result.serverEventVerification == .passed)
        #expect(result.recordedPassMismatches.isEmpty)
    }

    @Test("A tickless land's freeze settle and resume commit outside a turn, and verify at their pass")
    func legacyCycleCommitsVerify() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await OrdinalFixture.make()
        try await f.join(1)
        try await f.add(1, 2)
        let frozen = try await f.adapter.debugFreeze()
        _ = await f.adapter.debugResume(freezeToken: frozen.freezeToken)
        try await f.add(1, 5)
        #expect(await f.adapter.waitForOutboundDrain())
        let stream = ReevaluationSyncStreamEntry.stream(of: try await f.frames())
        let legacy = stream.compactMap { entry -> ReevaluationRecordedSyncOutput? in
            if case .output(let output) = entry, output.turnKind == .legacyCycle { return output } else { return nil }
        }
        #expect(!legacy.isEmpty, "the freeze settle commits a legacy cycle")
        #expect(legacy.allSatisfy { $0.afterPass != nil })
        let result = try await f.replay()
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
    }

    /// 3.0 records no passes (they arrive in 3.1): the land is known tickless from its
    /// definition, not from the record, so its sync outputs are skipped too, never compared by tick.
    @Test(
        "A tickless record from before 3.4 has no ordinals: its sync outputs are not verified, with the reason",
        arguments: ["3.3", "3.0"]
    )
    func olderTicklessRecordIsSkipped(version: String) async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await OrdinalFixture.make()
        try await playTies(f)
        let result = try await f.replay(version: version) { frames in
            guard version == "3.0" else { return }
            frames = frames.map { $0.replacing(passes: []) }
        }
        guard case .skipped(let reason) = result.syncOutput.verdict else {
            Issue.record("expected skipped, got \(result.syncOutput.summary)")
            return
        }
        #expect(reason.contains("#563"))
    }

    @Test("A pass numbered out of order is a record error, not replayed in another order")
    func ordinalGapIsReported() async throws {
        let f = await OrdinalFixture.make()
        try await playTies(f)
        let result = try await f.replay { frames in
            let index = frames.firstIndex { !$0.passes.isEmpty }!
            var passes = frames[index].passes
            let last = passes.count - 1
            passes[last] = ReevaluationRecordedPass(
                sequenceBefore: passes[last].sequenceBefore, inputs: passes[last].inputs, ordinal: (passes[last].ordinal ?? 0) + 1
            )
            frames[index] = frames[index].replacing(passes: passes)
        }
        #expect(result.recordedPassMismatches[0]?.contains("numbered") == true, "\(result.recordedPassMismatches)")
    }

    @Test("A tickless land's failure is recorded with its pass; replay reports it and verifies what came before")
    func ticklessFailureIsRecorded() async throws {
        let f = await OrdinalFixture.make()
        try await playTies(f)
        let passCount = Int64(try await f.frames().flatMap(\.passes).count)
        await f.keeper.failLandForTesting(LandFailure(
            kind: .syncEncode, detail: "test failure", position: LandFailurePosition(stage: .syncPhase)
        ))
        let frames = try await f.frames()
        let failure = try #require(frames.compactMap(\.landFailure).first)
        #expect(frames.compactMap(\.landFailure).count == 1)
        #expect(failure.kind == .syncEncode)
        #expect(failure.position.stage == .syncPhase)
        #expect(failure.position.pass.map(Int64.init) == passCount, "the last pass applied")
        #expect(failure.position.tickId == nil)
        let result = try await f.replay()
        #expect(result.liveFailure?.kind == .syncEncode)
        if InTurnSync.isEnabled() {
            #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        }
    }

    @Test("A tick land's failure is recorded in its tick's frame; replay stops at that tick and reports it")
    func tickFailureIsRecorded() async throws {
        let f = await VerifierFixture.make(encoding: .json)
        try await f.join(1)
        await f.tick(4)
        await f.keeper.failLandForTesting(LandFailure(
            kind: .eventEncode, detail: "test failure", position: LandFailurePosition(stage: .eventFlush)
        ))
        await f.keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await f.keeper.getReevaluationRecorder())
        let frames = await recorder.getAllFrames()
        let failing = try #require(frames.first { $0.landFailure != nil })
        #expect(frames.filter { $0.landFailure != nil }.count == 1)
        #expect(failing.tickId == frames.map(\.tickId).max(), "the frame of the last tick")
        #expect(failing.landFailure?.position.pass == nil, "a tick land counts by tick")
        let result = try await f.replay()
        #expect(result.liveFailure?.kind == .eventEncode)
        #expect(result.liveFailure?.position.stage == .eventFlush)
        #expect(result.tickHashes.keys.max() == failing.tickId)

        // Moved to an earlier tick, the failure ends the replay there: no later tick is replayed.
        let earlier = try await f.replay { frames in
            let failure = frames.compactMap(\.landFailure).first
            frames = frames.map { $0.tickId == 1 ? $0.replacing(landFailure: failure) : $0 }
        }
        #expect(earlier.liveFailure?.kind == .eventEncode)
        #expect(failing.tickId > 1)
        #expect(earlier.tickHashes.keys.max() == 1)
    }

    @Test("The sync stream ends at the land failure: a firstSync read before it records nothing, a later clear neither, and what came before is kept (#535)")
    func syncStreamEndsAtTheFailure() async throws {
        guard InTurnSync.isEnabled() else { return }
        let f = await OrdinalFixture.make()
        try await f.join(1)
        try await f.add(1, 5)
        let before = ReevaluationSyncStreamEntry.stream(of: try await f.frames())
        // p1's seed, then the action's output: the last entry before the failure.
        let lastBefore = try #require(before.last)
        guard case .output = lastBefore else {
            Issue.record("the last entry before the failure is not the action's output: \(lastBefore)")
            return
        }

        // p2 joins the direct way; its standalone firstSync reads the state and is held.
        let session = SessionID("s2"), client = ClientID("c2"), player = OrdinalFixture.player(2)
        await f.adapter.onConnect(sessionID: session, clientID: client)
        let decision = try await f.keeper.join(
            session: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
            clientID: client, sessionID: session, services: LandServices()
        )
        guard case .allow = decision else {
            Issue.record("p2's join was denied")
            return
        }
        await f.adapter.registerSession(sessionID: session, clientID: client, playerID: player, authInfo: nil)
        _ = await f.adapter.allocatePlayerSlot(accountKey: player.rawValue, for: player)
        let afterRead = TestGate()
        await f.adapter.installHolds(HoldRegistry.at(.initialSyncAfterRead) { await afterRead.arrive() })
        let firstSync = Task { await f.adapter.syncStateForNewPlayer(playerID: player, sessionID: session) }
        #expect(await afterRead.waitForArrivals(1))
        await f.adapter.installHolds(nil)

        // The land fails while the read is held; its teardown is held too, so p2's ticket is
        // still current when the firstSync resumes: only the closed gate stops it.
        let teardown = TestGate()
        await f.keeper.installHolds(HoldRegistry.at(.landFailedTeardown) { await teardown.arrive() })
        await f.keeper.failLandForTesting(LandFailure(
            kind: .syncEncode, detail: "test failure", position: LandFailurePosition(stage: .syncPhase)
        ))
        afterRead.open()
        await firstSync.value
        #expect(await f.adapter.initialSyncsDroppedLandFailed == 1)
        #expect(await f.adapter.initialSyncsDroppedStale == 0)

        // A disconnect after the failure: its clear is outside the stream too.
        await f.adapter.onDisconnect(sessionID: SessionID("s1"), clientID: ClientID("c1"))
        teardown.open()
        await f.keeper.installHolds(nil)

        let frames = try await f.frames()
        #expect(frames.compactMap(\.landFailure).count == 1)
        let stream = ReevaluationSyncStreamEntry.stream(of: frames)
        // Nothing after the failure: the stream is what it was before it, entry for entry, its
        // indices dense from 0. A guard placed too early would drop entries from before it.
        #expect(stream.map(\.streamIndex) == before.map(\.streamIndex))
        #expect(stream.map(\.streamIndex) == Array(0..<UInt64(stream.count)))
        #expect(stream.last?.streamIndex == lastBefore.streamIndex)
        let markers = stream.compactMap { entry -> ReevaluationRecordedSyncMarker? in
            if case .marker(let marker) = entry { return marker } else { return nil }
        }
        #expect(!markers.contains { $0.playerID == player.rawValue }, "p2's seed was recorded after the failure")
        #expect(!markers.contains { $0.kind == .clear }, "a clear was recorded after the failure")
    }
}
