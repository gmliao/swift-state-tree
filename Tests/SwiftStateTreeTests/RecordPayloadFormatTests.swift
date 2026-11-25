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
import SwiftStateTreeReevaluationMonitor

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

/// The input kinds whose payload a 3.7 record holds as bytes.
enum PayloadEntryKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case action
    case clientEvent
    case serverInput
    var testDescription: String { rawValue }
}

/// A one-tick JSON record whose one entry, of `kind`, holds `payloadJSON` as its payload.
private func jsonRecord(version: String, kind: PayloadEntryKind, payloadJSON: String) throws -> String {
    guard kind != .action else { return try jsonRecord(version: version, payloadJSON: payloadJSON) }
    let fingerprint = try ReevaluationSchemaFingerprint.compute(for: makePayloadFormatLand())
    let entry: String
    switch kind {
    case .action:
        entry = ""
    case .clientEvent:
        entry = #""actions":[],"clientEvents":[{"kind":"clientEvent","sequence":0,"typeIdentifier":"e","payload":\#(payloadJSON),"playerID":"p","clientID":"c","sessionID":"s","resolvedAtTick":0}]"#
    case .serverInput:
        entry = #""actions":[],"clientEvents":[],"serverInputs":[{"kind":"serverInput","sequence":0,"typeIdentifier":"i","payload":\#(payloadJSON),"resolvedAtTick":0}]"#
    }
    let text = #"{"recordMetadata":{"landID":"payload-format:1","landType":"payload-format","landDefinitionID":"payload-format","createdAt":"1970-01-01T00:00:00Z","metadata":{},"version":"\#(version)","schemaFingerprint":"\#(fingerprint)"},"tickFrames":[{"tickId":0,\#(entry),"lifecycleEvents":[]}]}"#
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("payload-format-\(UUID().uuidString).json").path
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    return path
}

/// A tick record whose one entry, of `kind`, holds a payload tree, as a record before 3.7 does.
private func treeTickRecord(_ kind: PayloadEntryKind) -> ReevaluationTickRecord {
    let tree = AnyCodable(["label": "x"] as [String: Any])
    switch kind {
    case .action:
        return ReevaluationTickRecord(tickId: 0, actions: [ReevaluationRecordedAction(
            kind: "action", sequence: 0, typeIdentifier: String(describing: PayloadFormatAction.self),
            payload: Data(), payloadEncoding: nil, legacyPayload: tree,
            playerID: "p", clientID: "c", sessionID: "s", resolverOutputs: [:], resolvedAtTick: 0
        )])
    case .clientEvent:
        return ReevaluationTickRecord(tickId: 0, clientEvents: [ReevaluationRecordedClientEvent(
            kind: "clientEvent", sequence: 0, typeIdentifier: "e", payload: Data(), payloadEncoding: nil,
            legacyPayload: tree, playerID: "p", clientID: "c", sessionID: "s", resolvedAtTick: 0
        )])
    case .serverInput:
        return ReevaluationTickRecord(tickId: 0, serverInputs: [ReevaluationRecordedServerInput(
            sequence: 0, typeIdentifier: "i", payload: Data(), legacyPayload: tree, resolvedAtTick: 0
        )])
    }
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

    @Test("A 3.7 JSON record whose payload isn't base64 is refused when it is read, for each input kind",
          arguments: PayloadEntryKind.allCases)
    func record37WithTreePayloadIsRefused(kind: PayloadEntryKind) throws {
        let path = try jsonRecord(version: ReevaluationRecordVersion.current, kind: kind, payloadJSON: #""not base64!""#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: ReevaluationRecordContentError.payloadNotBytes(tickId: 0, sequence: 0)) {
            _ = try ReevaluationRecordFile.openSource(filePath: path)
        }
        // The same entry in a 3.6 record is its tree, and is read.
        let old = try jsonRecord(version: "3.6", kind: kind, payloadJSON: #""not base64!""#)
        defer { try? FileManager.default.removeItem(atPath: old) }
        _ = try ReevaluationRecordFile.openSource(filePath: old)
    }

    @Test("A 3.7 binary record holding a payload tree is refused when it is read, and has no JSON view, for each input kind",
          arguments: PayloadEntryKind.allCases)
    func binaryRecord37WithTreePayloadIsRefused(kind: PayloadEntryKind) async throws {
        let recorder = ReevaluationRecorder()
        await recorder.setMetadata(try formatMetadata(payloadEncoding: nil))
        await recorder.recordTick(treeTickRecord(kind))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("payload-format-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await recorder.save(to: path)
        #expect(throws: ReevaluationRecordContentError.payloadNotBytes(tickId: 0, sequence: 0)) {
            _ = try ReevaluationRecordFile.openSource(filePath: path)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(throws: ReevaluationRecordContentError.payloadNotBytes(tickId: 0, sequence: 0)) {
            _ = try ReevaluationRecordFile.jsonView(ofRecordData: data)
        }
    }

    @Test("The test upgrader turns a server input's tree into its canonical MessagePack bytes")
    func upgraderConvertsServerInputs() async throws {
        let recorder = ReevaluationRecorder()
        await recorder.setMetadata(try formatMetadata(payloadEncoding: nil))
        await recorder.recordTick(treeTickRecord(.serverInput))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("payload-format-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await recorder.save(to: path)
        let upgraded = try LegacyRecordUpgrader.upgradedCopy(ofRecordAt: path)
        defer { try? FileManager.default.removeItem(atPath: upgraded) }
        let source = try ReevaluationRecordFile.openSource(filePath: upgraded)
        let inputs = try await source.getServerInputs(for: 0)
        #expect(inputs.map(\.payload) == [Data(try CanonicalMessagePack.encode(AnyCodable(["label": "x"] as [String: Any])))])
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

    @Test("A binary record with a MessagePack entry under a JSON header lists both encodings, and a JSON-only replay refuses it")
    func binaryMessagePackEntryUnderJSONHeaderIsRefused() async throws {
        let recorder = ReevaluationRecorder()
        await recorder.setMetadata(try formatMetadata(payloadEncoding: nil))
        await recorder.record(tickId: 0, actions: [try formatAction(0, "x", .messagepack)], clientEvents: [], lifecycleEvents: [])
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("payload-format-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await recorder.save(to: path)
        let source = try ReevaluationRecordFile.openSource(filePath: path)
        #expect(source is ReevaluationRecordLogSource)
        #expect(try await source.getMetadata().effectivePayloadEncoding == .json)
        #expect(try await source.getPayloadEncodings() == [.json, .messagepack])
        await #expect(throws: ReevaluationRecordPayloadError.noDecoder(encoding: .messagepack)) {
            _ = try await ReevaluationEngine.run(definition: makePayloadFormatLand(), initialState: PayloadFormatState(), recordFilePath: path)
        }
        let result = try await ReevaluationEngine.run(
            definition: makePayloadFormatLand(), initialState: PayloadFormatState(), recordFilePath: path, payloadDecoders: .standard
        )
        #expect(result.maxTickId == 0)
    }

    @Test("Each replay entry refuses a MessagePack record with JSON decoders only, itself: the runner at its init, a keeper at its initialization")
    func eachReplayEntryChecksTheDecoders() async throws {
        let bytes = Data(try CanonicalMessagePack.encode(PayloadFormatAction(label: "x")))
        let path = try jsonRecord(version: ReevaluationRecordVersion.current, payloadEncoding: .messagepack, payloadJSON: "\"\(bytes.base64EncodedString())\"")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let refusal = ReevaluationRecordPayloadError.noDecoder(encoding: .messagepack)

        // The runner refuses at its init, before it builds a keeper (whose own check would
        // otherwise report it as an initialization failure later).
        await #expect(throws: refusal) {
            _ = try await ConcreteReevaluationRunner<PayloadFormatState>(definition: makePayloadFormatLand(), recordFilePath: path, payloadDecoders: .jsonOnly)
        }
        await #expect(throws: refusal) {
            _ = try await ConcreteReevaluationRunner<PayloadFormatState>(
                definition: makePayloadFormatLand(), initialState: PayloadFormatState(), recordFilePath: path, payloadDecoders: .jsonOnly
            )
        }

        // A keeper built directly on the source refuses at its initialization, before any input.
        let keeper = LandKeeper<PayloadFormatState>(
            definition: makePayloadFormatLand(),
            initialState: PayloadFormatState(),
            mode: .reevaluation,
            reevaluationSource: try ReevaluationRecordFile.openSource(filePath: path),
            payloadDecoders: .jsonOnly,
            autoStartLoops: false
        )
        let failure = try await #require(throws: LandInitializationError.self) {
            try await keeper.leave(playerID: PlayerID("p"), clientID: ClientID("c"), sessionID: SessionID("s"))
        }
        #expect(failure.underlying as? ReevaluationRecordPayloadError == refusal)
    }

    @Test("A keeper built directly on a source whose metadata can't be read refuses at its initialization (fails closed)")
    func unreadableMetadataFailsTheKeeper() async throws {
        let path = try jsonRecord(version: ReevaluationRecordVersion.current, payloadJSON: "\"\(Data(#"{"label":"x"}"#.utf8).base64EncodedString())\"")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let keeper = LandKeeper<PayloadFormatState>(
            definition: makePayloadFormatLand(),
            initialState: PayloadFormatState(),
            mode: .reevaluation,
            reevaluationSource: MetadataFailingSource(base: try ReevaluationRecordFile.openSource(filePath: path)),
            payloadDecoders: .standard,
            autoStartLoops: false
        )
        let failure = try await #require(throws: LandInitializationError.self) {
            try await keeper.leave(playerID: PlayerID("p"), clientID: ClientID("c"), sessionID: SessionID("s"))
        }
        #expect(failure.underlying is MetadataFailingSource.Unreadable)
    }

    @Test("A recorded server input equals another only with the same payload: different bytes differ, and a tree never equals bytes")
    func serverInputEqualityComparesThePayload() {
        func input(_ payload: Data, legacy: AnyCodable? = nil) -> ReevaluationRecordedServerInput {
            ReevaluationRecordedServerInput(sequence: 1, typeIdentifier: "i", payload: payload, legacyPayload: legacy, resolvedAtTick: 0)
        }
        #expect(input(Data([1, 2])) == input(Data([1, 2])))
        #expect(input(Data([1, 2])) != input(Data([1, 3])))
        #expect(input(Data(), legacy: AnyCodable(["a": 1] as [String: Any])) != input(Data()))
        #expect(input(Data(), legacy: AnyCodable(["a": 1] as [String: Any])) == input(Data(), legacy: AnyCodable(["a": 1] as [String: Any])))
        #expect(input(Data(), legacy: AnyCodable(["a": 1] as [String: Any])) != input(Data(), legacy: AnyCodable(["a": 2] as [String: Any])))
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

/// Forwards every read but the metadata, which throws.
private struct MetadataFailingSource: ForwardingTestSource {
    struct Unreadable: Error {}
    let base: any ReevaluationSource
    func getMetadata() async throws -> ReevaluationRecordMetadata { throw Unreadable() }
}
