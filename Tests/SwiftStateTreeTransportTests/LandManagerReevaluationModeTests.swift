// Tests/SwiftStateTreeTransportTests/LandManagerReevaluationModeTests.swift
//
// Tests for dynamic keeper mode resolver - live vs reevaluation

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct ReevaluationModeTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0

    public init() {}
}

/// A nested value with required fields and no `@SnapshotConvertible`: the record schema
/// fingerprint can't list its fields.
struct ReevaluationModeOpaque: Codable, Sendable {
    let x: Int
}

@Payload
struct ReevaluationModeOpaqueEvent: ServerEventPayload {
    let inner: ReevaluationModeOpaque
}

// MARK: - Tests

@Suite("LandManager Reevaluation Mode Tests")
struct LandManagerReevaluationModeTests {

    @Test("Live land instances use .live keeper mode")
    func liveLandUsesLiveKeeperMode() async throws {
        let landFactory: @Sendable (LandID) -> LandDefinition<ReevaluationModeTestState> = { landID in
            Land(landID.stringValue, using: ReevaluationModeTestState.self) {
                Rules {}
            }
        }
        let initialStateFactory: @Sendable (LandID) -> ReevaluationModeTestState = { _ in
            ReevaluationModeTestState()
        }

        let manager = LandManager<ReevaluationModeTestState>(
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            keeperModeResolver: nil
        )

        let landID = LandID("test-live:instance-1")
        let definition = landFactory(landID)
        let initialState = initialStateFactory(landID)

        let container = try await manager.getOrCreateLand(
            landID: landID,
            definition: definition,
            initialState: initialState,
            metadata: [:]
        )

        let mode = await container.keeper.getMode()
        #expect(mode == .live)
    }

    @Test("Replay instances use .reevaluation keeper mode and source file path")
    func replayInstancesUseReevaluationMode() async throws {
        let landFactory: @Sendable (LandID) -> LandDefinition<ReevaluationModeTestState> = { landID in
            Land(landID.landType, using: ReevaluationModeTestState.self) {
                Rules {}
            }
        }
        let recordFile = try writeModeRecord(
            version: ReevaluationRecordVersion.current,
            schemaFingerprint: try ReevaluationSchemaFingerprint.compute(for: landFactory(LandID(landType: "test-replay", instanceId: "x")))
        )
        defer { try? FileManager.default.removeItem(at: recordFile) }
        let initialStateFactory: @Sendable (LandID) -> ReevaluationModeTestState = { _ in
            ReevaluationModeTestState()
        }

        let manager = LandManager<ReevaluationModeTestState>(
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            keeperModeResolver: { landID, _ in
                if landID.landType.hasSuffix("-replay") {
                    return .reevaluation(recordFilePath: recordFile.path)
                }
                return nil
            }
        )

        let landID = LandID(landType: "test-replay", instanceId: "instance-1")
        let definition = landFactory(landID)
        let initialState = initialStateFactory(landID)

        let container = try await manager.getOrCreateLand(
            landID: landID,
            definition: definition,
            initialState: initialState,
            metadata: [:]
        )

        let mode = await container.keeper.getMode()
        #expect(mode == .reevaluation)
    }

    @Test("A replay keeper on a record older than 2.5 is not created: the source rejects it (#154)")
    func replayKeeperRejectsUnsupportedRecord() async throws {
        let recordFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("land-manager-reeval-old-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: recordFile) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ReevaluationRecordFile(
            recordMetadata: ReevaluationRecordMetadata(
                landID: "test-replay:local",
                landType: "test-replay",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                metadata: [:],
                landDefinitionID: "test-replay",
                version: "2.4"
            ),
            tickFrames: [ReevaluationTickFrame(tickId: 0, actions: [], clientEvents: [], lifecycleEvents: [])]
        )).write(to: recordFile)

        let landFactory: @Sendable (LandID) -> LandDefinition<ReevaluationModeTestState> = { landID in
            Land(landID.stringValue, using: ReevaluationModeTestState.self) {
                Rules {}
            }
        }
        let manager = LandManager<ReevaluationModeTestState>(
            landFactory: landFactory,
            initialStateFactory: { _ in ReevaluationModeTestState() },
            keeperModeResolver: { _, _ in .reevaluation(recordFilePath: recordFile.path) }
        )
        let landID = LandID(landType: "test-replay", instanceId: "instance-old")
        await #expect(throws: ReevaluationRecordVersionError.unsupported(recorded: "2.4", minimum: "2.5")) {
            _ = try await manager.getOrCreateLand(
                landID: landID,
                definition: landFactory(landID),
                initialState: ReevaluationModeTestState(),
                metadata: [:]
            )
        }
    }

    @Test("A replay keeper is not created on a record without the land's schema fingerprint: none, or another (#521 D15)")
    func replayKeeperChecksFingerprint() async throws {
        let landFactory: @Sendable (LandID) -> LandDefinition<ReevaluationModeTestState> = { landID in
            Land(landID.landType, using: ReevaluationModeTestState.self) { Rules {} }
        }
        let landID = LandID(landType: "test-replay", instanceId: "fingerprint")
        let current = try ReevaluationSchemaFingerprint.compute(for: landFactory(landID))
        let cases: [(String?, ReevaluationRecordFingerprintError)] = [
            (nil, .missing(recordedVersion: ReevaluationRecordVersion.current)),
            ("0123456789abcdef", .mismatch(recorded: "0123456789abcdef", current: current)),
        ]
        for (recorded, expected) in cases {
            let recordFile = try writeModeRecord(version: ReevaluationRecordVersion.current, schemaFingerprint: recorded)
            defer { try? FileManager.default.removeItem(at: recordFile) }
            let manager = LandManager<ReevaluationModeTestState>(
                landFactory: landFactory,
                initialStateFactory: { _ in ReevaluationModeTestState() },
                keeperModeResolver: { _, _ in .reevaluation(recordFilePath: recordFile.path) }
            )
            await #expect(throws: expected) {
                _ = try await manager.getOrCreateLand(
                    landID: landID,
                    definition: landFactory(landID),
                    initialState: ReevaluationModeTestState(),
                    metadata: [:]
                )
            }
            #expect(await manager.listLands().isEmpty)
        }
    }

    @Test("A replay definition named by the replay alias checks a record against the recorded definition's fingerprint (#521 D15)")
    func replayAliasDefinitionChecksLiveFingerprint() async throws {
        // The factory names each definition by its land type, the replay land's too.
        let landFactory: @Sendable (LandID) -> LandDefinition<ReevaluationModeTestState> = { landID in
            Land(landID.landType, using: ReevaluationModeTestState.self) { Rules {} }
        }
        let live = try ReevaluationSchemaFingerprint.compute(for: landFactory(LandID(landType: "alias-game", instanceId: "live")))
        let replayID = LandID(landType: "alias-game-replay", instanceId: "replay-1")
        let alias = try ReevaluationSchemaFingerprint.compute(for: landFactory(replayID))
        #expect(alias != live, "the definition's id is part of the fingerprint")

        // A live recording holds the live type's fingerprint: the replay land is created.
        let liveRecord = try writeModeRecord(
            version: ReevaluationRecordVersion.current, schemaFingerprint: live, landDefinitionID: "alias-game"
        )
        defer { try? FileManager.default.removeItem(at: liveRecord) }
        let manager = LandManager<ReevaluationModeTestState>(
            landFactory: landFactory,
            initialStateFactory: { _ in ReevaluationModeTestState() },
            keeperModeResolver: { _, _ in .reevaluation(recordFilePath: liveRecord.path) }
        )
        let container = try await manager.getOrCreateLand(
            landID: replayID, definition: landFactory(replayID), initialState: ReevaluationModeTestState(), metadata: [:]
        )
        #expect(await container.keeper.getMode() == .reevaluation)

        // The alias definition's own value, which no live recording holds, is another schema.
        let aliasRecord = try writeModeRecord(
            version: ReevaluationRecordVersion.current, schemaFingerprint: alias, landDefinitionID: "alias-game"
        )
        defer { try? FileManager.default.removeItem(at: aliasRecord) }
        let refusing = LandManager<ReevaluationModeTestState>(
            landFactory: landFactory,
            initialStateFactory: { _ in ReevaluationModeTestState() },
            keeperModeResolver: { _, _ in .reevaluation(recordFilePath: aliasRecord.path) }
        )
        await #expect(throws: ReevaluationRecordFingerprintError.mismatch(recorded: alias, current: live)) {
            _ = try await refusing.getOrCreateLand(
                landID: replayID, definition: landFactory(replayID), initialState: ReevaluationModeTestState(), metadata: [:]
            )
        }
    }

    @Test("A recording manager refuses a land whose schema fingerprint can't be computed; one that doesn't record creates it (#521 D15)")
    func recordingManagerChecksFingerprint() async throws {
        let landFactory: @Sendable (LandID) -> LandDefinition<ReevaluationModeTestState> = { landID in
            Land(landID.landType, using: ReevaluationModeTestState.self) {
                ServerEvents { Register(ReevaluationModeOpaqueEvent.self) }
                Rules {}
            }
        }
        let landID = LandID(landType: "test-opaque", instanceId: "a")
        let recording = LandManager<ReevaluationModeTestState>(
            landFactory: landFactory,
            initialStateFactory: { _ in ReevaluationModeTestState() },
            enableLiveStateHashRecording: true
        )
        let error = try await #require(throws: LandRegistrationError.self) {
            _ = try await recording.getOrCreateLand(
                landID: landID, definition: landFactory(landID), initialState: ReevaluationModeTestState(), metadata: [:]
            )
        }
        #expect(error.schemaFingerprint == .unbuildableType("ReevaluationModeOpaque"))
        #expect(await recording.listLands().isEmpty)

        let notRecording = LandManager<ReevaluationModeTestState>(
            landFactory: landFactory,
            initialStateFactory: { _ in ReevaluationModeTestState() }
        )
        _ = try await notRecording.getOrCreateLand(
            landID: landID, definition: landFactory(landID), initialState: ReevaluationModeTestState(), metadata: [:]
        )
        #expect(await notRecording.listLands() == [landID])
    }

    @Test("Invalid replay session descriptor throws ReevaluationReplayError")
    func invalidReplaySessionThrowsReevaluationReplayError() async throws {
        let landFactory: @Sendable (LandID) -> LandDefinition<ReevaluationModeTestState> = { landID in
            Land(landID.stringValue, using: ReevaluationModeTestState.self) {
                Rules {}
            }
        }
        let initialStateFactory: @Sendable (LandID) -> ReevaluationModeTestState = { _ in
            ReevaluationModeTestState()
        }

        let manager = LandManager<ReevaluationModeTestState>(
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            keeperModeResolver: { landID, _ in
                if landID.landType == "test-replay" {
                    return .invalidReplaySession(message: "Invalid replay session descriptor for instanceId")
                }
                return nil
            }
        )

        let landID = LandID(landType: "test-replay", instanceId: "invalid-instance-id")
        let definition = landFactory(landID)
        let initialState = initialStateFactory(landID)

        do {
            _ = try await manager.getOrCreateLand(
                landID: landID,
                definition: definition,
                initialState: initialState,
                metadata: [:]
            )
            Issue.record("Expected ReevaluationReplayError to be thrown")
        } catch let error as ReevaluationReplayError {
            if case let .invalidSessionDescriptor(message) = error {
                #expect(message == "Invalid replay session descriptor for instanceId")
            } else {
                Issue.record("Expected invalidSessionDescriptor case, got \(error)")
            }
        } catch {
            Issue.record("Expected ReevaluationReplayError, got \(type(of: error)): \(error)")
        }
    }
}

/// A one-frame JSON record of `test-replay` at `version`, recorded with the definition `landDefinitionID`.
private func writeModeRecord(version: String, schemaFingerprint: String?, landDefinitionID: String = "test-replay") throws -> URL {
    let recordFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("land-manager-reeval-test-\(UUID().uuidString).json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(ReevaluationRecordFile(
        recordMetadata: ReevaluationRecordMetadata(
            landID: "test-replay:local",
            landType: "test-replay",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            landDefinitionID: landDefinitionID,
            version: version,
            schemaFingerprint: schemaFingerprint
        ),
        tickFrames: [ReevaluationTickFrame(tickId: 0, actions: [], clientEvents: [], lifecycleEvents: [])]
    )).write(to: recordFile)
    return recordFile
}

private struct ReevaluationRecordFile: Codable {
    let recordMetadata: ReevaluationRecordMetadata
    let tickFrames: [ReevaluationTickFrame]
}
