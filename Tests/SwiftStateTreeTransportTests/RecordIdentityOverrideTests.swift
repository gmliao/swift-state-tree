// Tests/SwiftStateTreeTransportTests/RecordIdentityOverrideTests.swift
//
// The record-identity override (#555): a land built after the override writes the pinned
// `createdAt` and no hardware info into its record's metadata, so records from different
// processes and machines have the same bytes. Without it, the wall clock and this machine.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct RecordIdentityState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
}

private func makeManager() -> LandManager<RecordIdentityState> {
    let definition = Land("record-identity", using: RecordIdentityState.self) { Rules {} }
    return LandManager<RecordIdentityState>(
        landFactory: { _ in definition },
        initialStateFactory: { _ in RecordIdentityState() },
        enableLiveStateHashRecording: true,
        syncLagPolicy: nil,
        autoStartLoops: false
    )
}

private func recordedMetadata(
    _ manager: LandManager<RecordIdentityState>, instance: String
) async throws -> ReevaluationRecordMetadata {
    let definition = Land("record-identity", using: RecordIdentityState.self) { Rules {} }
    let container = try await manager.getOrCreateLand(
        landID: LandID(landType: "record-identity", instanceId: instance),
        definition: definition, initialState: RecordIdentityState(), metadata: [:]
    )
    let recorder = try #require(await container.keeper.getReevaluationRecorder())
    return try #require(await recorder.getMetadata())
}

@Suite("Record-identity override (#555)")
struct RecordIdentityOverrideTests {
    @Test("A land built after the override records the pinned createdAt and no hardware info")
    func overridePinsIdentity() async throws {
        let manager = makeManager()
        let pinned = Date(timeIntervalSince1970: 1_800_000_000)
        await manager.setRecordIdentityForTesting(.init(createdAt: pinned, hardwareInfo: nil))
        let metadata = try await recordedMetadata(manager, instance: "pinned")
        #expect(metadata.createdAt == pinned)
        #expect(metadata.hardwareInfo == nil)
    }

    @Test("Without the override, the wall clock and this machine")
    func defaultIsLive() async throws {
        let manager = makeManager()
        let before = Date()
        let metadata = try await recordedMetadata(manager, instance: "live")
        #expect(metadata.createdAt >= before)
        #expect(metadata.hardwareInfo != nil)
    }
}
