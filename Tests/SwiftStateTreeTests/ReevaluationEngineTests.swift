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

@Test("ReevaluationEngine.run matches recorded state hashes")
func testReevaluationEngineRunMatchesRecordedHashes() async throws {
    let definition = Land("reeval-engine-test", using: ReevaluationEngineTestState.self) {
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

    let landID = "reeval-engine-test:local"
    let expectedSeed = DeterministicSeed.fromLandID(landID)
    let recordingFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("reevaluation-engine-\(UUID().uuidString).json")

    defer {
        try? FileManager.default.removeItem(at: recordingFile)
    }

    let keeper = LandKeeper<ReevaluationEngineTestState>(
        definition: definition,
        initialState: ReevaluationEngineTestState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false
    )

    if let recorder = await keeper.getReevaluationRecorder() {
        let meta = ReevaluationRecordMetadata(
            landID: landID,
            landType: "reeval-engine-test",
            createdAt: Date(),
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
    }

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

    guard let recorder = await keeper.getReevaluationRecorder() else {
        Issue.record("ReevaluationRecorder not available")
        return
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
