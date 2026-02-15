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

    @Test("Replay runner pipeline preserves tick ordering through service queue")
    func replayRunnerPipelineOrderingContract() async throws {
        let orderedTickIDs: [Int64] = [1, 2, 3, 4]
        let results = try orderedTickIDs.map { tickID in
            let jsonText = try encodeJSONObjectToString(["score": Int(tickID)])
            return ReevaluationStepResult(
                tickId: tickID,
                stateHash: "hash-\(tickID)",
                recordedHash: "hash-\(tickID)",
                isMatch: true,
                actualState: AnyCodable(jsonText)
            )
        }
        let runner = ScriptedRunner(results: results)
        let factory = ScriptedFactory(runner: runner)
        let service = ReevaluationRunnerService(
            factory: factory,
            projectorResolver: { _ in HeroDefenseReplayProjector() }
        )

        service.startVerification(landType: "ordering-contract", recordFilePath: "/tmp/record.json")
        try await waitForTerminalStatus(of: service)

        let queuedTickIDs = service.consumeResults().map(\.tickId)
        #expect(queuedTickIDs == orderedTickIDs)
        #expect(service.getStatus().phase == .completed)
    }

    @Test("Projector failure terminates replay run without completion overwrite")
    func projectorFailureTerminatesRunDeterministically() async throws {
        let results = [
            ReevaluationStepResult(
                tickId: 1,
                stateHash: "hash-1",
                recordedHash: "hash-1",
                isMatch: true,
                actualState: AnyCodable("{}")
            ),
            ReevaluationStepResult(
                tickId: 2,
                stateHash: "hash-2",
                recordedHash: "hash-2",
                isMatch: true,
                actualState: AnyCodable("{}")
            ),
        ]
        let runner = ScriptedRunner(results: results)
        let factory = ScriptedFactory(runner: runner)
        let service = ReevaluationRunnerService(
            factory: factory,
            projectorResolver: { _ in FailingProjector() }
        )

        service.startVerification(landType: "failure-contract", recordFilePath: "/tmp/record.json")
        try await waitForTerminalStatus(of: service)

        let terminalStatus = service.getStatus()
        #expect(terminalStatus.phase == .failed)
        #expect(!terminalStatus.errorMessage.isEmpty)
        #expect(service.consumeResults().isEmpty)
        #expect(await runner.getStepCalls() == 1)

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(service.getStatus().phase == .failed)
    }

    @Test("Monitor land keeps terminal failed status when projector fails")
    func monitorLandFailureStatusIsTerminalContract() async throws {
        let results = [
            ReevaluationStepResult(
                tickId: 1,
                stateHash: "hash-1",
                recordedHash: "hash-1",
                isMatch: true,
                actualState: AnyCodable("{}")
            ),
        ]
        let runner = ScriptedRunner(results: results)
        let factory = ScriptedFactory(runner: runner)
        let service = ReevaluationRunnerService(
            factory: factory,
            projectorResolver: { _ in FailingProjector() }
        )

        var services = LandServices()
        services.register(service, as: ReevaluationRunnerService.self)

        let keeper = LandKeeper<ReevaluationMonitorState>(
            definition: ReevaluationMonitor.makeLand(),
            initialState: ReevaluationMonitorState(),
            services: services,
            autoStartLoops: false
        )

        let playerID = PlayerID("monitor-player")
        let clientID = ClientID("monitor-client")
        let sessionID = SessionID("monitor-session")
        try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)

        let startAction = StartVerificationAction(
            landType: "hero-defense",
            recordFilePath: "/tmp/replay-monitor-contract.json"
        )
        let startEnvelope = ActionEnvelope(
            typeIdentifier: String(describing: StartVerificationAction.self),
            payload: AnyCodable(startAction)
        )
        _ = try await keeper.handleActionEnvelope(
            startEnvelope,
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID
        )

        let failedState = try await waitForTerminalMonitorState(of: keeper)
        #expect(monitorStateStatus(from: failedState) == ReevaluationStatus.Phase.failed.rawValue)
        #expect(!(monitorStateErrorMessage(from: failedState) ?? "").isEmpty)

        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        let finalState = await keeper.currentState()
        #expect(monitorStateStatus(from: finalState) == ReevaluationStatus.Phase.failed.rawValue)
        #expect(!(monitorStateErrorMessage(from: finalState) ?? "").isEmpty)
        #expect(await runner.getStepCalls() == 1)
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
            _ = try await ConcreteReevaluationRunner(
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
    guard let compatibilityError = error as? ReevaluationReplayCompatibilityError else {
        return false
    }

    if case .schemaMismatch = compatibilityError {
        return true
    }
    return false
}

private func hasSchemaMismatchContext(
    _ error: Error,
    expectedRecordedLandDefinitionID: String,
    expectedRuntimeLandDefinitionID: String
) -> Bool {
    guard case let .schemaMismatch(runtimeID, recordedID)? = (error as? ReevaluationReplayCompatibilityError) else {
        return false
    }

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

private final class ScriptedFactory: ReevaluationTargetFactory, @unchecked Sendable {
    private let runner: ScriptedRunner

    init(runner: ScriptedRunner) {
        self.runner = runner
    }

    func createRunner(landType _: String, recordFilePath _: String) async throws -> any ReevaluationRunnerProtocol {
        runner
    }
}

private actor ScriptedRunner: ReevaluationRunnerProtocol {
    nonisolated let maxTickId: Int64
    private let results: [ReevaluationStepResult]
    private var index = 0
    private var stepCalls = 0

    init(results: [ReevaluationStepResult]) {
        self.results = results
        self.maxTickId = results.last?.tickId ?? 0
    }

    func prepare() async throws {}

    func step() async throws -> ReevaluationStepResult? {
        stepCalls += 1
        guard index < results.count else {
            return nil
        }

        let result = results[index]
        index += 1
        return result
    }

    func getStepCalls() -> Int {
        stepCalls
    }
}

private struct FailingProjector: ReevaluationReplayProjecting {
    enum Failure: Error {
        case projectionFailed
    }

    func project(_ result: ReevaluationStepResult) throws -> ProjectedReplayFrame {
        _ = result
        throw Failure.projectionFailed
    }
}

private func waitForTerminalStatus(
    of service: ReevaluationRunnerService,
    timeoutNanoseconds: UInt64 = 2_000_000_000
) async throws {
    let start = DispatchTime.now().uptimeNanoseconds

    while true {
        let phase = service.getStatus().phase
        if phase == .completed || phase == .failed {
            return
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        if elapsed > timeoutNanoseconds {
            Issue.record("Timed out waiting for terminal status, phase=\(phase.rawValue)")
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private func waitForTerminalMonitorState(
    of keeper: LandKeeper<ReevaluationMonitorState>,
    timeoutNanoseconds: UInt64 = 2_000_000_000
) async throws -> ReevaluationMonitorState {
    let start = DispatchTime.now().uptimeNanoseconds

    while true {
        await keeper.stepTickOnce()
        let state = await keeper.currentState()
        let status = monitorStateStatus(from: state) ?? ""
        if status == ReevaluationStatus.Phase.completed.rawValue || status == ReevaluationStatus.Phase.failed.rawValue {
            return state
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        if elapsed > timeoutNanoseconds {
            Issue.record("Timed out waiting for monitor terminal status, status=\(status)")
            return state
        }

        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private func monitorStateStatus(from state: ReevaluationMonitorState) -> String? {
    monitorStateSnapshotValue(from: state, key: "status")?.stringValue
}

private func monitorStateErrorMessage(from state: ReevaluationMonitorState) -> String? {
    monitorStateSnapshotValue(from: state, key: "errorMessage")?.stringValue
}

private func monitorStateSnapshotValue(from state: ReevaluationMonitorState, key: String) -> SnapshotValue? {
    (try? state.broadcastSnapshot(dirtyFields: nil))?.values[key]
}

private let stableFixtureDate = Date(timeIntervalSince1970: 1_700_000_000)

private func stableFixtureFileURL(prefix: String, identifier: String, ext: String) -> URL {
    let safeIdentifier = identifier.replacingOccurrences(of: ":", with: "-")
    return FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(safeIdentifier).\(ext)")
}
