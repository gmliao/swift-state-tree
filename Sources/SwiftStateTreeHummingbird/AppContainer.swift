import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
import Logging
import NIOCore

/// Bundles runtime, transport, and Hummingbird hosting for any Land definition.
public struct AppContainer<State: StateNodeProtocol> {
    public typealias Land = LandDefinition<State>
    
    public struct Configuration: Sendable {
        public var host: String
        public var port: UInt16
        public var webSocketPath: String
        public var healthPath: String
        public var enableHealthRoute: Bool
        public var logStartupBanner: Bool
        public var logger: Logger?
        
        // JWT validation configuration
        /// JWT configuration (if provided, will create DefaultJWTAuthValidator)
        /// When set, JWT validation will be performed during WebSocket handshake.
        /// Client must include `token` query parameter in the WebSocket URL: `ws://host:port/path?token=<jwt-token>`
        public var jwtConfig: JWTConfiguration?
        /// Custom JWT validator (if provided, takes precedence over jwtConfig)
        /// When set, JWT validation will be performed during WebSocket handshake.
        /// Client must include `token` query parameter in the WebSocket URL: `ws://host:port/path?token=<jwt-token>`
        public var jwtValidator: JWTAuthValidator?
        
        /// Enable guest mode (allow connections without JWT token)
        /// When enabled and JWT validation is enabled:
        /// - Connections with valid JWT token: use JWT payload for PlayerSession
        /// - Connections without JWT token: use createGuestSession closure
        /// When disabled and JWT validation is enabled:
        /// - All connections must have valid JWT token (connections without token will be rejected)
        public var allowGuestMode: Bool = false
        
        public init(
            host: String = "localhost",
            port: UInt16 = 8080,
            webSocketPath: String = "/game",
            healthPath: String = "/health",
            enableHealthRoute: Bool = true,
            logStartupBanner: Bool = true,
            logger: Logger? = nil,
            jwtConfig: JWTConfiguration? = nil,
            jwtValidator: JWTAuthValidator? = nil,
            allowGuestMode: Bool = false
        ) {
            self.host = host
            self.port = port
            self.webSocketPath = webSocketPath
            self.healthPath = healthPath
            self.enableHealthRoute = enableHealthRoute
            self.logStartupBanner = logStartupBanner
            self.logger = logger
            self.jwtConfig = jwtConfig
            self.jwtValidator = jwtValidator
            self.allowGuestMode = allowGuestMode
        }
    }
    
    public struct AppContainerForTest {
        public let land: Land
        public let keeper: LandKeeper<State>
        public let transport: WebSocketTransport
        public let transportAdapter: TransportAdapter<State>
        fileprivate let adapterHolder: TransportAdapterHolder<State>
        
        public func connect(
            sessionID: SessionID,
            using connection: any WebSocketConnection
        ) async {
            await transport.handleConnection(sessionID: sessionID, connection: connection)
        }
        
        public func disconnect(sessionID: SessionID) async {
            await transport.handleDisconnection(sessionID: sessionID)
        }
        
        public func send(_ data: Data, from sessionID: SessionID) async {
            await transport.handleIncomingMessage(sessionID: sessionID, data: data)
        }
        
        fileprivate init(
            land: Land,
            keeper: LandKeeper<State>,
            transport: WebSocketTransport,
            transportAdapter: TransportAdapter<State>,
            adapterHolder: TransportAdapterHolder<State>
        ) {
            self.land = land
            self.keeper = keeper
            self.transport = transport
            self.transportAdapter = transportAdapter
            self.adapterHolder = adapterHolder
        }
    }
    
    public let configuration: Configuration
    public let land: Land
    public let keeper: LandKeeper<State>
    public let transport: WebSocketTransport
    public let transportAdapter: TransportAdapter<State>
    public let hbAdapter: HummingbirdStateTreeAdapter
    public let router: Router<BasicWebSocketRequestContext>
    
    private let adapterHolder: TransportAdapterHolder<State>
    
    public func run() async throws {
        let logger = configuration.logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.hummingbird",
            scope: "AppContainer"
        )

        let httpConfiguration = ApplicationConfiguration(
            address: .hostname(configuration.host, port: Int(configuration.port))
        )
        
        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(
                webSocketRouter: router
            ),
            configuration: httpConfiguration,
            logger: logger
        )
        
        if configuration.logStartupBanner {
            let baseURL = "http://\(configuration.host):\(configuration.port)"
            let wsURL = "ws://\(configuration.host):\(configuration.port)\(configuration.webSocketPath)"
            logger.info("🚀 SwiftStateTree Hummingbird server started at \(baseURL)")
            logger.info("📡 WebSocket endpoint: \(wsURL)")
            if configuration.enableHealthRoute {
                logger.info("❤️  Health check: \(baseURL)\(configuration.healthPath)")
            }
        }
        
        try await app.runService()
    }
    
    /// Assemble a runnable server with Hummingbird hosting.
    ///
    /// - Parameters:
    ///   - configuration: Server configuration (host, port, paths, etc.)
    ///   - land: The Land definition
    ///   - initialState: Initial state for the Land
    ///   - createGuestSession: Optional closure to create PlayerSession for guest users (when JWT validation is enabled but no token is provided).
    ///                          Only used when `allowGuestMode` is true and JWT validation is enabled.
    ///                          Default creates guest session with "guest-{randomID}" as playerID.
    ///   - configureRouter: Optional router configuration closure
    public static func makeServer(
        configuration: Configuration = Configuration(),
        land definition: Land,
        initialState: State,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        configureRouter: ((Router<BasicWebSocketRequestContext>) -> Void)? = nil
    ) async throws -> AppContainer {
        let logger = configuration.logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.hummingbird",
            scope: "AppContainer"
        )
        // Create JWT validator if configured
        let jwtValidator: JWTAuthValidator? = {
            if let customValidator = configuration.jwtValidator {
                return customValidator
            } else if let jwtConfig = configuration.jwtConfig {
                return DefaultJWTAuthValidator(config: jwtConfig, logger: logger)
            }
            return nil
        }()
        
        let core = await buildCoreComponents(
            land: definition,
            initialState: initialState,
            createGuestSession: createGuestSession,
            logger: logger
        )
        
        let hbAdapter = HummingbirdStateTreeAdapter(transport: core.transport, jwtValidator: jwtValidator)
        let router = Router(context: BasicWebSocketRequestContext.self)
        let schemaDataResult: Result<Data, Error> = {
            do {
                let anyLand = AnyLandDefinition(definition)
                let schema = anyLand.extractSchema()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let jsonData = try encoder.encode(schema)
                return .success(jsonData)
            } catch {
                return .failure(error)
            }
        }()
        @Sendable
        func addCORSHeaders(_ response: inout Response) {
            response.headers[.accessControlAllowOrigin] = "*"
            response.headers[.accessControlAllowMethods] = "GET, OPTIONS"
            response.headers[.accessControlAllowHeaders] = "Content-Type"
        }
        
        router.ws(RouterPath(configuration.webSocketPath)) { inbound, outbound, context in
            await hbAdapter.handle(inbound: inbound, outbound: outbound, context: context)
        }
        
        if configuration.enableHealthRoute {
            router.get(RouterPath(configuration.healthPath)) { _, _ in
                "OK"
            }
        }
        
        // Add schema endpoint with CORS support
        router.on(RouterPath("/schema"), method: .options) { _, _ in
            var response = Response(status: .noContent)
            addCORSHeaders(&response)
            return response
        }
        
        router.get(RouterPath("/schema")) { _, _ in
            switch schemaDataResult {
            case let .success(schemaData):
                var buffer = ByteBufferAllocator().buffer(capacity: schemaData.count)
                buffer.writeBytes(schemaData)
                var response = Response(status: .ok, body: .init(byteBuffer: buffer))
                response.headers[.contentType] = "application/json"
                response.headers[.cacheControl] = "public, max-age=3600"
                addCORSHeaders(&response)
                return response
            case let .failure(error):
                logger.error("Failed to generate schema at startup: \(error)")
                let errorMsg = "Failed to generate schema: \(error)"
                var buffer = ByteBufferAllocator().buffer(capacity: errorMsg.utf8.count)
                buffer.writeString(errorMsg)
                var response = Response(status: .internalServerError, body: .init(byteBuffer: buffer))
                response.headers[.contentType] = "text/plain"
                addCORSHeaders(&response)
                return response
            }
        }
        
        configureRouter?(router)
        
        return AppContainer(
            configuration: configuration,
            land: definition,
            keeper: core.keeper,
            transport: core.transport,
            transportAdapter: core.transportAdapter,
            hbAdapter: hbAdapter,
            router: router,
            adapterHolder: core.adapterHolder
        )
    }
    
    public static func makeForTest(
        land definition: Land,
        initialState: State,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        logger: Logger? = nil
    ) async -> AppContainerForTest {
        let testLogger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.test",
            scope: "Test"
        )
        let core = await buildCoreComponents(
            land: definition,
            initialState: initialState,
            createGuestSession: createGuestSession,
            logger: testLogger
        )
        
        return AppContainerForTest(
            land: definition,
            keeper: core.keeper,
            transport: core.transport,
            transportAdapter: core.transportAdapter,
            adapterHolder: core.adapterHolder
        )
    }
    
    private struct CoreComponents {
        let land: Land
        let keeper: LandKeeper<State>
        let transport: WebSocketTransport
        let transportAdapter: TransportAdapter<State>
        let adapterHolder: TransportAdapterHolder<State>
    }
    
    private static func buildCoreComponents(
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
        let transportAdapter = TransportAdapter<State>(
            keeper: keeper,
            transport: transport,
            landID: definition.id,
            createGuestSession: createGuestSession,
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

private actor TransportAdapterHolder<State: StateNodeProtocol> {
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
