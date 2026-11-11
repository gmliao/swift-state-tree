import Foundation
import NIOHTTP1
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeNIO
@testable import SwiftStateTreeReevaluationMonitor
@testable import SwiftStateTreeTransport

@Suite("NIO Admin Replay Start Route Tests")
struct NIOAdminRoutesReplayStartTests {
    @Test("Replay start accepts recordFilePath returned by records list endpoint")
    func replayStartAcceptsListedRelativePath() async throws {
        let router = try await makeRouter()
        let recordFileURL = try writeRecordFile(
            landType: "hero-defense",
            landDefinitionID: "hero-defense",
            version: "2.5"
        )
        defer { try? FileManager.default.removeItem(at: recordFileURL) }

        let listResponse = try await sendRecordsListRequest(on: router)
        #expect(listResponse.status == .ok)

        let listDecoded = try decodeAdminResponse(from: listResponse)
        #expect(listDecoded.success)
        #expect(listDecoded.error == nil)

        let listedPath = (listDecoded.data?.base as? [String])?
            .first(where: { $0.hasSuffix(recordFileURL.lastPathComponent) })
        guard let listedPath else {
            Issue.record("Expected records list to contain newly created file path")
            return
        }

        let requestBody = try JSONSerialization.data(withJSONObject: [
            "landType": "hero-defense",
            "recordFilePath": listedPath,
        ])

        let response = try await sendReplayStartRequest(body: requestBody, on: router)
        #expect(response.status == .ok)

        let decoded = try decodeAdminResponse(from: response)
        #expect(decoded.success)
        #expect(decoded.error == nil)
    }

    @Test("Replay start keeps backward compatibility when expectedLandDefinitionID is omitted")
    func replayStartAllowsOmittedExpectedLandDefinitionID() async throws {
        let router = try await makeRouter()
        let recordFileURL = try writeRecordFile(
            landType: "hero-defense",
            landDefinitionID: "legacy-schema-v1",
            version: "1.0"
        )
        defer { try? FileManager.default.removeItem(at: recordFileURL) }

        let requestBody = try JSONSerialization.data(withJSONObject: [
            "landType": "hero-defense",
            "recordFilePath": recordFileURL.path,
        ])

        let response = try await sendReplayStartRequest(body: requestBody, on: router)
        #expect(response.status == .ok)

        let decoded = try decodeAdminResponse(from: response)
        #expect(decoded.success)
        #expect(decoded.error == nil)
    }

    @Test("Replay start returns schema mismatch conflict with actionable details")
    func replayStartSchemaMismatchPayload() async throws {
        let router = try await makeRouter()
        let recordFileURL = try writeRecordFile(
            landType: "hero-defense",
            landDefinitionID: "legacy-schema-v1",
            version: "1.0"
        )
        defer { try? FileManager.default.removeItem(at: recordFileURL) }

        let requestBody = try JSONSerialization.data(withJSONObject: [
            "landType": "hero-defense",
            "recordFilePath": recordFileURL.path,
            "expectedLandDefinitionID": "hero-defense-schema-v2",
        ])

        let response = try await sendReplayStartRequest(body: requestBody, on: router)
        #expect(response.status == .conflict)

        let decoded = try decodeAdminResponse(from: response)
        #expect(decoded.success == false)
        #expect(decoded.error?.code == "SCHEMA_MISMATCH")
        #expect(detailString(decoded.error?.details, key: "expectedLandDefinitionID") == "hero-defense-schema-v2")
        #expect(detailString(decoded.error?.details, key: "recordedLandDefinitionID") == "legacy-schema-v1")
    }

    @Test("Replay start returns schema mismatch when record schema is missing in strict mode")
    func replayStartSchemaMissingInStrictMode() async throws {
        let router = try await makeRouter()
        let recordFileURL = try writeRecordFile(
            landType: "hero-defense",
            landDefinitionID: nil,
            version: "1.0"
        )
        defer { try? FileManager.default.removeItem(at: recordFileURL) }

        let requestBody = try JSONSerialization.data(withJSONObject: [
            "landType": "hero-defense",
            "recordFilePath": recordFileURL.path,
            "expectedLandDefinitionID": "hero-defense-schema-v2",
        ])

        let response = try await sendReplayStartRequest(body: requestBody, on: router)
        #expect(response.status == .conflict)

        let decoded = try decodeAdminResponse(from: response)
        #expect(decoded.success == false)
        #expect(decoded.error?.code == "SCHEMA_MISMATCH")
        #expect(detailString(decoded.error?.details, key: "expectedLandDefinitionID") == "hero-defense-schema-v2")
        #expect(hasDetailKey(decoded.error?.details, key: "recordedLandDefinitionID"))
        #expect(detailString(decoded.error?.details, key: "recordedLandDefinitionID") == nil)
    }

    @Test("Replay start returns record version mismatch conflict with actionable details")
    func replayStartRecordVersionMismatchPayload() async throws {
        let router = try await makeRouter()
        let recordFileURL = try writeRecordFile(
            landType: "hero-defense",
            landDefinitionID: "hero-defense",
            version: "1.0"
        )
        defer { try? FileManager.default.removeItem(at: recordFileURL) }

        let requestBody = try JSONSerialization.data(withJSONObject: [
            "landType": "hero-defense",
            "recordFilePath": recordFileURL.path,
            "expectedRecordVersion": "2.5",
        ])

        let response = try await sendReplayStartRequest(body: requestBody, on: router)
        #expect(response.status == .conflict)

        let decoded = try decodeAdminResponse(from: response)
        #expect(decoded.success == false)
        #expect(decoded.error?.code == "RECORD_VERSION_MISMATCH")
        #expect(detailString(decoded.error?.details, key: "expectedRecordVersion") == "2.5")
        #expect(detailString(decoded.error?.details, key: "recordedRecordVersion") == "1.0")
    }

    @Test("Replay start accepts a record with the same major version and another minor", arguments: [("2.6", "2.5"), ("2.5", "2.6")])
    func replayStartAcceptsSameMajor(versions: (recorded: String, expected: String)) async throws {
        let router = try await makeRouter()
        let recordFileURL = try writeRecordFile(
            landType: "hero-defense",
            landDefinitionID: "hero-defense",
            version: versions.recorded
        )
        defer { try? FileManager.default.removeItem(at: recordFileURL) }

        let requestBody = try JSONSerialization.data(withJSONObject: [
            "landType": "hero-defense",
            "recordFilePath": recordFileURL.path,
            "expectedRecordVersion": versions.expected,
        ])

        let response = try await sendReplayStartRequest(body: requestBody, on: router)
        #expect(response.status == .ok)
        #expect(try decodeAdminResponse(from: response).success)
    }

    @Test("Replay start rejects a record older than 2.5 as unsupported, with or without an expected version (#154)", arguments: [nil, "2.5"] as [String?])
    func replayStartRejectsUnsupportedRecord(expected: String?) async throws {
        let router = try await makeRouter()
        let recordFileURL = try writeRecordFile(
            landType: "hero-defense",
            landDefinitionID: "hero-defense",
            version: "2.4"
        )
        defer { try? FileManager.default.removeItem(at: recordFileURL) }

        var body: [String: Any] = ["landType": "hero-defense", "recordFilePath": recordFileURL.path]
        if let expected { body["expectedRecordVersion"] = expected }
        let response = try await sendReplayStartRequest(body: try JSONSerialization.data(withJSONObject: body), on: router)
        #expect(response.status == .conflict)

        let decoded = try decodeAdminResponse(from: response)
        #expect(decoded.success == false)
        #expect(decoded.error?.code == "RECORD_VERSION_UNSUPPORTED")
        #expect(decoded.error?.message.contains("re-record") == true)
        #expect(detailString(decoded.error?.details, key: "recordedRecordVersion") == "2.4")
        #expect(detailString(decoded.error?.details, key: "minimumRecordVersion") == "2.5")
    }

    @Test("Replay start returns land type mismatch conflict with actionable details")
    func replayStartLandTypeMismatchPayload() async throws {
        let router = try await makeRouter()
        let recordFileURL = try writeRecordFile(
            landType: "counter",
            landDefinitionID: "counter",
            version: "2.5"
        )
        defer { try? FileManager.default.removeItem(at: recordFileURL) }

        let requestBody = try JSONSerialization.data(withJSONObject: [
            "landType": "hero-defense",
            "recordFilePath": recordFileURL.path,
        ])

        let response = try await sendReplayStartRequest(body: requestBody, on: router)
        #expect(response.status == .conflict)

        let decoded = try decodeAdminResponse(from: response)
        #expect(decoded.success == false)
        #expect(decoded.error?.code == "LAND_TYPE_MISMATCH")
        #expect(detailString(decoded.error?.details, key: "expectedLandType") == "hero-defense")
        #expect(detailString(decoded.error?.details, key: "recordedLandType") == "counter")
    }

    @Test("Monitor start: the body is required, a path outside the records directory is refused, and the ID is a monitor ticket binding the record")
    func monitorStart() async throws {
        let router = try await makeRouter()
        let monitorURI = "/admin/reevaluation/start"

        // The old body-less call is refused.
        let bare = try await sendReplayStartRequest(body: nil, on: router, uri: monitorURI)
        #expect(bare.status == .badRequest)

        // A record outside the records directory is refused when the ticket would be issued.
        let outside = try JSONEncoder().encode(ReevaluationMonitorStartRequest(
            landType: "hero-defense", recordFilePath: "/etc/hosts"
        ))
        let refused = try await sendReplayStartRequest(body: outside, on: router, uri: monitorURI)
        #expect(refused.status == .badRequest)
        #expect(try decodeAdminResponse(from: refused).success == false)

        // A record inside: the ID is a monitor ticket for the monitor land type, binding the
        // record's live land type, and not a replay ticket.
        let recordFileURL = try writeRecordFile(landType: "hero-defense", landDefinitionID: "hero-defense", version: "2.5")
        defer { try? FileManager.default.removeItem(at: recordFileURL) }
        let body = try JSONEncoder().encode(ReevaluationMonitorStartRequest(
            landType: "hero-defense", recordFilePath: recordFileURL.path
        ))
        let response = try await sendReplayStartRequest(body: body, on: router, uri: monitorURI)
        #expect(response.status == .ok)
        let data = try #require(try decodeAdminResponse(from: response).data?.base as? [String: Any])
        let landID = LandID(try #require(data["monitorLandID"] as? String))
        #expect(landID.landType == "reevaluation-monitor")
        let inspection = ReplayTicketSigner.process.inspect(instanceId: landID.instanceId, kind: .monitor, landType: "reevaluation-monitor")
        #expect(inspection.verdict == .valid)
        #expect(inspection.fields?.liveLandType == "hero-defense")
        #expect(ReplayTicketSigner.process.verify(instanceId: landID.instanceId, replayLandType: "reevaluation-monitor") == .invalid)

        // A record of another land type is refused at issue time (the compatibility check).
        let mismatched = try JSONEncoder().encode(ReevaluationMonitorStartRequest(
            landType: "other-game", recordFilePath: recordFileURL.path
        ))
        #expect(try await sendReplayStartRequest(body: mismatched, on: router, uri: monitorURI).status == .conflict)
    }

    @Test("Replay start response includes enough metadata to build ReevaluationReplaySessionDescriptor")
    func replayStartResponseIncludesDescriptorMetadata() async throws {
        let router = try await makeRouter()
        let recordFileURL = try writeRecordFile(
            landType: "hero-defense",
            landDefinitionID: "hero-defense",
            version: "2.5"
        )
        defer { try? FileManager.default.removeItem(at: recordFileURL) }

        let requestBody = try JSONSerialization.data(withJSONObject: [
            "landType": "hero-defense",
            "recordFilePath": recordFileURL.path,
        ])

        let response = try await sendReplayStartRequest(body: requestBody, on: router)
        #expect(response.status == .ok)

        let decoded = try decodeAdminResponse(from: response)
        #expect(decoded.success)
        guard let data = decoded.data?.base as? [String: Any] else {
            Issue.record("Expected success data as dictionary")
            return
        }

        let descriptor = ReevaluationReplaySessionDescriptor.encode(from: data)
        #expect(descriptor != nil)
        // Compare resolved paths: under a symlinked directory (/tmp on macOS) the route and the
        // test can spell the same file differently.
        let resolve = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        #expect(descriptor.map { resolve($0.recordFilePath) } == resolve(recordFileURL.path))
        #expect(descriptor?.landType == "hero-defense")
        #expect(descriptor?.webSocketPath == "/game/hero-defense-replay")
        // The replay land ID is a ticket the process signer issued for the replay land type (#366).
        let replayLandID = try #require(data["replayLandID"] as? String)
        let landID = LandID(replayLandID)
        #expect(landID.landType == "hero-defense-replay")
        #expect(ReplayTicketSigner.process.verify(instanceId: landID.instanceId, replayLandType: "hero-defense-replay") == .valid)
        #expect(ReplayTicketSigner.process.verify(instanceId: landID.instanceId, replayLandType: "other-replay") == .invalid)
    }

    @Test("ReevaluationReplaySessionDescriptor decode rejects path traversal in token")
    func descriptorDecodeRejectsPathTraversal() async throws {
        let recordsDir = "\(FileManager.default.currentDirectoryPath)/reevaluation-records"
        let traversalToken = encodeBase64URLForTest("/../etc/passwd")
        let instanceId = "\(UUID().uuidString.lowercased()).\(traversalToken)"

        let result = ReevaluationReplaySessionDescriptor.decode(
            instanceId: instanceId,
            landType: "hero-defense-replay",
            recordsDir: recordsDir
        )
        #expect(result == nil)
    }

    @Test("ReevaluationReplaySessionDescriptor decode rejects invalid payload")
    func descriptorDecodeRejectsInvalidPayload() async throws {
        let recordsDir = "\(FileManager.default.currentDirectoryPath)/reevaluation-records"
        let invalidToken = "not-valid-base64!!!"
        let instanceId = "\(UUID().uuidString.lowercased()).\(invalidToken)"

        let result = ReevaluationReplaySessionDescriptor.decode(
            instanceId: instanceId,
            landType: "hero-defense-replay",
            recordsDir: recordsDir
        )
        #expect(result == nil)
    }
}

private func sendRecordsListRequest(on router: NIOHTTPRouter) async throws -> NIOHTTPResponse {
    var headers = HTTPHeaders()
    headers.add(name: "X-API-Key", value: "test-admin-key")

    let request = NIOHTTPRequest(
        method: .GET,
        uri: "/admin/reevaluation/records",
        headers: headers,
        body: nil
    )

    let optionalResponse = try await router.handle(request)
    guard let response = optionalResponse else {
        throw CocoaError(.fileReadUnknown)
    }
    return response
}

private func makeRouter() async throws -> NIOHTTPRouter {
    let landRealm = LandRealm()
    try await landRealm.register(landType: "hero-defense-replay", server: MockReplayLandServer())
    try await landRealm.register(landType: "reevaluation-monitor", server: MockReplayLandServer())

    let adminAuth = NIOAdminAuth(apiKey: "test-admin-key")
    let routes = NIOAdminRoutes(landRealm: landRealm, adminAuth: adminAuth)
    let router = NIOHTTPRouter()
    await routes.registerRoutes(on: router)
    return router
}

private func sendReplayStartRequest(
    body: Data?,
    on router: NIOHTTPRouter,
    uri: String = "/admin/reevaluation/replay/start"
) async throws -> NIOHTTPResponse {
    var headers = HTTPHeaders()
    headers.add(name: "X-API-Key", value: "test-admin-key")
    headers.add(name: "Content-Type", value: "application/json")

    let request = NIOHTTPRequest(
        method: .POST,
        uri: uri,
        headers: headers,
        body: body
    )

    let optionalResponse = try await router.handle(request)
    guard let response = optionalResponse else {
        throw CocoaError(.fileReadUnknown)
    }
    return response
}

private func decodeAdminResponse(from response: NIOHTTPResponse) throws -> AdminAPIAnyResponse {
    guard let body = response.body else {
        throw CocoaError(.coderReadCorrupt)
    }
    return try JSONDecoder().decode(AdminAPIAnyResponse.self, from: body)
}

private func detailString(_ details: [String: AnyCodable]?, key: String) -> String? {
    details?[key]?.base as? String
}

private func hasDetailKey(_ details: [String: AnyCodable]?, key: String) -> Bool {
    details?[key] != nil
}

private func encodeBase64URLForTest(_ raw: String) -> String {
    Data(raw.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private struct ReplayRecordFile: Codable {
    let recordMetadata: ReevaluationRecordMetadata
    let tickFrames: [ReevaluationTickFrame]
}

private func writeRecordFile(
    landType: String,
    landDefinitionID: String?,
    version: String
) throws -> URL {
    let recordsDirectory = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    ).appendingPathComponent("reevaluation-records", isDirectory: true)

    try FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)

    let fileURL = recordsDirectory
        .appendingPathComponent("nio-admin-replay-start-")
        .appendingPathExtension(UUID().uuidString.lowercased())
        .appendingPathExtension("json")

    let metadata = ReevaluationRecordMetadata(
        landID: "hero-defense:test",
        landType: landType,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        metadata: [:],
        landDefinitionID: landDefinitionID,
        initialStateHash: nil,
        landConfig: nil,
        rngSeed: nil,
        ruleVariantId: nil,
        ruleParams: nil,
        version: version,
        extensions: nil,
        hardwareInfo: nil
    )

    let payload = ReplayRecordFile(recordMetadata: metadata, tickFrames: [])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(payload)
    try data.write(to: fileURL)
    return fileURL
}

private struct MockReplayLandServer: LandServerProtocol {
    typealias State = DummyReplayState

    func shutdown() async throws {}

    func healthCheck() async -> Bool {
        true
    }

    func listLands() async -> [LandID] {
        []
    }

    func getLandStats(landID _: LandID) async -> LandStats? {
        nil
    }

    func stopLand(landID _: LandID) async -> StopLandResult { .notFound }

    func getReevaluationRecord(landID _: LandID) async throws -> Data? {
        nil
    }
}

private struct DummyReplayState: StateNodeProtocol {
    init() {}

    func getSyncFields() -> [SyncFieldInfo] {
        []
    }

    static func getFieldMetadata() -> [FieldMetadata] {
        []
    }

    func validateSyncFields() -> Bool {
        true
    }

    func snapshot(for _: PlayerID?, dirtyFields _: Set<String>?) throws -> StateSnapshot {
        StateSnapshot()
    }

    func broadcastSnapshot(dirtyFields _: Set<String>?) throws -> StateSnapshot {
        StateSnapshot()
    }

    func fullStateSnapshot() throws -> StateSnapshot {
        StateSnapshot()
    }

    func isDirty() -> Bool {
        false
    }

    func getDirtyFields() -> Set<String> {
        []
    }

    mutating func clearDirty() {}
}
