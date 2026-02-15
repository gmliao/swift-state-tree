import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeReevaluationMonitor

@Suite("ReevaluationReplayCompatibilityTests")
struct ReevaluationReplayCompatibilityTests {
    @Test("Replay projection emits Hero Defense-compatible state fields")
    func replayProjectionStateShapeParityContract() throws {
        let snapshotObject: [String: Any] = [
            "players": ["p1": ["x": 10, "y": 20]],
            "monsters": ["1": ["position": ["x": 10, "y": 20]]],
            "turrets": ["1": ["position": ["x": 5, "y": 6]]],
            "base": ["hp": 100],
            "score": 123,
            "currentStateJSON": "legacy-replay-only",
        ]
        let snapshotJSONString = try encodeJSONObjectToString(snapshotObject)
        let stepResult = ReevaluationStepResult(
            tickId: 5,
            stateHash: "abc",
            recordedHash: "abc",
            isMatch: true,
            actualState: AnyCodable(snapshotJSONString)
        )

        let projector = HeroDefenseReplayProjector()
        let projected = try projector.project(stepResult)

        #expect(projected.tickID == 5)
        #expect(projected.stateObject["players"] != nil)
        #expect(projected.stateObject["monsters"] != nil)
        #expect(projected.stateObject["turrets"] != nil)
        #expect(projected.stateObject["base"] != nil)
        #expect(projected.stateObject["score"] != nil)
        #expect(projected.stateObject["currentStateJSON"] == nil)
    }

    @Test("Replay projection preserves tick ordering")
    func deterministicTickOrderingContract() throws {
        let projector = HeroDefenseReplayProjector()
        let orderedTickIDs: [Int64] = [1, 2, 3, 4]

        let projectedTickIDs = try orderedTickIDs.map { tickID in
            let jsonText = try encodeJSONObjectToString(["score": Int(tickID)])
            let result = ReevaluationStepResult(
                tickId: tickID,
                stateHash: "hash-\(tickID)",
                recordedHash: nil,
                isMatch: true,
                actualState: AnyCodable(jsonText)
            )
            return try projector.project(result).tickID
        }

        #expect(projectedTickIDs == orderedTickIDs)
    }

    @Test("Replay start rejects schema mismatch")
    func schemaMismatchGuardContract() async throws {
        let definition = makeReevaluationEngineTestDefinition()
        let mismatchedDefinitionID = "mismatched-schema-id"
        let recordingFile = try await createRecordingFile(
            definition: definition,
            landID: "reeval-schema-contract:local",
            metadataLandDefinitionID: mismatchedDefinitionID,
            actions: [5]
        )

        defer {
            try? FileManager.default.removeItem(at: recordingFile)
        }

        do {
            _ = try await ReevaluationEngine.run(
                definition: definition,
                initialState: ReevaluationEngineTestState(),
                recordFilePath: recordingFile.path
            )
            Issue.record("Expected schema mismatch error, but replay run succeeded")
        } catch {
            #expect(
                hasSchemaMismatchErrorSignature(error),
                "Schema mismatch should fail with a deterministic error signature (domain/code)"
            )
            #expect(
                hasSchemaMismatchContext(
                    error,
                    expectedRecordedLandDefinitionID: mismatchedDefinitionID,
                    expectedRuntimeLandDefinitionID: definition.id
                ),
                "Schema mismatch should carry deterministic mismatch context (recorded/runtime definition IDs)"
            )
        }
    }
}

private enum ReevaluationReplayCompatibilityTestError: Error {
    case reevaluationRecorderUnavailable
}

private func encodeJSONObjectToString(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    return text
}

private func hasSchemaMismatchErrorSignature(_ error: Error) -> Bool {
    let nsError = error as NSError
    let expectedDomain = "ReevaluationEngine"
    let expectedCode = 1001

    return nsError.domain == expectedDomain && nsError.code == expectedCode
}

private func hasSchemaMismatchContext(
    _ error: Error,
    expectedRecordedLandDefinitionID: String,
    expectedRuntimeLandDefinitionID: String
) -> Bool {
    let nsError = error as NSError

    let recordedKeys = [
        "recordedLandDefinitionID",
        "recordLandDefinitionID",
        "recordedDefinitionID",
        "recordDefinitionID",
    ]
    let runtimeKeys = [
        "runtimeLandDefinitionID",
        "currentLandDefinitionID",
        "expectedLandDefinitionID",
        "runtimeDefinitionID",
    ]

    let recordedID = recordedKeys
        .compactMap { nsError.userInfo[$0] as? String }
        .first
    let runtimeID = runtimeKeys
        .compactMap { nsError.userInfo[$0] as? String }
        .first

    return recordedID == expectedRecordedLandDefinitionID && runtimeID == expectedRuntimeLandDefinitionID
}

private func createRecordingFile(
    definition: LandDefinition<ReevaluationEngineTestState>,
    landID: String,
    metadataLandDefinitionID: String,
    actions: [Int]
) async throws -> URL {
    let expectedSeed = DeterministicSeed.fromLandID(landID)
    let recordingFile = stableFixtureFileURL(
        prefix: "reeval-replay-compat",
        identifier: landID,
        ext: "json"
    )

    let keeper = LandKeeper<ReevaluationEngineTestState>(
        definition: definition,
        initialState: ReevaluationEngineTestState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false
    )

    guard let recorder = await keeper.getReevaluationRecorder() else {
        throw ReevaluationReplayCompatibilityTestError.reevaluationRecorderUnavailable
    }

    let metadata = ReevaluationRecordMetadata(
        landID: landID,
        landType: definition.id,
        createdAt: stableFixtureDate,
        metadata: [:],
        landDefinitionID: metadataLandDefinitionID,
        initialStateHash: nil,
        landConfig: ["autoStartLoops": AnyCodable(false)],
        rngSeed: expectedSeed,
        ruleVariantId: nil,
        ruleParams: nil,
        version: "1.0",
        extensions: nil
    )
    await recorder.setMetadata(metadata)

    let playerID = PlayerID("contract-player")
    let clientID = ClientID("contract-client")
    let sessionID = SessionID("contract-session")
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)

    for amount in actions {
        let action = ReevaluationAddAction(amount: amount)
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: ReevaluationAddAction.self),
            payload: AnyCodable(action)
        )
        _ = try await keeper.handleActionEnvelope(
            envelope,
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID
        )
        await keeper.stepTickOnce()
    }

    if FileManager.default.fileExists(atPath: recordingFile.path) {
        try FileManager.default.removeItem(at: recordingFile)
    }
    try await recorder.save(to: recordingFile.path)
    return recordingFile
}

private let stableFixtureDate = Date(timeIntervalSince1970: 1_700_000_000)

private func stableFixtureFileURL(prefix: String, identifier: String, ext: String) -> URL {
    let safeIdentifier = identifier.replacingOccurrences(of: ":", with: "-")
    return FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(safeIdentifier).\(ext)")
}
