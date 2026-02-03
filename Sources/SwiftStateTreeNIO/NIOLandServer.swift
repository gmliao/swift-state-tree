// Sources/SwiftStateTreeNIO/NIOLandServer.swift
//
// NIO-based LandServer implementation conforming to LandServerProtocol.

import Foundation
import Logging
import NIOCore
import SwiftStateTree
import SwiftStateTreeTransport

/// NIO-based LandServer that conforms to LandServerProtocol.
///
/// This provides the same interface as the Hummingbird LandServer,
/// allowing it to be registered with LandRealm for multi-land management.
public struct NIOLandServer<State: StateNodeProtocol>: LandServerProtocol, Sendable {
    public let landManager: LandManager<State>
    public let transport: WebSocketTransport
    public let landRouter: LandRouter<State>
    public let landType: String
    
    private let logger: Logger
    
    /// Create a NIOLandServer.
    ///
    /// - Parameters:
    ///   - landType: Unique identifier for this land type.
    ///   - landFactory: Factory for creating LandDefinition instances.
    ///   - initialStateFactory: Factory for creating initial state.
    ///   - configuration: Server configuration.
    ///   - transport: Shared WebSocketTransport instance.
    public init(
        landType: String,
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        configuration: NIOLandServerConfiguration,
        transport: WebSocketTransport
    ) {
        self.landType = landType
        self.transport = transport
        self.logger = configuration.logger ?? Logger(label: "com.swiftstatetree.nio.server.\(landType)")
        
        // Create LandManager
        self.landManager = LandManager<State>(
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            servicesFactory: configuration.servicesFactory,
            transport: transport,
            createGuestSession: nil,
            transportEncoding: configuration.transportEncoding,
            enableLiveStateHashRecording: configuration.enableLiveStateHashRecording,
            pathHashes: configuration.pathHashes,
            eventHashes: configuration.eventHashes,
            clientEventHashes: configuration.clientEventHashes,
            logger: configuration.logger
        )
        
        // Create LandTypeRegistry
        let registry = LandTypeRegistry<State>(
            landFactory: { (_: String, landID: LandID) in landFactory(landID) },
            initialStateFactory: { (_: String, landID: LandID) in initialStateFactory(landID) }
        )
        
        // Create LandRouter
        self.landRouter = LandRouter<State>(
            landManager: landManager,
            landTypeRegistry: registry,
            transport: transport,
            createGuestSession: nil,
            allowAutoCreateOnJoin: configuration.allowAutoCreateOnJoin,
            transportEncoding: configuration.transportEncoding,
            logger: configuration.logger
        )
    }
    
    // MARK: - LandServerProtocol
    
    public func shutdown() async throws {
        logger.info("Shutting down NIOLandServer", metadata: ["landType": .string(landType)])
        // LandManager handles cleanup
    }
    
    public func healthCheck() async -> Bool {
        // Basic health check - server is running
        return true
    }
    
    public func listLands() async -> [LandID] {
        await landManager.listLands()
    }
    
    public func getLandStats(landID: LandID) async -> LandStats? {
        await landManager.getLandStats(landID: landID)
    }
    
    public func removeLand(landID: LandID) async {
        await landManager.removeLand(landID: landID)
    }
    
    public func getReevaluationRecord(landID: LandID) async throws -> Data? {
        guard let container = await landManager.getLand(landID: landID) else { return nil }
        guard let recorder = await container.keeper.getReevaluationRecorder() else { return nil }
        return try await recorder.encode()
    }
}
