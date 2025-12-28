import Foundation
import SwiftStateTree
import Logging

/// High-level realm that manages all land types and State types.
///
/// Automatically creates and manages LandServer instances for different State types.
/// Developers only need to define State and Land, without directly managing LandServer.
///
/// **Key Feature**: Can manage multiple LandServer instances with different State types.
/// This is the unified entry point for creating all land states.
///
/// **Note**: Distributed architecture support (multi-server coordination) is planned for future versions.
/// Currently, each server creates its own LandRealm instance independently.
///
/// **Framework Support**:
/// - Works with any HTTP framework that implements the `LandServerProtocol` protocol
/// - Currently supports Hummingbird via `LandServer`
/// - Future frameworks (Vapor, Kitura, etc.) can implement `LandServerProtocol` to work with `LandRealm`
public actor LandRealm {
    /// Internal storage for server information
    private struct ServerInfo {
        let landType: String
        let stateTypeName: String
        nonisolated(unsafe) let runClosure: () async throws -> Void
        nonisolated(unsafe) let shutdownClosure: () async throws -> Void
        nonisolated(unsafe) let healthCheckClosure: () async -> Bool
        nonisolated(unsafe) let listLandsClosure: () async -> [LandID]
        nonisolated(unsafe) let getLandStatsClosure: (LandID) async -> LandStats?
        nonisolated(unsafe) let removeLandClosure: (LandID) async -> Void
        
        init<Server: LandServerProtocol>(
            landType: String,
            server: Server,
            logger: Logger
        ) {
            self.landType = landType
            self.stateTypeName = String(describing: Server.State.self)
            
            // Capture server in closures (server is isolated to this actor, so it's safe)
            // Note: These closures are only used within the actor, so @Sendable is not required
            self.runClosure = {
                try await server.run()
            }
            
            self.shutdownClosure = {
                try await server.shutdown()
            }
            
            self.healthCheckClosure = {
                await server.healthCheck()
            }
            
            self.listLandsClosure = {
                await server.listLands()
            }
            
            self.getLandStatsClosure = { landID in
                await server.getLandStats(landID: landID)
            }
            
            self.removeLandClosure = { landID in
                await server.removeLand(landID: landID)
            }
        }
    }
    
    private var servers: [String: ServerInfo] = [:]
    private let logger: Logger
    
    /// Initialize a new LandRealm.
    ///
    /// - Parameter logger: Optional logger instance. If not provided, a default logger will be created.
    public init(logger: Logger? = nil) {
        self.logger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.transport",
            scope: "LandRealm"
        )
    }
    
    /// Register a land type with a LandServer instance.
    ///
    /// **Key Feature**: Can register LandServer instances with different State types.
    /// Each land type can have its own State type, allowing complete flexibility.
    ///
    /// **Note**: This method accepts any type that conforms to `LandServerProtocol` protocol.
    /// This allows `LandRealm` to work with different HTTP frameworks (Hummingbird, Vapor, etc.)
    /// as long as they implement the `LandServerProtocol` protocol.
    ///
    /// - Parameters:
    ///   - landType: The land type identifier (e.g., "chess", "cardgame", "rpg")
    ///   - server: The LandServer instance to register
    /// - Throws: `LandRealmError.duplicateLandType` if the land type is already registered
    /// - Throws: `LandRealmError.invalidLandType` if the land type is invalid (e.g., empty)
    public func register<Server: LandServerProtocol>(
        landType: String,
        server: Server
    ) async throws {
        // Validate landType
        guard !landType.isEmpty else {
            throw LandRealmError.invalidLandType(landType)
        }
        
        // Check for duplicate
        guard servers[landType] == nil else {
            throw LandRealmError.duplicateLandType(landType)
        }
        
        // Store server info
        let serverInfo = ServerInfo(
            landType: landType,
            server: server,
            logger: logger
        )
        
        servers[landType] = serverInfo
        logger.info("Registered land type '\(landType)' with State type '\(String(describing: Server.State.self))'")
    }
    
    /// Start all registered LandServer instances.
    ///
    /// This method will start all servers concurrently and wait for them to complete.
    /// If any server fails, the error will be propagated.
    ///
    /// - Throws: Error if any server fails to start
    public func run() async throws {
        let serversToRun = servers
        
        guard !serversToRun.isEmpty else {
            logger.warning("No servers registered in LandRealm")
            return
        }
        
        logger.info("Starting \(serversToRun.count) server(s) in LandRealm")
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (landType, serverInfo) in serversToRun {
                let logger = self.logger
                group.addTask {
                    do {
                        logger.info("Starting server for land type: \(landType)")
                        try await serverInfo.runClosure()
                    } catch {
                        logger.error("Server for land type '\(landType)' failed: \(error)")
                        throw LandRealmError.serverFailure(landType: landType, underlying: error)
                    }
                }
            }
            
            // Wait for all tasks to complete
            try await group.waitForAll()
        }
    }
    
    /// Gracefully shutdown all registered LandServer instances.
    ///
    /// This method will shutdown all servers concurrently.
    /// Errors during shutdown are logged but do not prevent other servers from shutting down.
    public func shutdown() async throws {
        let serversToShutdown = servers
        
        guard !serversToShutdown.isEmpty else {
            logger.info("No servers to shutdown in LandRealm")
            return
        }
        
        logger.info("Shutting down \(serversToShutdown.count) server(s) in LandRealm")
        
        await withTaskGroup(of: Void.self) { group in
            for (landType, serverInfo) in serversToShutdown {
                let logger = self.logger
                group.addTask {
                    do {
                        try await serverInfo.shutdownClosure()
                        logger.info("Successfully shut down server for land type: \(landType)")
                    } catch {
                        logger.error("Error shutting down server for land type '\(landType)': \(error)")
                        // Continue shutting down other servers even if one fails
                    }
                }
            }
            
            // Wait for all shutdown tasks to complete
            await group.waitForAll()
        }
    }
    
    /// Check the health status of all registered servers.
    ///
    /// - Returns: A dictionary mapping land type to health status (true = healthy, false = unhealthy)
    public func healthCheck() async -> [String: Bool] {
        let serversToCheck = servers
        
        var healthStatus: [String: Bool] = [:]
        
        await withTaskGroup(of: (String, Bool).self) { group in
            for (landType, serverInfo) in serversToCheck {
                let closure = serverInfo.healthCheckClosure
                group.addTask {
                    let isHealthy = await closure()
                    return (landType, isHealthy)
                }
            }
            
            for await (landType, isHealthy) in group {
                healthStatus[landType] = isHealthy
            }
        }
        
        return healthStatus
    }
    
    /// Get the number of registered land types.
    public var registeredLandTypeCount: Int {
        servers.count
    }
    
    /// Check if a land type is registered.
    ///
    /// - Parameter landType: The land type identifier
    /// - Returns: `true` if the land type is registered, `false` otherwise
    public func isRegistered(landType: String) -> Bool {
        servers[landType] != nil
    }
    
    /// List all lands across all registered servers.
    ///
    /// Aggregates lands from all registered LandServer instances, regardless of State type.
    ///
    /// - Returns: Array of all land IDs from all registered servers
    public func listAllLands() async -> [LandID] {
        let serversToQuery = servers
        var allLands: [LandID] = []
        
        await withTaskGroup(of: [LandID].self) { group in
            for (_, serverInfo) in serversToQuery {
                let closure = serverInfo.listLandsClosure
                group.addTask {
                    await closure()
                }
            }
            
            for await lands in group {
                allLands.append(contentsOf: lands)
            }
        }
        
        return allLands
    }
    
    /// Get statistics for a specific land across all registered servers.
    ///
    /// Searches all registered LandServer instances to find the land.
    ///
    /// - Parameter landID: The unique identifier for the land
    /// - Returns: LandStats if the land exists in any server, nil otherwise
    public func getLandStats(landID: LandID) async -> LandStats? {
        let serversToQuery = servers
        
        // Try each server in parallel
        return await withTaskGroup(of: LandStats?.self) { group in
            for (_, serverInfo) in serversToQuery {
                let closure = serverInfo.getLandStatsClosure
                group.addTask {
                    await closure(landID)
                }
            }
            
            // Return the first non-nil result
            for await stats in group {
                if let stats = stats {
                    return stats
                }
            }
            
            return nil
        }
    }
    
    /// Remove a land from the appropriate server.
    ///
    /// Searches all registered LandServer instances to find and remove the land.
    ///
    /// - Parameter landID: The unique identifier for the land to remove
    public func removeLand(landID: LandID) async {
        let serversToQuery = servers
        
        // Try each server in parallel, stop when one succeeds
        await withTaskGroup(of: Bool.self) { group in
            for (_, serverInfo) in serversToQuery {
                let closure = serverInfo.removeLandClosure
                group.addTask {
                    // Check if this server has the land first
                    let lands = await serverInfo.listLandsClosure()
                    if lands.contains(landID) {
                        await closure(landID)
                        return true
                    }
                    return false
                }
            }
            
            // Wait for one to succeed
            for await removed in group {
                if removed {
                    // Cancel remaining tasks
                    group.cancelAll()
                    break
                }
            }
        }
    }
}
