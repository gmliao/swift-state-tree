import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore
import SwiftStateTree
import SwiftStateTreeTransport

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
        @Sendable func corsOptionsResponse() -> Response {
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

        // Handle OPTIONS requests for specific admin paths
        // We register these explicitly to ensure CORS preflight works
        // Note: Avoid wildcard overlaps which can cause crashes in some Router implementations
        router.on("/admin/reevaluation/records", method: .options) { _, _ in
            corsOptionsResponse()
        }
        router.on("/admin/reevaluation/start", method: .options) { _, _ in
            corsOptionsResponse()
        }
        // Register OPTIONS for exact match /admin/lands only
        router.on("/admin/lands", method: .options) { _, _ in
            corsOptionsResponse()
        }
        // For subpaths like /admin/lands/:landID, we rely on the specific method handlers to handle CORS response headers
        // or we need to register exact path patterns if preflight is needed for them.
        router.on("/admin/lands/:landID", method: .options) { _, _ in
            corsOptionsResponse()
        }
        router.on("/admin/lands/:landID/stats", method: .options) { _, _ in
            corsOptionsResponse()
        }
        router.on("/admin/lands/:landID/reevaluation-record", method: .options) { _, _ in
            corsOptionsResponse()
        }
        router.on("/admin/stats", method: .options) { _, _ in
            corsOptionsResponse()
        }

        // GET /admin/lands - List all lands
        router.get("/admin/lands") { request, _ in
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
        router.post("/admin/lands") { request, _ in
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
        router.get("/admin/stats") { request, _ in
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
                "totalPlayers": AnyCodable(totalPlayers),
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

        // GET /admin/reevaluation/records - List all reevaluation records
        router.get("/admin/reevaluation/records") { request, _ in
            guard await self.adminAuth.hasRequiredRole(from: request, requiredRole: .viewer) else {
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .unauthorized,
                    message: "Invalid API key or token"
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .unauthorized)
            }

            // Get records directory from environment or use default
            let recordsDir = ProcessInfo.processInfo.environment["REEVALUATION_RECORDS_DIR"]
                ?? "./reevaluation-records"

            // List all .json files
            let fileManager = FileManager.default
            guard let files = try? fileManager.contentsOfDirectory(atPath: recordsDir) else {
                let response = AdminAPIAnyResponse.success([String]())
                return try HTTPResponseHelpers.adminResponse(response)
            }

            let jsonFiles = files.filter { $0.hasSuffix(".json") }
                .map { "\(recordsDir)/\($0)" }

            let response = AdminAPIAnyResponse.success(jsonFiles)
            return try HTTPResponseHelpers.adminResponse(response)
        }

        // POST /admin/reevaluation/start - Start reevaluation verification
        router.post("/admin/reevaluation/start") { request, _ in
            guard await self.adminAuth.hasRequiredRole(from: request, requiredRole: .admin) else {
                let errorResponse = AdminAPIAnyResponse.error(
                    code: .unauthorized,
                    message: "Invalid API key or token"
                )
                return try HTTPResponseHelpers.adminResponse(errorResponse, status: .unauthorized)
            }

            // Create a new ReevaluationMonitor Land instance
            let monitorLandID = LandID("reevaluation-monitor:\(UUID().uuidString)")

            // Note: The ReevaluationMonitor Land should be registered in the LandRealm
            // before this endpoint can be used. This is typically done in the server setup.

            let response = AdminAPIAnyResponse.success([
                "monitorLandID": AnyCodable(monitorLandID.stringValue),
            ])
            return try HTTPResponseHelpers.adminResponse(response)
        }
    }
}
