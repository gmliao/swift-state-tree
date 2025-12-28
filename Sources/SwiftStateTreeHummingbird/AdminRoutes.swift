import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
import Logging
import NIOCore

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
        // GET /admin/lands - List all lands
        router.get("/admin/lands") { request, context in
            guard await self.adminAuth.hasRequiredRole(from: request, requiredRole: .viewer) else {
                return Response(status: .unauthorized)
            }
            
            // List all lands across all registered servers
            let landIDs = await self.landRealm.listAllLands()
            let landList = landIDs.map { $0.stringValue }
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            
            do {
                let jsonData = try encoder.encode(landList)
                var buffer = ByteBufferAllocator().buffer(capacity: jsonData.count)
                buffer.writeBytes(jsonData)
                var response = Response(status: .ok, body: .init(byteBuffer: buffer))
                response.headers[.contentType] = "application/json"
                return response
            } catch {
                self.logger.error("Failed to encode land list: \(error)")
                return Response(status: .internalServerError)
            }
        }
        
        // GET /admin/lands/:landID - Get specific land info
        router.get("/admin/lands/:landID") { request, context in
            guard await self.adminAuth.hasRequiredRole(from: request, requiredRole: .viewer) else {
                return Response(status: .unauthorized)
            }
            
            // Extract landID from path
            let landIDString = context.parameters.get("landID") ?? "unknown"
            let landID = LandID(landIDString)
            
            // Get land stats from any registered server
            guard let stats = await self.landRealm.getLandStats(landID: landID) else {
                return Response(status: .notFound)
            }
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            
            do {
                let jsonData = try encoder.encode(stats)
                var buffer = ByteBufferAllocator().buffer(capacity: jsonData.count)
                buffer.writeBytes(jsonData)
                var response = Response(status: .ok, body: .init(byteBuffer: buffer))
                response.headers[.contentType] = "application/json"
                return response
            } catch {
                self.logger.error("Failed to encode land stats: \(error)")
                return Response(status: .internalServerError)
            }
        }
        
        // GET /admin/lands/:landID/stats - Get land statistics (alias for above)
        router.get("/admin/lands/:landID/stats") { request, context in
            guard await self.adminAuth.hasRequiredRole(from: request, requiredRole: .viewer) else {
                return Response(status: .unauthorized)
            }
            
            let landIDString = context.parameters.get("landID") ?? "unknown"
            let landID = LandID(landIDString)
            
            guard let stats = await self.landRealm.getLandStats(landID: landID) else {
                return Response(status: .notFound)
            }
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            
            do {
                let jsonData = try encoder.encode(stats)
                var buffer = ByteBufferAllocator().buffer(capacity: jsonData.count)
                buffer.writeBytes(jsonData)
                var response = Response(status: .ok, body: .init(byteBuffer: buffer))
                response.headers[.contentType] = "application/json"
                return response
            } catch {
                self.logger.error("Failed to encode land stats: \(error)")
                return Response(status: .internalServerError)
            }
        }
        
        // POST /admin/lands - Create a new land (admin only)
        router.post("/admin/lands") { request, context in
            guard await self.adminAuth.hasRequiredRole(from: request, requiredRole: .admin) else {
                return Response(status: .unauthorized)
            }
            
            // Extract landID from request body or generate one
            // For now, generate a new landID
            _ = LandID(UUID().uuidString)
            
            // Note: This requires definition and initialState, which should come from request body
            // For now, return not implemented
            return Response(status: .notImplemented)
        }
        
        // DELETE /admin/lands/:landID - Remove a land (admin only)
        router.delete("/admin/lands/:landID") { request, context in
            guard await self.adminAuth.hasRequiredRole(from: request, requiredRole: .admin) else {
                return Response(status: .unauthorized)
            }
            
            let landIDString = context.parameters.get("landID") ?? "unknown"
            let landID = LandID(landIDString)
            
            await self.landRealm.removeLand(landID: landID)
            
            return Response(status: .noContent)
        }
        
        // GET /admin/stats - System statistics
        router.get("/admin/stats") { request, context in
            guard await self.adminAuth.hasRequiredRole(from: request, requiredRole: .viewer) else {
                return Response(status: .unauthorized)
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
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            
            do {
                let jsonData = try encoder.encode(systemStats)
                var buffer = ByteBufferAllocator().buffer(capacity: jsonData.count)
                buffer.writeBytes(jsonData)
                var response = Response(status: .ok, body: .init(byteBuffer: buffer))
                response.headers[.contentType] = "application/json"
                return response
            } catch {
                self.logger.error("Failed to encode system stats: \(error)")
                return Response(status: .internalServerError)
            }
        }
    }
}

