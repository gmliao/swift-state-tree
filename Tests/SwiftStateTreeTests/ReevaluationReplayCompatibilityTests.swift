import Foundation
import Testing
@testable import SwiftStateTree

@Suite("ReevaluationReplayCompatibilityTests")
struct ReevaluationReplayCompatibilityTests {
    @Test("Replay projection emits live-compatible fields and hides replay-only payload")
    func replayProjectionStateShapeParityContract() async throws {
        let definition = makeReevaluationEngineTestDefinition()
        let landID = "reeval-projection-contract:local"
        let recordingFile = try await createRecordingFile(
            definition: definition,
            landID: landID,
            metadataLandDefinitionID: definition.id,
            actions: [3]
        )
        let exportedJsonl = stableFixtureFileURL(
            prefix: "reeval-projection",
            identifier: landID,
            ext: "jsonl"
        )

        defer {
            try? FileManager.default.removeItem(at: recordingFile)
            try? FileManager.default.removeItem(at: exportedJsonl)
        }

        _ = try await ReevaluationEngine.run(
            definition: definition,
            initialState: ReevaluationEngineTestState(),
            recordFilePath: recordingFile.path,
            exportJsonlPath: exportedJsonl.path
        )

        let firstTickLine = try readFirstJsonlLine(from: exportedJsonl)

        #expect(firstTickLine["ticks"] != nil, "Replay output should expose live state field 'ticks'")
        #expect(firstTickLine["total"] != nil, "Replay output should expose live state field 'total'")
        #expect(firstTickLine["currentStateJSON"] == nil, "Replay output should not require replay-only field 'currentStateJSON'")
    }

    @Test("Replay output uses deterministic tick ordering without synthetic tick zero")
    func deterministicTickOrderingContract() async throws {
        let definition = makeReevaluationEngineTestDefinition()
        let expectedTickCount = 2
        let recordingFile = try await createRecordingFile(
            definition: definition,
            landID: "reeval-order-contract:local",
            metadataLandDefinitionID: definition.id,
            actions: [1, 2]
        )

        defer {
            try? FileManager.default.removeItem(at: recordingFile)
        }

        let result = try await ReevaluationEngine.run(
            definition: definition,
            initialState: ReevaluationEngineTestState(),
            recordFilePath: recordingFile.path
        )

        let observedTickIDs = result.tickHashes.keys.sorted()
        let expectedTickIDs = (1...expectedTickCount).map(Int64.init)

        #expect(observedTickIDs == expectedTickIDs, "Replay tick stream should be strictly [1...maxTickId]")
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
    case exportedJsonlMissingTickObject
    case exportedJsonlLineIsNotObject
}

private func readFirstJsonlLine(from fileURL: URL) throws -> [String: Any] {
    let text = try String(contentsOf: fileURL, encoding: .utf8)
    let lines = text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)

    for line in lines {
        let data = Data(line.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let lineObject = object as? [String: Any] else {
            throw ReevaluationReplayCompatibilityTestError.exportedJsonlLineIsNotObject
        }

        if lineObject["tickId"] != nil {
            return lineObject
        }
    }

    throw ReevaluationReplayCompatibilityTestError.exportedJsonlMissingTickObject
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
