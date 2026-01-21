import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
import Logging
import NIOCore
import HTTPTypes

/// Admin HTTP routes for managing lands across all land types.
///
/// Provides endpoints for querying, creating, and managing lands.
/// Works with `LandRealm` to aggregate data from all registered `LandServer` instances,
/// regardless of their `State` types.
///
/// **Key Feature**: Unlike the old `AdminRoutes<State>`, this version can manage
/// lands across different `State` types when used with `LandRealm`.
public struct AdminRoutes: Sendable {
    public let landRealm: LandRealm
    public let adminAuth: AdminAuthMiddleware
    public let logger: Logger
    
    public init(
        landRealm: LandRealm,
        adminAuth: AdminAuthMiddleware,
        logger: Logger? = nil
    ) {
        self.landRealm = landRealm
        self.adminAuth = adminAuth
        self.logger = logger ?? Logger(label: "com.swiftstatetree.admin.routes")
    }
    
    /// Register admin routes to the router.
    ///
    /// - Parameter router: The Hummingbird router to register routes on.
    public func registerRoutes(on router: Router<BasicWebSocketRequestContext>) {
        // Helper function to create CORS response for OPTIONS requests
        func corsOptionsResponse() -> Response {
            var response = Response(status: .ok)
            response.headers[HTTPField.Name("Access-Control-Allow-Origin")!] = "*"
            response.headers[HTTPField.Name("Access-Control-Allow-Methods")!] = "GET, POST, DELETE, OPTIONS"
            response.headers[HTTPField.Name("Access-Control-Allow-Headers")!] = "Content-Type, X-API-Key, Authorization"
            response.headers[HTTPField.Name("Access-Control-Max-Age")!] = "3600"
            return response
        }
        
        // Register OPTIONS handler for all admin routes to handle CORS preflight
        // Note: Hummingbird router.on may not support OPTIONS directly, so we'll handle it in each route
        // For now, we rely on the CORS headers in adminResponse to handle simple requests
        // OPTIONS preflight will be handled by checking request method in route handlers if needed
        
        // GET /admin/lands - List all lands
        router.get("/admin/lands") { request, context in
            guard await self.adminAuth.hasRequiredRole(from: request, requiredRole: .viewer) else {
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .unauthorized,
                    message: "Invalid API key or token"
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .unauthorized)
            }
            
            // List all lands across all registered servers
            let landIDs = await self.landRealm.listAllLands()
            let landList = landIDs.map { $0.stringValue }
            
            do {
                let response = AdminAPIAnyResponse.success(landList)
                return try HTTPResponseHelpers.adminResponse(response)
            } catch {
                self.logger.error("Failed to encode land list: \(error)")
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .internalError,
                    message: "Failed to encode land list"
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .internalServerError)
            }
        }
        
        // GET /admin/lands/:landID - Get specific land info
        router.get("/admin/lands/:landID") { request, context in
            guard await self.adminAuth.hasRequiredRole(from: request, requiredRole: .viewer) else {
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .unauthorized,
                    message: "Invalid API key or token"
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .unauthorized)
            }
            
            // Extract landID from path and URL decode
            let landIDString = context.parameters.get("landID") ?? "unknown"
            let decodedLandIDString = landIDString.removingPercentEncoding ?? landIDString
            let landID = LandID(decodedLandIDString)
            
            // Get land stats from any registered server
            guard let stats = await self.landRealm.getLandStats(landID: landID) else {
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .notFound,
                    message: "Land not found",
                    details: ["landID": AnyCodable(landIDString)]
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .notFound)
            }
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            
            do {
                let response = AdminAPIAnyResponse.success(stats)
                return try HTTPResponseHelpers.adminResponse(response, encoder: encoder)
            } catch {
                self.logger.error("Failed to encode land stats: \(error)")
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .internalError,
                    message: "Failed to encode land stats"
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .internalServerError)
            }
        }
        
        // GET /admin/lands/:landID/stats - Get land statistics (alias for above)
        router.get("/admin/lands/:landID/stats") { request, context in
            guard await self.adminAuth.hasRequiredRole(from: request, requiredRole: .viewer) else {
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .unauthorized,
                    message: "Invalid API key or token"
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .unauthorized)
            }
            
            let landIDString = context.parameters.get("landID") ?? "unknown"
            let decodedLandIDString = landIDString.removingPercentEncoding ?? landIDString
            let landID = LandID(decodedLandIDString)
            
            guard let stats = await self.landRealm.getLandStats(landID: landID) else {
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .notFound,
                    message: "Land not found",
                    details: ["landID": AnyCodable(decodedLandIDString)]
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .notFound)
            }
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            
            do {
                let response = AdminAPIAnyResponse.success(stats)
                return try HTTPResponseHelpers.adminResponse(response, encoder: encoder)
            } catch {
                self.logger.error("Failed to encode land stats: \(error)")
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .internalError,
                    message: "Failed to encode land stats"
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .internalServerError)
            }
        }

        // GET /admin/lands/:landID/reevaluation-record - Download re-evaluation record (admin only)
        router.get("/admin/lands/:landID/reevaluation-record") { request, context in
            guard await self.adminAuth.hasRequiredRole(from: request, requiredRole: .admin) else {
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .unauthorized,
                    message: "Invalid API key or token"
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .unauthorized)
            }

            let landIDString = context.parameters.get("landID") ?? "unknown"
            let decodedLandIDString = landIDString.removingPercentEncoding ?? landIDString
            let landID = LandID(decodedLandIDString)

            do {
                guard let jsonData = try await self.landRealm.getReevaluationRecord(landID: landID) else {
                    let errorResponse = AdminAPIAnyResponse.error(
                        code: .notFound,
                        message: "Re-evaluation record not found",
                        details: ["landID": AnyCodable(decodedLandIDString)]
                    )
                    return try HTTPResponseHelpers.adminResponse(errorResponse, status: .notFound)
                }

                var response = HTTPResponseHelpers.jsonResponse(from: jsonData, status: .ok)
                response.headers[HTTPField.Name("Access-Control-Allow-Origin")!] = "*"
                response.headers[HTTPField.Name("Access-Control-Allow-Methods")!] = "GET, POST, DELETE, OPTIONS"
                response.headers[HTTPField.Name("Access-Control-Allow-Headers")!] = "Content-Type, X-API-Key, Authorization"
                return response
            } catch {
                self.logger.error("Failed to get re-evaluation record: \(error)")
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .internalError,
                    message: "Failed to get re-evaluation record"
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .internalServerError)
            }
        }
        
        // POST /admin/lands - Create a new land (admin only)
        router.post("/admin/lands") { request, context in
            guard await self.adminAuth.hasRequiredRole(from: request, requiredRole: .admin) else {
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .unauthorized,
                    message: "Invalid API key or token"
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .unauthorized)
            }
            
            // Extract landID from request body or generate one
            // For now, generate a new landID
            _ = LandID(UUID().uuidString)
            
            // Note: This requires definition and initialState, which should come from request body
            // For now, return not implemented
            let errorResponse = AdminAPIAnyResponse.error(
                code: .notImplemented,
                message: "Create land endpoint is not yet implemented"
            )
            return try HTTPResponseHelpers.adminResponse(errorResponse, status: .notImplemented)
        }
        
        // DELETE /admin/lands/:landID - Remove a land (admin only)
        router.delete("/admin/lands/:landID") { request, context in
            guard await self.adminAuth.hasRequiredRole(from: request, requiredRole: .admin) else {
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .unauthorized,
                    message: "Invalid API key or token"
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .unauthorized)
            }
            
            let landIDString = context.parameters.get("landID") ?? "unknown"
            let decodedLandIDString = landIDString.removingPercentEncoding ?? landIDString
            let landID = LandID(decodedLandIDString)
            
            await self.landRealm.removeLand(landID: landID)
            
            // Return success response for DELETE (no content, but with unified format)
            let response = AdminAPIAnyResponse.success(["message": AnyCodable("Land deleted successfully")])
            return try HTTPResponseHelpers.adminResponse(response, status: .ok)
        }
        
        // GET /admin/stats - System statistics
        router.get("/admin/stats") { request, context in
            guard await self.adminAuth.hasRequiredRole(from: request, requiredRole: .viewer) else {
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .unauthorized,
                    message: "Invalid API key or token"
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .unauthorized)
            }
            
            // Get system stats across all registered servers
            let landIDs = await self.landRealm.listAllLands()
            var totalPlayers = 0
            
            for landID in landIDs {
                if let stats = await self.landRealm.getLandStats(landID: landID) {
                    totalPlayers += stats.playerCount
                }
            }
            
            let systemStats: [String: AnyCodable] = [
                "totalLands": AnyCodable(landIDs.count),
                "totalPlayers": AnyCodable(totalPlayers)
            ]
            
            do {
                let response = AdminAPIAnyResponse.success(systemStats)
                return try HTTPResponseHelpers.adminResponse(response)
            } catch {
                self.logger.error("Failed to encode system stats: \(error)")
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .internalError,
                    message: "Failed to encode system stats"
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .internalServerError)
            }
        }
    }
}

