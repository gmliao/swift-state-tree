import Foundation
import Logging

/// Request-scoped context for Land handlers
///
/// LandContext is created for each Action/Event request and released after processing.
/// It follows the Request-scoped Context pattern.
///
/// Supports dynamic resolver outputs via @dynamicMemberLookup.
/// Resolver outputs are populated before Action/Event handler execution.
@dynamicMemberLookup
public struct LandContext: Sendable {
    // MARK: - System IDs
    
    /// System player ID used for system operations (Tick, OnInitialize, OnFinalize, AfterFinalize).
    ///
    /// Use this to identify system-initiated operations in handlers.
    /// Example: `if ctx.playerID == LandContext.systemPlayerID { ... }`
    public static let systemPlayerID = PlayerID("_system")
    
    /// System client ID used for system operations.
    public static let systemClientID = ClientID("_system")
    
    /// System session ID used for system operations.
    public static let systemSessionID = SessionID("_system")
    
    /// Invalid player slot constant (used when player slot is not available).
    ///
    /// This value is returned when:
    /// - The context is for a system operation (not a real player)
    /// - The transport layer doesn't support player slots
    /// - The player hasn't been assigned a slot yet
    ///
    /// Example usage:
    /// ```swift
    /// HandleAction(AttackAction.self) { state, action, ctx in
    ///     let slot = ctx.playerSlot ?? LandContext.invalidPlayerSlot
    ///     if slot != LandContext.invalidPlayerSlot {
    ///         print("Player has valid slot: \(slot)")
    ///     }
    /// }
    /// ```
    public static let invalidPlayerSlot: Int32 = -1
    
    // MARK: - Instance Properties
    
    /// Land identifier
    public let landID: String

    /// Player identifier (account level, user identity)
    public let playerID: PlayerID

    /// Client identifier (device level, client instance provided by application)
    public let clientID: ClientID

    /// Session identifier (connection level, dynamically generated for tracking)
    public let sessionID: SessionID

    /// Device identifier (optional, from PlayerSession)
    public let deviceID: String?

    /// Whether this is a guest session (not authenticated via JWT).
    public let isGuest: Bool

    /// Additional metadata from PlayerSession (e.g., connectedAt, platform, etc.)
    public let metadata: [String: String]

    /// Service abstractions (does not depend on HTTP)
    ///
    /// Provides access to external services like database, metrics, or logging
    /// in a protocol-agnostic way.
    public let services: LandServices
    
    /// Logger instance for logging in handlers
    ///
    /// Logger is synchronous and can be used directly in Action/Event handlers.
    public let logger: Logger

    /// Tick ID for deterministic replay (0-based, increments with each tick).
    ///
    /// **In tick handlers**: Represents the current tick number being executed.
    /// **In action/event handlers**: Represents the last committed tick ID (the most recent
    /// tick that has completed execution). This represents the world state's current committed
    /// tick, not the next tick that will execute. This allows actions/events to be bound to
    /// the committed world state for replay logging.
    ///
    /// **Replay logging format**: `tickId:action` or `tickId:event`
    /// This allows replay systems to record and replay actions/events in tick order.
    ///
    /// **Semantic clarity**:
    /// - Tick handler: `tickId` is the ID of the tick being executed (e.g., tick 100)
    /// - Action/Event handler: `tickId` is the last committed tick (e.g., tick 100 if executed
    ///   after tick 100 completes but before tick 101 starts)
    ///
    /// **Type**: `Int64` for long-running servers and replay compatibility.
    /// At 60 Hz, Int64 can run for ~4.9 million years before overflow.
    ///
    /// To calculate deterministic time, use: `tickId * tickInterval`
    ///
    /// Example in tick handler:
    /// ```swift
    /// Tick(every: .milliseconds(50)) { state, ctx in
    ///     // Use tickId for deterministic logic
    ///     if let tickId = ctx.tickId {
    ///         let gameTime = Double(tickId) * 0.05  // 50ms = 0.05s
    ///         state.position += state.velocity * 0.05  // Deterministic movement
    ///     }
    /// }
    /// ```
    ///
    /// Example in action handler (for replay logging):
    /// ```swift
    /// HandleAction(AttackAction.self) { state, action, ctx in
    ///     // tickId is available for replay logging
    ///     // Log format: tickId:action (e.g., "42:AttackAction")
    ///     state.applyAttack(action, atTick: ctx.tickId)
    /// }
    /// ```
    public let tickId: Int64?

    /// Player slot for the current player (deterministic Int32 identifier for transport encoding).
    ///
    /// This is a deterministic slot number allocated for the current player, used for efficient
    /// transport encoding (e.g., in opcode-based state updates). The slot is allocated when the
    /// player joins and remains stable for the duration of their session.
    ///
    /// **Availability**:
    /// - Available in Action/Event handlers (for joined players)
    /// - `nil` for system operations (Tick, OnInitialize, OnFinalize, etc.)
    /// - `nil` if transport layer doesn't support player slots
    ///
    /// Example usage:
    /// ```swift
    /// HandleAction(AttackAction.self) { state, action, ctx in
    ///     if let slot = ctx.playerSlot {
    ///         print("Player \(ctx.playerID) has slot \(slot)")
    ///     }
    /// }
    /// ```
    public let playerSlot: Int32?

    /// Deterministic event emission handler (used from synchronous handlers).
    private let emitEventHandler: @Sendable (AnyServerEvent, EventTarget) -> Void

    /// Deterministic sync request handler (used from synchronous handlers).
    private let requestSyncNowHandler: @Sendable () -> Void

    /// Deterministic broadcast-only sync request handler (used from synchronous handlers).
    private let requestSyncBroadcastOnlyHandler: @Sendable () -> Void

    /// Storage for resolver outputs (dynamically populated based on @Resolvers declaration)
    private var resolverOutputs: [String: any ResolverOutput] = [:]
    
    /// Thread-safe deterministic random number generator.
    ///
    /// This property provides convenient access to the deterministic RNG service.
    /// The RNG service is automatically registered by `LandKeeper` during initialization,
    /// ensuring deterministic behavior based on the land instance ID.
    ///
    /// **Thread Safety**: The returned RNG is thread-safe and can be used concurrently.
    ///
    /// **Precondition**: A `DeterministicRngService` must be registered in `services`.
    /// `LandKeeper` automatically ensures this during initialization.
    ///
    /// Example usage:
    /// ```swift
    /// HandleAction(SpawnMonster.self) { state, action, ctx in
    ///     let count = ctx.random.nextInt(in: 1...5)
    ///     let position = ctx.random.nextFloat(in: 0.0..<100.0)
    ///     // ...
    /// }
    /// ```
    public var random: DeterministicRngService {
        // LandKeeper ensures DeterministicRngService is always registered
        guard let rngService = services.get(DeterministicRngService.self) else {
            fatalError("DeterministicRngService not found in services. This should not happen as LandKeeper automatically registers it.")
        }
        return rngService
    }

    /// Internal initializer for creating LandContext
    internal init(
        landID: String,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        services: LandServices,
        logger: Logger,
        deviceID: String? = nil,
        isGuest: Bool = false,
        metadata: [String: String] = [:],
        tickId: Int64? = nil,
        playerSlot: Int32? = nil,
        emitEventHandler: @escaping @Sendable (AnyServerEvent, EventTarget) -> Void,
        requestSyncNowHandler: @escaping @Sendable () -> Void,
        requestSyncBroadcastOnlyHandler: @escaping @Sendable () -> Void,
        resolverOutputs: [String: any ResolverOutput] = [:]
    ) {
        self.landID = landID
        self.playerID = playerID
        self.clientID = clientID
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.isGuest = isGuest
        self.metadata = metadata
        self.services = services
        self.logger = logger
        self.tickId = tickId
        self.playerSlot = playerSlot
        self.emitEventHandler = emitEventHandler
        self.requestSyncNowHandler = requestSyncNowHandler
        self.requestSyncBroadcastOnlyHandler = requestSyncBroadcastOnlyHandler
        self.resolverOutputs = resolverOutputs
    }

    // MARK: - Public Methods

    /// Emit a server event deterministically from synchronous handlers.
    ///
    /// This does NOT perform network I/O directly. The runtime will flush emitted events
    /// in a deterministic order at the end of the current tick.
    public func emitEvent(_ event: any ServerEventPayload, to target: EventTarget) {
        let anyEvent = AnyServerEvent(event)
        emitEventHandler(anyEvent, target)
    }

    /// Request an immediate sync at the end of the current tick (deterministic).
    public func requestSyncNow() {
        requestSyncNowHandler()
    }

    /// Request a broadcast-only sync at the end of the current tick (deterministic).
    public func requestSyncBroadcastOnly() {
        requestSyncBroadcastOnlyHandler()
    }

    // MARK: - Resolver Outputs

    /// Set a resolver output (internal use by runtime)
    ///
    /// This method is called by the runtime after resolving all declared resolvers.
    /// The property name is derived from the resolver type name (e.g., "ProductInfoResolver" -> "productInfo").
    internal mutating func setResolverOutput<Output: ResolverOutput>(
        _ output: Output,
        forPropertyName propertyName: String
    ) {
        resolverOutputs[propertyName] = output
    }

    /// Get a resolver output by property name (internal use)
    internal func getResolverOutput<Output: ResolverOutput>(
        _ type: Output.Type,
        forPropertyName propertyName: String
    ) -> Output? {
        return resolverOutputs[propertyName] as? Output
    }
    
    /// Get all resolver outputs (internal use for recording)
    internal func getAllResolverOutputs() -> [String: any ResolverOutput] {
        return resolverOutputs
    }

    // MARK: - Dynamic Member Lookup

    /// Dynamic member lookup for resolver outputs
    ///
    /// Allows accessing resolver outputs using dot notation:
    /// ```swift
    /// let productInfo = ctx.productInfo  // Returns ProductInfo?
    /// let userProfile = ctx.userProfile  // Returns UserProfileInfo?
    /// ```
    ///
    /// Property names are derived from resolver type names:
    /// - `ProductInfoResolver` -> `productInfo`
    /// - `UserProfileResolver` -> `userProfile`
    ///
    /// **Replay Mode Support**: In replay mode, resolver outputs are stored as `AnyCodableResolverOutput`
    /// wrappers. This subscript automatically decodes them to the requested type when accessed.
    /// 
    /// **Type Safety**: If the recorded type identifier doesn't match the expected type,
    /// this will attempt to decode anyway (for compatibility), but ideally types should match.
    public subscript<T: ResolverOutput>(dynamicMember member: String) -> T? {
        guard let output = resolverOutputs[member] else {
            return nil
        }
        
        // Direct cast if types match (live mode or already decoded)
        if let direct = output as? T {
            return direct
        }
        
        // In replay mode, outputs may be wrapped in AnyCodableResolverOutput
        // Decode from AnyCodable using the recorded type information
        if let wrapped = output as? AnyCodableResolverOutput {
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            do {
                // Encode the AnyCodable value
                let encoded = try encoder.encode(wrapped.value)
                // Decode as the target type T
                let decoded = try decoder.decode(T.self, from: encoded)
                
                // Optional: Log type mismatch warnings for debugging
                let expectedTypeName = String(describing: T.self)
                if wrapped.typeIdentifier != expectedTypeName {
                    // Type names don't match, but decoding succeeded (might be compatible types)
                    // This is acceptable but worth noting for debugging
                }
                
                return decoded
            } catch {
                // Decoding failed - this indicates a type mismatch
                // Return nil to indicate the resolver output is not available
                return nil
            }
        }
        
        return nil
    }
}

// MARK: - Replay Mode Helper

/// Wrapper to convert AnyCodable to ResolverOutput for replay
/// This allows storing resolver outputs as AnyCodable during recording,
/// and decoding them back to concrete types when accessed in replay mode.
internal struct AnyCodableResolverOutput: ResolverOutput {
    /// Type identifier of the resolver output (e.g., "SlowDeterministicOutput")
    let typeIdentifier: String
    /// The actual resolver output value as AnyCodable
    let value: AnyCodable
    
    init(typeIdentifier: String, value: AnyCodable) {
        self.typeIdentifier = typeIdentifier
        self.value = value
    }
    
    enum CodingKeys: String, CodingKey {
        case typeIdentifier
        case value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.typeIdentifier = try container.decode(String.self, forKey: .typeIdentifier)
        self.value = try container.decode(AnyCodable.self, forKey: .value)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeIdentifier, forKey: .typeIdentifier)
        try container.encode(value, forKey: .value)
    }
}
