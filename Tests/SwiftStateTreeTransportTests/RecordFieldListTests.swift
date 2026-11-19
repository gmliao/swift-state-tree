// Tests/SwiftStateTreeTransportTests/RecordFieldListTests.swift
//
// The replay record's field list (#555): every field of a decoded record is named with its
// comparison rule, so a field added later fails here until it is classified.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct RecordFieldsState: StateNodeProtocol {
    @Sync(.broadcast)
    var values: [Int] = []
}

@Payload
struct RecordFieldsAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct RecordFieldsAction: ActionPayload {
    typealias Response = RecordFieldsAck
    let value: Int
}

private func makeRecordFieldsLand() -> LandDefinition<RecordFieldsState> {
    Land("record-fields", using: RecordFieldsState.self) {
        Rules {
            HandleAction(RecordFieldsAction.self) {
                (state: inout RecordFieldsState, action: RecordFieldsAction, _: LandContext) in
                state.values.append(action.value)
                return RecordFieldsAck(ok: true)
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { (_: inout RecordFieldsState, _: LandContext) in }
        }
    }
}

private actor SilentTransport: Transport {
    var delegate: TransportDelegate?
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {}
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {}
}

@Suite("Replay record field list (#555)")
struct RecordFieldListTests {
    @Test("Every field of a decoded record is on the field list")
    func everyFieldIsClassified() async throws {
        let landID = "record-fields:local"
        let keeper = LandKeeper<RecordFieldsState>(
            definition: makeRecordFieldsLand(),
            initialState: RecordFieldsState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false
        )
        await keeper.setLandID(landID)
        let transport = SilentTransport()
        let adapter = TransportAdapter<RecordFieldsState>(keeper: keeper, transport: transport, landID: landID)
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: landID,
            landType: "record-fields",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            metadata: ["k": "v"],
            landDefinitionID: "record-fields",
            rngSeed: DeterministicSeed.fromLandID(landID),
            recordsSyncStream: await keeper.recordsSyncStream,
            syncConfig: adapter.syncConfigForRecord
        ))

        let session = SessionID("s1"), client = ClientID("c1")
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: PlayerID("p1"))
        await keeper.stepTickOnce()
        let envelope = ActionEnvelope(typeIdentifier: String(describing: RecordFieldsAction.self), payload: AnyCodable(RecordFieldsAction(value: 3)))
        await adapter.onMessage(try JSONEncoder().encode(TransportMessage.action(requestID: "a1", action: envelope)), from: session)
        await keeper.stepTickOnce()
        await adapter.onDisconnect(sessionID: session, clientID: client)
        await keeper.stepTickOnce()
        _ = await adapter.waitForOutboundDrain()
        await keeper.waitForRecorderSubmissionsForTesting()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-fields-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("record.sstr").path
        try await recorder.save(to: path)
        let contents = try ReevaluationRecordLog.decodeForTesting(Array(try Data(contentsOf: URL(fileURLWithPath: path))))
        #expect(contents.completeness == .complete)

        let paths = recordFieldPaths(of: contents)
        // The record holds the fields the walk must reach: an action, sync markers, metadata.
        #expect(paths.isSuperset(of: ["frames[].actions[].clientID", "frames[].syncMarkers[].viewHash", "metadata.createdAt"]))
        #expect(RecordFieldList.unclassified(paths) == [], "classify each new field in RecordFieldList")
    }

    @Test("A field on neither list is unclassified; a replaced field covers its subtree")
    func unclassifiedFieldFails() {
        #expect(RecordFieldList.unclassified(["metadata.landID", "metadata.newField", "frames[].actions[].newField"])
            == ["frames[].actions[].newField", "metadata.newField"])
        #expect(RecordFieldList.rule(for: "metadata.hardwareInfo.cpu") == .replaced(because: "the recording machine"))
        #expect(RecordFieldList.rule(for: "metadata.createdAtLocal") == nil, "a prefix match is by whole field")
        #expect(RecordFieldList.rule(for: "frames[].actions[].clientID") == .compared)
    }

    @Test("The walk names nested, optional, array and dictionary fields by path")
    func walkPaths() {
        struct Inner { let x: Int; let tags: [String] }
        struct Outer { let a: Inner; let b: Inner?; let c: [Inner]; let d: [String: Inner]; let e: Inner? }
        let value = Outer(a: Inner(x: 1, tags: ["t"]), b: Inner(x: 2, tags: []), c: [Inner(x: 3, tags: [])], d: ["k": Inner(x: 4, tags: [])], e: nil)
        #expect(recordFieldPaths(of: value) == [
            "a", "a.x", "a.tags", "b", "b.x", "b.tags", "c", "c[].x", "c[].tags", "d", "d[].x", "d[].tags", "e",
        ])
    }
}
