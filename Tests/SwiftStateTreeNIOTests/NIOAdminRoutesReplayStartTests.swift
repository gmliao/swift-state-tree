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
            version: "2.0"
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
            "expectedRecordVersion": "2.0",
        ])

        let response = try await sendReplayStartRequest(body: requestBody, on: router)
        #expect(response.status == .conflict)

        let decoded = try decodeAdminResponse(from: response)
        #expect(decoded.success == false)
        #expect(decoded.error?.code == "RECORD_VERSION_MISMATCH")
        #expect(detailString(decoded.error?.details, key: "expectedRecordVersion") == "2.0")
        #expect(detailString(decoded.error?.details, key: "recordedRecordVersion") == "1.0")
    }

    @Test("Replay start returns land type mismatch conflict with actionable details")
    func replayStartLandTypeMismatchPayload() async throws {
        let router = try await makeRouter()
        let recordFileURL = try writeRecordFile(
            landType: "counter",
            landDefinitionID: "counter",
            version: "2.0"
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

    @Test("Replay start response includes enough metadata to build ReevaluationReplaySessionDescriptor")
    func replayStartResponseIncludesDescriptorMetadata() async throws {
        let router = try await makeRouter()
        let recordFileURL = try writeRecordFile(
            landType: "hero-defense",
            landDefinitionID: "hero-defense",
            version: "2.0"
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
        #expect(descriptor?.recordFilePath == recordFileURL.path)
        #expect(descriptor?.landType == "hero-defense")
        #expect(descriptor?.webSocketPath == "/game/hero-defense-replay")
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

    let adminAuth = NIOAdminAuth(apiKey: "test-admin-key")
    let routes = NIOAdminRoutes(landRealm: landRealm, adminAuth: adminAuth)
    let router = NIOHTTPRouter()
    await routes.registerRoutes(on: router)
    return router
}

private func sendReplayStartRequest(body: Data, on router: NIOHTTPRouter) async throws -> NIOHTTPResponse {
    var headers = HTTPHeaders()
    headers.add(name: "X-API-Key", value: "test-admin-key")
    headers.add(name: "Content-Type", value: "application/json")

    let request = NIOHTTPRequest(
        method: .POST,
        uri: "/admin/reevaluation/replay/start",
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

    func removeLand(landID _: LandID) async {}

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

    func isDirty() -> Bool {
        false
    }

    func getDirtyFields() -> Set<String> {
        []
    }

    mutating func clearDirty() {}
}
