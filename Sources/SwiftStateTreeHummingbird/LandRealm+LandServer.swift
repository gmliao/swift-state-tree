import Foundation
import SwiftStateTree
import SwiftStateTreeTransport
import Logging

/// Convenience extension for LandRealm to work with LandServer (Hummingbird).
///
/// This extension provides a convenient way to register LandServer instances
/// with LandRealm, making it easier to use LandRealm with Hummingbird.
///
/// **Note**: `AppContainer<State>` is an alias for `LandServer<State>` (for backward compatibility).
/// This method works with `LandServer` instances. The `AppContainer` typealias can also be used.
extension LandRealm {
    /// Register a land type with LandServer (Hummingbird-specific convenience method).
    ///
    /// This is a convenience method that creates a LandServer and registers it with LandRealm.
    /// For framework-agnostic usage, use `LandRealm.register(landType:server:)` directly.
    ///
    /// - Parameters:
    ///   - landType: The land type identifier (e.g., "chess", "cardgame", "rpg")
    ///   - landFactory: Factory function to create LandDefinition for a given LandID
    ///   - initialStateFactory: Factory function to create initial state for a given LandID
    ///   - webSocketPath: Optional custom WebSocket path (defaults to "/{landType}")
    ///   - configuration: Optional LandServer configuration (uses defaults if not provided)
    /// - Throws: `LandRealmError.duplicateLandType` if the land type is already registered
    /// - Throws: `LandRealmError.invalidLandType` if the land type is invalid (e.g., empty)
    public func registerWithLandServer<State: StateNodeProtocol>(
        landType: String,
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        webSocketPath: String? = nil,
        configuration: LandServer<State>.Configuration? = nil
    ) async throws {
        // Validate landType
        guard !landType.isEmpty else {
            throw LandRealmError.invalidLandType(landType)
        }
        
        // Check for duplicate
        if await isRegistered(landType: landType) {
            throw LandRealmError.duplicateLandType(landType)
        }
        
        // Create server
        let path = webSocketPath ?? "/\(landType)"
        let finalConfig: LandServer<State>.Configuration
        if let providedConfig = configuration {
            var config = providedConfig
            config.webSocketPath = path
            finalConfig = config
        } else {
            finalConfig = LandServer<State>.Configuration(webSocketPath: path)
        }
        
        let server = try await LandServer<State>.makeMultiRoomServer(
            configuration: finalConfig,
            landFactory: landFactory,
            initialStateFactory: initialStateFactory
        )
        
        // Register using the generic method
        try await register(landType: landType, server: server)
    }
    
    /// Register a land type with LandServer (deprecated, use `registerWithLandServer` instead).
    ///
    /// This method is kept for backward compatibility. New code should use `registerWithLandServer` instead.
    @available(*, deprecated, renamed: "registerWithLandServer", message: "Use registerWithLandServer instead. This method will be removed in a future version.")
    public func registerWithAppContainer<State: StateNodeProtocol>(
        landType: String,
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        webSocketPath: String? = nil,
        configuration: LandServer<State>.Configuration? = nil
    ) async throws {
        try await registerWithLandServer(
            landType: landType,
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            webSocketPath: webSocketPath,
            configuration: configuration
        )
    }
}
