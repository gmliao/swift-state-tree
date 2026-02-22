// Tests/SwiftStateTreeTests/ReevaluationEngineTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct ReevaluationEngineTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    @Sync(.broadcast)
    var total: Int = 0
}

@Payload
struct ReevaluationAddAction: ActionPayload {
    typealias Response = ReevaluationAddResponse
    let amount: Int
}

@Payload
struct ReevaluationAddResponse: ResponsePayload {
    let total: Int
}

@Payload
struct ReevaluationAddEvent: ClientEventPayload {
    let amount: Int
}

func makeReevaluationEngineTestDefinition() -> LandDefinition<ReevaluationEngineTestState> {
    Land("reeval-engine-test", using: ReevaluationEngineTestState.self) {
        ClientEvents {
            Register(ReevaluationAddEvent.self)
        }

        Rules {
            HandleAction(ReevaluationAddAction.self) { (state: inout ReevaluationEngineTestState, action: ReevaluationAddAction, _: LandContext) in
                state.total += action.amount
                return ReevaluationAddResponse(total: state.total)
            }

            HandleEvent(ReevaluationAddEvent.self) { (state: inout ReevaluationEngineTestState, event: ReevaluationAddEvent, _: LandContext) in
                state.total += event.amount
            }
        }

        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout ReevaluationEngineTestState, _: LandContext) in
                state.ticks += 1
            }
        }
    }
}

@Test("ReevaluationEngine.run matches recorded state hashes")
func testReevaluationEngineRunMatchesRecordedHashes() async throws {
    let definition = makeReevaluationEngineTestDefinition()

    let landID = "reeval-engine-test:local"
    let expectedSeed = DeterministicSeed.fromLandID(landID)
    let recordingFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("reevaluation-engine-\(landID.replacingOccurrences(of: ":", with: "-")).json")

    defer {
        try? FileManager.default.removeItem(at: recordingFile)
    }

    let keeper = LandKeeper<ReevaluationEngineTestState>(
        definition: definition,
        initialState: ReevaluationEngineTestState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false
    )

    guard let recorder = await keeper.getReevaluationRecorder() else {
        Issue.record("ReevaluationRecorder not available")
        return
    }

    let meta = ReevaluationRecordMetadata(
        landID: landID,
        landType: "reeval-engine-test",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        metadata: [:],
        landDefinitionID: definition.id,
        initialStateHash: nil,
        landConfig: ["autoStartLoops": AnyCodable(false)],
        rngSeed: expectedSeed,
        ruleVariantId: nil,
        ruleParams: nil,
        version: "1.0",
        extensions: nil
    )
    await recorder.setMetadata(meta)

    let playerID = PlayerID("alice")
    let clientID = ClientID("c1")
    let sessionID = SessionID("s1")
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)

    let action1 = ReevaluationAddAction(amount: 1)
    let envelope1 = ActionEnvelope(
        typeIdentifier: String(describing: ReevaluationAddAction.self),
        payload: AnyCodable(action1)
    )
    _ = try await keeper.handleActionEnvelope(
        envelope1,
        playerID: playerID,
        clientID: clientID,
        sessionID: sessionID
    )
    try await keeper.handleClientEvent(
        AnyClientEvent(ReevaluationAddEvent(amount: 2)),
        playerID: playerID,
        clientID: clientID,
        sessionID: sessionID
    )
    await keeper.stepTickOnce()

    let action2 = ReevaluationAddAction(amount: 3)
    let envelope2 = ActionEnvelope(
        typeIdentifier: String(describing: ReevaluationAddAction.self),
        payload: AnyCodable(action2)
    )
    _ = try await keeper.handleActionEnvelope(
        envelope2,
        playerID: playerID,
        clientID: clientID,
        sessionID: sessionID
    )
    await keeper.stepTickOnce()

    if FileManager.default.fileExists(atPath: recordingFile.path) {
        try FileManager.default.removeItem(at: recordingFile)
    }
    try await recorder.save(to: recordingFile.path)

    let result = try await ReevaluationEngine.run(
        definition: definition,
        initialState: ReevaluationEngineTestState(),
        recordFilePath: recordingFile.path
    )

    #expect(result.maxTickId >= 1, "Recorded run should include multiple ticks")
    #expect(!result.recordedStateHashes.isEmpty, "Recorded state hashes should be available")

    for (tickId, recordedHash) in result.recordedStateHashes {
        #expect(
            result.tickHashes[tickId] == recordedHash,
            "Reevaluation hash should match recorded hash at tick \(tickId)"
        )
    }
}

// MARK: - State Snapshot JSONL Recording Test

@Test("State snapshot recording writes JSONL alongside main record when snapshots are recorded")
func testStateSnapshotRecordingWritesJsonl() async throws {
    let definition = makeReevaluationEngineTestDefinition()
    let landID = "state-snapshot-test:local"
    let expectedSeed = DeterministicSeed.fromLandID(landID)
    let tmpDir = FileManager.default.temporaryDirectory
    let recordingFile = tmpDir.appendingPathComponent("state-snapshot-\(UUID().uuidString).json")
    let stateJsonlFile = tmpDir.appendingPathComponent(recordingFile.deletingPathExtension().lastPathComponent + "-state.jsonl")

    defer {
        try? FileManager.default.removeItem(at: recordingFile)
        try? FileManager.default.removeItem(at: stateJsonlFile)
    }

    let recorder = ReevaluationRecorder()
    let meta = ReevaluationRecordMetadata(
        landID: landID,
        landType: "reeval-engine-test",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        metadata: [:],
        landDefinitionID: definition.id,
        rngSeed: expectedSeed,
        version: "1.0"
    )
    await recorder.setMetadata(meta)

    // Simulate a few ticks with state snapshots recorded directly
    let keeper = LandKeeper<ReevaluationEngineTestState>(
        definition: definition,
        initialState: ReevaluationEngineTestState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false
    )

    await keeper.stepTickOnce()
    let state0 = await keeper.currentState()
    let (hash0, snapshot0) = ReevaluationEngine.calculateStateHashAndSnapshot(state0)
    await recorder.recordStateSnapshot(tickId: 0, stateSnapshot: snapshot0)
    await recorder.setStateHash(tickId: 0, stateHash: hash0)

    await keeper.stepTickOnce()
    let state1 = await keeper.currentState()
    let (hash1, snapshot1) = ReevaluationEngine.calculateStateHashAndSnapshot(state1)
    await recorder.recordStateSnapshot(tickId: 1, stateSnapshot: snapshot1)
    await recorder.setStateHash(tickId: 1, stateHash: hash1)

    try await recorder.save(to: recordingFile.path)

    // Verify main JSON was written
    #expect(FileManager.default.fileExists(atPath: recordingFile.path), "Main record JSON should exist")

    // Verify state JSONL was written alongside main record
    #expect(FileManager.default.fileExists(atPath: stateJsonlFile.path), "State JSONL file should be written when snapshots are recorded")

    let content = try String(contentsOf: stateJsonlFile, encoding: .utf8)
    let lines = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    #expect(lines.count == 2, "State JSONL should contain one line per recorded tick")

    // Verify each line parses as JSON with tickId and stateSnapshot
    for line in lines {
        let data = try #require(line.data(using: .utf8))
        let json = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["tickId"] != nil, "Each JSONL line should have tickId")
        #expect(json["stateSnapshot"] != nil, "Each JSONL line should have stateSnapshot")
    }
}

// MARK: - Server Event Recording Test

@Payload
struct ServerEventRecordingTestEvent: ServerEventPayload {
    let value: Int
}

@StateNodeBuilder
struct ServerEventRecordingTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
}

func makeServerEventRecordingTestDefinition() -> LandDefinition<ServerEventRecordingTestState> {
    Land("server-event-recording-test", using: ServerEventRecordingTestState.self) {
        ServerEvents {
            Register(ServerEventRecordingTestEvent.self)
        }
        Rules {}
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout ServerEventRecordingTestState, ctx: LandContext) in
                state.ticks += 1
                ctx.emitEvent(ServerEventRecordingTestEvent(value: state.ticks), to: .all)
            }
        }
    }
}

@Test("Live recording captures server events; reevaluation produces identical events")
func testServerEventRecordingAndVerification() async throws {
    let definition = makeServerEventRecordingTestDefinition()
    let landID = "server-event-recording-test:local"
    let expectedSeed = DeterministicSeed.fromLandID(landID)
    let recordingFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("server-event-recording-\(UUID().uuidString).json")

    defer {
        try? FileManager.default.removeItem(at: recordingFile)
    }

    let keeper = LandKeeper<ServerEventRecordingTestState>(
        definition: definition,
        initialState: ServerEventRecordingTestState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false
    )

    guard let recorder = await keeper.getReevaluationRecorder() else {
        Issue.record("ReevaluationRecorder not available")
        return
    }

    let meta = ReevaluationRecordMetadata(
        landID: landID,
        landType: "server-event-recording-test",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        metadata: [:],
        landDefinitionID: definition.id,
        rngSeed: expectedSeed,
        version: "1.0"
    )
    await recorder.setMetadata(meta)

    let playerID = PlayerID("p1")
    let clientID = ClientID("c1")
    let sessionID = SessionID("s1")
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)

    await keeper.stepTickOnce()
    await keeper.stepTickOnce()

    try await recorder.save(to: recordingFile.path)

    let frames = await recorder.getAllFrames()
    let framesWithEvents = frames.filter { !$0.serverEvents.isEmpty }
    #expect(!framesWithEvents.isEmpty, "Record should contain server events")

    let result = try await ReevaluationEngine.run(
        definition: definition,
        initialState: ServerEventRecordingTestState(),
        recordFilePath: recordingFile.path
    )

    #expect(result.serverEventMismatches.isEmpty, "Reevaluation should produce identical server events")
}
