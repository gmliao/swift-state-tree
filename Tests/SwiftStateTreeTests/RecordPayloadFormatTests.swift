// Tests/SwiftStateTreeTests/RecordPayloadFormatTests.swift
//
// #700 K1a, format 3.7: how a record holds an action's and a client event's payload bytes and
// their encoding. The header names the encoding once; an entry names its own only when it differs,
// and a reader fills it in from the header in force. A record from before 3.7 (payload trees) is
// read and refused for replay; a replay without the decoder the header names is refused before
// any input.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct PayloadFormatState: StateNodeProtocol {
    @Sync(.broadcast)
    var labels: [String] = []
}

@Payload
struct PayloadFormatAck: ResponsePayload {}

@Payload
struct PayloadFormatAction: ActionPayload {
    typealias Response = PayloadFormatAck
    let label: String
}

private func makePayloadFormatLand() -> LandDefinition<PayloadFormatState> {
    Land("payload-format", using: PayloadFormatState.self) {
        Rules {
            HandleAction(PayloadFormatAction.self) { state, action, _ in
                state.labels.append(action.label)
                return PayloadFormatAck()
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { _, _ in }
        }
    }
}

private func formatAction(_ sequence: Int64, _ label: String, _ encoding: RecordPayloadEncoding) throws -> ReevaluationRecordedAction {
    let payload: Data = switch encoding {
    case .json: try RecordPayloadEncoding.canonicalJSON(PayloadFormatAction(label: label))
    case .messagepack: Data(try CanonicalMessagePack.encode(PayloadFormatAction(label: label)))
    }
    return ReevaluationRecordedAction(
        kind: "action", sequence: sequence, typeIdentifier: String(describing: PayloadFormatAction.self),
        payload: payload, payloadEncoding: encoding,
        playerID: "p", clientID: "c", sessionID: "s", resolverOutputs: [:], resolvedAtTick: 0
    )
}

private func formatMetadata(version: String? = nil, payloadEncoding: RecordPayloadEncoding?) throws -> ReevaluationRecordMetadata {
    ReevaluationRecordMetadata(
        landID: "payload-format:1", landType: "payload-format", createdAt: Date(timeIntervalSince1970: 0),
        metadata: [:], landDefinitionID: "payload-format", version: version,
        schemaFingerprint: try ReevaluationSchemaFingerprint.compute(for: makePayloadFormatLand()),
        payloadEncoding: payloadEncoding
    )
}

/// A JSON record of one tick frame with one action whose payload field is `payloadJSON` as written.
private func jsonRecord(version: String, payloadEncoding: RecordPayloadEncoding? = nil, payloadJSON: String) throws -> String {
    let fingerprint = try ReevaluationSchemaFingerprint.compute(for: makePayloadFormatLand())
    let encodingField = payloadEncoding.map { #","payloadEncoding":"\#($0.rawValue)""# } ?? ""
    let text = #"{"recordMetadata":{"landID":"payload-format:1","landType":"payload-format","landDefinitionID":"payload-format","createdAt":"1970-01-01T00:00:00Z","metadata":{},"version":"\#(version)","schemaFingerprint":"\#(fingerprint)"\#(encodingField)},"tickFrames":[{"tickId":0,"actions":[{"kind":"action","sequence":0,"typeIdentifier":"\#(String(describing: PayloadFormatAction.self))","payload":\#(payloadJSON),"playerID":"p","clientID":"c","sessionID":"s","resolverOutputs":{},"resolvedAtTick":0}],"clientEvents":[],"lifecycleEvents":[]}]}"#
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("payload-format-\(UUID().uuidString).json").path
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    return path
}

@Suite("Recorded payload bytes and their encoding in the record (#700 K1a)")
struct RecordPayloadFormatTests {
    @Test("An entry in the header's encoding is written without it, and each is read back with its own, across two headers")
    func entryEncodingStrippedAndResolvedPerHeader() async throws {
        let recorder = ReevaluationRecorder()
        await recorder.setMetadata(try formatMetadata(payloadEncoding: nil))
        await recorder.record(tickId: 0, actions: [try formatAction(0, "a", .messagepack), try formatAction(1, "b", .json)], clientEvents: [], lifecycleEvents: [])
        // Ends the turn: an open turn is written when it closes, under the header in force then.
        await recorder.flushForTesting()
        await recorder.setMetadata(try formatMetadata(payloadEncoding: .messagepack))
        await recorder.record(tickId: 1, actions: [try formatAction(2, "c", .json), try formatAction(3, "d", .messagepack)], clientEvents: [], lifecycleEvents: [])
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("payload-format-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await recorder.save(to: path)

        // As written: only the entries whose encoding differs from their header's name it.
        let written = try LegacyRecordUpgrader.writtenActions(ofRecordAt: path)
        #expect(written.map(\.sequence) == [0, 1, 2, 3])
        #expect(written.map(\.payloadEncoding) == [.messagepack, nil, .json, nil])

        // As read: each entry's own encoding, filled in from the header in force.
        let source = try #require(try ReevaluationRecordFile.openSource(filePath: path) as? ReevaluationRecordLogSource)
        let read = await source.getAllFrames().flatMap(\.actions)
        #expect(read.map(\.payloadEncoding) == [.messagepack, .json, .json, .messagepack])
        let labels = try read.map { try RecordedPayloadTree.tree(of: $0) }.map { ($0.base as? [String: Any])?["label"] as? String }
        #expect(labels == ["a", "b", "c", "d"])
    }

    @Test("A 3.6 record is read, its payloads as trees, and refused for replay")
    func recordBefore37IsReadAndRefused() async throws {
        let path = try jsonRecord(version: "3.6", payloadJSON: #"{"label":"x"}"#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let source = try ReevaluationRecordFile.openSource(filePath: path)
        let action = try #require(await (source as! JSONReevaluationSource).getAllFrames().first?.actions.first)
        #expect(action.payloadEncoding == nil)
        #expect(action.payload.isEmpty)
        #expect((action.legacyPayload?.base as? [String: Any])?["label"] as? String == "x")
        await #expect(throws: ReevaluationRecordFingerprintError.payloadsNotReplayable(recordedVersion: "3.6")) {
            _ = try await ReevaluationEngine.run(definition: makePayloadFormatLand(), initialState: PayloadFormatState(), recordFilePath: path)
        }
    }

    @Test("A 3.7 record replays its payload bytes")
    func record37Replays() async throws {
        let bytes = try RecordPayloadEncoding.canonicalJSON(PayloadFormatAction(label: "x"))
        let path = try jsonRecord(version: ReevaluationRecordVersion.current, payloadJSON: "\"\(bytes.base64EncodedString())\"")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let keeperResult = try await ReevaluationEngine.run(definition: makePayloadFormatLand(), initialState: PayloadFormatState(), recordFilePath: path)
        #expect(keeperResult.maxTickId == 0)
    }

    @Test("A 3.7 JSON record whose payload isn't base64 is refused when it is read")
    func record37WithTreePayloadIsRefused() throws {
        let path = try jsonRecord(version: ReevaluationRecordVersion.current, payloadJSON: #""not base64!""#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: ReevaluationRecordContentError.payloadNotBytes(tickId: 0, sequence: 0)) {
            _ = try ReevaluationRecordFile.openSource(filePath: path)
        }
        // The same entry in a 3.6 record is its tree, and is read.
        let old = try jsonRecord(version: "3.6", payloadJSON: #""not base64!""#)
        defer { try? FileManager.default.removeItem(atPath: old) }
        _ = try ReevaluationRecordFile.openSource(filePath: old)
    }

    @Test("A 3.7 binary record holding a payload tree is refused when it is read")
    func binaryRecord37WithTreePayloadIsRefused() async throws {
        let recorder = ReevaluationRecorder()
        await recorder.setMetadata(try formatMetadata(payloadEncoding: nil))
        let tree = ReevaluationRecordedAction(
            kind: "action", sequence: 0, typeIdentifier: String(describing: PayloadFormatAction.self),
            payload: Data(), payloadEncoding: nil, legacyPayload: AnyCodable(["label": "x"] as [String: Any]),
            playerID: "p", clientID: "c", sessionID: "s", resolverOutputs: [:], resolvedAtTick: 0
        )
        await recorder.record(tickId: 0, actions: [tree], clientEvents: [], lifecycleEvents: [])
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("payload-format-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await recorder.save(to: path)
        #expect(throws: ReevaluationRecordContentError.payloadNotBytes(tickId: 0, sequence: 0)) {
            _ = try ReevaluationRecordFile.openSource(filePath: path)
        }
    }

    @Test("A MessagePack entry under a JSON header is refused by a JSON-only replay before any input")
    func messagePackEntryUnderJSONHeaderIsRefused() async throws {
        // A host that sets the recorder's metadata itself without `payloadEncoding` over a
        // MessagePack transport writes this: the header says `json`, the entries MessagePack.
        let bytes = Data(try CanonicalMessagePack.encode(PayloadFormatAction(label: "x")))
        let entry = #""\#(bytes.base64EncodedString())","payloadEncoding":"messagepack""#
        let path = try jsonRecord(version: ReevaluationRecordVersion.current, payloadJSON: entry)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try await ReevaluationRecordFile.openSource(filePath: path).getPayloadEncodings() == [.json, .messagepack])
        await #expect(throws: ReevaluationRecordPayloadError.noDecoder(encoding: .messagepack)) {
            _ = try await ReevaluationEngine.run(definition: makePayloadFormatLand(), initialState: PayloadFormatState(), recordFilePath: path)
        }
        let result = try await ReevaluationEngine.run(
            definition: makePayloadFormatLand(), initialState: PayloadFormatState(), recordFilePath: path, payloadDecoders: .standard
        )
        #expect(result.maxTickId == 0)
    }

    @Test("A replay with JSON decoders only refuses a record whose header says MessagePack, before any input; the standard decoders replay it")
    func jsonOnlyRefusesMessagePackHeader() async throws {
        let bytes = Data(try CanonicalMessagePack.encode(PayloadFormatAction(label: "x")))
        let path = try jsonRecord(version: ReevaluationRecordVersion.current, payloadEncoding: .messagepack, payloadJSON: "\"\(bytes.base64EncodedString())\"")
        defer { try? FileManager.default.removeItem(atPath: path) }
        await #expect(throws: ReevaluationRecordPayloadError.noDecoder(encoding: .messagepack)) {
            _ = try await ReevaluationEngine.run(definition: makePayloadFormatLand(), initialState: PayloadFormatState(), recordFilePath: path)
        }
        let result = try await ReevaluationEngine.run(
            definition: makePayloadFormatLand(), initialState: PayloadFormatState(), recordFilePath: path, payloadDecoders: .standard
        )
        #expect(result.maxTickId == 0)
    }
}
