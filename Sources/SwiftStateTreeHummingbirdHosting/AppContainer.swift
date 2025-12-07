import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
import SwiftStateTreeHummingbird
import Logging

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
        
        public init(
            host: String = "localhost",
            port: UInt16 = 8080,
            webSocketPath: String = "/game",
            healthPath: String = "/health",
            enableHealthRoute: Bool = true,
            logStartupBanner: Bool = true,
            logger: Logger? = nil
        ) {
            self.host = host
            self.port = port
            self.webSocketPath = webSocketPath
            self.healthPath = healthPath
            self.enableHealthRoute = enableHealthRoute
            self.logStartupBanner = logStartupBanner
            self.logger = logger
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
    ///   - createPlayerSession: Optional closure to create PlayerSession from sessionID and clientID.
    ///                          This allows customizing how playerID, deviceID, and metadata are extracted
    ///                          (e.g., from auth headers, JWT tokens, etc.).
    ///                          Default uses sessionID as playerID.
    ///   - configureRouter: Optional router configuration closure
    public static func makeServer(
        configuration: Configuration = Configuration(),
        land definition: Land,
        initialState: State,
        createPlayerSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        configureRouter: ((Router<BasicWebSocketRequestContext>) -> Void)? = nil
    ) async throws -> AppContainer {
        let logger = configuration.logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.hummingbird",
            scope: "AppContainer"
        )
        let core = await buildCoreComponents(
            land: definition,
            initialState: initialState,
            createPlayerSession: createPlayerSession,
            logger: logger
        )
        
        let hbAdapter = HummingbirdStateTreeAdapter(transport: core.transport)
        let router = Router(context: BasicWebSocketRequestContext.self)
        
        router.ws(RouterPath(configuration.webSocketPath)) { inbound, outbound, context in
            await hbAdapter.handle(inbound: inbound, outbound: outbound, context: context)
        }
        
        if configuration.enableHealthRoute {
            router.get(RouterPath(configuration.healthPath)) { _, _ in
                "OK"
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
        createPlayerSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        logger: Logger? = nil
    ) async -> AppContainerForTest {
        let testLogger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.test",
            scope: "Test"
        )
        let core = await buildCoreComponents(
            land: definition,
            initialState: initialState,
            createPlayerSession: createPlayerSession,
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
        createPlayerSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
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
            createPlayerSession: createPlayerSession,
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
