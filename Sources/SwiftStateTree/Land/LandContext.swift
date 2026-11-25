import Foundation
import Logging
import SwiftStateTurns

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
    
    /// The service for this handler invocation's draws, bound by the keeper at the call: a step
    /// service written back to the land's generator when the step ends, or a detached copy for a
    /// handler that replay doesn't repeat. `nil` in a context built without a keeper.
    var stepRandom: DeterministicRngService? = nil

    /// The land's deterministic random number generator.
    ///
    /// Draws continue one sequence across the land's steps, started from the land's seed, and
    /// replay repeats them. The keeper binds the service at each handler call:
    /// - A handler that replay repeats from the record (OnInitialize, OnJoin, OnLeave, an
    ///   action, a client event, a server input, the tick) gets its own service, and its draws
    ///   move the land's generator. The keeper copies the generator back when the handler returns.
    /// - A handler that replay doesn't repeat draws from a copy that never moves the land's
    ///   generator. CanJoin and the sync handler each get their own copy, so two such calls in a
    ///   row can draw the same values. The drain's three handlers (OnDestroyWhenEmpty, OnFinalize,
    ///   AfterFinalize) share one copy, so their draws continue one another.
    ///
    /// **In a handler whose draws move the land's generator, draw synchronously.** A `random`
    /// kept past its handler draws from a copy that no longer moves the land. A draw from a
    /// `Task` the handler starts may land before or after the step's write-back, so replay can't
    /// repeat it. Resolvers don't get the
    /// land's generator (#765): a resolver that needs randomness brings its own.
    ///
    /// A context built without a keeper (a unit test) falls back to a `DeterministicRngService`
    /// registered in `services`.
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
        if let stepRandom { return stepRandom }
        guard let rngService = services.get(DeterministicRngService.self) else {
            fatalError("LandContext.random: no generator. A keeper binds one for each handler call; a context built without a keeper needs a DeterministicRngService in services.")
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
    /// **Replay:** a recorded output is held as `RecordedResolverOutput`, its canonical
    /// MessagePack bytes, and this read decodes them into the requested type
    /// (`CanonicalMessagePack.decode`, with the record's integral-float allowance), so a `Data`
    /// field reads back in the form the recorder wrote, as a replayed server event's does. An
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
            // A recorded output, in replay: its canonical MessagePack bytes, decoded with the
            // record's codec (#707, #700 K1b-1 K1-Q7 (d)). A JSON round trip can't read a `Data`
            // field back.
            do {
                return try CanonicalMessagePack.decode(T.self, from: try wrapped.bytes(), integralFloats: wrapped.integralFloats)
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
@PlainData
package enum HeldResolverOutput: Sendable {
    case live(any ResolverOutput)
    case recorded(RecordedResolverOutput)
}

/// Replay only: a recorded output as canonical MessagePack bytes, decoded when the handler reads
/// it, with the record's own codec (#707). Not a `ResolverOutput`, so nothing can mistake it for
/// an output.
///
/// The replay build encodes the record's tree once (#700 K1b-1, K1-Q7 (d)): the item holds bytes,
/// not an `AnyCodable`, so it is plain. #769 R2 later records the bytes themselves.
@PlainData
package struct RecordedResolverOutput: Sendable {
    /// The tree's canonical MessagePack bytes, or why it couldn't be encoded.
    @PlainData
    package enum Payload: Sendable {
        case bytes([UInt8])
        case failed(RecordedPayloadDecodeFailure)
    }

    /// Type identifier of the resolver output (e.g., "SlowDeterministicOutput")
    package let typeIdentifier: String
    package let payload: Payload
    /// The JSON view's integer-to-float allowance (`CanonicalMessagePack.decode(_:from:integralFloats:)`):
    /// true when the record was read from its JSON view, which doesn't keep the float/integer split.
    package let integralFloats: Bool

    /// Encodes `value` once. A tree that can't be encoded is held as its failure: nesting past
    /// the canonical limit as `.recordTooDeep` (#817), anything else as `.undecodable` with its text.
    package init(typeIdentifier: String, value: AnyCodable, integralFloats: Bool = false) {
        self.typeIdentifier = typeIdentifier
        self.integralFloats = integralFloats
        do {
            self.payload = .bytes(try CanonicalMessagePack.encode(value))
        } catch {
            self.payload = .failed(RecordedPayloadDecodeFailure(error))
        }
    }

    /// The bytes, or the encode's failure as the read's error.
    package func bytes() throws -> [UInt8] {
        switch payload {
        case .bytes(let bytes): return bytes
        case .failed(let failure): throw failure.error
        }
    }
}

extension Dictionary where Key == String, Value == HeldResolverOutput {
    /// The record's entries for these outputs: a live output's type and value, a recorded one's
    /// type and its bytes read back as a tree. One projection for every record write site.
    ///
    /// A replay keeper has no recorder, so nothing reads a recorded output's projection today.
    /// It is kept for the contract: a recorded output whose bytes don't read back as a tree (one
    /// that failed to encode, or, under strict integral floats, an unsigned value above
    /// `Int.max`) is left out, with no entry.
    package var recordedEntries: [String: ReevaluationRecordedResolverOutput] {
        compactMapValues { held in
            switch held {
            case .live(let output):
                ReevaluationRecordedResolverOutput(typeIdentifier: String(describing: type(of: output)), value: AnyCodable(output))
            case .recorded(let recorded):
                (try? CanonicalMessagePack.decode(AnyCodable.self, from: recorded.bytes(), integralFloats: recorded.integralFloats))
                    .map { ReevaluationRecordedResolverOutput(typeIdentifier: recorded.typeIdentifier, value: $0) }
            }
        }
    }
}
