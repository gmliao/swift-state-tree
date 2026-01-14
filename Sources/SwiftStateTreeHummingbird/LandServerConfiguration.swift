import Foundation
import Logging
import SwiftStateTreeTransport

/// Configuration for LandServer instances.
///
/// This configuration is independent of the State type and can be reused across
/// different land types. Use `LandServerConfiguration` directly instead of
/// `LandServer<State>.Configuration` to avoid specifying the State type.
public struct LandServerConfiguration: Sendable {
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
    
    /// Allow auto-creating land when join with instanceId but land doesn't exist (default: false).
    ///
    /// **Security Note**: When `true`, clients can create rooms by specifying any instanceId.
    /// This is useful for demo/testing but should be `false` in production.
    public var allowAutoCreateOnJoin: Bool = false
    
    /// Enable parallel encoding for state updates (default: nil, uses codec default).
    ///
    /// When `true`, enables parallel JSON encoding for multiple player updates, which can improve
    /// performance when syncing to many players simultaneously. Only effective for JSON codec.
    /// When `nil`, uses the default behavior based on codec type.
    public var enableParallelEncoding: Bool? = nil

    /// Encoding configuration for transport messages and state updates.
    public var transportEncoding: TransportEncodingConfig = .jsonOpcode
    
    /// Path hashes for state update compression (extracted from schema).
    /// When provided, enables PathHash format for OpcodeJSONStateUpdateEncoder.
    public var pathHashes: [String: UInt32]? = nil
    
    /// Event hashes for event compression (extracted from schema).
    /// When provided, enables Opcode encoding for event types.
    public var eventHashes: [String: Int]? = nil
    
    /// Client event hashes for client event compression (extracted from schema).
    public var clientEventHashes: [String: Int]? = nil
    
    public init(
        logger: Logger? = nil,
        jwtConfig: JWTConfiguration? = nil,
        jwtValidator: JWTAuthValidator? = nil,
        allowGuestMode: Bool = false,
        allowAutoCreateOnJoin: Bool = false,
        transportEncoding: TransportEncodingConfig = .jsonOpcode,
        enableParallelEncoding: Bool? = nil,
        pathHashes: [String: UInt32]? = nil,
        eventHashes: [String: Int]? = nil,
        clientEventHashes: [String: Int]? = nil
    ) {
        self.logger = logger
        self.jwtConfig = jwtConfig
        self.jwtValidator = jwtValidator
        self.allowGuestMode = allowGuestMode
        self.allowAutoCreateOnJoin = allowAutoCreateOnJoin
        self.transportEncoding = transportEncoding
        self.enableParallelEncoding = enableParallelEncoding
        self.pathHashes = pathHashes
        self.eventHashes = eventHashes
        self.clientEventHashes = clientEventHashes
    }
}
