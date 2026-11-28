// Record format 3.4: a tickless land's passes are numbered, and its sync outputs and seeds are
// located by the pass they read after (#563); the failure that ended a land is recorded and
// replay stops there (#535 D9).

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
import SwiftStateTreeReevaluationMonitor
import SwiftStateTreeTestSupport

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

/// A server input that changes state and emits, as the emit action does.
@Payload
struct OrdinalServerEmit: ServerInputPayload {
    let amount: Int
}

@Payload
struct OrdinalEmitAction: ActionPayload {
    typealias Response = SyncStreamSetResponse
    let amount: Int
}

/// No tick: inputs run in passes. The add action changes state, asks for a sync and emits no
/// event, so its output reads at the sequence its own pass started at (the #563 tie). The emit
/// action does the same and emits an event to everyone and one to its player first.
func makeOrdinalLand() -> LandDefinition<OrdinalState> {
    Land("tickless-pass-ordinal-test", using: OrdinalState.self) {
        ServerEvents { Register(SyncStreamTestEvent.self) }
        Rules {
            HandleAction(OrdinalEmitAction.self) { state, action, ctx in
                state.total += action.amount
                state.marks[ctx.playerID] = state.total
                ctx.emitEvent(SyncStreamTestEvent(message: "all-\(action.amount)"), to: .all)
                ctx.emitEvent(SyncStreamTestEvent(message: "to-\(ctx.playerID.rawValue)"), to: .player(ctx.playerID))
                ctx.requestSyncNow()
                return SyncStreamSetResponse(ok: true)
            }
            HandleServerInput(OrdinalServerEmit.self) { state, input, ctx in
                state.total += input.amount
                ctx.emitEvent(SyncStreamTestEvent(message: "server-\(input.amount)"), to: .all)
            }
            HandleAction(OrdinalAddAction.self) { state, action, ctx in
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

    static func make(encoding: InTurnEncoding = .json) async -> OrdinalFixture {
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
            encodingConfig: encoding.config
        )
        await transport.setDelegate(adapter)
        await keeper.awaitInitialization()
        await keeper.setTransport(adapter)
        // The adapter link is a cycle until the drain: the suite's trait drains it (#910).
        FixtureKeepers.register(keeper)
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

    func emit(_ n: Int, _ amount: Int) async throws {
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: OrdinalEmitAction.self),
                payload: AnyCodable(OrdinalEmitAction(amount: amount))
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
        try await withSavedRecord(version: version, rewrite: rewrite) { path in
            try await ReevaluationEngine.run(
                definition: makeOrdinalLand(),
                initialState: OrdinalState(),
                recordFilePath: path
            )
        }
    }

    /// Replays the record with the hosted runner (the monitor's replay) and returns its sync-output
    /// verification and the live failure it read.
    func replayHosted() async throws -> (sync: SyncOutputVerification, liveFailure: LandFailure?, steps: Int) {
        try await withSavedRecord(version: ReevaluationRecordVersion.current, rewrite: nil) { path in
            let runner = try await ConcreteReevaluationRunner(
                definition: makeOrdinalLand(), initialState: OrdinalState(), recordFilePath: path
            )
            var steps = 0
            while try await runner.step() != nil { steps += 1 }
            return (await runner.syncOutputVerification(), await runner.liveFailure(), steps)
        }
    }

    /// Saves the record as `version`, after `rewrite`, and runs `body` on its path.
    private func withSavedRecord<T>(
        version: String,
        rewrite: ((inout [ReevaluationTickFrame]) -> Void)?,
        _ body: (String) async throws -> T
    ) async throws -> T {
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
        return try await body(path)
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
    await f.adapter.waitForOutboundIdleForTesting()
}

@Suite("Tickless pass ordinals (#563) and the recorded land failure (#535 D9)", .timeLimit(.minutes(1)), .drainsFixtureKeepers)
struct TicklessPassOrdinalTests {
    @Test("Each pass is numbered from 1, and every output and seed records the pass it read after")
    func passesAndEntriesAreNumbered() async throws {
        let f = await OrdinalFixture.make()
        try await playTies(f)
        let frames = try await f.frames()
        let passes = frames.flatMap(\.passes)
        #expect(!passes.isEmpty)
        #expect(passes.map(\.ordinal) == (1 ... Int64(passes.count)).map { Optional($0) })
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
        let f = await OrdinalFixture.make()
        try await playTies(f)
        let result = try await f.replay()
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        #expect(result.serverEventVerification == .passed)
        #expect(result.recordedPassMismatches.isEmpty)
    }

    @Test("A tickless land's freeze settle is its own sync-only turn record, and verifies at its pass")
    func settleTurnCommitsVerify() async throws {
        let f = await OrdinalFixture.make()
        try await f.join(1)
        try await f.add(1, 2)
        let before = try await f.frames()
        let settleIndex = UInt64(ReevaluationSyncStreamEntry.stream(of: before).count)
        let passesBefore = before.flatMap(\.passes).count
        let frozen = try await f.adapter.debugFreeze()
        _ = await f.adapter.debugResume(freezeToken: frozen.freezeToken)
        try await f.add(1, 5)
        await f.adapter.waitForOutboundIdleForTesting()
        let frames = try await f.frames()
        let stream = ReevaluationSyncStreamEntry.stream(of: frames)
        guard case .output(let settle) = try #require(stream.first { $0.streamIndex == settleIndex }, "the settle recorded an entry") else {
            Issue.record("the settle's entry is not an output")
            return
        }
        #expect(settle.turnKind == .syncOnly, "the settle is a sync-only turn (#546 L2d-1)")
        #expect(settle.afterPass == Int64(passesBefore), "it reads after the last pass")
        // The settle is a turn record of its own, so the later action's pass reads after it.
        let later = stream.compactMap { entry -> ReevaluationRecordedSyncOutput? in
            if case .output(let output) = entry, output.streamIndex > settleIndex { return output } else { return nil }
        }
        #expect(!later.isEmpty)
        #expect(later.allSatisfy { ($0.afterPass ?? 0) > Int64(passesBefore) })
        let result = try await f.replay()
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
    }

    /// Before #521 D15, a 3.3 or 3.0 tickless record replayed with its sync outputs skipped
    /// (#563). Such a record has no schema fingerprint, so replay now refuses it before the first
    /// step (S5).
    @Test(
        "A tickless record from before 3.4 is refused at replay: it has no schema fingerprint",
        arguments: ["3.3", "3.0"]
    )
    func olderTicklessRecordIsRefused(version: String) async throws {
        let f = await OrdinalFixture.make()
        try await playTies(f)
        do {
            _ = try await f.replay(version: version) { frames in
                guard version == "3.0" else { return }
                frames = frames.map { $0.replacing(passes: []) }
            }
            Issue.record("expected the record to be refused")
        } catch ReevaluationRecordFingerprintError.missing(let recorded) {
            #expect(recorded == version)
        }
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
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
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
        // The teardown closes the sessions: their clears are outside the stream too.
        await f.keeper.waitUntilDrained()

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

    @Test("A tickless pass's events reach the shadow before the outputs read after it", arguments: [InTurnEncoding.json, .messagepack])
    func ticklessPassEventsReachTheShadow(encoding: InTurnEncoding) async throws {
        let f = await OrdinalFixture.make(encoding: encoding)
        try await f.join(1)
        try await f.emit(1, 3)
        try await f.join(2)
        try await f.add(2, 4)
        try await f.emit(2, 5)
        let result = try await f.replay()
        #expect(result.serverEventVerification == .passed)
        #expect(result.syncOutput.verdict == .passed, "\(result.syncOutput.summary)")
        if encoding == .messagepack {
            // Merged broadcast frames carry the events: each emitting pass's output compares them.
            #expect(result.syncOutput.events.compared > 0, "\(result.syncOutput.summary)")
        }
        // The hosted runner (the monitor's replay) locates them the same way (#563).
        let hosted = try await f.replayHosted()
        #expect(hosted.sync.verdict == .passed, "\(hosted.sync.summary)")
        #expect(hosted.sync.perPlayer.compared == result.syncOutput.perPlayer.compared)
    }

    @Test("A 3.4 tickless pass without its ordinal is a record error")
    func missingOrdinalIsReported() async throws {
        let f = await OrdinalFixture.make()
        try await playTies(f)
        let result = try await f.replay { frames in
            let index = frames.firstIndex { !$0.passes.isEmpty }!
            var passes = frames[index].passes
            passes[1] = ReevaluationRecordedPass(sequenceBefore: passes[1].sequenceBefore, inputs: passes[1].inputs)
            frames[index] = frames[index].replacing(passes: passes)
        }
        let reason = try #require(result.recordedPassMismatches[0])
        #expect(reason.contains("has no ordinal"), "\(reason)")
    }

    @Test("A failure applied as an input in a tickless pass ends that pass: its events are dropped, live and in replay")
    func ticklessFailureInsideAPass() async throws {
        let f = await OrdinalFixture.make(encoding: .messagepack)
        try await f.join(1)
        try await f.emit(1, 2)
        // The next pass holds an emitting action and, behind it, a transport-reported failure.
        // The action's intake queues it and starts the drain, held at its start: the action is
        // queued once the drain arrives.
        let drain = TestGate()
        // The earlier pass's drain has ended, so the action starts a drain of its own.
        await f.keeper.waitForInputDrainIdleForTesting()
        await f.keeper.installHolds(HoldRegistry.at(.inputDrain) { await drain.arrive() })
        let action = Task { try? await f.emit(1, 7) }
        #expect(await drain.waitForArrivals(1))
        await f.keeper.submitLandFailure(LandFailure(
            kind: .syncEncode, detail: "test failure", position: LandFailurePosition(stage: .syncPhase)
        ))
        drain.open()
        await f.keeper.installHolds(nil)
        _ = await action.value
        #expect(await f.keeper.waitForFailureForTesting())

        let frames = try await f.frames()
        let failure = try #require(frames.compactMap(\.landFailure).first)
        let passes = frames.flatMap(\.passes)
        #expect(failure.position.endsInputs == true)
        #expect(failure.position.pass.map(Int64.init) == passes.last?.ordinal, "the pass the failure ended")
        #expect(failure.position.sequence == nil, "a sequence names an input only for the .input stage")
        let lastPass = try #require(passes.last)
        let recordedEvents = frames.flatMap(\.serverEvents)
        #expect(!recordedEvents.contains { $0.sequence >= lastPass.sequenceBefore }, "the failing pass's events were sent")

        let result = try await f.replay()
        #expect(result.liveFailure?.kind == .syncEncode)
        #expect(result.serverEventVerification == .passed, "the replayed failing pass emitted its events")
        #expect(result.recordedPassMismatches.isEmpty, "\(result.recordedPassMismatches)")
        let hosted = try await f.replayHosted()
        #expect(hosted.liveFailure?.kind == .syncEncode)
        #expect(hosted.sync.verdict == .passed, "\(hosted.sync.summary)")
    }

    @Test("A failure applied as an input inside a tick ends that tick: no tick handler and none of its events, live and in replay")
    func tickFailureInsideATick() async throws {
        let f = await VerifierFixture.make(encoding: .json)
        try await f.join(1)
        await f.tick()
        // An emitting action, and behind it a transport-reported failure, both queued for tick 2:
        // a tick land's action returns once queued.
        try await f.set(1, "burst", 2)
        await f.keeper.submitLandFailure(LandFailure(
            kind: .eventEncode, detail: "test failure", position: LandFailurePosition(stage: .eventFlush)
        ))
        await f.keeper.stepTickOnce()
        #expect(await f.keeper.waitForFailureForTesting())

        await f.keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await f.keeper.getReevaluationRecorder())
        let frames = await recorder.getAllFrames()
        let failing = try #require(frames.first { $0.landFailure != nil })
        #expect(failing.landFailure?.position.endsInputs == true)
        #expect(failing.serverEvents.isEmpty, "the failing tick's events were sent")
        #expect(!failing.actions.isEmpty, "the action applied before the failure is recorded")

        let result = try await f.replay()
        #expect(result.liveFailure?.kind == .eventEncode)
        #expect(result.serverEventVerification == .passed, "the replayed tick emitted what live dropped")
        #expect(result.tickHashes.keys.max() == failing.tickId)
        for (tickId, recorded) in result.recordedStateHashes {
            #expect(result.tickHashes[tickId] == recorded, "tick \(tickId)")
        }
    }
}
