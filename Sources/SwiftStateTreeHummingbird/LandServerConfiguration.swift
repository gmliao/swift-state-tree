import Foundation
import Logging

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
    
    public init(
        logger: Logger? = nil,
        jwtConfig: JWTConfiguration? = nil,
        jwtValidator: JWTAuthValidator? = nil,
        allowGuestMode: Bool = false,
        allowAutoCreateOnJoin: Bool = false
    ) {
        self.logger = logger
        self.jwtConfig = jwtConfig
        self.jwtValidator = jwtValidator
        self.allowGuestMode = allowGuestMode
        self.allowAutoCreateOnJoin = allowAutoCreateOnJoin
    }
}
