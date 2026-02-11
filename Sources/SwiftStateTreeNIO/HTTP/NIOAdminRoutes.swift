// Sources/SwiftStateTreeNIO/HTTP/NIOAdminRoutes.swift
//
// Admin HTTP routes for NIO-based servers.

import Foundation
import Logging
import NIOHTTP1
import SwiftStateTree
import SwiftStateTreeTransport

/// Admin HTTP routes for managing lands across all land types.
///
/// Provides endpoints for querying, creating, and managing lands.
/// Works with `LandRealm` to aggregate data from all registered `LandServer` instances.
public struct NIOAdminRoutes: Sendable {
    public let landRealm: LandRealm
    public let adminAuth: NIOAdminAuth
    public let logger: Logger
    
    public init(
        landRealm: LandRealm,
        adminAuth: NIOAdminAuth,
        logger: Logger? = nil
    ) {
        self.landRealm = landRealm
        self.adminAuth = adminAuth
        self.logger = logger ?? Logger(label: "com.swiftstatetree.nio.admin.routes")
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
            "/admin/reevaluation/start"
        ]
        
        for path in optionsPaths {
            await router.options(path, handler: corsOptionsHandler)
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
                
                return NIOHTTPResponse.json(data: jsonData).withCORS()
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
            
            let jsonFiles = files.filter { $0.hasSuffix(".json") }
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
        
        logger.info("Registered admin routes", metadata: [
            "paths": .string(optionsPaths.joined(separator: ", "))
        ])
    }
}
