// Tests/SwiftStateTreeTransportTests/RecordHeaderPayloadEncodingTests.swift
//
// The record header's payload encoding (#700 K1a, C4): written once in the header, read back as
// written, absent in a record that didn't set it, and the adapter's value follows its codec.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct HeaderEncodingState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
}

private func headerEncodingLand() -> LandDefinition<HeaderEncodingState> {
    Land("header-encoding", using: HeaderEncodingState.self) {
        Rules {}
    }
}

/// A live keeper whose recorder gets `payloadEncoding` in its header, saved and read back.
private func savedHeader(payloadEncoding: RecordPayloadEncoding?) async throws -> ReevaluationRecordMetadata {
    let landID = "header-encoding:1"
    let keeper = LandKeeper<HeaderEncodingState>(
        definition: headerEncodingLand(),
        initialState: HeaderEncodingState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        landID: landID
    )
    await keeper.awaitInitialization()
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: landID,
        landType: "header-encoding",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        metadata: [:],
        landDefinitionID: "header-encoding",
        payloadEncoding: payloadEncoding
    ))
    await keeper.waitForRecorderSubmissionsForTesting()
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("header-encoding-\(UUID().uuidString).sstr").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    try await recorder.save(to: path)
    await keeper.forceShutdown()
    let source = try ReevaluationRecordFile.openSource(filePath: path)
    return try await source.getMetadata()
}

@Suite("The record header's payload encoding (#700 K1a)")
struct RecordHeaderPayloadEncodingTests {
    @Test("The header's payload encoding reads back as written", arguments: RecordPayloadEncoding.allCases)
    func readsBack(encoding: RecordPayloadEncoding) async throws {
        #expect(try await savedHeader(payloadEncoding: encoding).payloadEncoding == encoding)
    }

    @Test("A header without a payload encoding reads back without one")
    func absentReadsBackAbsent() async throws {
        #expect(try await savedHeader(payloadEncoding: nil).payloadEncoding == nil)
    }

    @Test("The adapter's payload encoding follows its codec's frames")
    func adapterFollowsCodec() async throws {
        for (config, expected) in [
            (TransportEncodingConfig.json, RecordPayloadEncoding.json),
            (.opcode, .json),
            (.messagepack, .messagepack),
        ] {
            let keeper = LandKeeper<HeaderEncodingState>(
                definition: headerEncodingLand(), initialState: HeaderEncodingState(), autoStartLoops: false, landID: "header-encoding:2"
            )
            let adapter = TransportAdapter<HeaderEncodingState>(
                keeper: keeper, transport: VerifierTransport(), landID: "header-encoding:2", encodingConfig: config
            )
            #expect(adapter.payloadEncodingForRecord == expected, "\(config.message)")
            await keeper.forceShutdown()
        }
    }
}
