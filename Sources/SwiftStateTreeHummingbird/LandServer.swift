import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore
import SwiftStateTree
import SwiftStateTreeMatchmaking
import SwiftStateTreeTransport

/// Bundles runtime, transport, and Hummingbird hosting for any Land definition.
///
/// **Note**: This is the Hummingbird-specific implementation of `LandServerProtocol`.
/// For framework-agnostic usage, use the `LandServerProtocol` protocol.
public struct LandServer<State: StateNodeProtocol>: Sendable {
    public typealias Land = LandDefinition<State>

    /// Configuration type alias for backward compatibility.
    /// Prefer using `LandServerConfiguration` directly to avoid specifying State type.
    public typealias Configuration = LandServerConfiguration

    /// Default implementation for creating guest sessions.
    ///
    /// Creates a PlayerSession with:
    /// - playerID: "guest-{randomID}" format (6-character random ID)
    /// - deviceID: clientID.rawValue
    /// - isGuest: true
    ///
    /// This is the recommended default for most use cases.
    public static func defaultCreateGuestSession(_: SessionID, clientID: ClientID) -> PlayerSession {
        let randomID = String(UUID().uuidString.prefix(6))
        return PlayerSession(
            playerID: "guest-\(randomID)",
            deviceID: clientID.rawValue,
            isGuest: true
        )
    }

    public let configuration: Configuration
    public let land: Land?
    public let keeper: LandKeeper<State>?
    public let transport: WebSocketTransport?
    public let transportAdapter: TransportAdapter<State>?
    public let hbAdapter: HummingbirdStateTreeAdapter?
    public let landRouter: LandRouter<State>?

    // Multi-room mode
    public let landManager: LandManager<State>?

    private let adapterHolder: TransportAdapterHolder<State>?

    private init(
        configuration: Configuration,
        landManager: LandManager<State>,
        transport: WebSocketTransport? = nil,
        hbAdapter: HummingbirdStateTreeAdapter? = nil,
        landRouter: LandRouter<State>? = nil
    ) {
        self.configuration = configuration
        land = nil
        keeper = nil
        self.transport = transport
        transportAdapter = nil
        self.hbAdapter = hbAdapter
        self.landRouter = landRouter
        self.landManager = landManager
        adapterHolder = nil
    }

    /// Factory method for creating servers.
    ///
    /// Note: Uses static method instead of initializer because Swift initializers cannot be async,
    /// and this method requires async operations (e.g., `await landManager.getOrCreateLand`).
    ///
    /// This is used by LandHost and tests. Not intended for general public use.
    public static func create(
        configuration: Configuration,
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        lobbyIDs: [String] = []
    ) async throws -> LandServer {
        let logger = configuration.logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.hummingbird",
            scope: "LandServer"
        )

        // Create JWT validator if configured
        let jwtValidator = createJWTValidator(configuration: configuration, logger: logger)

        // Create global WebSocketTransport
        // Since we are using LandRouter, all connections go through this single transport
        let transport = WebSocketTransport(logger: logger)

        // Create LandManager (must share the same transport so per-land adapters can send snapshots/updates)
        let landManager = LandManager<State>(
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            transport: transport,
            createGuestSession: createGuestSession ?? defaultCreateGuestSession,
            enableParallelEncoding: configuration.enableParallelEncoding,
            logger: logger
        )

        // Pre-create lobbies if specified
        for lobbyIDString in lobbyIDs {
            let lobbyID = LandID(lobbyIDString)
            let definition = landFactory(lobbyID)
            let initialState = initialStateFactory(lobbyID)
            _ = await landManager.getOrCreateLand(
                landID: lobbyID,
                definition: definition,
                initialState: initialState
            )
            logger.info("Pre-created lobby: \(lobbyIDString)")
        }

        // Create adapter for LandTypeRegistry
        // Note: landFactory here expects LandID which needs the 'type' embedded if we pass it directly
        let landTypeRegistry = LandTypeRegistry<State>(
            landFactory: { _, landID in landFactory(landID) },
            initialStateFactory: { _, landID in initialStateFactory(landID) }
        )

        // Create LandRouter using the global transport
        let landRouter = LandRouter<State>(
            landManager: landManager,
            landTypeRegistry: landTypeRegistry,
            transport: transport,
            createGuestSession: createGuestSession ?? defaultCreateGuestSession,
            allowAutoCreateOnJoin: configuration.allowAutoCreateOnJoin,
            logger: logger
        )

        // Set LandRouter as the delegate for the transport to handle events
        await transport.setDelegate(landRouter)

        // Create Hummingbird Adapter that feeds the global transport
        let hbAdapter = HummingbirdStateTreeAdapter(
            transport: transport,
            jwtValidator: jwtValidator,
            allowGuestMode: configuration.allowGuestMode,
            logger: logger
        )

        // Note: Router registration is handled by LandHost, not LandServer

        return LandServer(
            configuration: configuration,
            landManager: landManager,
            transport: transport,
            hbAdapter: hbAdapter,
            landRouter: landRouter
        )
    }

    /// Internal structure for core components used during server setup.
    struct CoreComponents {
        let land: Land
        let keeper: LandKeeper<State>
        let transport: WebSocketTransport
        let transportAdapter: TransportAdapter<State>
        let adapterHolder: TransportAdapterHolder<State>
    }

    // MARK: - Helper Methods for Server Setup

    /// Create JWT validator from configuration.
    private static func createJWTValidator(
        configuration: Configuration,
        logger: Logger
    ) -> JWTAuthValidator? {
        if let customValidator = configuration.jwtValidator {
            return customValidator
        } else if let jwtConfig = configuration.jwtConfig {
            return DefaultJWTAuthValidator(config: jwtConfig, logger: logger)
        }
        return nil
    }

    /// Build core components for a LandServer (used by both production and testing code).
    static func buildCoreComponents(
        land definition: Land,
        initialState: State,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        logger: Logger
    ) async -> CoreComponents {
        let transport = WebSocketTransport(logger: logger)
        let adapterHolder = TransportAdapterHolder<State>()

        // Create keeper first (without transport)
        let keeper = LandKeeper<State>(
            definition: definition,
            initialState: initialState,
            logger: logger
        )

        // Create TransportAdapter with keeper
        // Note: enableParallelEncoding is not available in buildCoreComponents context
        // For single-room mode, use LandManager which supports this configuration
        let transportAdapter = TransportAdapter<State>(
            keeper: keeper,
            transport: transport,
            landID: definition.id,
            createGuestSession: createGuestSession,
            enableLegacyJoin: true,
            enableParallelEncoding: nil,  // Use default (codec-based)
            logger: logger
        )

        // Set transport adapter as the transport for keeper
        await keeper.setTransport(transportAdapter)

        await adapterHolder.set(transportAdapter)
        await transport.setDelegate(transportAdapter)

        return CoreComponents(
            land: definition,
            keeper: keeper,
            transport: transport,
            transportAdapter: transportAdapter,
            adapterHolder: adapterHolder
        )
    }
}

/// Internal actor for holding TransportAdapter reference.
/// Used internally by LandServer for managing adapter lifecycle.
actor TransportAdapterHolder<State: StateNodeProtocol> {
    private var adapter: TransportAdapter<State>?

    func set(_ adapter: TransportAdapter<State>) {
        self.adapter = adapter
    }

    func forwardSendEvent(
        _ event: AnyServerEvent,
        to target: SwiftStateTree.EventTarget
    ) async {
        await adapter?.sendEvent(event, to: target)
    }

    func forwardSyncNow() async {
        await adapter?.syncNow()
    }

    func forwardSyncBroadcastOnly() async {
        await adapter?.syncBroadcastOnly()
    }
}

// MARK: - LandServerProtocol Conformance

/// Extension to make LandServer conform to LandServerProtocol.
///
/// This allows LandServer to be used with LandRealm and other components
/// that work with the LandServerProtocol abstraction.
extension LandServer: LandServerProtocol {
    /// Gracefully shutdown the server.
    ///
    /// Note: Currently, LandServer doesn't have explicit shutdown support.
    /// This is a placeholder for future implementation.
    public func shutdown() async throws {
        // TODO: Implement graceful shutdown for LandServer
        // This might involve:
        // - Stopping accepting new connections
        // - Waiting for existing connections to close
        // - Cleaning up resources
    }

    /// Check the health status of the server.
    ///
    /// For now, we consider a server healthy if it exists.
    /// In a real implementation, we might check if the server is running,
    /// if it can accept connections, etc.
    public func healthCheck() async -> Bool {
        // TODO: Implement actual health check
        // This might involve:
        // - Checking if the server is running
        // - Checking if it can accept connections
        // - Checking resource usage
        return true
    }

    /// List all lands managed by this server.
    ///
    /// Returns all lands from the LandManager.
    public func listLands() async -> [LandID] {
        guard let landManager = landManager else {
            return []
        }
        return await landManager.listLands()
    }

    /// Get statistics for a specific land.
    ///
    /// - Parameter landID: The unique identifier for the land
    /// - Returns: LandStats if the land exists, nil otherwise
    public func getLandStats(landID: LandID) async -> LandStats? {
        guard let landManager = landManager else {
            return nil
        }
        return await landManager.getLandStats(landID: landID)
    }

    /// Errors that can be thrown by LandServer.
    public enum LandServerError: Error, Sendable {
        // Note: All run() related errors have been removed as run() method has been removed.
        // HTTP server lifecycle is now managed by LandHost.
    }

    /// Remove a land from the server.
    ///
    /// - Parameter landID: The unique identifier for the land to remove
    public func removeLand(landID: LandID) async {
        guard let landManager = landManager else {
            return
        }
        await landManager.removeLand(landID: landID)
    }
}
