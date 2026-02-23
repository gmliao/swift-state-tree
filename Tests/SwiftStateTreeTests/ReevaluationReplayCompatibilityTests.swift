import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeReevaluationMonitor

@Suite("ReevaluationReplayCompatibilityTests")
struct ReevaluationReplayCompatibilityTests {
    @Test("Replay projection emits Hero Defense-compatible live state fields")
    func replayProjectionStateShapeParityContract() throws {
        let snapshotObject: [String: Any] = [
            "players": [
                "p1": [
                    "position": ["x": 10, "y": 20],
                    "health": 99,
                    "maxHealth": 100,
                ],
            ],
            "monsters": [
                "1": [
                    "id": 1,
                    "position": ["x": 10, "y": 20],
                ],
            ],
            "turrets": [
                "1": [
                    "id": 1,
                    "position": ["x": 5, "y": 6],
                ],
            ],
            "base": ["health": 100, "maxHealth": 100],
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

        let projectedPlayers = projected.stateObject["players"]?.base as? [String: Any]
        let projectedPlayerP1 = projectedPlayers?["p1"] as? [String: Any]
        #expect(projectedPlayerP1?["position"] as? [String: Any] != nil)

        let projectedMonsters = projected.stateObject["monsters"]?.base as? [String: Any]
        let projectedMonster = projectedMonsters?["1"] as? [String: Any]
        #expect(projectedMonster?["position"] as? [String: Any] != nil)

        let projectedTurrets = projected.stateObject["turrets"]?.base as? [String: Any]
        let projectedTurret = projectedTurrets?["1"] as? [String: Any]
        #expect(projectedTurret?["position"] as? [String: Any] != nil)

        let projectedBase = projected.stateObject["base"]?.base as? [String: Any]
        #expect(projectedBase?["health"] as? Int == 100)
        #expect(projected.stateObject["score"]?.base as? Int == 123)
    }

    @Test("Replay projection filters wrapped artifacts per-entity and keeps valid values fields")
    func replayProjectionLegacyWrappedShapeContract() throws {
        let snapshotObject: [String: Any] = [
            "values": [
                "players": [
                    "p1": [
                        "base": [
                            "position": ["x": 10, "y": 20],
                            "health": 99,
                        ],
                    ],
                    "p2": [
                        "position": ["x": 30, "y": 40],
                        "health": 80,
                    ],
                ],
                "monsters": ["1": ["position": ["x": 10, "y": 20]]],
                "turrets": ["1": ["position": ["x": 5, "y": 6]]],
                "base": ["base": ["health": 100, "maxHealth": 100]],
                "score": 7,
            ],
            "currentStateJSON": "legacy-replay-only",
        ]
        let snapshotJSONString = try encodeJSONObjectToString(snapshotObject)
        let stepResult = ReevaluationStepResult(
            tickId: 9,
            stateHash: "hash-9",
            recordedHash: "hash-9",
            isMatch: true,
            actualState: AnyCodable(snapshotJSONString)
        )

        let projector = HeroDefenseReplayProjector()
        let projected = try projector.project(stepResult)

        #expect(projected.tickID == 9)
        #expect(projected.stateObject["players"] != nil)
        #expect(projected.stateObject["monsters"] != nil)
        #expect(projected.stateObject["turrets"] != nil)
        #expect(projected.stateObject["base"] == nil)
        #expect(projected.stateObject["score"]?.base as? Int == 7)
        #expect(projected.stateObject["currentStateJSON"] == nil)

        let projectedPlayers = projected.stateObject["players"]?.base as? [String: Any]
        #expect(projectedPlayers?["p1"] == nil)
        #expect((projectedPlayers?["p2"] as? [String: Any])?["position"] as? [String: Any] != nil)

        let projectedMonsters = projected.stateObject["monsters"]?.base as? [String: Any]
        let projectedTurrets = projected.stateObject["turrets"]?.base as? [String: Any]
        #expect((projectedMonsters?["1"] as? [String: Any])?["position"] as? [String: Any] != nil)
        #expect((projectedTurrets?["1"] as? [String: Any])?["position"] as? [String: Any] != nil)
    }

    @Test("Replay projection keeps emitted server events for visual effects")
    func replayProjectionIncludesEmittedServerEventsContract() throws {
        let snapshotJSONString = try encodeJSONObjectToString(["score": 1])
        let playerShootPayload: [String: Any] = [
            "from": ["v": ["x": 1000, "y": 2000]],
            "to": ["v": ["x": 3000, "y": 4000]],
            "playerID": ["rawValue": "p1"],
        ]
        let emittedEvent = ReevaluationRecordedServerEvent(
            kind: "serverEvent",
            sequence: 1,
            tickId: 7,
            typeIdentifier: "PlayerShoot",
            payload: AnyCodable(playerShootPayload),
            target: ReevaluationEventTargetRecord(kind: "all", ids: [])
        )
        let stepResult = ReevaluationStepResult(
            tickId: 7,
            stateHash: "hash-7",
            recordedHash: "hash-7",
            isMatch: true,
            actualState: AnyCodable(snapshotJSONString),
            emittedServerEvents: [emittedEvent]
        )

        let projector = HeroDefenseReplayProjector()
        let projected = try projector.project(stepResult)

        #expect(projected.serverEvents.count == 1)
        let eventObject = projected.serverEvents.first?.base as? [String: Any]
        #expect(eventObject?["typeIdentifier"] as? String == "PlayerShoot")
        let payloadWrapped = eventObject?["payload"] as? AnyCodable
        let payload = payloadWrapped?.base as? [String: Any]
        let from = payload?["from"] as? [String: Any]
        #expect(from != nil)
    }

    @Test("Replay projection keeps emitted TurretFire events for turret effects")
    func replayProjectionIncludesTurretFireEventsContract() throws {
        let snapshotJSONString = try encodeJSONObjectToString(["score": 1])
        let turretFirePayload: [String: Any] = [
            "turretID": 2,
            "from": ["v": ["x": 1000, "y": 2000]],
            "to": ["v": ["x": 3000, "y": 4000]],
        ]
        let emittedEvent = ReevaluationRecordedServerEvent(
            kind: "serverEvent",
            sequence: 2,
            tickId: 8,
            typeIdentifier: "TurretFire",
            payload: AnyCodable(turretFirePayload),
            target: ReevaluationEventTargetRecord(kind: "all", ids: [])
        )
        let stepResult = ReevaluationStepResult(
            tickId: 8,
            stateHash: "hash-8",
            recordedHash: "hash-8",
            isMatch: true,
            actualState: AnyCodable(snapshotJSONString),
            emittedServerEvents: [emittedEvent]
        )

        let projector = HeroDefenseReplayProjector()
        let projected = try projector.project(stepResult)

        #expect(projected.serverEvents.count == 1)
        let eventObject = projected.serverEvents.first?.base as? [String: Any]
        #expect(eventObject?["typeIdentifier"] as? String == "TurretFire")
        let payloadWrapped = eventObject?["payload"] as? AnyCodable
        let payload = payloadWrapped?.base as? [String: Any]
        #expect(payload?["turretID"] as? Int == 2)
    }

    @Test("ReevaluationEventTargetRecord round-trip to EventTarget")
    func reevaluationEventTargetRecordToEventTargetRoundTrip() {
        // .all
        let allRecord = ReevaluationEventTargetRecord(kind: "all", ids: [])
        if case .all = allRecord.toEventTarget() { } else { Issue.record("Expected .all") }

        // .player
        let playerRecord = ReevaluationEventTargetRecord(kind: "player", ids: ["player-uuid-1"])
        if case .player(let pid) = playerRecord.toEventTarget() {
            #expect(pid.rawValue == "player-uuid-1")
        } else {
            Issue.record("Expected .player(PlayerID)")
        }

        // .players
        let playersRecord = ReevaluationEventTargetRecord(kind: "players", ids: ["a", "b"])
        if case .players(let pids) = playersRecord.toEventTarget() {
            #expect(pids.count == 2)
            #expect(pids[0].rawValue == "a")
            #expect(pids[1].rawValue == "b")
        } else {
            Issue.record("Expected .players([PlayerID])")
        }

        // .client
        let clientRecord = ReevaluationEventTargetRecord(kind: "client", ids: ["client-device-1"])
        if case .client(let cid) = clientRecord.toEventTarget() {
            #expect(cid.rawValue == "client-device-1")
        } else {
            Issue.record("Expected .client(ClientID)")
        }

        // .session
        let sessionRecord = ReevaluationEventTargetRecord(kind: "session", ids: ["session-conn-1"])
        if case .session(let sid) = sessionRecord.toEventTarget() {
            #expect(sid.rawValue == "session-conn-1")
        } else {
            Issue.record("Expected .session(SessionID)")
        }

        // Round-trip: EventTarget -> Record -> toEventTarget() (compare by pattern + values)
        let allBack = ReevaluationEventTargetRecord.from(EventTarget.all).toEventTarget()
        if case .all = allBack { } else { Issue.record("Round-trip .all failed") }

        let playerBack = ReevaluationEventTargetRecord.from(EventTarget.player(PlayerID("p1"))).toEventTarget()
        if case .player(let p) = playerBack { #expect(p.rawValue == "p1") } else { Issue.record("Round-trip .player failed") }

        let playersBack = ReevaluationEventTargetRecord.from(EventTarget.players([PlayerID("p1"), PlayerID("p2")])).toEventTarget()
        if case .players(let ps) = playersBack {
            #expect(ps.count == 2 && ps[0].rawValue == "p1" && ps[1].rawValue == "p2")
        } else { Issue.record("Round-trip .players failed") }

        let clientBack = ReevaluationEventTargetRecord.from(EventTarget.client(ClientID("c1"))).toEventTarget()
        if case .client(let c) = clientBack { #expect(c.rawValue == "c1") } else { Issue.record("Round-trip .client failed") }

        let sessionBack = ReevaluationEventTargetRecord.from(EventTarget.session(SessionID("s1"))).toEventTarget()
        if case .session(let s) = sessionBack { #expect(s.rawValue == "s1") } else { Issue.record("Round-trip .session failed") }

        // Unknown kind or empty ids fallback to .all
        let unknownRecord = ReevaluationEventTargetRecord(kind: "unknown", ids: ["x"])
        if case .all = unknownRecord.toEventTarget() { } else { Issue.record("Unknown kind should fallback to .all") }
        let playerEmptyIds = ReevaluationEventTargetRecord(kind: "player", ids: [])
        if case .all = playerEmptyIds.toEventTarget() { } else { Issue.record("Empty player ids should fallback to .all") }
    }

    @Test("ReevaluationStepResult recordedServerEvents preserved when projector runs")
    func reevaluationStepResultRecordedServerEventsPreserved() throws {
        let recordedEvent = ReevaluationRecordedServerEvent(
            kind: "serverEvent",
            sequence: 1,
            tickId: 70,
            typeIdentifier: "PlayerShoot",
            payload: AnyCodable(["from": ["v": ["x": 39867, "y": 38980]], "to": ["v": ["x": 20336, "y": 41028]], "playerID": ["rawValue": "EF198066-1074-431F-89D0-EA29F257D50C"]]),
            target: ReevaluationEventTargetRecord(kind: "all", ids: [])
        )
        let result = ReevaluationStepResult(
            tickId: 70,
            stateHash: "abc",
            recordedHash: "abc",
            isMatch: true,
            actualState: AnyCodable(try encodeJSONObjectToString(["score": 0])),
            emittedServerEvents: [],
            recordedServerEvents: [recordedEvent]
        )
        let projector = HeroDefenseReplayProjector()
        let projected = try projector.project(result)
        #expect(projected.serverEvents.count == 0)
        #expect(result.recordedServerEvents.count == 1)
        #expect(result.recordedServerEvents.first?.typeIdentifier == "PlayerShoot")
    }

    @Test("Replay projection keeps arbitrary emitted server event envelopes")
    func replayProjectionPassesThroughArbitraryServerEventEnvelopeContract() throws {
        let snapshotJSONString = try encodeJSONObjectToString(["score": 1])
        let customPayload: [String: Any] = [
            "label": "fx",
            "count": 3,
        ]
        let emittedEvent = ReevaluationRecordedServerEvent(
            kind: "serverEvent",
            sequence: 3,
            tickId: 10,
            typeIdentifier: "CustomFx",
            payload: AnyCodable(customPayload),
            target: ReevaluationEventTargetRecord(kind: "all", ids: [])
        )
        let stepResult = ReevaluationStepResult(
            tickId: 10,
            stateHash: "hash-10",
            recordedHash: "hash-10",
            isMatch: true,
            actualState: AnyCodable(snapshotJSONString),
            emittedServerEvents: [emittedEvent]
        )

        let projector = HeroDefenseReplayProjector()
        let projected = try projector.project(stepResult)

        #expect(projected.serverEvents.count == 1)
        let eventObject = projected.serverEvents.first?.base as? [String: Any]
        #expect(eventObject?["typeIdentifier"] as? String == "CustomFx")
        let payloadWrapped = eventObject?["payload"] as? AnyCodable
        let payload = payloadWrapped?.base as? [String: Any]
        #expect(payload?["label"] as? String == "fx")
        #expect(payload?["count"] as? Int == 3)
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

    @Test("Replay runner rejects missing schema in strict mode deterministically")
    func missingSchemaMismatchGuardContract() async throws {
        let definition = makeReevaluationEngineTestDefinition()
        let recordingFile = try await createRecordingFile(
            definition: definition,
            landID: "reeval-schema-missing-contract:local",
            metadataLandDefinitionID: nil,
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
            Issue.record("Expected schema mismatch error for missing record schema, but replay run succeeded")
        } catch {
            #expect(
                hasSchemaMismatchErrorSignature(error),
                "Missing record schema should fail with deterministic schema mismatch signature"
            )
            guard case let .schemaMismatch(expected, recorded)? = (error as? ReevaluationReplayCompatibilityError) else {
                Issue.record("Expected ReevaluationReplayCompatibilityError.schemaMismatch")
                return
            }
            #expect(expected == definition.id)
            #expect(recorded == nil)
        }
    }

    @Test("Replay runner rejects land type mismatch deterministically")
    func landTypeMismatchGuardContract() async throws {
        let definition = makeReevaluationEngineTestDefinition()
        let recordingFile = try await createRecordingFile(
            definition: definition,
            landID: "reeval-landtype-contract:local",
            metadataLandType: "other-land-type",
            metadataLandDefinitionID: definition.id,
            actions: [1]
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
            Issue.record("Expected landType mismatch error, but replay run succeeded")
        } catch {
            #expect(
                hasLandTypeMismatchErrorSignature(error),
                "Land type mismatch should fail with deterministic error signature (domain/code)"
            )
            guard case let .landTypeMismatch(expected, actual)? = (error as? ReevaluationReplayCompatibilityError) else {
                Issue.record("Expected ReevaluationReplayCompatibilityError.landTypeMismatch")
                return
            }
            #expect(expected == definition.id)
            #expect(actual == "other-land-type")
        }
    }

    @Test("Replay runner rejects record version mismatch deterministically")
    func recordVersionMismatchGuardContract() async throws {
        let definition = makeReevaluationEngineTestDefinition()
        let recordingFile = try await createRecordingFile(
            definition: definition,
            landID: "reeval-version-contract:local",
            metadataLandDefinitionID: definition.id,
            metadataVersion: "1.0",
            actions: [1]
        )

        defer {
            try? FileManager.default.removeItem(at: recordingFile)
        }

        do {
            _ = try await ConcreteReevaluationRunner(
                definition: definition,
                initialState: ReevaluationEngineTestState(),
                recordFilePath: recordingFile.path,
                requiredRecordVersion: "2.0"
            )
            Issue.record("Expected record version mismatch error, but replay run succeeded")
        } catch {
            #expect(
                hasRecordVersionMismatchErrorSignature(error),
                "Record version mismatch should fail with deterministic error signature (domain/code)"
            )
            guard case let .recordVersionMismatch(expected, recorded)? = (error as? ReevaluationReplayCompatibilityError) else {
                Issue.record("Expected ReevaluationReplayCompatibilityError.recordVersionMismatch")
                return
            }
            #expect(expected == "2.0")
            #expect(recorded == "1.0")
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

    let nsError = compatibilityError as NSError
    let hasExpectedNSErrorSignature =
        nsError.domain == ReevaluationReplayCompatibilityError.errorDomain &&
        nsError.code == 2002

    guard hasExpectedNSErrorSignature else {
        return false
    }

    if case .schemaMismatch = compatibilityError {
        return true
    }
    return false
}

private func hasLandTypeMismatchErrorSignature(_ error: Error) -> Bool {
    guard let compatibilityError = error as? ReevaluationReplayCompatibilityError else {
        return false
    }

    let nsError = compatibilityError as NSError
    let hasExpectedNSErrorSignature =
        nsError.domain == ReevaluationReplayCompatibilityError.errorDomain &&
        nsError.code == 2001

    guard hasExpectedNSErrorSignature else {
        return false
    }

    if case .landTypeMismatch = compatibilityError {
        return true
    }
    return false
}

private func hasRecordVersionMismatchErrorSignature(_ error: Error) -> Bool {
    guard let compatibilityError = error as? ReevaluationReplayCompatibilityError else {
        return false
    }

    let nsError = compatibilityError as NSError
    let hasExpectedNSErrorSignature =
        nsError.domain == ReevaluationReplayCompatibilityError.errorDomain &&
        nsError.code == 2003

    guard hasExpectedNSErrorSignature else {
        return false
    }

    if case .recordVersionMismatch = compatibilityError {
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
    metadataLandType: String? = nil,
    metadataLandDefinitionID: String?,
    metadataVersion: String = "1.0",
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
        landType: metadataLandType ?? definition.id,
        createdAt: stableFixtureDate,
        metadata: [:],
        landDefinitionID: metadataLandDefinitionID,
        initialStateHash: nil,
        landConfig: ["autoStartLoops": AnyCodable(false)],
        rngSeed: expectedSeed,
        ruleVariantId: nil,
        ruleParams: nil,
        version: metadataVersion,
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
