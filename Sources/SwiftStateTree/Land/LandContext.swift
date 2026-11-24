import Foundation
import Logging

/// Request-scoped context for Land handlers
///
/// LandContext is created for each request (action, client event, join, leave) and released after processing.
/// It follows the Request-scoped Context pattern.
///
/// A handler that declares resolvers gets their outputs as typed parameters (#769); the context
/// holds them only for the runtime and the record.
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

    /// Submits server inputs to this land (#387). A turn that requests work outside the land's
    /// turns hands this to the work, with a ticket it took; the work's result comes back through
    /// it as a turn input (`HandleServerInput`). It holds the keeper weakly: after the land is
    /// gone, a submit returns `.refused(.draining)`.
    public let serverInputs: ServerInputSubmitter

    /// Deterministic event emission handler (used from synchronous handlers).
    private let emitEventHandler: @Sendable (AnyServerEvent, EventTarget) -> Void

    /// Deterministic sync request handler (used from synchronous handlers).
    private let requestSyncNowHandler: @Sendable () -> Void

    /// Deterministic broadcast-only sync request handler (used from synchronous handlers).
    private let requestSyncBroadcastOnlyHandler: @Sendable () -> Void

    /// Storage for resolver outputs (dynamically populated based on @Resolvers declaration):
    /// produced live, or read from a record in replay.
    private var resolverOutputs: [String: HeldResolverOutput] = [:]
    
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
        resolverOutputs: [String: HeldResolverOutput] = [:],
        serverInputs: ServerInputSubmitter = .unavailable
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
        self.serverInputs = serverInputs
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

    /// Emits a pre-built type-erased event (tests only). Land code emits typed events only
    /// (`emitEvent`); the public untyped emit was removed with the typed replay re-emit (#521
    /// PR 1b, #538). This keeps the path a framework bug would take: on a compressed encoding a
    /// payload that isn't a payload type is lost and ends the land with `.eventEncode` (#544).
    package func emitAnyServerEventForTesting(_ event: AnyServerEvent, to target: EventTarget) {
        emitEventHandler(event, target)
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
        resolverOutputs[propertyName] = .live(output)
    }

    /// Get all resolver outputs (internal use for recording), in the form they are held
    internal func getAllResolverOutputs() -> [String: HeldResolverOutput] {
        return resolverOutputs
    }

    // MARK: - Typed outputs

    /// The output held under `member` (`ProductInfoResolver` -> `productInfo`), as `T`. The
    /// entries' typed parameters read through here (#769).
    ///
    /// **Replay:** a recorded output is held as `RecordedResolverOutput`, and this read decodes
    /// it into the requested type with the record's own codec (`RecordPayloadSource`, #707), as a
    /// replayed server event is: a `Data` field reads back in the form the recorder wrote. An
    /// output that doesn't decode into the requested type reads as `nil`, with a warning naming
    /// the output and the error: in replay a `nil` the live handler didn't see is a divergence,
    /// and a silent one is how #707 went unnoticed.
    func resolverOutput<T: ResolverOutput>(_ type: T.Type, named member: String) -> T? {
        switch resolverOutputs[member] {
        case nil:
            return nil
        case .live(let output):
            return output as? T
        case .recorded(let wrapped):
            // A recorded output, in replay: decoded with the codec that wrote the record. A JSON
            // round trip can't read a `Data` field back (#707).
            do {
                return try RecordPayloadSource(wrapped.value, integralFloats: wrapped.integralFloats).decode(T.self)
            } catch {
                logger.warning("A recorded resolver output doesn't decode in replay; the handler reads nil", metadata: [
                    "output": .string(member),
                    "recordedType": .string(wrapped.typeIdentifier),
                    "requestedType": .string(String(reflecting: T.self)),
                    "error": .string("\(error)"),
                ])
                return nil
            }
        }
    }
}

// MARK: - Replay Mode Helper

/// A resolver output as an item or a context holds it: produced live, or read from a record.
/// Not `PlainData`: a recorded output is an `AnyCodable` tree until the handler reads it.
package enum HeldResolverOutput: Sendable {
    case live(any ResolverOutput)
    case recorded(RecordedResolverOutput)
}

/// Replay only: a recorded output's tree, decoded when the handler reads it, with the record's
/// own codec (#707). Not a `ResolverOutput`, so nothing can mistake it for an output.
package struct RecordedResolverOutput: Sendable {
    /// Type identifier of the resolver output (e.g., "SlowDeterministicOutput")
    package let typeIdentifier: String
    /// The output's tree, as the record holds it
    package let value: AnyCodable
    /// The JSON view's integer-to-float allowance (`RecordPayloadSource.integralFloats`): true when
    /// the record was read from its JSON view, which doesn't keep the float/integer split.
    package let integralFloats: Bool

    package init(typeIdentifier: String, value: AnyCodable, integralFloats: Bool = false) {
        self.typeIdentifier = typeIdentifier
        self.value = value
        self.integralFloats = integralFloats
    }
}

extension Dictionary where Key == String, Value == HeldResolverOutput {
    /// The record's entries for these outputs: a live output's type and value, a recorded one's
    /// type and tree as it was read. One projection for every record write site.
    package var recordedEntries: [String: ReevaluationRecordedResolverOutput] {
        mapValues { held in
            switch held {
            case .live(let output):
                ReevaluationRecordedResolverOutput(typeIdentifier: String(describing: type(of: output)), value: AnyCodable(output))
            case .recorded(let recorded):
                ReevaluationRecordedResolverOutput(typeIdentifier: recorded.typeIdentifier, value: recorded.value)
            }
        }
    }
}
