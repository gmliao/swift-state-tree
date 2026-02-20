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
        let recordFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("land-manager-reeval-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: recordFile) }

        let metadata = ReevaluationRecordMetadata(
            landID: "test-replay:local",
            landType: "test-replay",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            landDefinitionID: "test-replay",
            version: "1.0"
        )
        let frame = ReevaluationTickFrame(
            tickId: 0,
            actions: [],
            clientEvents: [],
            lifecycleEvents: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let recordData = try encoder.encode(ReevaluationRecordFile(
            recordMetadata: metadata,
            tickFrames: [frame]
        ))
        try recordData.write(to: recordFile)

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
}

private struct ReevaluationRecordFile: Codable {
    let recordMetadata: ReevaluationRecordMetadata
    let tickFrames: [ReevaluationTickFrame]
}
