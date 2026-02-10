import Foundation
import SwiftStateTree
import SwiftStateTreeTransport
import Logging

// MARK: - Testing Support

extension LandServer {
    /// Test harness for LandServer that provides direct access to core components
    /// and allows simulating WebSocket connections without running an HTTP server.
    ///
    /// This is primarily used for unit testing Land logic and transport behavior.
    public struct LandServerForTest {
        public let land: Land
        public let keeper: LandKeeper<State>
        public let transport: WebSocketTransport
        public let transportAdapter: TransportAdapter<State>
        /// Internal adapter holder (not typically needed in tests, but exposed for advanced use cases)
        internal let adapterHolder: TransportAdapterHolder<State>
        
        /// Simulate a WebSocket connection.
        ///
        /// - Parameters:
        ///   - sessionID: The session identifier
        ///   - connection: The WebSocket connection to use
        public func connect(
            sessionID: SessionID,
            using connection: any WebSocketConnection
        ) async {
            await transport.handleConnection(sessionID: sessionID, connection: connection)
        }
        
        /// Simulate disconnecting a WebSocket session.
        ///
        /// - Parameter sessionID: The session identifier to disconnect
        public func disconnect(sessionID: SessionID) async {
            await transport.handleDisconnection(sessionID: sessionID)
        }
        
        /// Send data to simulate an incoming WebSocket message.
        ///
        /// - Parameters:
        ///   - data: The message data to send
        ///   - sessionID: The session identifier
        public func send(_ data: Data, from sessionID: SessionID) async {
            await transport.handleIncomingMessage(sessionID: sessionID, data: data)
        }
        
        internal init(
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
    
    /// Create a test harness for unit testing Land logic.
    ///
    /// This method creates a `LandServerForTest` that provides direct access to
    /// core components (keeper, transport, transportAdapter) without running an HTTP server.
    /// This is useful for unit testing Land handlers, state mutations, and transport behavior.
    ///
    /// - Parameters:
    ///   - definition: The Land definition to test
    ///   - initialState: Initial state for the Land (defaults to `State()`)
    ///   - createGuestSession: Optional closure to create PlayerSession for guest users
    ///   - logger: Optional logger instance
    /// - Returns: A `LandServerForTest` harness for testing
    public static func makeForTest(
        land definition: Land,
        initialState: State = State(),
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        logger: Logger? = nil
    ) async -> LandServerForTest {
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
        
        return LandServerForTest(
            land: definition,
            keeper: core.keeper,
            transport: core.transport,
            transportAdapter: core.transportAdapter,
            adapterHolder: core.adapterHolder
        )
    }
}
