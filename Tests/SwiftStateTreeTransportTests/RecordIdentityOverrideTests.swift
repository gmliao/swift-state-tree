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
    // The manager keeps the land until its drain: the suite's trait drains it (#910).
    FixtureKeepers.register(container.keeper)
    let recorder = try #require(await container.keeper.getReevaluationRecorder())
    return try await firstSerializedHeader(recorder)
}

/// The metadata of the first header written to the record file: a later header would replace it
/// on read, so reading the recorder's current metadata could hide a wrong first one.
private func firstSerializedHeader(_ recorder: ReevaluationRecorder) async throws -> ReevaluationRecordMetadata {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-identity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("record.sstr").path
    try await recorder.saveCopyForTesting(to: path)
    let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: path)))
    let start = ReevaluationRecordLog.preamble.count
    try #require(ReevaluationRecordLog.hasMagic(bytes) && bytes.count > start + 4)
    let length = Int(bytes[start]) << 24 | Int(bytes[start + 1]) << 16 | Int(bytes[start + 2]) << 8 | Int(bytes[start + 3])
    try #require(bytes.count >= start + 4 + length, "the header record is whole")
    let body = Array(bytes[(start + 4)..<(start + 4 + length)])
    let record = try CanonicalMessagePack.decode(ReevaluationLogRecord.self, from: body)
    #expect(record.kind == .header, "the first record is the header")
    return try #require(record.metadata)
}

@Suite("Record-identity override (#555)", .drainsFixtureKeepers)
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
        // The record keeps whole seconds.
        #expect(metadata.createdAt.timeIntervalSince1970 >= before.timeIntervalSince1970 - 1)
        #expect(metadata.hardwareInfo != nil)
    }
}
