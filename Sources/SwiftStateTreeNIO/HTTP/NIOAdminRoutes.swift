// Sources/SwiftStateTreeNIO/HTTP/NIOAdminRoutes.swift
//
// Admin HTTP routes for NIO-based servers.

import Foundation
import Logging
import NIOHTTP1
import SwiftStateTree
import SwiftStateTreeTransport

private enum ReplayStartCompatibilityError: Error, Sendable {
    case landTypeMismatch(expected: String, actual: String)
    case schemaMismatch(expectedLandDefinitionID: String, recordedLandDefinitionID: String?)
    case recordVersionMismatch(expectedVersion: String, recordedVersion: String?)
    /// Older than the oldest version this build reads (#154): re-record, never a replay mismatch.
    case recordVersionUnsupported(recordedVersion: String, minimumVersion: String)

    var apiCode: String {
        switch self {
        case .landTypeMismatch:
            return "LAND_TYPE_MISMATCH"
        case .schemaMismatch:
            return "SCHEMA_MISMATCH"
        case .recordVersionMismatch:
            return "RECORD_VERSION_MISMATCH"
        case .recordVersionUnsupported:
            return "RECORD_VERSION_UNSUPPORTED"
        }
    }

    var message: String {
        switch self {
        case .landTypeMismatch(let expected, let actual):
            return "Replay record landType mismatch: expected \(expected), got \(actual)."
        case .schemaMismatch(let expected, let actual):
            let actualValue = actual ?? "nil"
            return "Replay record schema mismatch: expected landDefinitionID \(expected), got \(actualValue)."
        case .recordVersionMismatch(let expected, let actual):
            let actualValue = actual ?? "nil"
            return "Replay record version mismatch: expected \(expected), got \(actualValue)."
        case .recordVersionUnsupported(let recorded, _):
            return ReevaluationRecordVersion.unsupportedReason(recorded: recorded) ?? "Unsupported record version \(recorded)."
        }
    }

    var details: [String: AnyCodable] {
        switch self {
        case .landTypeMismatch(let expected, let actual):
            return [
                "expectedLandType": AnyCodable(expected),
                "recordedLandType": AnyCodable(actual),
            ]
        case .schemaMismatch(let expected, let actual):
            return [
                "expectedLandDefinitionID": AnyCodable(expected),
                "recordedLandDefinitionID": AnyCodable(actual),
            ]
        case .recordVersionMismatch(let expected, let actual):
            return [
                "expectedRecordVersion": AnyCodable(expected),
                "recordedRecordVersion": AnyCodable(actual),
            ]
        case .recordVersionUnsupported(let recorded, let minimum):
            return [
                "recordedRecordVersion": AnyCodable(recorded),
                "minimumRecordVersion": AnyCodable(minimum),
            ]
        }
    }
}

/// Admin HTTP routes for managing lands across all land types.
///
/// Provides endpoints for querying, creating, and managing lands.
/// Works with `LandRealm` to aggregate data from all registered `LandServer` instances.
public struct NIOAdminRoutes: Sendable {
    public let landRealm: LandRealm
    public let adminAuth: NIOAdminAuth
    public let logger: Logger
    /// Resolver for replay land WebSocket path. When nil, uses default "/game/{replayLandType}".
    public let replayWebSocketPathResolver: (@Sendable (String) -> String)?
    /// Suffix appended to base land type to form the replay land type (e.g. "-replay").
    public let replayLandSuffix: String
    /// Whether `/admin/lands/:landID/debug/*` (freeze, projection, resume) is registered.
    ///
    /// These routes expose full land state and let a caller pause a land (a denial-of-service
    /// lever), so they need both the admin API key and this flag. Never enable in production.
    public let enableDebugStateRoutes: Bool

    /// - Parameter enableDebugStateRoutes: nil reads `ENABLE_DEBUG_STATE_ROUTES` (default false).
    public init(
        landRealm: LandRealm,
        adminAuth: NIOAdminAuth,
        logger: Logger? = nil,
        replayWebSocketPathResolver: (@Sendable (String) -> String)? = nil,
        replayLandSuffix: String = "-replay",
        enableDebugStateRoutes: Bool? = nil
    ) {
        self.landRealm = landRealm
        self.adminAuth = adminAuth
        self.logger = logger ?? Logger(label: "com.swiftstatetree.nio.admin.routes")
        self.replayWebSocketPathResolver = replayWebSocketPathResolver
        self.replayLandSuffix = replayLandSuffix
        self.enableDebugStateRoutes = enableDebugStateRoutes ?? NIOEnvConfig.fromEnvironment().enableDebugStateRoutes
    }
    
    /// Register admin routes to the router.
    public func registerRoutes(on router: NIOHTTPRouter) async {
        // Helper for CORS preflight
        let corsOptionsHandler: NIOHTTPHandler = { _ in
            NIOHTTPResponse.noContent()
                .withCORS(maxAge: "3600")
        }
        
        // Helper for unauthorized response
        @Sendable func unauthorizedResponse() throws -> NIOHTTPResponse {
            let response = AdminAPIAnyResponse.error(
                code: .unauthorized,
                message: "Invalid API key"
            )
            return try NIOHTTPResponse.json(response, status: .unauthorized).withCORS()
        }
        
        // Register OPTIONS handlers for CORS preflight
        let optionsPaths = [
            "/admin/lands",
            "/admin/lands/:landID",
            "/admin/lands/:landID/stats",
            "/admin/lands/:landID/reevaluation-record",
            "/admin/stats",
            "/admin/reevaluation/records",
            "/admin/reevaluation/start",
            "/admin/reevaluation/replay/start"
        ]
        
        for path in optionsPaths {
            await router.options(path, handler: corsOptionsHandler)
        }

        if enableDebugStateRoutes {
            await registerDebugStateRoutes(on: router, corsOptionsHandler: corsOptionsHandler)
        }
        
        // GET /admin/lands - List all lands
        await router.get("/admin/lands") { [self] request in
            guard adminAuth.hasRequiredRole(from: request, requiredRole: .viewer) else {
                return try unauthorizedResponse()
            }
            
            let landIDs = await landRealm.listAllLands()
            let landList = landIDs.map { $0.stringValue }
            
            let response = AdminAPIAnyResponse.success(landList)
            return try NIOHTTPResponse.json(response).withCORS()
        }
        
        // GET /admin/lands/:landID - Get specific land info
        await router.get("/admin/lands/:landID") { [self] request in
            guard adminAuth.hasRequiredRole(from: request, requiredRole: .viewer) else {
                return try unauthorizedResponse()
            }
            
            guard let landIDString = request.pathParam("landID") else {
                let response = AdminAPIAnyResponse.error(
                    code: .invalidRequest,
                    message: "Missing landID"
                )
                return try NIOHTTPResponse.json(response, status: .badRequest).withCORS()
            }
            
            let landID = LandID(landIDString)
            
            guard let stats = await landRealm.getLandStats(landID: landID) else {
                let response = AdminAPIAnyResponse.error(
                    code: .notFound,
                    message: "Land not found",
                    details: ["landID": AnyCodable(landIDString)]
                )
                return try NIOHTTPResponse.json(response, status: .notFound).withCORS()
            }
            
            let response = AdminAPIAnyResponse.success(stats)
            return try NIOHTTPResponse.json(response).withCORS()
        }
        
        // GET /admin/lands/:landID/stats - Get land statistics
        await router.get("/admin/lands/:landID/stats") { [self] request in
            guard adminAuth.hasRequiredRole(from: request, requiredRole: .viewer) else {
                return try unauthorizedResponse()
            }
            
            guard let landIDString = request.pathParam("landID") else {
                let response = AdminAPIAnyResponse.error(
                    code: .invalidRequest,
                    message: "Missing landID"
                )
                return try NIOHTTPResponse.json(response, status: .badRequest).withCORS()
            }
            
            let landID = LandID(landIDString)
            
            guard let stats = await landRealm.getLandStats(landID: landID) else {
                let response = AdminAPIAnyResponse.error(
                    code: .notFound,
                    message: "Land not found",
                    details: ["landID": AnyCodable(landIDString)]
                )
                return try NIOHTTPResponse.json(response, status: .notFound).withCORS()
            }
            
            let response = AdminAPIAnyResponse.success(stats)
            return try NIOHTTPResponse.json(response).withCORS()
        }
        
        // GET /admin/lands/:landID/reevaluation-record - Download re-evaluation record
        await router.get("/admin/lands/:landID/reevaluation-record") { [self] request in
            guard adminAuth.hasRequiredRole(from: request, requiredRole: .admin) else {
                return try unauthorizedResponse()
            }
            
            guard let landIDString = request.pathParam("landID") else {
                let response = AdminAPIAnyResponse.error(
                    code: .invalidRequest,
                    message: "Missing landID"
                )
                return try NIOHTTPResponse.json(response, status: .badRequest).withCORS()
            }
            
            let landID = LandID(landIDString)
            
            do {
                guard let jsonData = try await landRealm.getReevaluationRecord(landID: landID) else {
                    let response = AdminAPIAnyResponse.error(
                        code: .notFound,
                        message: "Re-evaluation record not found",
                        details: ["landID": AnyCodable(landIDString)]
                    )
                    return try NIOHTTPResponse.json(response, status: .notFound).withCORS()
                }
                
                // A 3.0 record (binary log, #245); a client saves the bytes as they are.
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: "application/octet-stream")
                return NIOHTTPResponse(status: .ok, headers: headers, body: jsonData).withCORS()
            } catch {
                logger.error("Failed to get re-evaluation record: \(error)")
                let response = AdminAPIAnyResponse.error(
                    code: .internalError,
                    message: "Failed to get re-evaluation record"
                )
                return try NIOHTTPResponse.json(response, status: .internalServerError).withCORS()
            }
        }
        
        // POST /admin/lands - Create a new land
        await router.post("/admin/lands") { [self] request in
            guard adminAuth.hasRequiredRole(from: request, requiredRole: .admin) else {
                return try unauthorizedResponse()
            }
            
            let response = AdminAPIAnyResponse.error(
                code: .notImplemented,
                message: "Create land endpoint is not yet implemented"
            )
            return try NIOHTTPResponse.json(response, status: .notImplemented).withCORS()
        }
        
        // DELETE /admin/lands/:landID - Remove a land
        await router.delete("/admin/lands/:landID") { [self] request in
            guard adminAuth.hasRequiredRole(from: request, requiredRole: .admin) else {
                return try unauthorizedResponse()
            }
            
            guard let landIDString = request.pathParam("landID") else {
                let response = AdminAPIAnyResponse.error(
                    code: .invalidRequest,
                    message: "Missing landID"
                )
                return try NIOHTTPResponse.json(response, status: .badRequest).withCORS()
            }
            
            let landID = LandID(landIDString)
            await landRealm.removeLand(landID: landID)
            
            let response = AdminAPIAnyResponse.success(["message": AnyCodable("Land deleted successfully")])
            return try NIOHTTPResponse.json(response).withCORS()
        }
        
        // GET /admin/stats - System statistics
        await router.get("/admin/stats") { [self] request in
            guard adminAuth.hasRequiredRole(from: request, requiredRole: .viewer) else {
                return try unauthorizedResponse()
            }
            
            let landIDs = await landRealm.listAllLands()
            var totalPlayers = 0
            
            for landID in landIDs {
                if let stats = await landRealm.getLandStats(landID: landID) {
                    totalPlayers += stats.playerCount
                }
            }
            
            let systemStats: [String: AnyCodable] = [
                "totalLands": AnyCodable(landIDs.count),
                "totalPlayers": AnyCodable(totalPlayers)
            ]
            
            let response = AdminAPIAnyResponse.success(systemStats)
            return try NIOHTTPResponse.json(response).withCORS()
        }
        
        // GET /admin/reevaluation/records - List all reevaluation records
        let nioEnvConfig = NIOEnvConfig.fromEnvironment()
        await router.get("/admin/reevaluation/records") { [self, nioEnvConfig] request in
            guard adminAuth.hasRequiredRole(from: request, requiredRole: .viewer) else {
                return try unauthorizedResponse()
            }
            
            let recordsDir = nioEnvConfig.reevaluationRecordsDir
            
            let fileManager = FileManager.default
            guard let files = try? fileManager.contentsOfDirectory(atPath: recordsDir) else {
                let response = AdminAPIAnyResponse.success([String]())
                return try NIOHTTPResponse.json(response).withCORS()
            }
            
            let jsonFiles = files.filter { $0.hasSuffix(".json") || $0.hasSuffix(".sstr") }
                .map { "\(recordsDir)/\($0)" }
            
            let response = AdminAPIAnyResponse.success(jsonFiles)
            return try NIOHTTPResponse.json(response).withCORS()
        }
        
        // POST /admin/reevaluation/start - Start reevaluation verification
        await router.post("/admin/reevaluation/start") { [self] request in
            guard adminAuth.hasRequiredRole(from: request, requiredRole: .admin) else {
                return try unauthorizedResponse()
            }
            
            let monitorLandID = LandID("reevaluation-monitor:\(UUID().uuidString)")
            
            let response = AdminAPIAnyResponse.success([
                "monitorLandID": AnyCodable(monitorLandID.stringValue)
            ])
            return try NIOHTTPResponse.json(response).withCORS()
        }

        // POST /admin/reevaluation/replay/start - Start server-side replay stream session
        await router.post("/admin/reevaluation/replay/start") { [self, nioEnvConfig] request in
            guard adminAuth.hasRequiredRole(from: request, requiredRole: .admin) else {
                return try unauthorizedResponse()
            }

            guard let body = request.body,
                  let payload = try? JSONDecoder().decode(StartReevaluationReplayRequest.self, from: body)
            else {
                let response = AdminAPIAnyResponse.error(
                    code: .invalidRequest,
                    message: "Invalid JSON body. Expect { landType, recordFilePath, expectedLandDefinitionID?, expectedRecordVersion? }."
                )
                return try NIOHTTPResponse.json(response, status: .badRequest).withCORS()
            }

            let replayLandType = "\(payload.landType)\(replayLandSuffix)"
            guard await landRealm.isRegistered(landType: replayLandType) else {
                let response = AdminAPIAnyResponse.error(
                    code: .invalidRequest,
                    message: "Replay land type is not registered",
                    details: [
                        "landType": AnyCodable(payload.landType),
                        "replayLandType": AnyCodable(replayLandType),
                    ]
                )
                return try NIOHTTPResponse.json(response, status: .badRequest).withCORS()
            }

            guard let resolvedRecordPath = resolveReevaluationRecordPath(
                rawPath: payload.recordFilePath,
                recordsDir: nioEnvConfig.reevaluationRecordsDir
            ) else {
                let response = AdminAPIAnyResponse.error(
                    code: .invalidRequest,
                    message: "Path must be within reevaluation records directory"
                )
                return try NIOHTTPResponse.json(response, status: .badRequest).withCORS()
            }

            guard FileManager.default.fileExists(atPath: resolvedRecordPath.path) else {
                let response = AdminAPIAnyResponse.error(
                    code: .notFound,
                    message: "Record file not found"
                )
                return try NIOHTTPResponse.json(response, status: .notFound).withCORS()
            }

            do {
                let source = try ReevaluationRecordFile.openSource(filePath: resolvedRecordPath.path)
                let metadata = try await source.getMetadata()
                try validateReplayCompatibility(
                    metadata: metadata,
                    expectedLandType: payload.landType,
                    expectedLandDefinitionID: payload.expectedLandDefinitionID,
                    expectedRecordVersion: payload.expectedRecordVersion
                )
            } catch let ReevaluationRecordVersionError.unsupported(recorded, minimum) {
                // Rejected when the source opened the record
                let compatibilityError = ReplayStartCompatibilityError.recordVersionUnsupported(
                    recordedVersion: recorded,
                    minimumVersion: minimum
                )
                let response = AdminAPIAnyResponse.error(
                    AdminAPIError(
                        code: compatibilityError.apiCode,
                        message: compatibilityError.message,
                        details: compatibilityError.details
                    )
                )
                return try NIOHTTPResponse.json(response, status: .conflict).withCORS()
            } catch let compatibilityError as ReplayStartCompatibilityError {
                let response = AdminAPIAnyResponse.error(
                    AdminAPIError(
                        code: compatibilityError.apiCode,
                        message: compatibilityError.message,
                        details: compatibilityError.details
                    )
                )
                return try NIOHTTPResponse.json(response, status: .conflict).withCORS()
            } catch {
                logger.error("Failed to validate replay record compatibility: \(error)")
                let response = AdminAPIAnyResponse.error(
                    code: .invalidRequest,
                    message: "Failed to read reevaluation record metadata"
                )
                return try NIOHTTPResponse.json(response, status: .badRequest).withCORS()
            }

            let pathToken = encodeBase64URL(resolvedRecordPath.path)
            let landID = LandID(landType: replayLandType, instanceId: "\(UUID().uuidString.lowercased()).\(pathToken)")
            let webSocketPath = replayWebSocketPathResolver?(replayLandType) ?? "/game/\(replayLandType)"

            let response = AdminAPIAnyResponse.success([
                "replayLandID": AnyCodable(landID.stringValue),
                "webSocketPath": AnyCodable(webSocketPath),
                "landType": AnyCodable(payload.landType),
                "recordFilePath": AnyCodable(resolvedRecordPath.path),
            ])
            return try NIOHTTPResponse.json(response).withCORS()
        }
        
        logger.info("Registered admin routes", metadata: [
            "paths": .string(optionsPaths.joined(separator: ", "))
        ])
    }
}

// MARK: - Debug state routes

extension NIOAdminRoutes {
    static let debugStatePaths = [
        "/admin/lands/:landID/debug/freeze",
        "/admin/lands/:landID/debug/projection",
        "/admin/lands/:landID/debug/resume",
    ]

    /// `POST .../debug/freeze`, `GET .../debug/projection?playerID=...`,
    /// `POST .../debug/resume?freezeToken=...` (or body `{ "freezeToken": ... }`; a token of an
    /// already released freeze is a no-op). All require the `.admin` role.
    fileprivate func registerDebugStateRoutes(
        on router: NIOHTTPRouter,
        corsOptionsHandler: @escaping NIOHTTPHandler
    ) async {
        for path in Self.debugStatePaths {
            await router.options(path, handler: corsOptionsHandler)
        }

        @Sendable func errorResponse(
            _ code: AdminAPIErrorCode,
            _ message: String,
            status: HTTPResponseStatus,
            landID: String? = nil
        ) throws -> NIOHTTPResponse {
            let details = landID.map { ["landID": AnyCodable($0)] }
            let response = AdminAPIAnyResponse.error(code: code, message: message, details: details)
            return try NIOHTTPResponse.json(response, status: status).withCORS()
        }

        @Sendable func debugErrorResponse(_ error: Error, landID: String) throws -> NIOHTTPResponse {
            switch error as? DebugFreezeError {
            case .notFrozen:
                return try errorResponse(.invalidRequest, "Land is not frozen", status: .conflict, landID: landID)
            case .settleTimedOut:
                return try errorResponse(.internalError, "Drain or settle sync missed the deadline; the freeze was released", status: .serviceUnavailable, landID: landID)
            case .released:
                return try errorResponse(.invalidRequest, "The freeze was released before its settle finished", status: .conflict, landID: landID)
            case nil:
                return try errorResponse(.internalError, "Debug state operation failed: \(error)", status: .internalServerError, landID: landID)
            }
        }

        await router.post("/admin/lands/:landID/debug/freeze") { [self] request in
            guard adminAuth.hasRequiredRole(from: request, requiredRole: .admin) else {
                return try errorResponse(.unauthorized, "Invalid API key", status: .unauthorized)
            }
            guard let landIDString = request.pathParam("landID") else {
                return try errorResponse(.invalidRequest, "Missing landID", status: .badRequest)
            }
            do {
                guard let freeze = try await landRealm.debugFreeze(landID: LandID(landIDString)) else {
                    return try errorResponse(.notFound, "Land not found", status: .notFound, landID: landIDString)
                }
                logger.warning("Debug freeze", metadata: [
                    "landID": .string(landIDString),
                    "freezeCount": .stringConvertible(freeze.freezeCount),
                ])
                return try NIOHTTPResponse.json(AdminAPIResponse.success(freeze)).withCORS()
            } catch {
                return try debugErrorResponse(error, landID: landIDString)
            }
        }

        await router.get("/admin/lands/:landID/debug/projection") { [self] request in
            guard adminAuth.hasRequiredRole(from: request, requiredRole: .admin) else {
                return try errorResponse(.unauthorized, "Invalid API key", status: .unauthorized)
            }
            guard let landIDString = request.pathParam("landID") else {
                return try errorResponse(.invalidRequest, "Missing landID", status: .badRequest)
            }
            let playerID = request.queryParam("playerID").flatMap { $0.isEmpty ? nil : PlayerID($0) }
            do {
                guard let projection = try await landRealm.debugProjection(
                    landID: LandID(landIDString),
                    playerID: playerID
                ) else {
                    return try errorResponse(.notFound, "Land not found", status: .notFound, landID: landIDString)
                }
                return try NIOHTTPResponse.json(AdminAPIResponse.success(projection)).withCORS()
            } catch {
                return try debugErrorResponse(error, landID: landIDString)
            }
        }

        await router.post("/admin/lands/:landID/debug/resume") { [self] request in
            guard adminAuth.hasRequiredRole(from: request, requiredRole: .admin) else {
                return try errorResponse(.unauthorized, "Invalid API key", status: .unauthorized)
            }
            guard let landIDString = request.pathParam("landID") else {
                return try errorResponse(.invalidRequest, "Missing landID", status: .badRequest)
            }
            // Token from the query (`?freezeToken=`) or a JSON body `{ "freezeToken": ... }`.
            let bodyToken = request.body.flatMap { try? JSONDecoder().decode(DebugResumeRequest.self, from: $0) }?.freezeToken
            guard let freezeToken = request.queryParam("freezeToken") ?? bodyToken, !freezeToken.isEmpty else {
                return try errorResponse(.invalidRequest, "Missing freezeToken", status: .badRequest, landID: landIDString)
            }
            guard let resume = await landRealm.debugResume(landID: LandID(landIDString), freezeToken: freezeToken) else {
                return try errorResponse(.notFound, "Land not found", status: .notFound, landID: landIDString)
            }
            return try NIOHTTPResponse.json(AdminAPIResponse.success(resume)).withCORS()
        }

        logger.warning("Debug state routes registered (exposes full land state; not for production)", metadata: [
            "paths": .string(Self.debugStatePaths.joined(separator: ", "))
        ])
    }
}

private struct StartReevaluationReplayRequest: Decodable {
    let landType: String
    let recordFilePath: String
    let expectedLandDefinitionID: String?
    let expectedRecordVersion: String?
}

private func validateReplayCompatibility(
    metadata: ReevaluationRecordMetadata,
    expectedLandType: String,
    expectedLandDefinitionID: String?,
    expectedRecordVersion: String?
) throws {
    if metadata.landType != expectedLandType {
        throw ReplayStartCompatibilityError.landTypeMismatch(expected: expectedLandType, actual: metadata.landType)
    }

    if let expectedLandDefinitionID,
       metadata.landDefinitionID != expectedLandDefinitionID {
        throw ReplayStartCompatibilityError.schemaMismatch(
            expectedLandDefinitionID: expectedLandDefinitionID,
            recordedLandDefinitionID: metadata.landDefinitionID
        )
    }

    if let expectedRecordVersion,
       !ReevaluationRecordVersion.isCompatible(recorded: metadata.version, required: expectedRecordVersion) {
        throw ReplayStartCompatibilityError.recordVersionMismatch(
            expectedVersion: expectedRecordVersion,
            recordedVersion: metadata.version
        )
    }
}

/// The record a replay start names, or `nil` when it isn't within `recordsDir` (#281).
///
/// An absolute path is taken as is; a relative one is tried against the current directory, then
/// against `recordsDir`. The returned path keeps the client's spelling, with only `.` and `..`
/// removed: the containment check standardizes both sides (`standardizedFileURL`, which on
/// macOS also drops the `/private` of `/private/tmp`), but the response and the replay land's
/// token carry the path as sent, the same on every platform.
func resolveReevaluationRecordPath(
    rawPath: String,
    recordsDir: String,
    currentDirectory: String = FileManager.default.currentDirectoryPath
) -> URL? {
    let currentDirURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
    let recordsDirURL = URL(fileURLWithPath: recordsDir, isDirectory: true, relativeTo: currentDirURL)
    let recordsDirCheckURL = recordsDirURL.standardizedFileURL

    let candidates = rawPath.hasPrefix("/")
        ? [URL(fileURLWithPath: rawPath)]
        : [URL(fileURLWithPath: rawPath, relativeTo: currentDirURL), URL(fileURLWithPath: rawPath, relativeTo: recordsDirURL)]
    for candidate in candidates {
        // The path that is returned and opened is the one checked: `.` and `..` are removed
        // lexically first, so the check's `standardizedFileURL` (which may resolve `..` against
        // the real parent of a symlink on some Foundation versions) has no `..` left to resolve
        // and only reconciles spellings such as macOS's `/private`.
        let resolved = candidate.absoluteURL.standardized
        if isWithinDirectory(resolved.standardizedFileURL, directoryURL: recordsDirCheckURL) {
            return resolved
        }
    }
    return nil
}

private func encodeBase64URL(_ raw: String) -> String {
    Data(raw.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func isWithinDirectory(_ fileURL: URL, directoryURL: URL) -> Bool {
    if fileURL.path == directoryURL.path {
        return true
    }

    let directoryPath = directoryURL.path.hasSuffix("/") ? directoryURL.path : "\(directoryURL.path)/"
    return fileURL.path.hasPrefix(directoryPath)
}
