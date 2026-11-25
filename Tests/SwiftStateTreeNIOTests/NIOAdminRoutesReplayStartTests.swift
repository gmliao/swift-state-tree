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
            version: ReevaluationRecordVersion.current
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
            version: ReevaluationRecordVersion.current
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

    @Test("Replay start accepts a record with the same major version and another minor", arguments: [
        (ReevaluationRecordVersion.current, "3.0"), (ReevaluationRecordVersion.current, "3.4"),
    ])
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

    @Test("Replay start refuses a record without a schema fingerprint: one before 3.6, or a current one without the field (#521 D15)")
    func replayStartRefusesRecordWithoutFingerprint() async throws {
        let router = try await makeRouter()
        let cases: [(String, String?)] = [
            ("2.6", testRecordFingerprint), ("3.4", testRecordFingerprint), ("3.5", testRecordFingerprint),
            (ReevaluationRecordVersion.current, nil),
        ]
        for (version, fingerprint) in cases {
            let recordFileURL = try writeRecordFile(
                landType: "hero-defense", landDefinitionID: "hero-defense", version: version, schemaFingerprint: fingerprint
            )
            defer { try? FileManager.default.removeItem(at: recordFileURL) }
            let body = try JSONSerialization.data(withJSONObject: ["landType": "hero-defense", "recordFilePath": recordFileURL.path])
            let response = try await sendReplayStartRequest(body: body, on: router)
            #expect(response.status == .conflict, "\(version)")
            let decoded = try decodeAdminResponse(from: response)
            #expect(decoded.error?.code == "RECORD_SCHEMA_FINGERPRINT_MISSING", "\(version)")
            #expect(decoded.error?.message.contains("re-record") == true)
            #expect(detailString(decoded.error?.details, key: "recordedRecordVersion") == version)
            #expect(detailString(decoded.error?.details, key: "minimumReplayableVersion") == ReevaluationRecordVersion.minimumReplayable)
        }
    }

    @Test("Replay start refuses a record whose schema fingerprint differs from the live land type's, with both values (#521 D15)")
    func replayStartRefusesFingerprintMismatch() async throws {
        let router = try await makeRouter(live: .fingerprint("fedcba9876543210"))
        let recordFileURL = try writeRecordFile(
            landType: "hero-defense", landDefinitionID: "hero-defense", version: ReevaluationRecordVersion.current
        )
        defer { try? FileManager.default.removeItem(at: recordFileURL) }
        let body = try JSONSerialization.data(withJSONObject: ["landType": "hero-defense", "recordFilePath": recordFileURL.path])
        let response = try await sendReplayStartRequest(body: body, on: router)
        #expect(response.status == .conflict)
        let decoded = try decodeAdminResponse(from: response)
        #expect(decoded.error?.code == "RECORD_SCHEMA_FINGERPRINT_MISMATCH")
        #expect(detailString(decoded.error?.details, key: "recordedSchemaFingerprint") == testRecordFingerprint)
        #expect(detailString(decoded.error?.details, key: "currentSchemaFingerprint") == "fedcba9876543210")

        // The same record against a live land type with its fingerprint is accepted.
        let matching = try await makeRouter()
        #expect(try await sendReplayStartRequest(body: body, on: matching).status == .ok)
    }

    @Test("Replay start refuses a record when the land type has no fingerprint to compare with: its server reports none, can't list a type, or isn't registered (#521 D15)")
    func replayStartRefusesWithoutCurrentFingerprint() async throws {
        let recordFileURL = try writeRecordFile(
            landType: "hero-defense", landDefinitionID: "hero-defense", version: ReevaluationRecordVersion.current
        )
        defer { try? FileManager.default.removeItem(at: recordFileURL) }
        let body = try JSONSerialization.data(withJSONObject: ["landType": "hero-defense", "recordFilePath": recordFileURL.path])
        let reasons: [(LiveLand, String)] = [
            (.reportsNone, "reports one"),
            (.unbuildable, "Opaque"),
            (.unregistered, "reports one"),
        ]
        for (live, reason) in reasons {
            let response = try await sendReplayStartRequest(body: body, on: try await makeRouter(live: live))
            #expect(response.status == .conflict, "\(live)")
            let decoded = try decodeAdminResponse(from: response)
            #expect(decoded.error?.code == "RECORD_SCHEMA_FINGERPRINT_UNAVAILABLE", "\(live)")
            #expect(decoded.error?.message.contains(reason) == true, "\(live): \(decoded.error?.message ?? "")")
            #expect(detailString(decoded.error?.details, key: "landType") == "hero-defense")
        }
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

    private static let startURIs = ["/admin/reevaluation/replay/start", "/admin/reevaluation/start"]

    @Test("Both start routes refuse a 3.6 record whose fingerprint matches: its payloads are trees, which replay no longer decodes (#700 K1a)")
    func startRefusesA36RecordWithAMatchingFingerprint() async throws {
        let recordFileURL = try writeRecordFile(landType: "hero-defense", landDefinitionID: "hero-defense", version: "3.6")
        defer { try? FileManager.default.removeItem(at: recordFileURL) }
        let router = try await makeRouter()
        let body = try JSONSerialization.data(withJSONObject: [
            "landType": "hero-defense", "recordFilePath": recordFileURL.path,
        ])
        for uri in Self.startURIs {
            let response = try await sendReplayStartRequest(body: body, on: router, uri: uri)
            #expect(response.status == .conflict, "\(uri)")
            let decoded = try decodeAdminResponse(from: response)
            #expect(!decoded.success)
            #expect(decoded.error?.code == "RECORD_PAYLOADS_NOT_REPLAYABLE", "\(uri)")
            #expect(detailString(decoded.error?.details, key: "recordedRecordVersion") == "3.6", "\(uri)")
            #expect(
                detailString(decoded.error?.details, key: "minimumReplayableVersion") == ReevaluationRecordVersion.minimumReplayable,
                "\(uri)"
            )
        }
    }

    @Test(
        "Both start routes refuse a record whose version is missing, malformed or newer than this build reads, even with a matching fingerprint and no version asked for",
        arguments: [nil, "bogus", "3.7.1", "3.8", "4.0"] as [String?]
    )
    func startRefusesAnUnreadableVersionWithAMatchingFingerprint(_ version: String?) async throws {
        let recordFileURL = try writeRecordFile(landType: "hero-defense", landDefinitionID: "hero-defense", version: version)
        defer { try? FileManager.default.removeItem(at: recordFileURL) }
        let router = try await makeRouter()
        let body = try JSONSerialization.data(withJSONObject: [
            "landType": "hero-defense", "recordFilePath": recordFileURL.path,
        ])
        for uri in Self.startURIs {
            let response = try await sendReplayStartRequest(body: body, on: router, uri: uri)
            #expect(response.status == .conflict, "\(uri), \(version ?? "nil")")
            let decoded = try decodeAdminResponse(from: response)
            #expect(!decoded.success)
            #expect(decoded.error?.code == "RECORD_VERSION_MISMATCH", "\(uri), \(version ?? "nil")")
            #expect(detailString(decoded.error?.details, key: "recordedRecordVersion") == version, "\(uri)")
            #expect(detailString(decoded.error?.details, key: "expectedRecordVersion") == ReevaluationRecordVersion.current, "\(uri)")
        }
    }

    @Test("Both start routes refuse a record past the default run length limit, naming the last tick and the limit (#728)")
    func startRefusesARecordPastTheDefaultLimit() async throws {
        let limit = ReevaluationRecordFile.defaultMaxReplayTicks
        let recordFileURL = try writeRecordFile(
            landType: "hero-defense", landDefinitionID: "hero-defense",
            version: ReevaluationRecordVersion.current, tickIds: [0, limit]
        )
        defer { try? FileManager.default.removeItem(at: recordFileURL) }
        let router = try await makeRouter()
        let body = try JSONSerialization.data(withJSONObject: [
            "landType": "hero-defense", "recordFilePath": recordFileURL.path,
        ])
        for uri in Self.startURIs {
            let response = try await sendReplayStartRequest(body: body, on: router, uri: uri)
            #expect(response.status == .badRequest, "\(uri)")
            let decoded = try decodeAdminResponse(from: response)
            #expect(!decoded.success)
            let message = try #require(decoded.error?.message, "\(uri)")
            #expect(message.contains("last tick is \(limit)"), "\(uri): \(message)")
            #expect(message.contains("limit of \(limit)"), "\(uri): \(message)")
        }
    }

    @Test("Both start routes accept a record at the default limit (#728)")
    func startAcceptsARecordAtTheDefaultLimit() async throws {
        let recordFileURL = try writeRecordFile(
            landType: "hero-defense", landDefinitionID: "hero-defense",
            version: ReevaluationRecordVersion.current, tickIds: [0, ReevaluationRecordFile.defaultMaxReplayTicks - 1]
        )
        defer { try? FileManager.default.removeItem(at: recordFileURL) }
        let router = try await makeRouter()
        let body = try JSONSerialization.data(withJSONObject: [
            "landType": "hero-defense", "recordFilePath": recordFileURL.path,
        ])
        for uri in Self.startURIs {
            #expect(try await sendReplayStartRequest(body: body, on: router, uri: uri).status == .ok, "\(uri)")
        }
    }

    @Test("Both start routes accept the same record when the host raised the limit, and use the limit of the land type asked for (#728)")
    func startUsesTheHostsLimit() async throws {
        let limit = ReevaluationRecordFile.defaultMaxReplayTicks
        let recordFileURL = try writeRecordFile(
            landType: "hero-defense", landDefinitionID: "hero-defense",
            version: ReevaluationRecordVersion.current, tickIds: [0, limit]
        )
        defer { try? FileManager.default.removeItem(at: recordFileURL) }
        let body = try JSONSerialization.data(withJSONObject: [
            "landType": "hero-defense", "recordFilePath": recordFileURL.path,
        ])
        let raised = try await makeRouter(maxReplayTicksByLandType: ["hero-defense": limit + 1])
        for uri in Self.startURIs {
            #expect(try await sendReplayStartRequest(body: body, on: raised, uri: uri).status == .ok, "\(uri)")
        }
        // The limit is per land type: another land type's raised limit doesn't apply here, and a
        // lowered limit is honored.
        let other = try await makeRouter(maxReplayTicksByLandType: ["other-land": limit + 1])
        let lowered = try await makeRouter(maxReplayTicksByLandType: ["hero-defense": 1])
        for uri in Self.startURIs {
            #expect(try await sendReplayStartRequest(body: body, on: other, uri: uri).status == .badRequest, "\(uri)")
            #expect(try await sendReplayStartRequest(body: body, on: lowered, uri: uri).status == .badRequest, "\(uri)")
        }
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
        let recordFileURL = try writeRecordFile(landType: "hero-defense", landDefinitionID: "hero-defense", version: ReevaluationRecordVersion.current)
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
            version: ReevaluationRecordVersion.current
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

/// The fingerprint test records carry unless a test names another.
private let testRecordFingerprint = "0123456789abcdef"

/// What the live land type `hero-defense` gives the route as its record schema fingerprint
/// (#521 D15).
private enum LiveLand {
    case fingerprint(String)
    /// Registered, but its server reports none (the protocol's default).
    case reportsNone
    /// Registered, but its definition has a type the fingerprint can't list.
    case unbuildable
    /// Not registered.
    case unregistered
}

private func makeRouter(
    live: LiveLand = .fingerprint(testRecordFingerprint),
    maxReplayTicksByLandType: [String: Int64] = [:]
) async throws -> NIOHTTPRouter {
    let landRealm = LandRealm()
    switch live {
    case .fingerprint(let fingerprint):
        try await landRealm.register(landType: "hero-defense", server: MockReplayLandServer(fingerprint: fingerprint))
    case .reportsNone:
        try await landRealm.register(landType: "hero-defense", server: MockReplayLandServer())
    case .unbuildable:
        try await landRealm.register(landType: "hero-defense", server: MockReplayLandServer(failure: .unbuildableType("Opaque")))
    case .unregistered:
        break
    }
    try await landRealm.register(landType: "hero-defense-replay", server: MockReplayLandServer())
    try await landRealm.register(landType: "reevaluation-monitor", server: MockReplayLandServer())

    let adminAuth = NIOAdminAuth(apiKey: "test-admin-key")
    let routes = NIOAdminRoutes(
        landRealm: landRealm, adminAuth: adminAuth, maxReplayTicksByLandType: maxReplayTicksByLandType
    )
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
    version: String?,
    schemaFingerprint: String? = testRecordFingerprint,
    tickIds: [Int64] = []
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
        hardwareInfo: nil,
        schemaFingerprint: schemaFingerprint
    )

    let frames = tickIds.map { ReevaluationTickFrame(tickId: $0, actions: [], clientEvents: [], lifecycleEvents: []) }
    let payload = ReplayRecordFile(recordMetadata: metadata, tickFrames: frames)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(payload)
    try data.write(to: fileURL)
    return fileURL
}

private struct MockReplayLandServer: LandServerProtocol {
    typealias State = DummyReplayState

    var fingerprint: String?
    var failure: SchemaFingerprintError?

    func recordSchemaFingerprint() throws -> String? {
        if let failure { throw failure }
        return fingerprint
    }

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

@PlainData
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
