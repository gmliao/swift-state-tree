import Foundation
import Logging
import SwiftStateTurns

// MARK: - Helper for Replay Mode

// Note: HeldResolverOutput and RecordedResolverOutput are defined in LandContext.swift, beside the subscript that reads them

/// The runtime executor for a Land instance.
///
/// `LandKeeper` is an actor that manages the authoritative state and executes the handlers
/// defined in a `LandDefinition`. It handles:
/// - Player join/leave lifecycle
/// - Action and event processing
/// - Periodic ticks
/// - Automatic shutdown when empty
/// - State synchronization using snapshot model
///
/// All state mutations are serialized through the actor, ensuring thread-safety.
/// Sync operations use snapshot model - they take a snapshot at the start and work with it,
/// allowing mutations to proceed concurrently without blocking.
///
/// **Sync Model**: Snapshot-based, non-blocking
/// - Sync takes a snapshot of state at the start
/// - Mutations can proceed concurrently (not blocked by sync)
/// - Each sync gets a consistent snapshot (actor serialization ensures this)
/// - Sync deduplication prevents redundant concurrent sync operations
///
///     /// TODO: Performance considerations:
///     /// - When Resolver mechanism is implemented and Action Handlers become synchronous,
///     ///   we may be able to directly modify state without copying
///     /// - Consider sync queue or debouncing for high-frequency sync scenarios
public enum LandMode: Sendable {
    case live
    case reevaluation
}

/// Output mode for reevaluation mode: when to forward emitted events.
public enum ReevaluationOutputMode: Sendable {
    /// Only forward to reevaluation sink (default, backward compatible).
    case sinkOnly
    /// Forward to both the keeper's transport and the sink. No adapter serves a reevaluation
    /// keeper (#612), so the transport is one the caller set directly.
    case transportAndSink
}

/// The one key of a keeper's sync binding generations (#546 L2a).
@PlainData
package enum SyncBindingKey: Hashable, Sendable {
    case binding
}

/// A requested sync turn's ticket: the binding it was taken under.
package typealias SyncTurnTicket = Ticket<SyncBindingKey>

/// Where a `LandKeeper` awaits its test hold hook (`installHolds`).
enum LandKeeperHoldPoint: Hashable, Sendable {
    /// `forceShutdown`, right after its shutdown turn applied and before the destroy (#382).
    case shutdownTurnApplied
    /// The start of the destruction, after `isDraining` is set and before any destroy handler.
    case drainStart
    /// The start of a failed land's teardown task (#535), before it tells the transport: the
    /// failing segment has already cleared the players and installed `drainTask`.
    case landFailedTeardown
    /// Both `join` variants, after their checks and before the player insert.
    case join
    /// The start of `leave(playerID:clientID:sessionID:)`.
    case leave
    /// The start of each input drain, before its first turn.
    case inputDrain
    /// A tickless server input's task, before it waits for (or runs) the turn applying it.
    case serverInputKick
    /// After an input turn's record is enqueued (in the turn's synchronous segment), or, on a
    /// re-evaluation tick, after its inputs are applied: their callers wait only for the record.
    case turnRecord
    /// The start of an action job's completion (`completeAction`), before its segment.
    case actionComplete
    /// The start of an action job's task, before its resolvers run. The values were built in
    /// the intake segment (#769 §3.2); a test changes the State here and checks they don't see it.
    case actionJobStart
    /// The end of `submitAction`, before it returns or throws to its caller: its intake (and
    /// a job's registration) is done.
    case actionSubmitted
    /// The end of `forceShutdown`, after its flight finished and before it returns to its
    /// caller: a caller that records the destroy as finished does so after this point.
    case forceShutdownReturn
}

/// What `LandKeeper.submitAction` did with an action.
package enum ActionSubmission: Sendable {
    /// Handled through: its outcome (an ACK on a tick land, the handler's response on a
    /// tickless one).
    case completed(InputOutcome)
    /// Its resolvers run in a job: `LandKeeper.awaitActionResult(sequence:)` returns its outcome.
    case pending(sequence: Int64)
}

/// `LandKeeper.awaitActionResult(sequence:)` was called for a sequence with no unread slot: no
/// job was submitted under it, or its outcome was already read.
package struct ActionResultUnavailable: Error, Equatable {
    package let sequence: Int64
}

/// The empty-land destroy timer's handle (D16). A start staged in a turn body installs its task
/// here at the flush; a cancel before that marks the ticket, and the install then cancels the
/// task. Decided under the lock, cancelled after it: `cancel()` can run cancellation handlers
/// synchronously, and the lock isn't recursive.
private final class DestroyTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func install(_ newTask: Task<Void, Never>) {
        let cancelNow = lock.withLock { () -> Bool in
            task = newTask
            return cancelled
        }
        if cancelNow { newTask.cancel() }
    }

    func cancel() {
        let installed = lock.withLock { () -> Task<Void, Never>? in
            if let task { return task }
            cancelled = true
            return nil
        }
        installed?.cancel()
    }

    var installedTask: Task<Void, Never>? {
        lock.withLock { task }
    }
}

public actor LandKeeper<State: StateNodeProtocol>: LandKeeperProtocol {
    /// Unified pending item for every input kind (`package`: nothing public takes or returns it).
    @PlainData
    package enum PendingItem: Sendable {
        case action(PendingActionItem)
        case clientEvent(PendingClientEventItem)
        case lifecycle(PendingLifecycleItem)
        case serverInput(PendingServerInputItem)
        /// `forceShutdown`'s turn (#382): recorded as the lifecycle event kind `"shutdown"`.
        case shutdown(PendingShutdownItem)
        /// A failure the transport reported from outside a turn (`submitLandFailure`, #535): the
        /// turn that applies it ends the land. Not an input: it isn't recorded as one.
        case landFailure(PendingLandFailureItem)
    }

    /// A transport-reported failure (#535), queued as a turn input so it is applied in a turn.
    @PlainData
    package struct PendingLandFailureItem: Sendable {
        package let sequence: Int64
        package let resolvedAtTick: Int64
        package let failure: LandFailure
    }

    /// A server input (#387), taken at submit: the system identity applies it.
    @PlainData
    package struct PendingServerInputItem: Sendable {
        package let sequence: Int64
        package let typeIdentifier: String
        /// The record form's canonical MessagePack bytes: what the record writes, never a
        /// re-encode of `decoded`, which can differ from it (#700 K1a, K1-Q4 (a)).
        package let bytes: Data
        /// `payload` decoded as the handler's type, once: at submit live (where a failure is
        /// refused, so live holds a value), when the item is built in replay (where a failure is
        /// kept, and thrown when the item is applied).
        package let decoded: DecodedServerInput
        package let resolvedAtTick: Int64
    }

    /// The forced shutdown's input (#382). Its turn clears the players without OnLeave, drops
    /// every input still queued and starts the drain, in one synchronous segment
    /// (`applyInputs`).
    @PlainData
    package struct PendingShutdownItem: Sendable {
        package let sequence: Int64
        package let resolvedAtTick: Int64
    }

    /// The recorded lifecycle event kind of the shutdown turn (`PendingItem.shutdown`).
    static var shutdownLifecycleKind: String { "shutdown" }

    @PlainData
    public enum LifecycleKind: String, Codable, Sendable {
        case initialize
        case join
        case leave
    }

    @PlainData
    public struct PendingLifecycleItem: Sendable {
        public let sequence: Int64
        public let kind: LifecycleKind
        public let playerID: PlayerID?
        public let clientID: ClientID?
        public let sessionID: SessionID?
        public let deviceID: String?
        public let isGuest: Bool?
        public let metadata: [String: String]
        /// The resolver outputs: produced live, or read from a record in replay.
        package let heldResolverOutputs: [String: HeldResolverOutput]
        public let resolvedAtTick: Int64

        public init(
            sequence: Int64,
            kind: LifecycleKind,
            playerID: PlayerID?,
            clientID: ClientID?,
            sessionID: SessionID?,
            deviceID: String?,
            isGuest: Bool?,
            metadata: [String: String],
            resolverOutputs: [String: any ResolverOutput],
            resolvedAtTick: Int64
        ) {
            self.init(
                sequence: sequence, kind: kind, playerID: playerID, clientID: clientID, sessionID: sessionID,
                deviceID: deviceID, isGuest: isGuest, metadata: metadata,
                heldResolverOutputs: resolverOutputs.mapValues { .live($0) }, resolvedAtTick: resolvedAtTick
            )
        }

        /// An item whose outputs are held as they were produced or read.
        package init(
            sequence: Int64,
            kind: LifecycleKind,
            playerID: PlayerID?,
            clientID: ClientID?,
            sessionID: SessionID?,
            deviceID: String?,
            isGuest: Bool?,
            metadata: [String: String],
            heldResolverOutputs: [String: HeldResolverOutput],
            resolvedAtTick: Int64
        ) {
            self.sequence = sequence
            self.kind = kind
            self.playerID = playerID
            self.clientID = clientID
            self.sessionID = sessionID
            self.deviceID = deviceID
            self.isGuest = isGuest
            self.metadata = metadata
            self.heldResolverOutputs = heldResolverOutputs
            self.resolvedAtTick = resolvedAtTick
        }
    }

    @PlainData
    package struct PendingActionItem: Sendable {
        package let sequence: Int64
        /// The action as the apply step runs it (#521, #700 K1a): decoded at intake live, and
        /// when replay builds the item. A recorded payload that doesn't decode is kept as its
        /// failure, thrown when the item is applied, where a decode at apply threw before.
        package let decoded: DecodedAction
        /// The handler's position in `definition.actionHandlers` (#700 K1b-1, F9): found at
        /// intake, or by the recorded type identifier in replay, so it is known even when the
        /// payload didn't decode. Nil on a hand-built item, whose handler is found by its value's
        /// type when it is applied.
        package let handlerIndex: ActionHandlerIndex?
        /// The bytes the record keeps (#700 K1a): set only when the land records inputs, and on
        /// a hand-built item, whose init computes them to decode its action.
        package let recorded: RecordedPayloadBytes?
        package let playerID: PlayerID
        package let clientID: ClientID
        package let sessionID: SessionID
        /// The resolver outputs: produced live, or read from a record in replay.
        package let heldResolverOutputs: [String: HeldResolverOutput]
        package let resolvedAtTick: Int64

        /// A hand-built action (K1-Q8 (a)): it has no client bytes, so it is encoded once as
        /// canonical JSON, and the item holds the value those bytes decode to, recording or not.
        package init<A: ActionPayload>(
            sequence: Int64,
            action: A,
            playerID: PlayerID,
            clientID: ClientID,
            sessionID: SessionID,
            resolverOutputs: [String: any ResolverOutput],
            resolvedAtTick: Int64
        ) throws {
            let recorded = try RecordedPayloadBytes(typed: action)
            self.init(
                sequence: sequence,
                decoded: .value(try JSONDecoder().decode(A.self, from: recorded.bytes)),
                handlerIndex: nil,
                recorded: recorded,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                heldResolverOutputs: resolverOutputs.mapValues { .live($0) },
                resolvedAtTick: resolvedAtTick
            )
        }

        package init(
            sequence: Int64,
            decoded: DecodedAction,
            handlerIndex: ActionHandlerIndex?,
            recorded: RecordedPayloadBytes?,
            playerID: PlayerID,
            clientID: ClientID,
            sessionID: SessionID,
            heldResolverOutputs: [String: HeldResolverOutput],
            resolvedAtTick: Int64
        ) {
            self.sequence = sequence
            self.decoded = decoded
            self.handlerIndex = handlerIndex
            self.recorded = recorded
            self.playerID = playerID
            self.clientID = clientID
            self.sessionID = sessionID
            self.heldResolverOutputs = heldResolverOutputs
            self.resolvedAtTick = resolvedAtTick
        }

        /// This item with other resolver outputs and tick, its value and bytes kept.
        package func with(heldResolverOutputs: [String: HeldResolverOutput], resolvedAtTick: Int64) -> PendingActionItem {
            PendingActionItem(
                sequence: sequence,
                decoded: decoded,
                handlerIndex: handlerIndex,
                recorded: recorded,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                heldResolverOutputs: heldResolverOutputs,
                resolvedAtTick: resolvedAtTick
            )
        }
    }

    /// A client event's payload as its item holds it.
    @PlainData
    package enum PendingClientEventPayload: Sendable {
        /// Decoded at intake live, or when replay built the item (#521, #700 K1a).
        case decoded(any ClientEventPayload)
        /// A payload that didn't decode: a recorded one when replay built the item, or, live, one
        /// whose descriptor has no decode (the public descriptor init's), decoded with the
        /// descriptor's type at intake. The event is dropped at apply, as its handler dropped it
        /// when it decoded there (a nesting refusal is also logged and counted, #362).
        case failed(RecordedPayloadDecodeFailure)
    }

    @PlainData
    package struct PendingClientEventItem: Sendable {
        package let sequence: Int64
        /// The event's wire type, its descriptor's name.
        package let typeIdentifier: String
        package let payload: PendingClientEventPayload
        /// The bytes the record keeps (#700 K1a): set only when the land records inputs.
        package let recorded: RecordedPayloadBytes?
        package let playerID: PlayerID
        package let clientID: ClientID
        package let sessionID: SessionID
        package let resolvedAtTick: Int64

        package init(
            sequence: Int64,
            typeIdentifier: String,
            payload: PendingClientEventPayload,
            recorded: RecordedPayloadBytes?,
            playerID: PlayerID,
            clientID: ClientID,
            sessionID: SessionID,
            resolvedAtTick: Int64
        ) {
            self.sequence = sequence
            self.typeIdentifier = typeIdentifier
            self.payload = payload
            self.recorded = recorded
            self.playerID = playerID
            self.clientID = clientID
            self.sessionID = sessionID
            self.resolvedAtTick = resolvedAtTick
        }
    }

    // Legacy PendingAction kept for backward compatibility during migration
    public struct PendingAction<ID: Hashable & Sendable>: Sendable {
        public let id: ID
        public let action: AnyCodable
        public let actionType: any ActionPayload.Type
        public let playerID: PlayerID
        public let clientID: ClientID
        public let sessionID: SessionID
        public let resolverOutputs: [String: any ResolverOutput]
        public let resolvedAtTick: Int64

        public init(
            id: ID,
            action: AnyCodable,
            actionType: any ActionPayload.Type,
            playerID: PlayerID,
            clientID: ClientID,
            sessionID: SessionID,
            resolverOutputs: [String: any ResolverOutput],
            resolvedAtTick: Int64
        ) {
            self.id = id
            self.action = action
            self.actionType = actionType
            self.playerID = playerID
            self.clientID = clientID
            self.sessionID = sessionID
            self.resolverOutputs = resolverOutputs
            self.resolvedAtTick = resolvedAtTick
        }
    }

    /// The keeper's plain state (#700 K1b-4): every field a turn reads or writes. A step takes
    /// it with one `inout` access and reaches each field through that binding.
    private var model: KeeperModel<State>
    /// Each player's services (#700 K1b-4), beside the model: `LandServices` holds references.
    /// Written in the same synchronous segment as every insert and removal of `model.players`,
    /// keyed by the entry's generation, so a late writer never removes a newer entry's services.
    /// K2 replaces it with the turn core's table.
    private var playerServices: [PlayerID: (generation: Epoch, services: LandServices)] = [:]
    /// The re-evaluation fields; a live keeper keeps their defaults.
    private var replay = ReplayFields<State>()
    /// Re-evaluation: OnInitialize's `validate` threw on the recorded inputs (#593); see
    /// `ReplayFields.replayedInitializeRefusal`.
    package var replayedInitializeRefusal: String? { replay.replayedInitializeRefusal }

    // The model's fields that tests and diagnostics read, under their old names.
    /// Server inputs refused because the in-flight cap was reached.
    public var serverInputCapRejections: Int { model.serverInputCapRejections }
    var foldedSyncs: Int { model.foldedSyncs }
    var overdueFoldedSyncs: Int { model.overdueFoldedSyncs }
    var lateFoldedSyncs: Int { model.lateFoldedSyncs }
    var inTurnDeferredTurns: Int { model.inTurnDeferredTurns }
    var inputsSkippedAfterDestroy: Int { model.inputsSkippedAfterDestroy }
    var joinSyncTicks: Int { model.joinSyncTicks }
    var supersededSenderRejections: Int { model.supersededSenderRejections }
    var joinSyncWaitsForCommit: Bool { model.joinSyncWaitsForCommit }
    package var joinSyncRequestTurnsForTesting: Int { model.joinSyncRequestTurnsForTesting }
    var joinSyncTurnsForTesting: Int { model.joinSyncTurnsForTesting }
    var requestedSyncTurnsForTesting: [SyncTurnReason: Int] { model.requestedSyncTurnsForTesting }

    /// What the keeper is fixed with at init: the definition and its own configuration.
    nonisolated let behavior: KeeperBehavior<State>

    public nonisolated var definition: LandDefinition<State> { behavior.definition }



    private var transport: LandKeeperTransport?

    private var serverInputMaxInFlight = ServerInputLimits.maxInFlightPerLand()

    /// Whether this keeper is live. A `TransportAdapter` binds only a live keeper: a
    /// reevaluation keeper runs headless, with no adapter (#612).
    package nonisolated var isLive: Bool { behavior.config.mode == .live }

    private struct EmittedEvent: Sendable {
        let sequence: Int64
        let tickId: Int64
        let event: AnyServerEvent
        let target: EventTarget
    }

    private struct SyncRequests: Sendable {
        var syncNow: Bool = false
        var syncBroadcastOnly: Bool = false
    }

    private final class OutputCollector: @unchecked Sendable {
        var nextSequence: Int64 = 0
        /// Re-evaluation only: a take past `Int64.max` stops the replay instead of the process (#741).
        /// A live counter starts at 0 and traps first, so the live path keeps the plain increment.
        var checksOverflow = false
        /// Set by the first take that found no number left; read at the run's step boundaries.
        var sequenceExhausted = false
        var emittedEvents: [EmittedEvent] = []
        var syncRequestsByTick: [Int64: SyncRequests] = [:]

        func takeNextSequence() -> Int64 {
            let s = nextSequence
            guard checksOverflow else {
                nextSequence += 1
                return s
            }
            let (next, overflow) = s.addingReportingOverflow(1)
            if overflow {
                // The counter stays at Int64.max and the number repeats: the run ends at its next
                // step boundary (`replaySequenceExhausted()`), and what it computed meanwhile is dropped.
                sequenceExhausted = true
            } else {
                nextSequence = next
            }
            return s
        }

        func enqueueEmittedEvent(_ anyEvent: AnyServerEvent, to target: EventTarget, tickId: Int64) {
            let seq = takeNextSequence()
            emittedEvents.append(EmittedEvent(sequence: seq, tickId: tickId, event: anyEvent, target: target))
        }

        func requestSyncNow(tickId: Int64) {
            var req = syncRequestsByTick[tickId] ?? SyncRequests()
            req.syncNow = true
            syncRequestsByTick[tickId] = req
        }

        func requestSyncBroadcastOnly(tickId: Int64) {
            var req = syncRequestsByTick[tickId] ?? SyncRequests()
            req.syncBroadcastOnly = true
            syncRequestsByTick[tickId] = req
        }
    }

    private let outputCollector = OutputCollector()

    /// Recorder for deterministic re-evaluation (only in .live mode). Written once, in `init`, so
    /// the behavior holds it (#700 K1b-5 rev 2.3 D12).
    private var reevaluationRecorder: ReevaluationRecorder? { behavior.reevaluationRecorder }
    /// Whether anything reads the applied inputs' records: a recorder, or a reevaluation run.
    /// Without either, an action or client event isn't recorded, and its payload's tree is never
    /// built from a MessagePack source (#521).
    private var recordsInputs: Bool { reevaluationRecorder != nil || behavior.config.mode != .live }

    /// The record's bytes for an item that holds none, which only an item queued before the land
    /// recorded can be: the value's canonical JSON, the bytes of a typed value with no source
    /// (K1-Q8 (a)).
    /// The fallback bytes `prepareFallbackRecordBytes` encoded for `sequence`, or else (a caller
    /// outside an input turn's hold) the encode run now.
    private static func recordBytes(
        _ sequence: Int64,
        prepared: [Int64: Result<Data, any Error>],
        encode: () throws -> Data
    ) throws -> Data {
        if let prepared = prepared[sequence] { return try prepared.get() }
        return try encode()
    }

    /// The fallback record bytes of `batch`'s actions and client events that hold none, keyed by
    /// sequence, each encode's error kept for its own input: encoded before an input turn's body
    /// holds the model, because the encode runs the payload's `encode(to:)`, user code that must
    /// not run inside the hold (#700 K1b-5a, MF1). An action whose payload didn't decode gets no
    /// entry: its apply throws on the decode first.
    private func prepareFallbackRecordBytes(_ batch: [PendingItem]) -> [Int64: Result<Data, any Error>] {
        guard recordsInputs else { return [:] }
        var prepared: [Int64: Result<Data, any Error>] = [:]
        for item in batch {
            switch item {
            case let .action(actionItem) where actionItem.recorded == nil:
                guard let decoded = try? actionItem.decoded.get() else { continue }
                prepared[actionItem.sequence] = Result { try Self.fallbackRecordBytes(decoded) }
            case let .clientEvent(eventItem) where eventItem.recorded == nil:
                prepared[eventItem.sequence] = Result { try Self.fallbackRecordBytes(eventItem.payload) }
            default:
                continue
            }
        }
        return prepared
    }

    private static func fallbackRecordBytes(_ action: any ActionPayload) throws -> Data {
        try RecordPayloadEncoding.canonicalJSON(AnyCodable(action))
    }

    /// A client event whose descriptor has no decode (the public descriptor init's), decoded with
    /// the descriptor's type: the decode its handler ran when applied, before #700 K1b-1. A
    /// failure is held, not thrown: apply drops the event, and counts one nested too deep (#362).
    private static func decodeWithDescriptorType(
        _ descriptor: AnyEventDescriptor,
        _ source: any PayloadDecodingSource
    ) -> PendingClientEventPayload {
        guard let decode = AnyEventDescriptor.clientEventDecoder(for: descriptor.type) else {
            // Not a `ClientEventPayload`: no handler can match it, so apply skips it at the
            // handler lookup and never reads this.
            return .failed(.undecodable("\(descriptor.type) isn't a ClientEventPayload"))
        }
        do {
            try source.validateRecordable()
            return .decoded(try decode(source))
        } catch {
            return .failed(RecordedPayloadDecodeFailure(error))
        }
    }

    private static func fallbackRecordBytes(_ payload: PendingClientEventPayload) throws -> Data {
        switch payload {
        case .decoded(let event): return try RecordPayloadEncoding.canonicalJSON(AnyCodable(event))
        case .failed: return Data()
        }
    }




    /// Set the transport interface (called after TransportAdapter is created). A keeper whose
    /// destruction has finished keeps its released placeholder instead: a transport attached
    /// after it (a land whose initialization failed before it was wired) would never be
    /// released (#346).
    ///
    /// On a live keeper, a transport whose `runsSyncPhaseInTurn(of:)` is `false` for this keeper
    /// stops the process (`fatalError`, every build): a live keeper syncs only in its turns, so it
    /// would get no output (#546 L2d). An adapter built for another keeper is refused the same
    /// way. `nil` and re-evaluation keepers are exempt.
    ///
    /// Called synchronously while one of the keeper's turn bodies runs (a callback during a port
    /// call), it is refused and changes nothing, and the land ends with
    /// `LandFailure.Kind.keeperReentry` (#700 K1b-5a), as the other adapter-facing entries are.
    public func setTransport(_ transport: LandKeeperTransport?) {
        guard sentinel.bodyDepth == 0 else {
            noteReentry(through: "setTransport")
            return
        }
        if !model.destructionFinished {
            Self.refuseTransportWithoutInTurnPhase(transport, mode: behavior.config.mode, landID: behavior.config.actualLandID ?? definition.id, keeper: self)
        }
        let attached = model.destructionFinished ? releasedTransport : transport
        self.transport = attached
        model.transportRecordsFolds = attached?.recordsInTurnSyncFolds ?? false
        if transport != nil, !model.destructionFinished { noteTransportBound() }
    }

    /// Stops the process if a live keeper is handed a transport that can't run its sync phase in
    /// turn for it (#546 L2d): every live keeper syncs through its turns, so such a transport would
    /// get no output at all. Exempt: no transport, the released placeholder, a re-evaluation keeper.
    /// A `fatalError`, not a `precondition`: it must stop, with its message, in every build.
    private nonisolated static func refuseTransportWithoutInTurnPhase(
        _ transport: LandKeeperTransport?,
        mode: LandMode,
        landID: String,
        keeper: AnyObject
    ) {
        guard mode == .live, let transport, !(transport is ReleasedLandTransport) else { return }
        guard !transport.runsSyncPhaseInTurn(of: keeper) else { return }
        fatalError(
            "LandKeeper(\(landID)): a live keeper's transport must run its sync phase in turn for this keeper; "
                + "\(type(of: transport)).runsSyncPhaseInTurn(of:) returned false. Attach the TransportAdapter "
                + "built for this keeper, or no transport (#546 L2d)"
        )
    }


    /// The transport of a destroyed keeper: it holds nothing (so the adapter is released) and
    /// counts the calls late keeper work still makes, which a released adapter would otherwise
    /// never see. Set when the destruction finishes.
    private var releasedTransport: ReleasedLandTransport?

    /// Transport calls made after the destruction finished, dropped (events, sync requests).
    /// The adapter counted such late frames as dropped (`droppedAfterFinish`) while it was
    /// attached; once it is released the keeper counts them here (#346).
    package var transportCallsAfterDestruction: Int { releasedTransport?.dropped ?? 0 }


    /// Tests: the transport attached now (after the destruction, the released placeholder,
    /// `ReleasedLandTransport`, #346).
    var transportForTesting: LandKeeperTransport? { transport }

    /// Tests: the land's generator now.
    var landRandomForTesting: DeterministicRng { model.landRandom }

    /// The seed the land's generator started from, for the record header: a caller-registered
    /// `DeterministicRngService`'s seed, else the one derived from the land ID. Never `nil`.
    public func getRngSeed() -> UInt64? {
        behavior.config.landRandomSeed
    }

    private var tickTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    /// The empty-land destroy timer's box (D16): a start staged in a turn body installs its task
    /// into the ticket it captured, so a cancel before the flush still stops it.
    private var destroyTicket: DestroyTicket?
    /// The destruction in progress (single-flight): `shutdownIfIdle` runs it once.
    private var drainTask: Task<Void, Never>?
    private let drainFlag = DrainFlag()

    /// The land is being destroyed, or was: it became empty and its destruction started.
    ///
    /// Set synchronously right after the emptiness check, before the first await of the
    /// destruction, and never cleared. A draining keeper rejects joins
    /// (`JoinError.landShuttingDown`), and `LandManager` treats it as absent. Readable without
    /// awaiting the keeper, so a caller can check it in the same synchronous segment as its act.
    public nonisolated var isDraining: Bool { drainFlag.isSet }

    /// Why this land's destruction started, once it has (`nil` before). Set in the same
    /// synchronous segment as `isDraining`, by the first caller only, and never changed.
    public nonisolated var destructionCause: LandDestructionCause? { drainFlag.cause }

    /// The failure that ended this land (#535), once one has (`nil` otherwise). Set in the same
    /// synchronous segment as `destructionCause` becomes `.failed`, and never changed: the first
    /// failure wins.
    public nonisolated var failure: LandFailure? { drainFlag.failure }

    /// A failure a transport found outside a turn, noted for this keeper's next step boundary
    /// (#704). See `notePendingFailure(_:)`.
    private nonisolated let pendingTransportFailure = LandFailureMailbox()

    /// Notes a failure that a transport found outside a keeper turn, in the same segment as it
    /// closed the land's output gate (#704). The keeper's next step reads it before anything of
    /// that step goes out (`finishApply`, `runSyncOnlyTurn`, `runTurnOutputs`) and ends the land
    /// with it. The transport still submits it (`submitLandFailure`), which wakes a keeper with no
    /// turn due; by then the land has usually failed, and the first cause stays.
    ///
    /// The first failure noted wins. A keeper in re-evaluation never gets one: replay has no
    /// transport.
    package nonisolated func notePendingFailure(_ failure: LandFailure) {
        guard behavior.config.mode == .live else { return }
        pendingTransportFailure.note(failure)
    }

    /// Tests: the failure noted by `notePendingFailure(_:)`, if any.
    package nonisolated var pendingFailureForTesting: LandFailure? { pendingTransportFailure.failure }

    /// Waits until this keeper's destruction has finished, handlers and the transport's
    /// `onLandDestroyed` included. Returns at once when no destruction started.
    ///
    /// `LandManager` awaits it before creating a new instance for the same LandID, so the old
    /// instance's finalize never overlaps the new one's initialize.
    public func waitUntilDrained() async {
        if let drainTask {
            await drainTask.value
        }
    }

    /// Callers of `waitUntilDrainStartedForTesting`, resumed when `drainTask` is installed.
    private var drainStartedWaitersForTesting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextDrainStartedWaiterForTesting = 0

    /// Test hook: returns once this keeper's destruction has started, `drainTask` installed, so a
    /// `waitUntilDrained()` after it waits for the whole destruction. Keyed on `drainTask`, not
    /// `isDraining`: `forceShutdown` sets the flag before the task exists, and in that window
    /// `waitUntilDrained()` returns at once. Also returns when its task is cancelled; a test
    /// bounds it with that (`withinHangBound`), since no destruction may ever start.
    package func waitUntilDrainStartedForTesting() async {
        guard drainTask == nil else { return }
        let id = nextDrainStartedWaiterForTesting
        nextDrainStartedWaiterForTesting += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                drainStartedWaitersForTesting[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelDrainStartedWaiterForTesting(id) }
        }
    }

    private func cancelDrainStartedWaiterForTesting(_ id: Int) {
        drainStartedWaitersForTesting.removeValue(forKey: id)?.resume()
    }

    /// Resumes `waitUntilDrainStartedForTesting` callers; call right after installing `drainTask`.
    private func resumeDrainStartedWaitersForTesting() {
        guard !drainStartedWaitersForTesting.isEmpty else { return }
        let waiters = drainStartedWaitersForTesting.values
        drainStartedWaitersForTesting.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Forced-interleaving hold points (tests only; a no-op unless installed).
    private var holds = HoldPoints<LandKeeperHoldPoint>()

    /// Installs (or, with `nil`, removes) the hold hook for every `LandKeeperHoldPoint` (tests).
    func installHolds(_ hook: (@Sendable (LandKeeperHoldPoint) async -> Void)?) {
        holds.install(hook)
    }
    private var initializationTask: Task<Void, Never>?

    /// Holds `error` as the initialization's failure, wrapped as every caller gets it (#700 K1b-2).
    private func failInitialization(with error: any Error) {
        // Minting the ID writes the model. A plain assignment evaluates its right side first, so
        // this split is a precaution, kept in the shape of the slot fill's (`fillActionSlot`).
        let failure = recordFailure(&model, &turnSide, LandInitializationError(underlying: error))
        model.initializationFailure = failure
        checkActionTables(&model, &turnSide, #function)
    }

    /// Throws the initialization's failure, if it failed. Every caller gets the same value: the
    /// entry is read, never taken.
    private func throwIfInitializationFailed() throws {
        if let id = model.initializationFailure {
            throw failure(for: id, path: .initialization, sequence: nil)
        }
    }



    private func flushOutputs(forTick tickId: Int64) async {
        let toFlush = outputCollector.emittedEvents
            .filter { $0.tickId == tickId }
            .sorted { $0.sequence < $1.sequence }
        if !toFlush.isEmpty {
            // Remove flushed events first to keep deterministic behavior even if downstream awaits.
            outputCollector.emittedEvents.removeAll { $0.tickId == tickId }
        }

        switch behavior.config.mode {
        case .live:
            for item in toFlush {
                await transport?.sendEventToTransport(item.event, to: item.target)
            }
            // Record server events for verification when reevaluation recording is enabled
            if let recorder = reevaluationRecorder, !toFlush.isEmpty {
                let records = toFlush.map { item in
                    ReevaluationRecordedServerEvent(
                        kind: "serverEvent",
                        sequence: item.sequence,
                        tickId: item.tickId,
                        typeIdentifier: item.event.type,
                        payload: item.event.payload,
                        target: ReevaluationEventTargetRecord.from(item.target)
                    )
                }
                await recorder.recordServerEvents(tickId: tickId, events: records)
            }
        case .reevaluation:
            if behavior.config.reevaluationOutputMode == .transportAndSink {
                for item in toFlush {
                    await transport?.sendEventToTransport(item.event, to: item.target)
                }
            }
            if let sink = replay.reevaluationSink, !toFlush.isEmpty {
                let records = toFlush.map { item in
                    ReevaluationRecordedServerEvent(
                        kind: "serverEvent",
                        sequence: item.sequence,
                        tickId: item.tickId,
                        typeIdentifier: item.event.type,
                        payload: item.event.payload,
                        target: ReevaluationEventTargetRecord.from(item.target)
                    )
                }
                await sink.onEmittedServerEvents(tickId: tickId, events: records)
            }
        }

        await runSyncRequests(outputCollector.syncRequestsByTick.removeValue(forKey: tickId))
    }

    /// Runs the sync requests a tick's handlers made (`ctx.requestSyncNow()` and the like),
    /// taken from `outputCollector.syncRequestsByTick` by the caller.
    private func runSyncRequests(_ requests: SyncRequests?) async {
        guard let req = requests else { return }
        // In-turn paths take their own requests; one left here runs as a sync-only turn (a
        // broadcast-only request runs the full phase, as in a turn). No live keeper sends a
        // request through the legacy transport calls (#546 L2d); a re-evaluation keeper never
        // did here (its replayed passes make their broadcast-only call where they run).
        if syncsInTurn, req.syncNow || req.syncBroadcastOnly {
            runSyncOnlyTurnIfInTurn()
        }
    }


    // MARK: In-turn sync state (see `docs/core/runtime.md`, In-Turn Sync)

    /// Whether this keeper's inputs, ticks and initialization run as turns: every live keeper,
    /// whatever its transport (#546 L2d). Fixed at init. Re-evaluation keepers replay recorded
    /// passes instead.
    private var routesThroughTurn: Bool { behavior.config.mode == .live }

    /// Whether this keeper's turns run the sync phase, through the attached transport: live, and
    /// the transport runs it for this keeper (`LandKeeperTransport.runsSyncPhaseInTurn(of:)`).
    /// Never true for a transport attached to another keeper, so no turn reaches an
    /// `assumeIsolated` that would trap. False with no transport: the turns then record their
    /// outputs and deliver them nowhere.
    private var syncsInTurn: Bool {
        behavior.config.mode == .live && (transport?.runsSyncPhaseInTurn(of: self) ?? false)
    }





    /// The fold waiting for its tick turn: the tick deadline it folded on and whether that
    /// deadline had passed. Set with `inTurnSyncDue` by a fold, taken when a tick turn starts.
    private var pendingFold: PendingFold?




    /// The tick loop's next deadline: set by the loop after each tick, cleared when the tick starts.
    private var nextTickDeadline: ContinuousClock.Instant?

    /// The coincident-sync window: min(5 ms, tick / 4, sync / 4). A sync loop firing this close
    /// to the next tick folds into that tick turn instead of overtaking it.
    private var coincidentSyncWindow: Duration {
        var window = Duration.milliseconds(5)
        if let tick = definition.lifetimeHandlers.tickInterval { window = min(window, tick / 4) }
        if let sync = definition.lifetimeHandlers.syncInterval { window = min(window, sync / 4) }
        return window
    }


    /// Tickless lands: callers waiting for their input's turn, by input sequence. Actions get
    /// their own response; other inputs get an empty one (or the handler's error).
    private var inputTurnWaiters: [Int64: CheckedContinuation<InputOutcome, any Error>] = [:]

    /// Maximum inputs applied in one tickless input turn, so continuous input cannot starve the
    /// sync loop (other jobs run between turns).
    static var inputTurnBatchLimit: Int { 64 }


    /// The last recorder submission. Each submission awaits the one before it, so turn records
    /// reach the recorder in turn order.
    /// Orders recorder submissions and lets the shutdown saver wait for them.
    private let recorderSubmissions = ReevaluationSubmissionTracker()

    /// The turn side (#700 K1b-5a): borrowed `inout` by one body call at a time (`withTurn`).
    /// Nothing else touches it while a body runs.
    private var turnSide: KeeperTurnSide
    /// The re-entry sentinel (`KeeperReentrySentinel`), held by the behavior so a body on the
    /// model reaches it (#700 K1b-5, rev 2.3 D13).
    private var sentinel: KeeperReentrySentinel { behavior.reentrySentinel }

    /// A land without a tick handler: every turn records under one tick id, so the keeper
    /// closes each turn's record itself (`ReevaluationRecorder.endTurn()`, #327).
    private var isTickless: Bool { definition.lifetimeHandlers.tickHandler == nil }

    /// Tests only: called with turn markers ("turn-begin", "sync-committed", "turn-end"), the
    /// input drain's end ("input-drain-end"), intake points ("action-queued", "input-held-frozen"),
    /// the forced shutdown's steps ("force-shutdown-joined", "shutdown-stop-gate",
    /// "shutdown-queued") and labels passed to `recordInTurnProbeForTesting`.

    /// Tests only (the probe's negative control): one `await Task.yield()` inside the tick turn,
    /// after "turn-begin" and before the synchronous core.
    private var inTurnYieldForTesting = false

    /// Installs the side's probe (tests only).
    func setInTurnProbeForTesting(_ probe: (@Sendable (String) -> Void)?) {
        turnSide.probe = probe
    }

    /// Tests only: a job on this keeper's executor that records `label`.
    func recordInTurnProbeForTesting(_ label: String) {
        turnSide.probe?(label)
    }


    /// Tests only: the ticks with sync requests still in the output collector.
    func syncRequestTicksForTesting() -> [Int64] {
        outputCollector.syncRequestsByTick.keys.sorted()
    }

    /// Tests only: the ticks of the events still in the output collector, one entry per event.
    func emittedEventTicksForTesting() -> [Int64] {
        outputCollector.emittedEvents.map(\.tickId).sorted()
    }


    /// Tickless intake callers held by a freeze (tests only).
    var debugHeldInputCount: Int { debugHeldInputs.count }

    /// The empty-room destroy timer, if one is armed (tests only): awaiting its value waits for
    /// the timer and the destruction it starts, or returns at once once it was cancelled.
    func destroyTimerForTesting() -> Task<Void, Never>? {
        destroyTicket?.installedTask
    }

    /// Whether the tick loop has been started (tests only).
    func hasTickLoopForTesting() -> Bool {
        tickTask != nil
    }

    /// Whether the sync loop has been started (tests only).
    func hasSyncLoopForTesting() -> Bool {
        syncTask != nil
    }

    /// Installs `inTurnYieldForTesting` (tests only).
    func setInTurnYieldForTesting(_ enabled: Bool) {
        inTurnYieldForTesting = enabled
    }

    /// Tests only: runs `body` as a job on this keeper's executor.
    func runIsolatedForTesting(_ body: @Sendable () -> Void) {
        body()
    }

    /// Tests only: sets the tick loop's next deadline (the coincident-sync rule's input).
    /// Whether a sync is folded into the next tick turn (tests only).
    var inTurnSyncDueForTesting: Bool { model.inTurnSyncDue }

    func setNextTickDeadlineForTesting(_ deadline: ContinuousClock.Instant?) {
        nextTickDeadline = deadline
    }

    /// Tests only: the cadence diagnostics in one call, without copying the state (a sampler's
    /// probe on the keeper's executor stays small).
    func cadenceCountersForTesting() -> (deferredTurns: Int, foldedSyncs: Int, overdueFoldedSyncs: Int, lateFoldedSyncs: Int, ticksStarted: Int64) {
        (model.inTurnDeferredTurns, model.foldedSyncs, model.overdueFoldedSyncs, model.lateFoldedSyncs, model.nextTickId)
    }

    /// Tests only: one sync loop iteration (`runSync`), as the loop runs it.
    func runSyncLoopIterationForTesting() async {
        await runSync()
    }

    /// Tests only: one sync loop iteration that reads `now` as its clock for the coincident-sync
    /// check, so a test decides fold and overdue without depending on scheduling.
    func runSyncLoopIterationForTesting(at now: ContinuousClock.Instant) async {
        syncClockForTesting = now
        defer { syncClockForTesting = nil }
        await runSync()
    }

    /// Tests only: the clock `runSync` reads for the coincident-sync check, when set.
    private var syncClockForTesting: ContinuousClock.Instant?

    /// Tests only: one `stepTickOnce` whose tick turn reads `now` as its start, for the folded
    /// sync's lateness (#232).
    func stepTickOnceForTesting(at now: ContinuousClock.Instant) async {
        tickClockForTesting = now
        defer { tickClockForTesting = nil }
        await stepTickOnce()
    }

    /// Tests only: the clock a tick turn reads as its start, when set.
    private var tickClockForTesting: ContinuousClock.Instant?

    /// Tests only: the sequences of the queued inputs, in queue order.
    func pendingItemSequencesForTesting() -> [Int64] {
        model.pendingItems.map(\.sequence)
    }

    /// Tests only: the queued inputs, in queue order (#700 K1a: whether each holds its bytes).
    func pendingItemsForTesting() -> [PendingItem] {
        model.pendingItems
    }

    /// Tests only: how many input-turn outcomes are kept for callers (`inputTurnResults`).
    func inputTurnResultCountForTesting() -> Int {
        model.inputTurnResults.count
    }

    /// Whether this keeper runs its sync phases in its turns (tests and diagnostics).
    public func isUsingInTurnSync() -> Bool {
        syncsInTurn
    }

    // MARK: Debug freeze state (see `debugFreeze(generation:timeout:)`)

    /// Tickless inputs waiting for `debugResume()`.
    private var debugHeldInputs: [CheckedContinuation<Void, Never>] = []
    /// `debugFreeze` callers waiting for the drain, by waiter ID (resumed on drain, release or deadline).


    /// Initializes a new LandKeeper with the given definition and initial state.
    ///
    /// - Parameters:
    ///   - definition: The Land definition containing all handlers and configuration.
    ///   - initialState: The initial state of the Land.
    ///   - mode: The execution mode (live or re-evaluation). Defaults to .live.
    ///   - reevaluationSource: Optional re-evaluation source. Required when mode is .reevaluation.
    ///   - payloadDecoders: The decoders a replay reads recorded client payloads with (#700 K1a).
    ///                `.jsonOnly` reads a record whose header says `json`; a record of a MessagePack
    ///                land needs `RecordPayloadDecoders.standard` (SwiftStateTreeMessagePack), and is
    ///                refused at initialization without it. A live keeper ignores it.
    ///   - reevaluationSink: Optional sink for emitted events. Used when mode is .reevaluation.
    ///   - reevaluationOutputMode: When mode is .reevaluation, controls whether emitted events go to sink only (.sinkOnly) or both transport and sink (.transportAndSink). Defaults to .sinkOnly.
    ///   - enableLoopPhaseOffset: Delay the first tick and the first sync by a per-land offset in
    ///     `[0, min(interval, 100 ms))` (`LandLoopPhase`), keeping the period, so lands created together do not
    ///     run their loops in phase. Live mode only. Defaults to on unless
    ///     `LAND_LOOP_PHASE_OFFSET` is false.
    ///   - landID: The land instance ID (e.g. "counter:550e8400-..."), when known at creation.
    ///     Set before the eager initialization can start, so OnInitialize, the default RNG seed
    ///     and the loop phase offset all use the instance ID instead of the land type. Without
    ///     it, they use the land type. There is no setter: the init starts the initialization
    ///     eagerly, so an ID set later would race with it (#593).
    ///   - transport: Optional transport interface for sending events and syncing state.
    ///                If not provided, a live keeper still runs its turns and records their
    ///                outputs, but delivers none. On a live keeper a transport that can't run the
    ///                sync phase in turn for it stops the process, as `setTransport(_:)` does; a
    ///                `TransportAdapter` needs the keeper first, so attach it with
    ///                `setTransport(_:)`.
    ///   - logger: Optional logger instance. If not provided, a default logger will be created.
    public init(
        definition: LandDefinition<State>,
        initialState: State,
        mode: LandMode = .live,
        reevaluationSource: (any ReevaluationSource)? = nil,
        payloadDecoders: RecordPayloadDecoders = .jsonOnly,
        reevaluationSink: (any ReevaluationSink)? = nil,
        reevaluationOutputMode: ReevaluationOutputMode = .sinkOnly,
        services: LandServices = LandServices(),
        enableLiveStateHashRecording: Bool = false,
        autoStartLoops: Bool = true,
        enableLoopPhaseOffset: Bool = LandLoopPhase.isEnabled(),
        landID: String? = nil,
        transport: LandKeeperTransport? = nil,
        logger: Logger? = nil
    ) {
        self.init(
            definition: definition,
            resolverServices: nil,
            initialState: initialState,
            mode: mode,
            reevaluationSource: reevaluationSource,
            payloadDecoders: payloadDecoders,
            reevaluationSink: reevaluationSink,
            reevaluationOutputMode: reevaluationOutputMode,
            services: services,
            enableLiveStateHashRecording: enableLiveStateHashRecording,
            autoStartLoops: autoStartLoops,
            enableLoopPhaseOffset: enableLoopPhaseOffset,
            landID: landID,
            transport: transport,
            logger: logger
        )
    }

    /// A live keeper for a land that declares services (`Land(_:using:services:)`, #769 §3.4):
    /// its resolvers get `resolverServices`. A keeper built from such a land's `.definition` with
    /// `init(definition:…)` has no services value, and fails its initialization with the
    /// registration error.
    public init<Services: Sendable>(
        land: TypedLand<State, Services>,
        resolverServices: Services,
        initialState: State,
        mode: LandMode = .live,
        reevaluationSource: (any ReevaluationSource)? = nil,
        payloadDecoders: RecordPayloadDecoders = .jsonOnly,
        reevaluationSink: (any ReevaluationSink)? = nil,
        reevaluationOutputMode: ReevaluationOutputMode = .sinkOnly,
        services: LandServices = LandServices(),
        enableLiveStateHashRecording: Bool = false,
        autoStartLoops: Bool = true,
        enableLoopPhaseOffset: Bool = LandLoopPhase.isEnabled(),
        landID: String? = nil,
        transport: LandKeeperTransport? = nil,
        logger: Logger? = nil
    ) {
        self.init(
            definition: land.definition,
            resolverServices: resolverServices,
            initialState: initialState,
            mode: mode,
            reevaluationSource: reevaluationSource,
            payloadDecoders: payloadDecoders,
            reevaluationSink: reevaluationSink,
            reevaluationOutputMode: reevaluationOutputMode,
            services: services,
            enableLiveStateHashRecording: enableLiveStateHashRecording,
            autoStartLoops: autoStartLoops,
            enableLoopPhaseOffset: enableLoopPhaseOffset,
            landID: landID,
            transport: transport,
            logger: logger
        )
    }

    /// The designated init: `resolverServices` is the land's services value, or nil when the
    /// entry point brought none.
    package init(
        definition: LandDefinition<State>,
        resolverServices: (any Sendable)?,
        initialState: State,
        mode: LandMode = .live,
        reevaluationSource: (any ReevaluationSource)? = nil,
        payloadDecoders: RecordPayloadDecoders = .jsonOnly,
        reevaluationSink: (any ReevaluationSink)? = nil,
        reevaluationOutputMode: ReevaluationOutputMode = .sinkOnly,
        services: LandServices = LandServices(),
        enableLiveStateHashRecording: Bool = false,
        autoStartLoops: Bool = true,
        enableLoopPhaseOffset: Bool = LandLoopPhase.isEnabled(),
        landID: String? = nil,
        transport: LandKeeperTransport? = nil,
        logger: Logger? = nil
    ) {
        outputCollector.checksOverflow = mode == .reevaluation
        self.replay.reevaluationSink = reevaluationSink

        // The land's generator starts from a caller-registered service's seed (replay registers
        // the recorded one), else from the instance ID when known, else from definition.id. The
        // service itself is removed: only its seed is used, and contexts get the land's
        // generator per handler call.
        let rngSeed = services.get(DeterministicRngService.self)?.seed
            ?? DeterministicSeed.fromLandID(landID ?? definition.id)
        self.model = KeeperModel(state: initialState, landRandom: DeterministicRng(seed: rngSeed))
        var resolvedServices = services.removing(DeterministicRngService.self)

        self.transport = transport
        if transport != nil { model.hasHeldTransport = true }
        self.model.transportRecordsFolds = transport?.recordsInTurnSyncFolds ?? false
        let resolvedLogger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.runtime",
            scope: "LandKeeper"
        )
        self.turnSide = KeeperTurnSide(submissions: recorderSubmissions)

        // Initialize recorder if in live mode AND recording is enabled
        // This prevents unnecessary recorder creation in load tests or when recording is not needed
        var reevaluationRecorder: ReevaluationRecorder?
        if mode == .live && enableLiveStateHashRecording {
            // The record carries the land's schema fingerprint (#521 D15), cached on the
            // definition value: a land whose factory returns the registered value (NIOLandHost's)
            // reads what registration computed, and a factory that builds a definition per land
            // computes it here, once per land, at creation. A keeper whose definition has none
            // records without it, and its record is refused at replay.
            let schemaFingerprint: String?
            do {
                schemaFingerprint = try ReevaluationSchemaFingerprint.cached(for: definition)
            } catch {
                schemaFingerprint = nil
                resolvedLogger.warning(
                    "The land has no record schema fingerprint; its record won't replay",
                    metadata: ["landDefinitionID": .string(definition.id), "error": .string("\(error)")]
                )
            }
            let recorder = ReevaluationRecorder(flushInterval: 60, schemaFingerprint: schemaFingerprint)
            reevaluationRecorder = recorder

            // Register recorder service
            resolvedServices.register(
                ReevaluationRecorderService(recorder: recorder, submissions: recorderSubmissions),
                as: ReevaluationRecorderService.self
            )
        }
        self.behavior = KeeperBehavior(
            definition: definition,
            config: KeeperConfig(
                autoStartLoops: autoStartLoops,
                // Live lands only: re-evaluation replays recorded ticks, its timing is not live load.
                enableLoopPhaseOffset: (mode == .live) ? enableLoopPhaseOffset : false,
                enableLiveStateHashRecording: (mode == .live) ? enableLiveStateHashRecording : false,
                reevaluationOutputMode: reevaluationOutputMode,
                mode: mode,
                actualLandID: landID,
                landRandomSeed: rngSeed
            ),
            services: resolvedServices,
            // A land without services gets `NoServices()`: its resolvers depend on it (#769).
            resolverServices: resolverServices ?? (definition.servicesType == nil ? NoServices() : nil),
            payloadDecoders: payloadDecoders,
            logger: resolvedLogger,
            reevaluationRecorder: reevaluationRecorder,
            reentrySentinel: KeeperReentrySentinel()
        )

        // Initialize source if in re-evaluation mode
        if mode == .reevaluation {
            self.replay.reevaluationSource = reevaluationSource
        }

        // Execute OnInitialize handler and then start tick/sync loops.
        // Initialization is performed lazily (first entry point call) to avoid escaping self in init.

        // Before OnInitialize can run: a refused transport stops the process here (#546 L2d).
        Self.refuseTransportWithoutInTurnPhase(transport, mode: mode, landID: landID ?? definition.id, keeper: self)

        // Kick off initialization eagerly to preserve existing semantics:
        // - OnInitialize runs when Land is created
        // - Tick/sync loops start automatically when configured
        // A failed initialization (#104) tears the land down itself; its callers get the error.
        Task { [weak self] in
            guard let self else { return }
            try? await self.ensureInitialized()
        }
    }

    /// Waits until OnInitialize has run (re-evaluation: before the first tick is stepped).
    /// Waits for the initialization (re-evaluation). A failed one is not reported here: re-
    /// evaluation replays recorded resolver outputs, so its initialization has no deadline.
    package func awaitInitialization() async {
        try? await ensureInitialized()
    }

    /// Runs the initialization once; every caller waits for it. Throws `LandInitializationError`
    /// if it failed (#104), to this caller and every later one.
    private func ensureInitialized() async throws {
        try throwIfInitializationFailed()
        if model.didInitialize { return }
        if let task = initializationTask {
            noteInitializationWait()
            await task.value
            try throwIfInitializationFailed()
            return
        }

        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performInitialization()
        }
        initializationTask = task
        await task.value
        initializationTask = nil
        model.didInitialize = true
        resumeInitializationWaitWatchers { _ in true }
        try throwIfInitializationFailed()
    }

    /// Tests: how many calls have waited on a running initialization, and the tests waiting for
    /// a count (`waitForInitializationWaitersForTesting`).
    private var initializationWaits = 0
    private var initializationWaitWatchers: [(id: UUID, count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    private func noteInitializationWait() {
        initializationWaits += 1
        let waits = initializationWaits
        resumeInitializationWaitWatchers { $0.count <= waits }
    }

    private func resumeInitializationWaitWatchers(where ready: (_ watcher: (id: UUID, count: Int, continuation: CheckedContinuation<Void, Never>)) -> Bool) {
        let resumed = initializationWaitWatchers.filter(ready)
        initializationWaitWatchers.removeAll(where: ready)
        resumed.forEach { $0.continuation.resume() }
    }

    /// Tests: returns once `count` calls have waited on a running initialization, so a test can
    /// end the initialization with its waiters in place (#593). Also returns when the
    /// initialization ends first or the waiting task is cancelled, so a wrong count fails its
    /// test instead of hanging it (#447). True when `count` calls waited.
    /// `registered` runs once the watcher is in place, so a test can cancel a registered one.
    package func waitForInitializationWaitersForTesting(
        _ count: Int,
        registered: (@Sendable () -> Void)? = nil
    ) async -> Bool {
        if initializationWaits >= count { return true }
        if model.didInitialize { return false }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                initializationWaitWatchers.append((id: id, count: count, continuation: continuation))
                registered?()
            }
        } onCancel: {
            Task { await self.cancelInitializationWaitWatcher(id) }
        }
        return initializationWaits >= count
    }

    private func cancelInitializationWaitWatcher(_ id: UUID) {
        resumeInitializationWaitWatchers { $0.id == id }
    }

    /// `ensureInitialized` for a join: a failed initialization is a retryable
    /// `JoinError.landShuttingDown` (JOIN_DENIED, "retry the join"), as for a land closing. The
    /// land is being torn down, so a retry gets a new one.
    private func ensureInitializedForJoin() async throws {
        do {
            try await ensureInitialized()
        } catch {
            throw JoinError.landShuttingDown
        }
    }

    /// Ends one attempt's reservation; idempotent, and it leaves the player's other attempts' ones.
    private func endRejoinReservation(_ m: inout KeeperModel<State>, _ reservation: Epoch, of playerID: PlayerID) {
        guard var epochs = m.rejoinReservations[playerID] else { return }
        epochs.remove(reservation)
        m.rejoinReservations[playerID] = epochs.isEmpty ? nil : epochs
    }

    /// Tears the land down after its initialization failed (#104): the normal drain, without the
    /// destroy handlers (`initializationFailure` is set). Started from `performInitialization`,
    /// in a Task of its own: the drain's `forceShutdown` path would otherwise wait for the
    /// initialization it is part of.
    private func tearDownAfterFailedInitialization() async {
        model.players.removeAll()
        playerServices.removeAll()
        model.rejoinReservations.removeAll()
        dropPendingInputs(&model, &turnSide, reason: "initialization failed")
        await shutdownIfIdle(cause: .initializationFailed)
    }

    /// A record's resolver outputs as the replayed handler reads them: each held as recorded, and
    /// decoded by `LandContext`'s subscript with the record's codec when the handler asks (#707).
    /// The JSON view gets its integer-to-float allowance, as its recorded events do
    /// (`ReevaluationReplayFrame.integralFloats(for:)`).
    private func replayedResolverOutputs(
        _ recorded: [String: ReevaluationRecordedResolverOutput]
    ) -> [String: HeldResolverOutput] {
        let integralFloats = replay.reevaluationSource?.readsJSONRecord ?? false
        return recorded.mapValues {
            .recorded(RecordedResolverOutput(typeIdentifier: $0.typeIdentifier, value: $0.value, integralFloats: integralFloats))
        }
    }

    /// Re-evaluation of a record with an initialize record (format 2.1): OnInitialize runs here,
    /// before tick 0, as in the live run: at the recorded sequence, at tick -1 and with the
    /// recorded resolver outputs. Its events are flushed at tick -1 for the initialize check.
    private func replayInitializeBeforeTickZero() async {
        guard behavior.config.mode == .reevaluation,
              let source = replay.reevaluationSource,
              let handler = definition.lifetimeHandlers.onInitialize,
              let record = try? await source.getInitializeRecord(),
              let recorded = try? await source.getLifecycleEvents(for: 0)
                .first(where: { $0.kind == LifecycleKind.initialize.rawValue })
        else { return }
        let resolverOutputs = replayedResolverOutputs(recorded.resolverOutputs)
        outputCollector.nextSequence = record.sequence
        _ = outputCollector.takeNextSequence()
        let ctx = makeContext(&model,
            playerID: behavior.config.systemPlayerID,
            clientID: behavior.config.systemClientID,
            sessionID: behavior.config.systemSessionID,
            tickId: model.lastCommittedTickId,
            resolverOutputs: resolverOutputs
        )
        do {
            // `invoke` throws only from `validate`, before `apply` writes (#593).
            try withHandlerStep(&model, ctx) { m, ctx in
                try handler.invoke(&m.state, ctx)
            }
        } catch {
            noteReplayedInitializeRefusal(error)
        }
        replay.replayedInitializeBeforeTickZero = true
        await flushOutputs(forTick: model.lastCommittedTickId)
    }

    /// A replayed OnInitialize's `validate` threw (#593): logged, and kept for the initialize
    /// check (`replayedInitializeRefusal`). Nothing was written, and `validate` emits nothing.
    private func noteReplayedInitializeRefusal(_ error: any Error) {
        behavior.logger.error("❌ OnInitialize's validate threw during re-evaluation: nothing is written", metadata: [
            "error": .string(String(describing: error)),
        ])
        if replay.replayedInitializeRefusal == nil {
            replay.replayedInitializeRefusal = "OnInitialize's validate threw in replay: \(error)"
        }
    }

    /// Whether a throwing OnInitialize resolver group fails the initialization (#238): with
    /// `.failLand`, unless it is a cancellation while the land is shutting down. A cancellation
    /// a resolver raises for its own reasons (a cancelled HTTP request) follows the policy.
    ///
    /// The exemption is defensive: today no shutdown reaches a running initialization.
    /// `forceShutdown` waits for it, the empty-room timer is scheduled only after a leave or a
    /// join that didn't complete (both wait for it), and nothing cancels the initialization's task.
    static func initializeResolverFailureFailsLand(
        _ error: any Error,
        policy: InitializeResolverFailure,
        shuttingDown: Bool
    ) -> Bool {
        guard policy == .failLand else { return false }
        return !(shuttingDown && ResolverExecutionError.isCancellation(error))
    }

    private func performInitialization() async {
        // The backstop for a keeper no registration checked (#535 §4): a state type that fails
        // the synced-state rows, a definition with two handlers for one client-event or
        // server-input type, or a node it declares once declared twice (#586, #796), one whose
        // client event registrations and handlers disagree
        // (#771), or one holding a node its builder doesn't recognize (#794), fails initialization, as an OnInitialize resolver timeout does, before
        // any handler runs. One cached lookup per state type.
        let problems = SyncRegistration.cachedProblems(State.self)
        // #769 §3.4: a live keeper for a land that declares services needs its services value; a
        // replay never calls `resolve`.
        let missingServices = behavior.config.mode == .live && behavior.resolverServices == nil
            ? definition.servicesType.map { String(reflecting: $0) } : nil
        // A value of another type would fail every resolving input with `servicesMismatch`. A land
        // that declares no services takes `NoServices`, which an erased factory can replace too.
        var wrongServices: String?
        if behavior.config.mode == .live, let value = behavior.resolverServices {
            let declared: Any.Type = definition.servicesType ?? NoServices.self
            let accepts = definition.acceptsServices ?? { $0 is NoServices }
            if !accepts(value) {
                wrongServices = "declared \(String(reflecting: declared)), given \(String(reflecting: type(of: value)))"
            }
        }
        if !problems.isEmpty || !definition.duplicateHandlers.isEmpty || !definition.clientEventMismatches.isEmpty
            || !definition.unrecognizedNodes.isEmpty || !definition.resolverDeclarationProblems.isEmpty
            || missingServices != nil || wrongServices != nil {
            let error = LandRegistrationError(
                landType: definition.id,
                payload: nil,
                sync: problems.isEmpty ? nil : SyncRegistrationError(problems: problems),
                duplicateHandlers: definition.duplicateHandlers,
                clientEventMismatches: definition.clientEventMismatches,
                unrecognizedNodes: definition.unrecognizedNodes,
                missingServices: missingServices,
                wrongServices: wrongServices,
                resolverDeclarations: definition.resolverDeclarationProblems
            )
            behavior.logger.error("❌ The land fails the registration check: the land is torn down", metadata: [
                "error": .string(error.description),
            ])
            failInitialization(with: error)
            Task { await self.tearDownAfterFailedInitialization() }
            return
        }
        if behavior.config.mode == .reevaluation {
            // A record whose payloads this replay has no decoder for is refused before anything
            // is replayed (#700 K1a): `ReevaluationRecordPayloadError.noDecoder`.
            // A source whose metadata can't be read is refused too (fails closed).
            if let source = replay.reevaluationSource {
                do {
                    replay.replayHeaderPayloadEncoding = try await source.getMetadata().effectivePayloadEncoding
                    try await behavior.payloadDecoders.check(source)
                } catch {
                    behavior.logger.error("❌ The record can't be read, or this replay can't decode its payloads: the land is torn down", metadata: [
                        "error": .string(String(describing: error)),
                    ])
                    failInitialization(with: error)
                    Task { await self.tearDownAfterFailedInitialization() }
                    return
                }
            }
            await replayInitializeBeforeTickZero()
        }
        // Execute OnInitialize immediately in live mode (preserve existing semantics).
        // Record it as a lifecycle event under tick 0 so replay can apply it deterministically
        // before the first tick handler runs.
        if behavior.config.mode == .live, let handler = definition.lifetimeHandlers.onInitialize {
            let sequence = outputCollector.takeNextSequence()

            var ctx = makeContext(&model,
                playerID: behavior.config.systemPlayerID,
                clientID: behavior.config.systemClientID,
                sessionID: behavior.config.systemSessionID,
                tickId: model.lastCommittedTickId
            )

            // Execute resolvers in parallel if any are declared: the values are built from the
            // initial State, here, before the group runs (#769). A closure that built none has
            // no group to run.
            if let declaration = definition.lifetimeHandlers.onInitializeResolvers,
               case let executors = declaration.build(model.state, ValidateContext(ctx)), !executors.isEmpty {
                let resolverContext = makeResolverContext(ctx)
                do {
                    ctx = try await ResolverExecutor.executeInitializeResolvers(
                        executors: executors,
                        resolverContext: resolverContext,
                        landContext: ctx,
                        abandonment: resolverAbandonment(.onInitialize)
                    )
                } catch {
                    if case ResolverExecutionError.timedOut = error {
                        // Timed out (#104): the initialization fails. OnInitialize doesn't run,
                        // and the land is torn down; its waiters get the error from
                        // `ensureInitialized`.
                        behavior.logger.error("❌ OnInitialize resolvers timed out: the land is torn down", metadata: [
                            "error": .string(String(describing: error)),
                        ])
                        failInitialization(with: error)
                        Task { await self.tearDownAfterFailedInitialization() }
                        return
                    }
                    if Self.initializeResolverFailureFailsLand(
                        error,
                        policy: definition.lifetimeHandlers.onInitializeResolverFailure,
                        shuttingDown: isDraining || Task.isCancelled
                    ) {
                        // A resolver threw, with `.failLand` (#238): the same as a timeout.
                        ResolverDeadline.metrics.noteInitFailed()
                        behavior.logger.error("❌ OnInitialize resolvers failed: the land is torn down", metadata: [
                            "error": .string(String(describing: error)),
                        ])
                        failInitialization(with: error)
                        Task { await self.tearDownAfterFailedInitialization() }
                        return
                    }
                    // `.continue`, or cancelled by the land's shutdown: OnInitialize runs without
                    // the group's outputs.
                    behavior.logger.error("❌ OnInitialize resolvers failed", metadata: [
                        "error": .string(String(describing: error)),
                    ])
                }
            }

            // OnInitialize's step through its output step is one turn body (#700 K1b-5a step 2).
            let initialized = withTurn { m, side, outputs in
                initializeTurnBody(&m, &side, &outputs, handler: handler, ctx: ctx, sequence: sequence)
            }
            let initializeRecord: ReevaluationRecordedInitialize?
            let initializeMarker: ReevaluationRecordedSyncMarker?
            switch initialized {
            case let .failure(error):
                // A refusal fails the initialization, as a resolver failure with `.failLand`
                // does: nothing was written, `validate` emitted nothing, and nothing is recorded.
                behavior.logger.error("❌ OnInitialize's validate refused: the land is torn down", metadata: [
                    "error": .string(String(describing: error)),
                ])
                failInitialization(with: error)
                Task { await self.tearDownAfterFailedInitialization() }
                return
            case let .success(output):
                initializeRecord = output.record
                initializeMarker = output.marker
            }

            if let recorder = reevaluationRecorder {
                let resolverOutputsDict = ctx.getAllResolverOutputs().recordedEntries
                let recorded = ReevaluationRecordedLifecycleEvent(
                    kind: LifecycleKind.initialize.rawValue,
                    sequence: sequence,
                    tickId: 0,
                    playerID: nil,
                    clientID: nil,
                    sessionID: nil,
                    deviceID: nil,
                    isGuest: nil,
                    metadata: [:],
                    resolverOutputs: resolverOutputsDict,
                    resolvedAtTick: model.lastCommittedTickId
                )
                if routesThroughTurn {
                    // OnInitialize's server events belong to tick -1, which no frame's
                    // `serverEvents` records; the initialize record keeps them for verification.
                    await submitTurnRecord(ReevaluationTickRecord(
                        tickId: 0,
                        lifecycleEvents: [recorded],
                        syncMarkers: initializeMarker.map { [$0] } ?? [],
                        initialize: initializeRecord
                    ))
                } else {
                    await recorder.record(
                        tickId: 0,
                        actions: [],
                        clientEvents: [],
                        lifecycleEvents: [recorded]
                    )
                    // A tickless land's OnInitialize is one turn record (#327).
                    await recorder.recordTick(ReevaluationTickRecord(tickId: 0, initialize: initializeRecord), endsTurn: isTickless)
                }
            }
        }

        // Then, start tick and sync loops if configured (only after OnInitialize completes). Not on
        // a land that is ending: a refusal in initialization's turn failed it, or a drain began
        // during the record's await, and the drain has stopped (or will not see) the loops.
        guard behavior.config.autoStartLoops, !isDraining else { return }
        let tickInterval = definition.lifetimeHandlers.tickInterval
        let syncInterval = definition.lifetimeHandlers.syncInterval

        // Start tick loop if configured
        if let interval = tickInterval,
           definition.lifetimeHandlers.tickHandler != nil
        {
            await configureTickLoop(interval: interval)
        }

        // Start sync loop: use configured interval, or fallback to tick interval if not configured
        let effectiveSyncInterval: Duration?
        if let sync = syncInterval {
            effectiveSyncInterval = sync
        } else if let tick = tickInterval {
            // Auto-configure sync to match tick interval if sync is not explicitly set
            effectiveSyncInterval = tick
            behavior.logger.warning(
                "⚠️ Sync interval not configured for land '\(definition.id)'. Auto-configuring sync to match tick interval (\(tick)). Consider explicitly setting StateSync(every:) in Lifetime block for better control.",
                metadata: [
                    "landID": .string(definition.id),
                    "tickInterval": .string("\(tick)"),
                    "autoSyncInterval": .string("\(tick)"),
                ]
            )
        } else {
            effectiveSyncInterval = nil
        }

        if let interval = effectiveSyncInterval {
            await configureSyncLoop(interval: interval)
        }
    }

    /// Returns the current state snapshot.
    ///
    /// This is a read-only view of the state. Mutations should be done through action/event handlers.
    public func currentState() -> State {
        model.state
    }

    /// `currentState()`, with where it was read and whether the sync stream is recorded, from
    /// the same job.
    package func currentStateLocated() -> (state: State, position: SyncReadPosition, recordsSyncStream: Bool) {
        (model.state, syncReadPosition(model), recordsSyncStream)
    }

    /// Whether this keeper syncs the land periodically on its own: its loops auto-start and either
    /// the tick loop is configured (`tickInterval` and `tickHandler`) or a sync loop runs (an explicit
    /// `syncInterval`, or the tick interval as fallback). Mirrors the loop setup in
    /// `performInitialization`. When `false`, the land syncs only when someone requests it.
    public nonisolated var hasPeriodicSync: Bool {
        guard behavior.config.autoStartLoops else { return false }
        let handlers = definition.lifetimeHandlers
        let tickLoop = handlers.tickInterval != nil && handlers.tickHandler != nil
        let syncLoop = handlers.syncInterval != nil || handlers.tickInterval != nil
        return tickLoop || syncLoop
    }

    /// The player's entry as the keeper's joins left it: its client and its last session, or
    /// nil when the player has no entry. The realtime adapter's `registerSession` reads it to
    /// refuse a registration whose session the entry doesn't name (#531), by the rule of
    /// `rejectSenderIfSuperseded`.
    package func entrySession(for playerID: PlayerID) -> (clientID: ClientID?, sessionID: SessionID?)? {
        model.players[playerID].map { (clientID: $0.clientID, sessionID: $0.lastSessionID) }
    }

    /// Returns the current number of players in the land.
    ///
    /// This counts unique players (not connections), as a player can have multiple connections.
    public func playerCount() -> Int {
        model.players.count
    }

    /// Get the ReevaluationRecorder instance (for testing/debugging).
    /// Returns nil if not in live mode or recorder is not available.
    public func getReevaluationRecorder() -> ReevaluationRecorder? {
        reevaluationRecorder
    }

    /// Get the current LandMode (for testing/debugging).
    public func getMode() -> LandMode {
        behavior.config.mode
    }

    deinit {
        tickTask?.cancel()
        syncTask?.cancel()
        destroyTicket?.cancel()
    }

    // MARK: - Debug Freeze

    /// Pause the land for a debug state check and wait until in-flight work has finished.
    ///
    /// While frozen:
    /// - no tick body and no sync-loop body starts;
    /// - in tickless lands, `handleActionEnvelope` and `handleClientEvent` wait until the freeze
    ///   is released (in tick lands they only queue, and ticks do not run);
    /// - joins and leaves still run (callers detect them separately);
    /// - server inputs are accepted with their sequence and held until the resume. In a
    ///   tickless land a join or leave during the freeze is applied before a held server input
    ///   with a lower sequence; the record keeps the applied order, and replay follows it.
    ///
    /// The freeze belongs to `generation` (the caller's, increasing per freeze). A generation that
    /// was already released does not freeze again, so a late call cannot re-pause the land.
    ///
    /// - Returns: `true` once tick bodies and tickless input processing that were already running
    ///   (including their resolvers) have finished; `false` when `timeout` passes first or the
    ///   generation is released meanwhile. The land stays frozen until
    ///   `debugResume(generation:)` either way. Debug tooling only; the transport layer owns
    ///   reference counting.
    public func debugFreeze(generation: UInt64, timeout: Duration) async -> Bool {
        guard generation > model.debugReleasedGeneration else { return false }
        model.debugFrozen = true
        model.debugActiveGeneration = generation
        // A pending fold's tick turn doesn't run while frozen; reported after the resume, the
        // freeze would count as tick lateness (#232). The next sync iteration folds again.
        pendingFold = nil

        let deadline = ContinuousClock.now + timeout
        while model.debugInFlightWork > 0, model.debugActiveGeneration == generation {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return false }
            model.debugNextWaiterID &+= 1
            let waiterID = model.debugNextWaiterID
            let timer = Task { [weak self] in
                try? await safeTaskSleep(for: remaining)
                await self?.debugWakeDrainWaiter(waiterID)
            }
            await withCheckedContinuation { continuation in
                turnSide.debugDrainWaiters[waiterID] = continuation
                let watchers = freezeWaitWatchersForTesting
                freezeWaitWatchersForTesting.removeAll()
                watchers.forEach { $0.resume() }
            }
            timer.cancel()
        }
        return model.debugActiveGeneration == generation && model.debugInFlightWork == 0
    }

    /// Release the freeze of `generation`: held tickless inputs continue and ticks start again.
    /// A stale generation (not the one in effect) only marks that generation released.
    public func debugResume(generation: UInt64) {
        model.debugReleasedGeneration = max(model.debugReleasedGeneration, generation)
        guard model.debugActiveGeneration == generation else { return }
        model.debugActiveGeneration = nil
        model.debugFrozen = false
        releaseServerInputsHeldWhileFrozen()
        let held = debugHeldInputs
        debugHeldInputs.removeAll()
        held.forEach { $0.resume() }
        // Waiters of this generation re-check and return false.
        let waiters = turnSide.debugDrainWaiters
        turnSide.debugDrainWaiters.removeAll()
        waiters.values.forEach { $0.resume() }
    }

    /// Whether a debug freeze is in effect.
    public func isDebugFrozen() -> Bool {
        model.debugFrozen
    }

    /// The most recent committed tick ID (-1 before the first tick).
    public func debugLastCommittedTickId() -> Int64 {
        model.lastCommittedTickId
    }

    /// The fence of a settle turn: the freeze generation it settles and its deadline.
    package struct SettleFence: Sendable {
        package let generation: UInt64
        package let deadline: ContinuousClock.Instant

        package init(generation: UInt64, deadline: ContinuousClock.Instant) {
            self.generation = generation
            self.deadline = deadline
        }
    }

    /// What `settleTurn(via:fence:)` did.
    package enum SettleTurnOutcome: Sendable {
        /// The settle phase ran on `state`, the copy taken in the turn, with the last committed
        /// tick and the transport's membership epoch read in the same segment. `planned`: false
        /// for a land with no members (nothing was planned and the dirty flags stay).
        case settled(state: State, tickId: Int64, membershipEpoch: UInt64, planned: Bool)
        /// The settle's deadline passed.
        case timedOut
        /// `generation` is no longer the active freeze, or the land isn't frozen.
        case released
        /// The land isn't live, failed (its failure) or is draining (nil).
        case closed(LandFailure?)
        /// The transport refused the settle; nothing was planned.
        case refused(InTurnSettleRefusal)
        /// The settle's plan threw; the land ended in this turn on this failure.
        case failed(LandFailure)
    }

    /// The debug freeze settle as a sync-only turn (#546 L2d-1): the fence, then the settle
    /// phase through `port`, in one synchronous segment.
    ///
    /// The fence, in order; a failing check returns without a phase or a state change: the land
    /// is live and neither failed nor drains (`.closed`), the deadline (`.timedOut`), the
    /// frozen generation (`.released`), `port` runs in-turn here, is this keeper's sync port (the
    /// attached transport or, never attached, its bound requester, as `acceptsSyncTurn`) and is a
    /// settle port (`.refused(.notCurrent)`).
    ///
    /// The settle's own bookkeeping, not a requested turn's: it doesn't consume the pending
    /// sync-only turn (which runs later, skips as frozen and leaves its sync to the resume),
    /// doesn't reset the sync cadence or the join state, and arms no follow-up (the resume and
    /// the adapter's kept-events check own those). A plan that throws ends the land in this turn,
    /// as does a callback into the keeper during the settle's port calls (`.failed`); a settle
    /// requested from such a callback is refused (#700 K1b-5a).
    package func settleTurn(via port: any LandKeeperTransport, fence: SettleFence) -> SettleTurnOutcome {
        // A settle requested while a turn body runs (a callback during a port call) would nest a
        // second body: refused, changing nothing here, and the land ends (`noteReentry`).
        guard sentinel.bodyDepth == 0 else {
            noteReentry(through: "settleTurn")
            return .closed(failure)
        }
        return withTurn { m, side, outputs in
            settleBody(&m, &side, &outputs, port: port, fence: fence)
        }
    }

    /// `settleTurn`'s body, on the model the turn holds. Its two port calls (the in-turn check
    /// and the settle phase) go through `callOut`: a re-entry in either ends the land in that
    /// call, and its answer is never read.
    private func settleBody(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        port: any LandKeeperTransport,
        fence: SettleFence
    ) -> SettleTurnOutcome {
        m.requestedSyncTurnsForTesting[.settle, default: 0] += 1
        guard behavior.config.mode == .live, failure == nil, !isDraining else { return .closed(failure) }
        // A failure a transport noted outside a turn ends the land first (#704): no phase runs,
        // and a tickless land's turn still ends its record, as after a failed phase.
        let markBeforeNote = m.recorderSubmissionCount
        if applyPendingTransportFailure(&m, &side), let failure {
            enqueueTicklessTurnEnd(&m, since: markBeforeNote)
            return .failed(failure)
        }
        guard ContinuousClock.now < fence.deadline else { return .timedOut }
        guard m.debugFrozen, m.debugActiveGeneration == fence.generation else { return .released }
        // The requested turns' rule (`acceptsSyncTurn`): the attached transport or, on a keeper
        // never attached, its sync requester (#546 L2d). Checked without binding; a settle binds
        // the requester only once every check has passed, so a refused one changes nothing.
        let markBeforePort = m.recorderSubmissionCount
        let runsInTurn: Bool
        switch callOut(&m, &side, &outputs, { _ in port.runsSyncPhaseInTurn(of: self) }) {
        case .refused(let refused):
            enqueueTicklessTurnEnd(&m, since: markBeforePort)
            return .failed(failure ?? refused)
        case .answered(let answer):
            runsInTurn = answer
        }
        guard runsInTurn, let settlePort = port as? any LandKeeperSettlePort, isSyncPort(m, port) else {
            return .refused(.notCurrent)
        }
        _ = bindSyncRequester(&m, port)
        side.probe?("turn-begin")
        m.inTurnSyncTurnKind = .syncOnly
        defer { m.inTurnSyncTurnKind = .tick }
        let mark = m.recorderSubmissionCount
        let copy = m.state
        let tickId = m.lastCommittedTickId
        // The recording reads the port's witness (`recordsSyncStream`): through `callOut`, as the
        // sync-only body's, so a re-entry there ends the land before the phase runs.
        let recording: InTurnSyncRecording?
        switch callOut(&m, &side, &outputs, { m in inTurnSyncRecording(m) }) {
        case .refused(let refused):
            enqueueTicklessTurnEnd(&m, since: mark)
            side.probe?("turn-end")
            return .failed(failure ?? refused)
        case .answered(let answer):
            recording = answer
        }
        let outcome: SettleTurnOutcome
        switch callOut(&m, &side, &outputs, { _ in
            settlePort.runSettlePhaseInTurn(state: copy, settle: InTurnSettle(generation: fence.generation), recording: recording)
        }) {
        case .refused(let refused):
            outcome = .failed(failure ?? refused)
        case .answered(let output):
            // The transport's draft factories run here, outside any call out: a factory that
            // re-entered ends the land before the settle's result is applied. The batch is
            // recorded whole first, as the sync-only turn's is.
            let beforeRecording = sentinel.reentryViolations
            recordSyncStream(&m, output.syncStream)
            if sentinel.reentryViolations != beforeRecording {
                let refused = applyReentryFailure(&m, &side)
                outcome = .failed(failure ?? refused)
            } else {
                switch output.settle ?? .refused(.notCurrent) {
                case let .committed(membershipEpoch, clearDirtyFlags):
                    if clearDirtyFlags { m.state.clearDirty() }
                    outcome = .settled(state: copy, tickId: tickId, membershipEpoch: membershipEpoch, planned: true)
                case let .empty(membershipEpoch):
                    outcome = .settled(state: copy, tickId: tickId, membershipEpoch: membershipEpoch, planned: false)
                case let .refused(refusal):
                    outcome = .refused(refusal)
                case let .failed(reported):
                    failLand(&m, &side, reported)
                    outcome = .failed(failure ?? reported)
                }
            }
        }
        // A tickless land's sync-only turn is its own turn record (#327); a tick land's settle
        // output stays with the last committed tick's.
        enqueueTicklessTurnEnd(&m, since: mark)
        side.probe?("turn-end")
        return outcome
    }

    /// Holds tickless intake while frozen. Returns when the freeze is released or the drain
    /// starts (`releaseHeldInputsForDrain`); the intake then re-checks `rejectIfLandClosed`.
    private func debugWaitWhileFrozen() async {
        while model.debugFrozen, !isDraining {
            await withCheckedContinuation { continuation in
                debugHeldInputs.append(continuation)
                turnSide.probe?("input-held-frozen")
            }
        }
    }

    /// `debugBeginWork(_:)` for a caller outside a turn body.
    private func debugBeginWork() {
        debugBeginWork(&model)
    }

    private func debugBeginWork(_ m: inout KeeperModel<State>) {
        m.debugInFlightWork += 1
    }

    /// `debugEndWork(_:)` for a caller outside a turn body.
    private func debugEndWork() {
        debugEndWork(&model, &turnSide)
    }

    private func debugEndWork(_ m: inout KeeperModel<State>, _ side: inout KeeperTurnSide) {
        m.debugInFlightWork -= 1
        guard m.debugInFlightWork == 0, !side.debugDrainWaiters.isEmpty else { return }
        let waiters = side.debugDrainWaiters
        side.debugDrainWaiters.removeAll()
        waiters.values.forEach { $0.resume() }
    }

    private func debugWakeDrainWaiter(_ waiterID: UInt64) {
        turnSide.debugDrainWaiters.removeValue(forKey: waiterID)?.resume()
    }

    // MARK: - Player Lifecycle

    /// Handles a player joining the Land (legacy method for backward compatibility).
    ///
    /// This method creates a PlayerSession internally and calls the new join method.
    /// For new code, consider using the overload that accepts PlayerSession.
    ///
    /// - Parameters:
    ///   - playerID: The player's unique identifier.
    ///   - clientID: The client instance identifier.
    ///   - sessionID: The session/connection identifier.
    ///   - services: Services to inject into the LandContext.
    public func join(
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        services: LandServices = LandServices()
    ) async throws {
        try await ensureInitializedForJoin()
        await holds.at(.join)
        let call = LegacyJoinCall(playerID: playerID, clientID: clientID, sessionID: sessionID, services: services)
        var request = try withTurn { m, side, outputs in try legacyJoinBegin(&m, &side, &outputs, call) }
        while true {
            switch request {
            case let .kick(oldClientID, oldSessionID):
                // Kick old connection by calling leave
                // This will call OnLeave handler and clean up state
                try await leave(playerID: playerID, clientID: oldClientID, sessionID: oldSessionID)
                request = try withTurn { m, side, outputs in try legacyJoinInsert(&m, &side, &outputs, call) }
            case let .runOnJoinResolvers(capture, resolverContext, landContext):
                let resolverOutputs = try await runOnJoinResolvers(capture, resolverContext, landContext)
                request = try withTurn { m, side, outputs in
                    // Bind to the tick that was current when resolvers completed
                    try legacyJoinAppend(&m, &side, &outputs, capture, resolverOutputs: resolverOutputs, resolvedAtTick: m.lastCommittedTickId)
                }
            case let .awaitInputTurn(sequence):
                // Registered in the same segment as the append's: no suspension since it.
                _ = try await awaitInputTurn(sequence: sequence)
                return
            case .done:
                return
            }
        }
    }

    /// The legacy join's requests (#700 K1b-5b §4.2): no CanJoin, no cap, no admission.
    private enum LegacyJoinRequest {
        /// The old session's leave (§4.3's flow); G2 follows it.
        case kick(oldClientID: ClientID, oldSessionID: SessionID?)
        case runOnJoinResolvers(OnJoinCapture, ResolverContext, LandContext)
        case awaitInputTurn(sequence: Int64)
        case done
    }

    /// The legacy join's call.
    private struct LegacyJoinCall {
        let playerID: PlayerID
        let clientID: ClientID
        let sessionID: SessionID
        let services: LandServices
    }

    /// G1: the kick target, after the hold. Without one it goes on to G2 in this segment.
    private func legacyJoinBegin(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ call: LegacyJoinCall
    ) throws -> LegacyJoinRequest {
        // Check for duplicate playerID login (Kick Old strategy)
        if let existingSession = m.players[call.playerID], let oldClientID = existingSession.clientID {
            behavior.logger.info("Duplicate playerID login detected: \(call.playerID.rawValue), kicking old client: \(oldClientID.rawValue)")
            return .kick(oldClientID: oldClientID, oldSessionID: existingSession.lastSessionID)
        }
        return try legacyJoinInsert(&m, &side, &outputs, call)
    }

    /// G2: the insert, after the kick if there was one, and the OnJoin request.
    private func legacyJoinInsert(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ call: LegacyJoinCall
    ) throws -> LegacyJoinRequest {
        let playerID = call.playerID
        var session = m.players[playerID] ?? KeeperPlayerEntry()
        let isFirst = session.clientID == nil

        session.clientID = call.clientID
        session.lastSessionID = call.sessionID
        // Checked in the same synchronous segment as the insert: a destruction that started
        // during this join's awaits must not get a player after it stopped the loops.
        guard !isDraining else { throw JoinError.landShuttingDown }
        let entryGeneration = m.entryGenerations.next()
        session.generation = entryGeneration
        m.players[playerID] = session
        playerServices[playerID] = (generation: entryGeneration, services: call.services)

        cancelDestroy(&m, &side)

        // In reevaluation mode, replay viewers are observers: add to players for sync but skip OnJoin
        // so they are not added to game state (which would create an extra player in the replay).
        guard isFirst, definition.lifetimeHandlers.onJoin != nil, behavior.config.mode != .reevaluation else { return .done }

        let capture = OnJoinCapture(
            playerID: playerID,
            clientID: call.clientID,
            sessionID: call.sessionID,
            services: call.services,
            deviceID: session.deviceID,
            isGuest: session.isGuest,
            metadata: session.metadata,
            contextCarriesIdentity: false,
            entryGeneration: entryGeneration,
            // Allocate sequence number (shared across Action + ClientEvent + ServerEvent + Lifecycle)
            sequence: outputCollector.takeNextSequence(),
            // Snapshot tick at request time; update after resolver completion for async determinism.
            resolvedAtTick: m.lastCommittedTickId
        )
        // Execute resolvers in parallel if any are declared
        if let (resolverContext, landContext) = onJoinResolverRequest(&m, &side, &outputs, capture) {
            return .runOnJoinResolvers(capture, resolverContext, landContext)
        }
        return try legacyJoinAppend(&m, &side, &outputs, capture, resolverOutputs: [:], resolvedAtTick: capture.resolvedAtTick)
    }

    /// G4: the OnJoin append. A tickless land waits for its input turn.
    private func legacyJoinAppend(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ capture: OnJoinCapture,
        resolverOutputs: [String: HeldResolverOutput],
        resolvedAtTick: Int64
    ) throws -> LegacyJoinRequest {
        try appendOnJoin(&m, &side, &outputs, capture, resolverOutputs: resolverOutputs, resolvedAtTick: resolvedAtTick)
        // A tickless land applies it now, in an input turn the caller waits for.
        if definition.lifetimeHandlers.tickHandler == nil {
            return .awaitInputTurn(sequence: capture.sequence)
        }
        return .done
    }

    /// What a join carries from its insert to its OnJoin append (G2 → G4, J3 → J4).
    private struct OnJoinCapture {
        let playerID: PlayerID
        let clientID: ClientID
        let sessionID: SessionID
        let services: LandServices
        /// The identity the OnJoin input gets.
        let deviceID: String?
        let isGuest: Bool
        let metadata: [String: String]
        /// Whether the resolvers' context gets the identity too (the reporting join's does).
        let contextCarriesIdentity: Bool
        let entryGeneration: Epoch
        let sequence: Int64
        let resolvedAtTick: Int64
    }

    /// The OnJoin resolvers' request, nil when the land declares none.
    private func onJoinResolverRequest(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ capture: OnJoinCapture
    ) -> (ResolverContext, LandContext)? {
        guard !definition.lifetimeHandlers.onJoinResolverExecutors.isEmpty else { return nil }
        let ctx = capture.contextCarriesIdentity
            ? makeContext(&m,
                playerID: capture.playerID,
                clientID: capture.clientID,
                sessionID: capture.sessionID,
                servicesOverride: capture.services,
                deviceID: capture.deviceID,
                isGuest: capture.isGuest,
                metadata: capture.metadata
            )
            : makeContext(&m,
                playerID: capture.playerID,
                clientID: capture.clientID,
                sessionID: capture.sessionID,
                servicesOverride: capture.services
            )
        let resolverContext = ResolverContext(
            landContext: ctx,
            actionPayload: nil,
            eventPayload: nil,
            currentState: m.state
        )
        return (resolverContext, ctx)
    }

    /// The OnJoin resolvers' await. If they throw or time out (#104), the join fails: in the
    /// segment where the throw resumes, the entry goes if it is still this join's, so `players`
    /// keeps no player that never joined, and an empty land gets back the destroy timer the
    /// insert cancelled.
    private func runOnJoinResolvers(
        _ capture: OnJoinCapture,
        _ resolverContext: ResolverContext,
        _ landContext: LandContext
    ) async throws -> [String: HeldResolverOutput] {
        do {
            return try await ResolverExecutor.executeResolvers(
                executors: definition.lifetimeHandlers.onJoinResolverExecutors,
                resolverContext: resolverContext,
                landContext: landContext,
                abandonment: resolverAbandonment(.onJoin)
            ).getAllResolverOutputs()
        } catch {
            withTurn { m, side, outputs in onJoinResolversFailed(&m, &side, &outputs, capture) }
            throw error
        }
    }

    /// The OnJoin resolvers failed: the rollback of the entry, if it is still this join's.
    private func onJoinResolversFailed(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ capture: OnJoinCapture
    ) {
        if m.players[capture.playerID]?.generation == capture.entryGeneration {
            m.players.removeValue(forKey: capture.playerID)
            removePlayerServices(of: capture.playerID, generation: capture.entryGeneration)
            scheduleDestroyIfNeeded(&m, &outputs)
        }
    }

    /// The OnJoin input's append (G4, J4), with the drain check in the same segment.
    private func appendOnJoin(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ capture: OnJoinCapture,
        resolverOutputs: [String: HeldResolverOutput],
        resolvedAtTick: Int64
    ) throws {
        // Same synchronous segment as the append: a drain that started during the resolvers
        // must not get an OnJoin input after it took the pending inputs. The entry this join
        // inserted goes too (if it is still this join's), so `players` doesn't keep a player
        // that never joined.
        guard !isDraining else {
            if m.players[capture.playerID]?.generation == capture.entryGeneration {
                m.players.removeValue(forKey: capture.playerID)
                removePlayerServices(of: capture.playerID, generation: capture.entryGeneration)
            }
            throw JoinError.landShuttingDown
        }

        let pendingItem = PendingItem.lifecycle(
            PendingLifecycleItem(
                sequence: capture.sequence,
                kind: .join,
                playerID: capture.playerID,
                clientID: capture.clientID,
                sessionID: capture.sessionID,
                deviceID: capture.deviceID,
                isGuest: capture.isGuest,
                metadata: capture.metadata,
                heldResolverOutputs: resolverOutputs,
                resolvedAtTick: resolvedAtTick
            )
        )
        m.pendingItems.append(pendingItem)
    }

    /// Handles a player joining the Land with session-based validation.
    ///
    /// This method supports the CanJoin handler for pre-validation before adding
    /// the player to the authoritative state.
    ///
    /// - Parameters:
    ///   - session: The player session information.
    ///   - clientID: The client instance identifier.
    ///   - sessionID: The session/connection identifier.
    ///   - services: Services to inject into the LandContext.
    /// - Returns: JoinDecision indicating if the join was allowed or denied.
    /// - Throws: Errors from the CanJoin handler if join validation fails.
    public func join(
        session: PlayerSession,
        clientID: ClientID,
        sessionID: SessionID,
        services: LandServices
    ) async throws -> JoinDecision {
        try await joinReportingAdmission(
            session: session,
            clientID: clientID,
            sessionID: sessionID,
            services: services,
            admitThroughTransport: false
        ).decision
    }

    /// What `joinReportingAdmission` did.
    package struct JoinOutcome: Sendable {
        package let decision: JoinDecision
        /// The transport admitted the session inside the join
        /// (`LandKeeperTransport.admitJoiningSession` returned `true`). When `false`, the caller
        /// admits it after the join returns, so a session is admitted exactly once.
        package let admitted: Bool
        /// The transport refused the join for the player CanJoin resolved, before anything
        /// acted on it (`LandKeeperTransport.refusesResolvedJoin`, #234): nothing changed.
        /// Never set by `decision`, the land's own answer.
        package var refusedStale = false
    }

    /// `join(session:clientID:sessionID:services:)`, and, when `admitThroughTransport` and this
    /// keeper's turns run the sync phase in the turn (`syncsInTurn`), the transport's
    /// `admitJoiningSession` in the same synchronous segment as the player's insert (or as its
    /// OnJoin input's append, for a first join with OnJoin). Off that path, or for a non-live
    /// keeper, nothing is admitted here (`admitted == false`).
    package func joinReportingAdmission(
        session: PlayerSession,
        clientID: ClientID,
        sessionID: SessionID,
        services: LandServices,
        admitThroughTransport: Bool
    ) async throws -> JoinOutcome {
        try await ensureInitializedForJoin()
        let call = JoinCall(session: session, clientID: clientID, sessionID: sessionID, services: services, admitThroughTransport: admitThroughTransport)
        var request = try withTurn { m, side, outputs in try joinBegin(&m, &side, &outputs, call) }
        // The attempt's rejoin reservation, ended on every exit (the insert ends it too).
        var reserved: (epoch: Epoch, playerID: PlayerID)?
        defer {
            if let reserved {
                withTurn { m, _, _ in endRejoinReservation(&m, reserved.epoch, of: reserved.playerID) }
            }
        }
        while true {
            switch request {
            case let .runCanJoinResolvers(resolverContext, landContext):
                let ctx = try await ResolverExecutor.executeResolvers(
                    executors: definition.lifetimeHandlers.canJoinResolverExecutors,
                    resolverContext: resolverContext,
                    landContext: landContext,
                    abandonment: resolverAbandonment(.canJoin)
                )
                request = try withTurn { m, side, outputs in try joinDecide(&m, &side, &outputs, call, canJoinContext: ctx) }
            case let .holdThenKickCheck(decided):
                // J2 took the reservation in the segment that just ended: no suspension since.
                reserved = decided.reservation.map { ($0, decided.playerID) }
                await holds.at(.join)
                request = try withTurn { m, side, outputs in try joinKickCheck(&m, &side, &outputs, decided) }
            case let .kick(decided, oldClientID, oldSessionID):
                // Kick old connection by calling leave
                // This will call OnLeave handler and clean up state
                try await leave(playerID: decided.playerID, clientID: oldClientID, sessionID: oldSessionID)
                request = try withTurn { m, side, outputs in try joinInsert(&m, &side, &outputs, decided) }
            case let .admit(decided, joinSequence):
                // Between two segments, at depth zero, with no suspension since the insert or
                // the append (§3.5): the admission may call back into the keeper.
                let admission = admitJoiningInTurn(playerID: decided.playerID, clientID: decided.call.clientID, sessionID: decided.call.sessionID, joinSequence: joinSequence)
                guard let joinSequence else {
                    // J3b: no OnJoin input.
                    return JoinOutcome(decision: decided.decision, admitted: admission.isAdmitted)
                }
                request = withTurn { m, side, outputs in
                    joinAfterAdmission(&m, &side, &outputs, decided, sequence: joinSequence, admission: admission)
                }
            case let .runOnJoinResolvers(decided, capture, resolverContext, landContext):
                let resolverOutputs = try await runOnJoinResolvers(capture, resolverContext, landContext)
                request = try withTurn { m, side, outputs in
                    try joinAppend(&m, &side, &outputs, decided, capture, resolverOutputs: resolverOutputs, resolvedAtTick: m.lastCommittedTickId)
                }
            case let .awaitInputTurn(outcome, sequence):
                // Registered in the same segment as the append's: no suspension since it.
                _ = try await awaitInputTurn(sequence: sequence)
                return outcome
            case let .done(outcome):
                return outcome
            }
        }
    }

    /// The reporting join's requests (#700 K1b-5b §4.1): each segment returns the await it needs.
    private enum JoinRequest {
        case runCanJoinResolvers(ResolverContext, LandContext)
        /// J2 decided and reserved: the driver ends the reservation on every exit, runs the
        /// `.join` hold, then J2b.
        case holdThenKickCheck(JoinDecided)
        /// The old session's leave (§4.3's flow); J3 follows it.
        case kick(JoinDecided, oldClientID: ClientID, oldSessionID: SessionID?)
        /// The transport's admission, between two segments; `joinSequence` is nil without an
        /// OnJoin input (J3a), else the appended input's (J4).
        case admit(JoinDecided, joinSequence: Int64?)
        case runOnJoinResolvers(JoinDecided, OnJoinCapture, ResolverContext, LandContext)
        case awaitInputTurn(JoinOutcome, sequence: Int64)
        case done(JoinOutcome)
    }

    /// The reporting join's call.
    private struct JoinCall {
        let session: PlayerSession
        let clientID: ClientID
        let sessionID: SessionID
        let services: LandServices
        let admitThroughTransport: Bool
    }

    /// What the reporting join carries from J2's decision on.
    private struct JoinDecided {
        let call: JoinCall
        let decision: JoinDecision
        let playerID: PlayerID
        let reservation: Epoch?
    }

    /// J1: the CanJoin request. Without resolvers it goes on to J2 in this segment.
    private func joinBegin(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ call: JoinCall
    ) throws -> JoinRequest {
        // Call CanJoin handler if defined
        guard definition.lifetimeHandlers.canJoin != nil else {
            return try joinDecide(&m, &side, &outputs, call, canJoinContext: nil)
        }
        let ctx = makeContext(&m,
            playerID: PlayerID("_pending"), // Temporary ID for validation
            clientID: call.clientID,
            sessionID: call.sessionID,
            servicesOverride: call.services
        )

        // Execute resolvers in parallel if any are declared
        guard !definition.lifetimeHandlers.canJoinResolverExecutors.isEmpty else {
            return try joinDecide(&m, &side, &outputs, call, canJoinContext: ctx)
        }
        let resolverContext = ResolverContext(
            landContext: ctx,
            actionPayload: nil,
            eventPayload: nil,
            currentState: m.state
        )
        return .runCanJoinResolvers(resolverContext, ctx)
    }

    /// J2: CanJoin, the stale-join refusal (#234), the drain refusal, the player limit counting
    /// rejoin reservations, and the reservation (#852). `canJoinContext` is nil when the land
    /// has no CanJoin.
    private func joinDecide(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ call: JoinCall,
        canJoinContext: LandContext?
    ) throws -> JoinRequest {
        var decision: JoinDecision = .allow(playerID: PlayerID(call.session.playerID))
        if let canJoinHandler = definition.lifetimeHandlers.canJoin, let ctx = canJoinContext {
            // Execute handler synchronously (resolvers already executed above). CanJoin isn't
            // repeated from the record (a viewer joining a reevaluation keeper runs it live), so
            // its draws come from a copy of the land's generator, never written back.
            let (scoped, scope) = openStepScope(ctx, random: detachedRandom(m))
            defer { scope.close() }
            decision = try canJoinHandler(m.state, call.session, scoped)
        }

        // If denied, return early
        guard case let .allow(playerID) = decision else {
            return .done(JoinOutcome(decision: decision, admitted: false))
        }

        // A stale join attempt is refused by the player CanJoin resolved, in this segment,
        // before the player limit, the kick of its old session and the insert (#234). A
        // refused call out ended the land: the drain check below refuses the join.
        if call.admitThroughTransport,
           case .answered(true) = callOut(&m, &side, &outputs, { _ in
               refusesResolvedJoinInTurn(playerID: playerID, sessionID: call.sessionID)
           }) {
            return .done(JoinOutcome(decision: decision, admitted: false, refusedStale: true))
        }

        // A destroyed land refuses a late join as shutting down (retryable elsewhere), not as full.
        guard !isDraining else { throw JoinError.landShuttingDown }

        // Check maxPlayers limit after CanJoin handler (using the playerID returned by CanJoin)
        // Skip check if player is already in the room (reconnection scenario)
        // A player whose old session is being kicked has no entry for a while, but still has a reservation.
        let isReconnection = m.players[playerID] != nil || !(m.rejoinReservations[playerID]?.isEmpty ?? true)

        if let maxPlayers = definition.config.maxPlayers, !isReconnection {
            // Reserved places count too: their owners are about to come back with a new connection.
            let reservedPlaces = m.rejoinReservations.reduce(0) { $0 + ($1.value.isEmpty || m.players[$1.key] != nil ? 0 : 1) }
            let currentPlayerCount = m.players.count + reservedPlaces
            guard currentPlayerCount < maxPlayers else {
                behavior.logger.info("Join rejected: room is full", metadata: [
                    "currentPlayers": .stringConvertible(currentPlayerCount),
                    "maxPlayers": .stringConvertible(maxPlayers),
                ])
                throw JoinError.roomIsFull
            }
        }

        // Reserve the returning player's place until its entry is back or this join fails. Each
        // attempt ends only its own reservation, at the insert and on every other exit.
        let reservation = isReconnection ? m.rejoinReservationEpochs.next() : nil
        if let reservation { m.rejoinReservations[playerID, default: []].insert(reservation) }
        return .holdThenKickCheck(JoinDecided(call: call, decision: decision, playerID: playerID, reservation: reservation))
    }

    /// J2b: the kick target, after the hold. Without one it goes on to J3 in this segment.
    private func joinKickCheck(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ decided: JoinDecided
    ) throws -> JoinRequest {
        // Check for duplicate playerID login (Kick Old strategy)
        if let existingSession = m.players[decided.playerID], let oldClientID = existingSession.clientID {
            behavior.logger.info("Duplicate playerID login detected: \(decided.playerID.rawValue), kicking old client: \(oldClientID.rawValue)")
            return .kick(decided, oldClientID: oldClientID, oldSessionID: existingSession.lastSessionID)
        }
        return try joinInsert(&m, &side, &outputs, decided)
    }

    /// J3: the insert, after the kick if there was one, the reservation's end, and the OnJoin
    /// request. Without an OnJoin input the admission follows (J3a).
    private func joinInsert(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ decided: JoinDecided
    ) throws -> JoinRequest {
        let playerID = decided.playerID
        let session = decided.call.session
        // Proceed with join
        var playerSession = m.players[playerID] ?? KeeperPlayerEntry(
            deviceID: session.deviceID,
            isGuest: session.isGuest,
            metadata: session.metadata
        )
        let isFirst = playerSession.clientID == nil

        playerSession.clientID = decided.call.clientID
        playerSession.lastSessionID = decided.call.sessionID
        // Update deviceID, isGuest, and metadata if provided (for reconnection scenarios)
        if let deviceID = session.deviceID {
            playerSession.deviceID = deviceID
        }
        playerSession.isGuest = session.isGuest
        if !session.metadata.isEmpty {
            playerSession.metadata = session.metadata
        }
        // Checked in the same synchronous segment as the insert: a destruction that started
        // during this join's awaits must not get a player after it stopped the loops.
        guard !isDraining else { throw JoinError.landShuttingDown }
        let entryGeneration = m.entryGenerations.next()
        playerSession.generation = entryGeneration
        m.players[playerID] = playerSession
        playerServices[playerID] = (generation: entryGeneration, services: decided.call.services)
        if let reservation = decided.reservation { endRejoinReservation(&m, reservation, of: playerID) }

        cancelDestroy(&m, &side)

        // In reevaluation mode, replay viewers are observers: add to players for sync but skip OnJoin
        // so they are not added to game state (which would create an extra player in the replay).
        guard isFirst, definition.lifetimeHandlers.onJoin != nil, behavior.config.mode != .reevaluation else {
            // No OnJoin input: admitted in the same segment as the insert.
            guard decided.call.admitThroughTransport else {
                return .done(JoinOutcome(decision: decided.decision, admitted: false))
            }
            return .admit(decided, joinSequence: nil)
        }

        let capture = OnJoinCapture(
            playerID: playerID,
            clientID: decided.call.clientID,
            sessionID: decided.call.sessionID,
            services: decided.call.services,
            deviceID: session.deviceID,
            isGuest: session.isGuest,
            metadata: session.metadata,
            contextCarriesIdentity: true,
            entryGeneration: entryGeneration,
            // Allocate sequence number (shared across Action + ClientEvent + ServerEvent + Lifecycle)
            sequence: outputCollector.takeNextSequence(),
            // Snapshot tick at request time; update after resolver completion for async determinism.
            resolvedAtTick: m.lastCommittedTickId
        )
        // Execute resolvers in parallel if any are declared
        if let (resolverContext, landContext) = onJoinResolverRequest(&m, &side, &outputs, capture) {
            return .runOnJoinResolvers(decided, capture, resolverContext, landContext)
        }
        return try joinAppend(&m, &side, &outputs, decided, capture, resolverOutputs: [:], resolvedAtTick: capture.resolvedAtTick)
    }

    /// J4: the OnJoin append, then the admission (or, when the transport doesn't admit, J4b in
    /// this segment).
    private func joinAppend(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ decided: JoinDecided,
        _ capture: OnJoinCapture,
        resolverOutputs: [String: HeldResolverOutput],
        resolvedAtTick: Int64
    ) throws -> JoinRequest {
        try appendOnJoin(&m, &side, &outputs, capture, resolverOutputs: resolverOutputs, resolvedAtTick: resolvedAtTick)
        // Admitted in the same segment as the append, before the OnJoin turn can run.
        guard decided.call.admitThroughTransport else {
            return joinAfterAdmission(&m, &side, &outputs, decided, sequence: capture.sequence, admission: .notAdmitted)
        }
        return .admit(decided, joinSequence: capture.sequence)
    }

    /// J4b: after the admission of a join with an OnJoin input.
    private func joinAfterAdmission(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ decided: JoinDecided,
        sequence: Int64,
        admission: JoinAdmission
    ) -> JoinRequest {
        let outcome = JoinOutcome(decision: decided.decision, admitted: admission.isAdmitted)
        // If there's no tick handler, process lifecycle immediately (backward-compatible mode)
        guard definition.lifetimeHandlers.tickHandler == nil else { return .done(outcome) }
        if admission == .admittedCompletesInTurn {
            // Admitted in the turn: the transport completes the join when a turn consumes
            // the input (`noteJoinInputsConsumed`) and a sync phase commits for it. Nobody
            // awaits the input turn here, so it is scheduled in this segment.
            scheduleInputDrain(&m, &outputs)
            return .done(outcome)
        }
        return .awaitInputTurn(outcome, sequence: sequence)
    }

    /// The transport's admission of a joining session, only on the in-turn path (the transport
    /// shares this keeper's executor, so its synchronous call can't trap). Synchronous: called in
    /// the segment of the state change it belongs to.
    private func admitJoiningInTurn(playerID: PlayerID, clientID: ClientID, sessionID: SessionID, joinSequence: Int64?) -> JoinAdmission {
        guard syncsInTurn, let transport else { return .notAdmitted }
        return transport.admitJoiningSession(playerID: playerID, clientID: clientID, sessionID: sessionID, joinSequence: joinSequence)
    }

    /// The transport's refusal of a stale join by its resolved player, only on the in-turn path,
    /// as `admitJoiningInTurn`. Off that path the transport keeps its check by the requested
    /// player alone.
    private func refusesResolvedJoinInTurn(playerID: PlayerID, sessionID: SessionID) -> Bool {
        guard syncsInTurn, let transport else { return false }
        return transport.refusesResolvedJoin(playerID: playerID, sessionID: sessionID)
    }

    /// Reports the join inputs a turn applied to an in-turn transport (`noteJoinInputsConsumed`),
    /// in the segment that applied them. Live keepers only: re-evaluation feeds recorded joins.
    private func noteJoinInputsConsumed(_ results: [JoinInputResult]) {
        guard !results.isEmpty, behavior.config.mode == .live, syncsInTurn, let transport else { return }
        transport.noteJoinInputsConsumed(results)
    }

    /// `applyInputs`' join report outside a turn body: only re-evaluation's paths
    /// (`processPendingActions`, the replay passes), where `noteJoinInputsConsumed` returns before
    /// the port. Every live path applies inputs in a turn body (`reportJoinsInTurn`).
    private func reportJoinsOutsideTurn(_ m: inout KeeperModel<State>, _ side: inout KeeperTurnSide, _ results: [JoinInputResult]) {
        noteJoinInputsConsumed(results) // lint-allow: bare-port: re-evaluation only; noteJoinInputsConsumed returns before the port on a keeper that isn't live
    }

    /// `applyInputs`' join report in a turn body: through `callOut`, so a re-entry from the port
    /// ends the land in that call. The report comes after the pass applied its joins and before
    /// its number is taken, so a refusal names the pass in progress.
    private func reportJoinsInTurn(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ results: [JoinInputResult]
    ) {
        guard !results.isEmpty else { return }
        // Non-empty results: the pass applied at least one join before the report.
        _ = callOut(&m, &side, &outputs, endsInputs: true, appliedInputs: true, { _ in noteJoinInputsConsumed(results) })
    }

    /// Whether the transport has joins that wait for a committed sync phase, read in a turn.
    private var transportHasJoinsAwaitingSync: Bool {
        guard syncsInTurn, behavior.config.mode == .live, let transport else { return false }
        return transport.hasJoinsAwaitingSync
    }


    /// A sync-only turn for joins that wait for a committed sync phase (#69). Called by the
    /// transport when a join became ready outside a turn (its session registered with the
    /// transport after its OnJoin was consumed). Does nothing when no join waits, so a burst of
    /// such requests shares the first one's turn: it flips every ready join (up to the budget).
    package func requestJoinSyncTurn() async {
        // Draining: the drain fails the waiting joins with `landClosed`, none flips now.
        guard !isDraining, transportHasJoinsAwaitingSync, let transport else { return }
        if hasPeriodicSync {
            // A sync folded into the next tick (`inTurnSyncDue`) must not run ahead of that tick
            // (coincident-sync rule): the tick turn's cadence sync flips the ready joins.
            guard periodicJoinSyncAllowed, !model.inTurnSyncDue else { return }
            model.joinSyncRequestTurnsForTesting += 1
            runSyncOnlyTurn(transport: transport, joinSyncOnly: true)
        } else {
            model.joinSyncRequestTurnsForTesting += 1
            runSyncOnlyTurn(transport: transport)
        }
    }

    /// Whether a land with periodic sync runs a sync phase for its ready joins outside the
    /// cadence now. Not while draining (the drain fails the waiting joins), and not after such a
    /// sync was deferred by writer back-pressure, until a sync commits: the periodic sync
    /// completes them then. So a backlog adds at most one extra deferred turn per episode per
    /// land (`inTurnDeferredTurns`, and the profiler's `syncDeferredTurns`), not one per tick or
    /// per registration.
    private var periodicJoinSyncAllowed: Bool {
        hasPeriodicSync && !isDraining && !model.joinSyncWaitsForCommit && transportHasJoinsAwaitingSync
    }

    /// `periodicJoinSyncAllowed` in a turn body, with the joins read through `callOut`. Nil when
    /// that read was refused (the land ended in it). `transport` is the turn's port, nil when
    /// this keeper's turns don't run the phase, where the read is false.
    private func periodicJoinSyncAllowed(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        transport: (any LandKeeperTransport)?
    ) -> Bool? {
        guard hasPeriodicSync, !isDraining, !m.joinSyncWaitsForCommit, let transport else { return false }
        return joinsAwaitingSync(&m, &side, &outputs, transport: transport)
    }




    /// Intake check for actions and client events (#92, newest wins): rejects a sender only when
    /// the player has an entry and that entry is another client or session, i.e. a newer join
    /// of the player replaced the sender's session. Called on `.live` keepers only (the intake
    /// returns earlier otherwise), at intake. An action's resolvers lie between its intake and
    /// its append; its delivery checks the entry's generation instead (`deliverResolvedAction`).
    ///
    /// Unchanged: a player with no entry (direct callers that send before or without a join),
    /// the system player and client, and a sender matching the entry (a join, then sends with the
    /// same client and session).
    /// `rejectSenderIfSuperseded(_:…)` for a caller outside a turn body.
    private func rejectSenderIfSuperseded(
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        input: String
    ) throws {
        try rejectSenderIfSuperseded(&model, playerID: playerID, clientID: clientID, sessionID: sessionID, input: input)
    }

    private func rejectSenderIfSuperseded(
        _ m: inout KeeperModel<State>,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        input: String
    ) throws {
        guard playerID != behavior.config.systemPlayerID, clientID != behavior.config.systemClientID,
              let entry = m.players[playerID] else { return }
        let otherClient = entry.clientID.map { $0 != clientID } ?? false
        let otherSession = entry.lastSessionID.map { $0 != sessionID } ?? false
        guard otherClient || otherSession else { return }
        m.supersededSenderRejections += 1
        behavior.logger.warning("Input rejected: a newer session of the player replaced the sender's", metadata: [
            "playerID": .string(playerID.rawValue),
            "clientID": .string(clientID.rawValue),
            "sessionID": .string(sessionID.rawValue),
            "input": .string(input),
            "rejectedTotal": .stringConvertible(m.supersededSenderRejections),
        ])
        throw LandInputRejection.senderSuperseded
    }

    /// Intake (and delivery) check: once the drain has started (`isDraining`, set in the same
    /// segment as the emptiness check), no input is accepted, so nothing is appended after the
    /// drain took the pending inputs.
    private func rejectIfLandClosed() throws {
        guard isDraining else { return }
        throw LandInputRejection.landClosed
    }

    private func actionTicket(_ m: KeeperModel<State>, for playerID: PlayerID, clientID: ClientID) -> KeeperActionTicket {
        guard playerID != behavior.config.systemPlayerID, clientID != behavior.config.systemClientID else {
            return KeeperActionTicket(entryGeneration: nil)
        }
        return KeeperActionTicket(entryGeneration: m.players[playerID]?.generation)
    }

    /// Delivers an action whose resolvers finished: the only code that runs after their
    /// await, one synchronous segment. The result is an input like any other; it is validated
    /// against the current state with the intake's ticket, and appended only when it holds:
    /// - no entry at intake: accepted (nothing to compare);
    /// - the sender's entry at intake, the same generation now: accepted;
    /// - the sender's entry at intake, gone or replaced now (the player left, or a newer join
    ///   replaced it): rejected with `LandInputRejection.senderSuperseded`;
    /// - the land draining or shut down now: rejected with `LandInputRejection.landClosed`
    ///   (finalize doesn't remove entries, so the sender check alone would accept it).
    ///
    /// The input is bound to the tick current now (`resolvedAtTick`), so it applies in the
    /// first turn after its resolvers finish, as recorded. A rejected input has taken a
    /// sequence number and is never recorded; replay advances past the gap through the
    /// recorded watermarks.
    private func deliverResolvedAction(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ item: PendingActionItem,
        ticket: KeeperActionTicket,
        input: String
    ) throws {
        try validateDelivery(&m, of: item, ticket: ticket, input: input)
        m.pendingItems.append(.action(item.with(heldResolverOutputs: item.heldResolverOutputs, resolvedAtTick: m.lastCommittedTickId)))
        side.probe?("action-queued")
    }

    /// The delivery checks (`deliverResolvedAction`): the land isn't draining, and the sender's
    /// entry is still the one the ticket names.
    private func validateDelivery(_ m: inout KeeperModel<State>, of item: PendingActionItem, ticket: KeeperActionTicket, input: String) throws {
        // The land started draining during the resolvers: nothing is appended any more.
        try rejectIfLandClosed()
        if let generation = ticket.entryGeneration, m.players[item.playerID]?.generation != generation {
            m.supersededSenderRejections += 1
            behavior.logger.warning("Action rejected at delivery: the sender's entry ended during its resolvers", metadata: [
                "playerID": .string(item.playerID.rawValue),
                "clientID": .string(item.clientID.rawValue),
                "sessionID": .string(item.sessionID.rawValue),
                "input": .string(input),
                "rejectedTotal": .stringConvertible(m.supersededSenderRejections),
            ])
            throw LandInputRejection.senderSuperseded
        }
    }

    // MARK: - Action jobs

    // MARK: - The failure table (#700 K1b-2). Outside the model: `any Error` isn't plain.

    /// Where a failure is read from, for the miss's log.
    private enum FailurePath: String {
        case slot, inputTurn, initialization
    }

    private func recordFailure(_ m: inout KeeperModel<State>, _ side: inout KeeperTurnSide, _ error: any Error) -> FailureID {
        let id = FailureID(m.failureIDs.next())
        side.failures[id] = error
        return id
    }

    /// Removes the entry and returns its error; a miss returns `FailureTableMiss`, logged and counted.
    private func takeFailure(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ id: FailureID,
        path: FailurePath,
        sequence: Int64?
    ) -> any Error {
        if let error = side.failures.removeValue(forKey: id) { return error }
        return noteFailureMiss(&m, id, path: path, sequence: sequence)
    }

    /// Returns the entry's error and leaves it; a miss as `takeFailure`.
    private func failure(for id: FailureID, path: FailurePath, sequence: Int64?) -> any Error {
        if let error = turnSide.failures[id] { return error }
        return noteFailureMiss(&model, id, path: path, sequence: sequence)
    }

    private func noteFailureMiss(_ m: inout KeeperModel<State>, _ id: FailureID, path: FailurePath, sequence: Int64?) -> any Error {
        m.failureTableMisses += 1
        // A miss changes what a client sees (a sentinel takes the generic error frame, where an
        // event's `LandInputRejection` sends none) while the land keeps running: log it.
        behavior.logger.error("The keeper's failure table has no entry for a held failure", metadata: [
            "landID": .string(behavior.config.actualLandID ?? "-"),
            "path": .string(path.rawValue),
            "sequence": .string(sequence.map(String.init) ?? "-"),
            "failureID": .string(id.description),
        ])
        return FailureTableMiss(id: id, path: path.rawValue, sequence: sequence)
    }

    /// The result to hold: a success as is, a failure recorded in the table.
    private func held(_ m: inout KeeperModel<State>, _ side: inout KeeperTurnSide, _ result: Result<InputOutcome, any Error>) -> InputResult {
        switch result {
        case .success(let outcome): return .outcome(outcome)
        case .failure(let error): return .failed(recordFailure(&m, &side, error))
        }
    }

    /// The held result as its caller gets it, taking the failure out of the table.
    private func taken(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ held: InputResult,
        path: FailurePath,
        sequence: Int64
    ) -> Result<InputOutcome, any Error> {
        switch held {
        case .outcome(let outcome): return .success(outcome)
        case .failed(let id): return .failure(takeFailure(&m, &side, id, path: path, sequence: sequence))
        }
    }

    /// Sets `inputTurnResults[sequence]`, taking out of the table any failure the write displaces.
    /// Live sequencing never displaces one; a manual replay step (`stepTickOnce` has no
    /// single-flight) could, so the setter is safe anyway.
    private func setInputTurnResult(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ sequence: Int64,
        _ result: Result<InputOutcome, any Error>?
    ) {
        if case .failed(let displaced)? = m.inputTurnResults[sequence] {
            side.failures.removeValue(forKey: displaced)
        }
        // `held` writes the m. Split as a precaution, in the shape of the slot fill's
        // (`fillActionSlot`); whether a subscript set begins its access first is unproven.
        let entry = result.map { held(&m, &side, $0) }
        m.inputTurnResults[sequence] = entry
    }

    // MARK: - The alignment check (returns its violations; never asserts)

    /// What doesn't line up between the job table and its side table, the slots and their
    /// waiters, and the failure table and the IDs the model holds. Each call site logs and counts
    /// what this returns: an assertion inside a function a mutant changes would trap before a test
    /// could observe it.
    private func actionTableViolations(_ m: KeeperModel<State>, _ side: KeeperTurnSide) -> [String] {
        let actions = side.actions
        var violations: [String] = []
        if Set(actions.jobTasks.keys) != Set(m.actionJobs.keys) {
            violations.append("job tasks \(actions.jobTasks.keys.sorted()) != jobs \(m.actionJobs.keys.sorted())")
        }
        for sequence in actions.slotWaiters.keys {
            if m.actionSlots[sequence] == nil { violations.append("waiter \(sequence) without a slot") }
            if m.actionSlots[sequence]?.result != nil { violations.append("slot \(sequence) holds a result and a waiter") }
        }
        var owners: [FailureID: Int] = [:]
        if let id = m.initializationFailure { owners[id, default: 0] += 1 }
        for slot in m.actionSlots.values { if case .failed(let id)? = slot.result { owners[id, default: 0] += 1 } }
        for result in m.inputTurnResults.values { if case .failed(let id) = result { owners[id, default: 0] += 1 } }
        for (id, count) in owners where count > 1 { violations.append("\(id) has \(count) owners") }
        for id in owners.keys where side.failures[id] == nil { violations.append("\(id) has no table entry") }
        for id in side.failures.keys where owners[id] == nil { violations.append("\(id) has no owner") }
        return violations
    }

    /// Runs the check after a completed pair, logging and counting what it found, when a test
    /// turned it on. In production it reads one flag and returns.
    private func checkActionTables(_ m: inout KeeperModel<State>, _ side: inout KeeperTurnSide, _ site: StaticString) {
        guard side.actions.auditOn else { return }
        let violations = actionTableViolations(m, side)
        guard !violations.isEmpty else { return }
        m.alignmentViolations += violations.count
        behavior.logger.error("The keeper's action tables don't line up", metadata: [
            "site": .string("\(site)"),
            "violations": .string(violations.joined(separator: "; ")),
        ])
    }

    package func failureTableCountForTesting() -> Int { turnSide.failures.count }
    package func failureTableMissesForTesting() -> Int { model.failureTableMisses }
    package func alignmentViolationsForTesting() -> Int { model.alignmentViolations }
    /// Turns the alignment check at the call sites on or off (off by default).
    package func setActionTableAuditForTesting(_ enabled: Bool) { turnSide.actions.auditOn = enabled }
    package func actionTableViolationsForTesting() -> [String] { actionTableViolations(model, turnSide) }

    // MARK: - The player-services table (#700 K1b-4)

    /// The services of `playerID`'s current entry: the table's entry whose generation is the
    /// player's entry's. Nil when the player has no entry.
    private func currentPlayerServices(of playerID: PlayerID) -> LandServices? {
        model.players[playerID].flatMap { currentPlayerServices(of: playerID, entry: $0) }
    }

    /// The services of `entry`, `playerID`'s entry read by the caller.
    private func currentPlayerServices(of playerID: PlayerID, entry: KeeperPlayerEntry) -> LandServices? {
        guard let services = playerServices[playerID], services.generation == entry.generation else { return nil }
        return services.services
    }

    /// Removes `playerID`'s services if they are the entry of `generation`'s: a newer entry's
    /// stay.
    private func removePlayerServices(of playerID: PlayerID, generation: Epoch) {
        if playerServices[playerID]?.generation == generation {
            playerServices.removeValue(forKey: playerID)
        }
    }

    /// The player-services table's generations, and the player table's (tests: they must match).
    package func playerServiceGenerationsForTesting() -> (services: [PlayerID: Epoch], players: [PlayerID: Epoch]) {
        (playerServices.mapValues(\.generation), model.players.mapValues(\.generation))
    }

    /// The stored labels of the keeper and of each container it holds, by storage path, for the
    /// census test (#700 K1b-4). Read inside the keeper's isolation: a `Mirror`'s children load
    /// their fields lazily, so only the label arrays leave it. Present in release builds too, so
    /// a release run checks that the debug-only fields are absent.
    package func censusLabelsForTesting() -> [String: [String]] {
        func labels(_ value: Any) -> [String] { Mirror(reflecting: value).children.map { $0.label ?? "?" } }
        return [
            "actor": labels(self),
            "model": labels(model),
            "behavior": labels(behavior),
            "behavior.config": labels(behavior.config),
            "replay": labels(replay),
            "turnSide": labels(turnSide),
            "turnSide.actions": labels(turnSide.actions),
            "behavior.reentrySentinel": labels(behavior.reentrySentinel),
        ]
    }
    package func setInputTurnResultForTesting(_ sequence: Int64, _ result: Result<InputOutcome, any Error>?) {
        setInputTurnResult(&model, &turnSide, sequence, result)
    }
    /// This land's abandoned resolver groups still running, per kind (#364). Shared by its
    /// groups' abandonments, which update it inside their transitions; read at intake.
    package nonisolated let abandonmentCounter = LandAbandonmentCounter()

    /// A new abandonment for one of this land's resolver groups.
    private nonisolated func resolverAbandonment(
        _ kind: ResolverAbandonment.Kind,
        onEnded: (@Sendable () -> Void)? = nil
    ) -> ResolverAbandonment {
        ResolverAbandonment(kind: kind, counter: abandonmentCounter, metrics: ResolverDeadline.metrics, onEnded: onEnded)
    }
    #if DEBUG
    private static var filledActionSlotsCapacityForAssert: Int { 1024 }
    #endif

    /// Registers the job and its slot, and starts its resolvers' task. Called in the intake's
    /// segment (`actionIntake`), which writes the tables inline. The task starts inline, as
    /// before: it reaches the keeper only through an await (`completeAction`), so nothing of it
    /// runs on the keeper before this segment ends, and its handle is installed here.
    private func startActionJob(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ item: PendingActionItem,
        executors: [any AnyResolverExecutor],
        ctx: LandContext,
        ticket: KeeperActionTicket,
        input: String
    ) {
        let sequence = item.sequence
        let resolverContext = makeResolverContext(m, ctx)
        let abandonment = resolverAbandonment(.action) { [weak self] in
            Task { await self?.releaseCompletedActionJob(sequence) }
        }
        m.actionSlots[sequence] = KeeperActionSlot()
        m.actionJobs[sequence] = KeeperActionJob(item: item, ticket: ticket, input: input)
        let box = side.actions.insertJobTask(sequence, abandonment: abandonment)
        m.actionJobsStarted += 1
        // A copy, so the task doesn't hop to the keeper for it: with no hook it returns at once.
        let holds = self.holds
        let task = Task { [weak self] in
            await holds.at(.actionJobStart)
            let resolved: Result<[String: HeldResolverOutput], any Error>
            do {
                let outputs = try await ResolverExecutor.executeResolvers(
                    executors: executors,
                    resolverContext: resolverContext,
                    landContext: ctx,
                    abandonment: abandonment
                )
                resolved = .success(outputs.getAllResolverOutputs())
            } catch {
                resolved = .failure(error)
            }
            await self?.completeAction(sequence: sequence, resolved: resolved)
        }
        box.install(task)
        checkActionTables(&m, &side, #function)
    }

    /// A job's resolvers finished (or failed, or were cancelled): the worker's driver. After the
    /// hold point, one turn body (`completeActionBody`) delivers the result.
    private func completeAction(
        sequence: Int64,
        resolved: Result<[String: HeldResolverOutput], any Error>
    ) async {
        await holds.at(.actionComplete)
        withTurn { m, side, outputs in
            completeActionBody(&m, &side, &outputs, sequence: sequence, resolved: resolved)
        }
    }

    /// The worker's segment (A2): delivers the result like any input, with the intake's ticket
    /// checked against the current state, and fills the job's slot with the outcome. The slot's
    /// resume and the drain's task are staged.
    private func completeActionBody(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        sequence: Int64,
        resolved: Result<[String: HeldResolverOutput], any Error>
    ) {
        guard var job = m.actionJobs[sequence], !job.completed else { return }
        // Read before `removeActionJob` removes it. The two tables are written together, so it
        // is there; an optional read keeps the guard above the only early return.
        let jobTask = side.actions.jobTasks[sequence]
        // The job's place in the caps lasts until its resolvers' task ends.
        if jobTask?.abandonment.isRunning == true {
            job.completed = true
            m.actionJobs[sequence] = job
        } else {
            removeActionJob(&m, &side, &outputs, sequence)
        }
        guard !job.cancelledByKeeper else {
            checkActionTables(&m, &side, #function)
            return
        }
        let outcome: Result<InputOutcome, any Error>
        switch resolved {
        case .failure(let error):
            outcome = .failure(error)
        case .success where jobTask?.callerCancelled.isSet == true:
            outcome = .failure(CancellationError())
        case .success(let resolverOutputs):
            let item = job.item
            do {
                try deliverResolvedAction(&m, &side,
                    item.with(heldResolverOutputs: resolverOutputs, resolvedAtTick: item.resolvedAtTick),
                    ticket: job.ticket,
                    input: job.input
                )
                if definition.lifetimeHandlers.tickHandler == nil {
                    // Tickless: the turn or pass that applies it answers, after its record.
                    // Delivered, it is out of the job table's cancellations (`completed`).
                    m.ticklessJobTurns.insert(sequence)
                    scheduleInputDrain(&m, &outputs)
                    checkActionTables(&m, &side, #function)
                    return
                }
                // Tick land: acknowledged now; the handler runs in a tick.
                outcome = .success(.none)
            } catch {
                outcome = .failure(error)
            }
        }
        fillActionSlot(&m, &side, &outputs, sequence, with: outcome)
    }

    /// The job leaves the job table (and the caps); the resume of its test waiters is staged.
    private func removeActionJob(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ sequence: Int64
    ) {
        m.actionJobs.removeValue(forKey: sequence)
        let waiters = side.actions.removeJobTask(sequence)
        if !waiters.isEmpty {
            outputs.stage { waiters.forEach { $0.resume() } }
        }
        checkActionTables(&m, &side, #function)
    }

    /// Debug only: remembers a filled slot in the ring, forgetting the oldest once it's full.
    private func rememberFilledSlotForAssert(_ m: inout KeeperModel<State>, _ sequence: Int64) {
        #if DEBUG
        let firstFill = m.filledActionSlotsForAssert.insert(sequence).inserted
        assert(firstFill, "Action job \(sequence)'s slot was filled twice")
        let capacity = Self.filledActionSlotsCapacityForAssert
        if m.filledActionSlotsOrderForAssert.count < capacity {
            m.filledActionSlotsOrderForAssert.append(sequence)
        } else {
            m.filledActionSlotsForAssert.remove(m.filledActionSlotsOrderForAssert[m.filledActionSlotsNextForAssert])
            m.filledActionSlotsOrderForAssert[m.filledActionSlotsNextForAssert] = sequence
            m.filledActionSlotsNextForAssert = (m.filledActionSlotsNextForAssert + 1) % capacity
        }
        #endif
    }

    /// The abandoned resolvers of a completed job ended: it leaves the caps.
    private func releaseCompletedActionJob(_ sequence: Int64) {
        withTurn { m, side, outputs in
            guard m.actionJobs[sequence]?.completed == true else { return }
            removeActionJob(&m, &side, &outputs, sequence)
        }
    }

    /// The caps on action jobs (`ActionJobLimits`), checked at intake before the sequence is
    /// taken: the session's jobs still registered (abandoned ones included), this land's
    /// abandoned action groups (#364: only actions count, so an outage behind the join
    /// resolvers doesn't stop the actions of players already in), and the process's abandoned
    /// action jobs.
    private func rejectIfOverActionJobLimits(_ m: KeeperModel<State>, sessionID: SessionID, input: String) throws {
        let metrics = ResolverDeadline.metrics
        if let limit = ActionJobLimits.inFlightPerSession,
           m.actionJobs.values.lazy.filter({ $0.item.sessionID == sessionID }).count >= limit {
            metrics.noteInFlightLimitRejection()
            behavior.logger.warning("Action rejected: the session's in-flight limit is reached", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "input": .string(input),
                "limit": .stringConvertible(limit),
            ])
            throw ActionLimitRejection.inFlightLimit(limit: limit)
        }
        if let limit = ActionJobLimits.abandonedActionsPerLand, abandonmentCounter.count(.action) >= limit {
            metrics.noteLandAbandonedLimitRejection()
            behavior.logger.warning("Action rejected: the land's abandoned-resolver limit is reached", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "input": .string(input),
                "limit": .stringConvertible(limit),
            ])
            throw ActionLimitRejection.landAbandonedResolverLimit(limit: limit)
        }
        if let limit = ActionJobLimits.abandonedActions, metrics.snapshot.abandonedActions >= limit {
            metrics.noteAbandonedLimitRejection()
            behavior.logger.warning("Action rejected: the process's abandoned-resolver limit is reached", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "input": .string(input),
                "limit": .stringConvertible(limit),
            ])
            throw ActionLimitRejection.abandonedResolverLimit(limit: limit)
        }
    }

    /// Fills the job's slot with its one outcome. A tickless job's in-flight work ends here, on
    /// every path: the applying turn, a rejection or failure at completion, a cancellation, the drain.
    private func fillActionSlot(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ sequence: Int64,
        with outcome: Result<InputOutcome, any Error>
    ) {
        fillActionSlot(&m, &side, sequence, with: outcome) { resume in resume() }
    }

    /// `fillActionSlot` in a turn body whose resumes wait for the flush (§3.3: the waiter's
    /// removal and its outcome inline, the resume staged).
    private func fillActionSlot(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ sequence: Int64,
        with outcome: Result<InputOutcome, any Error>
    ) {
        fillActionSlot(&m, &side, sequence, with: outcome) { resume in outputs.stage(resume) }
    }

    /// The slot fill, with `resume` deciding when its continuations resume: inline (the call
    /// sites that resume at today's point, such as `cancelActionJob`'s ordered cancel) or staged.
    private func fillActionSlot(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ sequence: Int64,
        with outcome: Result<InputOutcome, any Error>,
        resume: (@escaping () -> Void) -> Void
    ) {
        if m.ticklessJobWork.remove(sequence) != nil {
            debugEndWork(&m, &side)
        }
        rememberFilledSlotForAssert(&m, sequence)
        side.probe?("action-slot-filled")
        guard m.actionSlots[sequence] != nil else { return }
        // The waiter leaves before the slot does: a slot holds at most one of a result and a
        // waiter. A waiting caller gets the value itself; only an unread result is held.
        if let waiter = side.actions.slotWaiters.removeValue(forKey: sequence) {
            m.actionSlots.removeValue(forKey: sequence)
            resume { waiter.resume(with: outcome) }
        } else {
            // `held` writes the model, and an optional-chain assignment begins its access to the
            // model before it evaluates its right side: run it first, or the two accesses overlap.
            let result = held(&m, &side, outcome)
            m.actionSlots[sequence]?.result = result
        }
        checkActionTables(&m, &side, #function)
        // The watchers leave inline; their wake is the resume.
        let watchers = takeSlotWatchers(&side, KeeperSlotWatchKey(waiter: false, sequence: sequence))
        if !watchers.isEmpty {
            resume { watchers.forEach { $0.yield(); $0.finish() } }
        }
    }

    /// The outcome of the job `submitAction` returned `.pending(sequence)` for: the ACK, or the
    /// rejection or resolver error. Read once; the slot is removed after, and a second read (or
    /// one for a sequence that had no job) throws `ActionResultUnavailable`.
    ///
    /// Cancelling the caller cancels the job's task through its box (no actor hop) and marks the job,
    /// so a completion that hasn't run yet fails with `CancellationError` instead of delivering.
    package func awaitActionResult(sequence: Int64) async throws -> InputOutcome {
        let box = turnSide.actions.jobTask(sequence)
        let callerCancelled = box?.callerCancelled
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InputOutcome, any Error>) in
                guard let slot = model.actionSlots[sequence], turnSide.actions.slotWaiters[sequence] == nil else {
                    continuation.resume(throwing: ActionResultUnavailable(sequence: sequence))
                    return
                }
                // Cancelled before the wait began: same segment as the check below, so a
                // completion can't run in between.
                if Task.isCancelled {
                    callerCancelled?.set()
                    box?.cancel()
                }
                if let result = slot.result {
                    model.actionSlots.removeValue(forKey: sequence)
                    let taken = taken(&model, &turnSide, result, path: .slot, sequence: sequence)
                    // After both the removal and the take.
                    checkActionTables(&model, &turnSide, #function)
                    continuation.resume(with: taken)
                    return
                }
                turnSide.actions.slotWaiters[sequence] = continuation
                checkActionTables(&model, &turnSide, #function)
                resumeSlotWatchers(KeeperSlotWatchKey(waiter: true, sequence: sequence))
            }
        } onCancel: {
            // Synchronous: once `cancel()` returns, a completion that hasn't run yet won't deliver.
            callerCancelled?.set()
            box?.cancel()
        }
    }

    /// Cancels the jobs whose ticket names the entry `generation` (a leave ended it). Only the
    /// ticket selects them, never the player or session key: a newer entry's jobs stay.
    private func cancelActionJobs(ofEntryGeneration generation: Epoch) {
        for (sequence, job) in model.actionJobs where job.ticket.entryGeneration == generation {
            cancelActionJob(&model, &turnSide, sequence)
        }
    }

    /// Cancels every job: the land is draining.
    private func cancelAllActionJobs(_ m: inout KeeperModel<State>, _ side: inout KeeperTurnSide) {
        for sequence in m.actionJobs.keys {
            cancelActionJob(&m, &side, sequence)
        }
    }

    /// The caller gets the delivery checks' rejection now (they also count and log it), not
    /// when the resolvers end; the job stays registered until its task ends.
    private func cancelActionJob(_ m: inout KeeperModel<State>, _ side: inout KeeperTurnSide, _ sequence: Int64) {
        // A completed job (kept only while its abandoned resolvers run) already has its outcome.
        guard let job = m.actionJobs[sequence], !job.cancelledByKeeper, !job.completed else { return }
        m.actionJobs[sequence]?.cancelledByKeeper = true
        let outcome: Result<InputOutcome, any Error>
        do {
            try validateDelivery(&m, of: job.item, ticket: job.ticket, input: job.input)
            // Unreachable from the two callers (a leave ended the entry, or the land drains).
            outcome = .failure(CancellationError())
        } catch {
            outcome = .failure(error)
        }
        let box = side.actions.jobTask(sequence)
        fillActionSlot(&m, &side, sequence, with: outcome)
        box?.cancel()
        checkActionTables(&m, &side, #function)
    }

    /// Test hook: the jobs still running and the slots not yet read.
    package func actionJobCountsForTesting() -> (jobs: Int, slots: Int, started: Int) {
        (model.actionJobs.count, model.actionSlots.count, model.actionJobsStarted)
    }

    /// Test hook: whether the slot of `sequence` holds its outcome, unread.
    package func actionSlotIsFilledForTesting(_ sequence: Int64) -> Bool {
        model.actionSlots[sequence]?.result != nil
    }

    /// Test hook: the in-flight work count `debugFreeze` waits on.
    package func debugInFlightWorkForTesting() -> Int {
        model.debugInFlightWork
    }

    /// Test hook: whether the land is frozen.
    /// Test hook, observation only: returns once a freeze is waiting for in-flight work (it
    /// registered its waiter, in the same segment that checked the work).
    package func waitUntilFreezeWaitsForTesting() async {
        guard turnSide.debugDrainWaiters.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            freezeWaitWatchersForTesting.append(continuation)
        }
    }

    /// Callers of `waitUntilFreezeWaitsForTesting` waiting for a freeze to wait.
    private var freezeWaitWatchersForTesting: [CheckedContinuation<Void, Never>] = []

    package func debugIsFrozenForTesting() -> Bool {
        model.debugFrozen
    }

    /// Test hook: whether an input drain is scheduled or running (`runInputDrain`).
    package func inputDrainScheduledForTesting() -> Bool {
        model.inputDrainScheduled
    }

    /// Callers of `waitForInputDrainIdleForTesting`, resumed when the drain ends.
    private var inputDrainIdleWaitersForTesting: [CheckedContinuation<Void, Never>] = []

    /// Test hook: returns once no input drain is scheduled or running, so the next input starts
    /// a drain of its own (and passes its `.inputDrain` hold).
    package func waitForInputDrainIdleForTesting() async {
        guard model.inputDrainScheduled else { return }
        await withCheckedContinuation { inputDrainIdleWaitersForTesting.append($0) }
    }

    /// Test hook: whether a caller waits on the slot of `sequence`.
    package func actionResultHasWaiterForTesting(_ sequence: Int64) -> Bool {
        turnSide.actions.slotWaiters[sequence] != nil
    }

    /// Test hook, observation only: registers a watcher on the slot of `sequence` in this call,
    /// and returns its stream. The stream yields once and finishes when the slot is filled
    /// (`waiter: false`) or a caller waits on it (`waiter: true`), or at once if that is already
    /// so. A test registers before it releases what fills the slot, so the event can't come
    /// first. A consumer that is cancelled ends its iteration, and the watcher is removed
    /// (`onTermination`), so a bound that cancels the consumer can't leave it behind.
    package func watchActionSlotForTesting(_ sequence: Int64, waiter: Bool) -> AsyncStream<Void> {
        let key = KeeperSlotWatchKey(waiter: waiter, sequence: sequence)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let already = waiter ? turnSide.actions.slotWaiters[sequence] != nil : model.actionSlots[sequence]?.result != nil
        if already {
            continuation.yield()
            continuation.finish()
            return stream
        }
        let id = UUID()
        turnSide.actions.slotWatchers[key, default: []].append((id: id, continuation: continuation))
        continuation.onTermination = { _ in Task { await self.removeSlotWatcherForTesting(key, id: id) } }
        return stream
    }

    private func removeSlotWatcherForTesting(_ key: KeeperSlotWatchKey, id: UUID) {
        guard var watchers = turnSide.actions.slotWatchers[key],
              let index = watchers.firstIndex(where: { $0.id == id }) else { return }
        watchers.remove(at: index)
        turnSide.actions.slotWatchers[key] = watchers.isEmpty ? nil : watchers
    }

    /// Removes the watchers of `key` and returns their continuations, to wake later.
    private func takeSlotWatchers(_ side: inout KeeperTurnSide, _ key: KeeperSlotWatchKey) -> [AsyncStream<Void>.Continuation] {
        guard !side.actions.slotWatchers.isEmpty else { return [] }
        return side.actions.slotWatchers.removeValue(forKey: key)?.map(\.continuation) ?? []
    }

    private func resumeSlotWatchers(_ key: KeeperSlotWatchKey) {
        guard !turnSide.actions.slotWatchers.isEmpty else { return }
        turnSide.actions.slotWatchers.removeValue(forKey: key)?.forEach {
            $0.continuation.yield()
            $0.continuation.finish()
        }
    }

    /// Test hook, observation only: waits until every job registered so far has left the job
    /// table through the production paths (its completion, or the release once its abandoned
    /// resolvers ended). It never releases a job itself; a job that is never released keeps it
    /// waiting, so callers bound it.
    package func waitForActionJobsForTesting() async {
        // Captured before the first await: the tables change while this waits.
        for (sequence, side) in turnSide.actions.jobTasks {
            let task = side.installedTask, abandonment = side.abandonment
            await task?.value
            await abandonment.waitUntilEnded()
            // The release is its own turn (`onEnded` hops to the keeper); wait for it without
            // spinning.
            guard model.actionJobs[sequence] != nil else { continue }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                turnSide.actions.removalWaiters[sequence, default: []].append(continuation)
            }
        }
    }

    /// Handles a player/client leaving the Land.
    ///
    /// If this is the player's last connection, the `OnLeave` handler is called.
    /// If the Land becomes empty, automatic shutdown may be scheduled.
    ///
    /// If the land starts draining while `OnLeave`'s resolvers run, the `OnLeave` input is
    /// dropped (and logged) and the leave returns normally: its caller isn't told. The player
    /// is removed either way.
    ///
    /// - Parameters:
    ///   - playerID: The player's unique identifier.
    ///   - clientID: The client instance identifier.
    public func leave(playerID: PlayerID, clientID: ClientID) async throws {
        try await leave(playerID: playerID, clientID: clientID, sessionID: nil)
    }

    /// `leave(playerID:clientID:)` for one session: when `sessionID` is given and the player's
    /// entry records a session, the leave applies only to that session. Client IDs are short and
    /// can collide, so a client's leave can't remove another client's entry that shares its ID.
    public func leave(playerID: PlayerID, clientID: ClientID, sessionID: SessionID?) async throws {
        try await ensureInitialized()
        await holds.at(.leave)
        guard let session = model.players[playerID] else {
            if behavior.logger.logLevel <= .debug {
                behavior.logger.debug("Leave called for player \(playerID.rawValue) but not found in players dictionary")
            }
            return
        }

        // Verify this is the correct client (should always match since we only allow one client per playerID)
        guard session.clientID == clientID else {
            if behavior.logger.logLevel <= .debug {
                behavior.logger.debug("Leave called for player \(playerID.rawValue) with mismatched clientID: expected=\(session.clientID?.rawValue ?? "nil"), received=\(clientID.rawValue)")
            }
            return
        }
        if let sessionID, let recorded = session.lastSessionID, recorded != sessionID {
            if behavior.logger.logLevel <= .debug {
                behavior.logger.debug("Leave called for player \(playerID.rawValue) with mismatched session: expected=\(recorded.rawValue), received=\(sessionID.rawValue)")
            }
            return
        }

        if behavior.logger.logLevel <= .debug {
            behavior.logger.debug("Player \(playerID.rawValue) leave: clientID=\(clientID.rawValue)")
        }

        // Since we only allow one client per playerID, always call OnLeave handler
        let deviceID = session.deviceID
        let isGuest = session.isGuest
        let metadata = session.metadata
        // The OnLeave resolvers get the outgoing entry's services, read before it goes.
        let outgoingServices = currentPlayerServices(of: playerID) ?? LandServices()
        model.players.removeValue(forKey: playerID)
        removePlayerServices(of: playerID, generation: session.generation)
        // Its pending actions can't be delivered any more (the ticket names this entry).
        cancelActionJobs(ofEntryGeneration: session.generation)

        // In reevaluation mode, replay viewers never ran OnJoin so skip OnLeave (no game state to clean).
        guard definition.lifetimeHandlers.onLeave != nil, behavior.config.mode != .reevaluation else {
            scheduleDestroyIfNeeded()
            return
        }

        behavior.logger.info("Player \(playerID.rawValue) leaving, enqueuing OnLeave lifecycle item")

        // Allocate sequence number (shared across Action + ClientEvent + ServerEvent + Lifecycle)
        let sequence = outputCollector.takeNextSequence()

        // Snapshot tick at request time; update after resolver completion for async determinism.
        var resolvedAtTick = model.lastCommittedTickId
        var resolverOutputs: [String: HeldResolverOutput] = [:]

        // Execute resolvers in parallel if any are declared
        if !definition.lifetimeHandlers.onLeaveResolverExecutors.isEmpty {
            var ctx = makeContext(&model,
                playerID: playerID,
                clientID: clientID,
                sessionID: session.lastSessionID ?? behavior.config.systemSessionID,
                servicesOverride: outgoingServices,
                deviceID: deviceID,
                isGuest: isGuest,
                metadata: metadata
            )
            let resolverContext = ResolverContext(
                landContext: ctx,
                actionPayload: nil,
                eventPayload: nil,
                currentState: model.state
            )
            do {
                ctx = try await ResolverExecutor.executeResolvers(
                    executors: definition.lifetimeHandlers.onLeaveResolverExecutors,
                    resolverContext: resolverContext,
                    landContext: ctx,
                    abandonment: resolverAbandonment(.onLeave)
                )
            } catch {
                // The player is already removed: its OnLeave is dropped (its sequence is a gap
                // replay steps over), and the player's game state stays behind.
                ResolverDeadline.metrics.noteOnLeaveDropped()
                behavior.logger.warning("OnLeave dropped: its resolvers failed", metadata: [
                    "playerID": .string(playerID.rawValue),
                    "error": .string("\(error)"),
                ])
                scheduleDestroyIfNeeded()
                throw error
            }
            resolverOutputs = ctx.getAllResolverOutputs()
            resolvedAtTick = model.lastCommittedTickId
        }

        // Same synchronous segment as the append: a drain that started during the resolvers
        // has taken the pending inputs and runs the destroy handlers, so this OnLeave is dropped
        // (its sequence is a gap replay steps over). The player was already removed.
        guard !isDraining else {
            behavior.logger.warning("OnLeave dropped: the land started closing during its resolvers", metadata: [
                "playerID": .string(playerID.rawValue),
            ])
            return
        }

        let pendingItem = PendingItem.lifecycle(
            PendingLifecycleItem(
                sequence: sequence,
                kind: .leave,
                playerID: playerID,
                clientID: clientID,
                sessionID: session.lastSessionID ?? behavior.config.systemSessionID,
                deviceID: deviceID,
                isGuest: isGuest,
                metadata: metadata,
                heldResolverOutputs: resolverOutputs,
                resolvedAtTick: resolvedAtTick
            )
        )
        model.pendingItems.append(pendingItem)

        // A tickless land applies it now, in an input turn the caller waits for.
        if definition.lifetimeHandlers.tickHandler == nil {
            _ = try await awaitInputTurn(sequence: sequence)
        }

        scheduleDestroyIfNeeded()
    }

    /// Shuts the land down now: the players still in it are cleared without OnLeave, the
    /// inputs not yet applied are dropped, and the destroy runs as for an empty land (#382).
    ///
    /// The clear, the drop and the drain flag are one keeper turn, the shutdown turn, recorded
    /// as the lifecycle event `"shutdown"`; replay stops at it.
    /// - Tickless: the shutdown is an input taken in arrival order. Inputs queued before it are
    ///   applied first (a leave with its OnLeave); inputs after it get `.landClosed`.
    /// - Tick land: no tick starts from the call on. The tick in flight finishes, then the
    ///   shutdown turn runs between ticks, as a frame of its own; the pending inputs would only
    ///   have applied in the next tick, so they are dropped. A join reaching intake after the
    ///   turn gets `.landShuttingDown`.
    ///
    /// A debug freeze is ended first, so held intake re-enters behind the shutdown and is
    /// rejected. Concurrent calls share one shutdown. If the empty-room drain has started (or
    /// starts before the turn), no shutdown turn runs and the call waits for that drain.
    ///
    /// Not to be awaited from inside this land's own tick or input turn (a resolver or handler
    /// waiting for its land's removal): it would wait for that turn.
    public func forceShutdown() async {
        try? await ensureInitialized()
        // A land shuts down once: the flight is never finished, so a later call waits for the
        // same (completed) task.
        let flight = forceShutdownFlight.flight(for: 0) { _ in
            Task { () async throws -> Void in await self.runForceShutdown() }
        }
        turnSide.probe?("force-shutdown-joined")
        _ = try? await SingleFlight<Int, Void>.value(of: flight)
        await holds.at(.forceShutdownReturn)
    }

    /// `forceShutdown`'s one flight.
    private var forceShutdownFlight = SingleFlight<Int, Void>()


    private func runForceShutdown() async {
        // No turn when the drain has started (the empty-room timer), the initialization failed
        // (#104), or in re-evaluation: as before, the players are cleared and the drain runs or
        // is awaited.
        guard drainTask == nil, !isDraining, model.initializationFailure == nil, behavior.config.mode == .live else {
            model.players.removeAll()
            playerServices.removeAll()
            model.rejoinReservations.removeAll()
            dropPendingInputs(&model, &turnSide, reason: "forceShutdown")
            await shutdownIfIdle(cause: .forceShutdown)
            return
        }
        // One synchronous segment: end a freeze (held intake then re-enters behind the
        // shutdown), then stop new ticks or queue the shutdown input.
        endDebugFreezeForShutdown()
        if definition.lifetimeHandlers.tickHandler != nil {
            model.shutdownRequested = true
            turnSide.probe?("shutdown-stop-gate")
            await waitForTickInFlight()
            // If the empty-room drain started during the wait, it is awaited instead.
            if drainTask == nil, !isDraining {
                await applyShutdownTurnBetweenTicks()
            }
        } else {
            let sequence = outputCollector.takeNextSequence()
            model.pendingItems.append(.shutdown(PendingShutdownItem(sequence: sequence, resolvedAtTick: model.lastCommittedTickId)))
            turnSide.probe?("shutdown-queued")
            scheduleInputDrain()
            // Until the turn has applied, or an empty-room drain that started first has dropped
            // the input (that drain is awaited below).
            await withCheckedContinuation { shutdownTurnWaiters.append($0) }
        }
        if model.shutdownTurnApplied { await holds.at(.shutdownTurnApplied) }
        await shutdownIfIdle(cause: .forceShutdown)
    }

    /// Tests only: what the empty-room timer runs when it fires.
    func runEmptyRoomShutdownForTesting() async {
        await shutdownIfIdle(cause: .emptyTimeout)
    }

    /// Ends a debug freeze for `forceShutdown`, as `debugResume` does, except that the server
    /// inputs accepted during the freeze stay out of the queue: the drain drops them, never
    /// applied, as it would without the shutdown turn. Held intake and `debugFreeze` waiters
    /// resume; the intake re-enters behind the shutdown input and is rejected.
    private func endDebugFreezeForShutdown() {
        guard let generation = model.debugActiveGeneration else { return }
        model.debugReleasedGeneration = max(model.debugReleasedGeneration, generation)
        model.debugActiveGeneration = nil
        model.debugFrozen = false
        let held = debugHeldInputs
        debugHeldInputs.removeAll()
        held.forEach { $0.resume() }
        let waiters = turnSide.debugDrainWaiters
        turnSide.debugDrainWaiters.removeAll()
        waiters.values.forEach { $0.resume() }
    }

    /// A tick land's shutdown turn (#382), between ticks: the stop gate is set and no tick is in
    /// flight. It is a frame of its own, the tick ID the next tick would have taken, holding
    /// only the shutdown. The turn changes no land state, so its state hash is the last tick's.
    private func applyShutdownTurnBetweenTicks() async {
        let record = withTurn { m, side, outputs in
            shutdownTurnBetweenTicksBody(&m, &side, &outputs)
        }
        guard let record else { return }
        await submitTurnRecord(record)
    }

    /// `applyShutdownTurnBetweenTicks`' turn body (#700 K1b-5a step 2). Its record, when this
    /// keeper records.
    private func shutdownTurnBetweenTicksBody(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs
    ) -> ReevaluationTickRecord? {
        let tickId = m.nextTickId
        m.nextTickId += 1
        let item = PendingItem.shutdown(PendingShutdownItem(
            sequence: outputCollector.takeNextSequence(),
            resolvedAtTick: m.lastCommittedTickId
        ))
        // A shutdown alone: no join to report.
        let applied = applyInputs(&m, &side, [item], executingTickId: tickId, reportJoins: { m, side, results in
            reportJoinsInTurn(&m, &side, &outputs, results)
        }).applied
        m.lastCommittedTickId = tickId
        guard reevaluationRecorder != nil else { return nil }
        var record = makeTurnRecord(tickId: tickId, applied: applied, emitted: [])
        if behavior.config.enableLiveStateHashRecording {
            record.stateHash = liveStateHash(&m, tickId: tickId).hash
        }
        return record
    }

    // MARK: - Action & Event Handling

    /// Handles an action envelope by decoding and dispatching to the registered handler.
    ///
    /// This is used by transport adapters that receive type-erased `ActionEnvelope` payloads.
    /// In `.live` mode, actions are queued and executed in ticks. In `.reevaluation` mode, returns immediately.
    ///
    /// `submitAction` followed by `awaitActionResult` for an action whose resolvers run in a job.
    public func handleActionEnvelope(
        _ envelope: ActionEnvelope,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async throws -> AnyCodable {
        // An awaiting caller holds its own wait: the action-job caps aren't applied, so direct
        // callers that send concurrently (tests, benchmarks) behave as before.
        switch try await submit(envelope, playerID: playerID, clientID: clientID, sessionID: sessionID, enforcingLimits: false) {
        case .completed(let outcome):
            return outcome.boundaryValue
        case .pending(let sequence):
            return try await awaitActionResult(sequence: sequence).boundaryValue
        }
    }

    /// Takes an action in: decodes it, runs the intake checks, takes its sequence and ticket.
    ///
    /// An action whose `resolvers:` closure builds at least one value becomes a job, on tick
    /// and tickless lands: its resolvers run in their own task, and the call returns `.pending`
    /// without waiting for them. The job's completion is a keeper turn (`completeAction`) that
    /// delivers the result like any input, and its outcome is kept in a slot created here,
    /// until `awaitActionResult` reads it.
    ///
    /// Every other action (no resolvers, or a closure that built no value) is delivered here
    /// and returns `.completed`: on a tickless land with the handler's response, after the
    /// input turn that applies it; on a tick land with an empty acknowledgement.
    ///
    /// A job is subject to the caps (`ActionJobLimits`): over one, the action is rejected at
    /// intake with `ActionLimitRejection`. A caller cancelled before it submits starts no job;
    /// an action delivered here is delivered whatever the caller's cancellation, as before.
    package func submitAction(
        _ envelope: ActionEnvelope,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async throws -> ActionSubmission {
        let submission: ActionSubmission
        do {
            submission = try await submit(envelope, playerID: playerID, clientID: clientID, sessionID: sessionID, enforcingLimits: true)
        } catch {
            await holds.at(.actionSubmitted)
            throw error
        }
        await holds.at(.actionSubmitted)
        return submission
    }

    private func submit(
        _ envelope: ActionEnvelope,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        enforcingLimits: Bool
    ) async throws -> ActionSubmission {
        try await ensureInitialized()
        // In re-evaluation mode, actions come from ReevaluationSource, not from transport.
        guard behavior.config.mode == .live else {
            // Return empty response in re-evaluation mode.
            return .completed(.none)
        }

        // Tickless lands apply actions immediately: hold them while frozen and count them as
        // in-flight work (resolvers included) so `debugFreeze` drains them. Tick lands only
        // queue the action here; ticks do not run while frozen.
        let isTickless = definition.lifetimeHandlers.tickHandler == nil
        if isTickless {
            try rejectIfLandClosed()
            await debugWaitWhileFrozen()
        }
        // The intake's segment (A1), in the same actor segment as the wait above: the work count
        // begins in it, with the append and the waiter's turn.
        let request = try withTurn { m, side, outputs in
            try actionIntakeBody(&m, &side, &outputs, envelope, playerID: playerID, clientID: clientID, sessionID: sessionID,
                                 enforcingLimits: enforcingLimits, isTickless: isTickless)
        }
        switch request {
        case .done(let submission):
            return submission
        case .awaitInputTurn(let sequence):
            // Tickless, delivered: an input turn applies it (with the other ready inputs) and
            // returns its response. The work count ends after it, on success and on a throw.
            defer { debugEndWork() }
            try rejectIfAppendedInputDropped(sequence)
            return .completed(try await awaitInputTurn(sequence: sequence))
        }
    }

    /// What the action intake's segment hands its driver (#700 K1b-5b, plan §4.4).
    private enum ActionIntakeRequest {
        /// Tickless and delivered: the driver awaits the input turn that applies it, then ends
        /// the work count the segment began.
        case awaitInputTurn(sequence: Int64)
        /// Answered without an await: a job started (`.pending`), or a tick land's ACK.
        case done(ActionSubmission)
    }

    /// The action intake's segment (A1): the handler lookup, the decode, the sender check, the
    /// limits, the sequence and the ticket, then the job's registration or the append. On a
    /// tickless land it begins the work count; a throw ends it here, and so does a job's
    /// registration hand it to the job (`ticklessJobWork`).
    private func actionIntakeBody(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ envelope: ActionEnvelope,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        enforcingLimits: Bool,
        isTickless: Bool
    ) throws -> ActionIntakeRequest {
        guard isTickless else {
            return try actionIntake(&m, &side, &outputs, envelope, playerID: playerID, clientID: clientID, sessionID: sessionID,
                                    enforcingLimits: enforcingLimits, isTickless: false)
        }
        debugBeginWork(&m)
        do {
            let request = try actionIntake(&m, &side, &outputs, envelope, playerID: playerID, clientID: clientID,
                                           sessionID: sessionID, enforcingLimits: enforcingLimits, isTickless: true)
            // Kept on return: a job's work ends when its response exists (`fillActionSlot`), a
            // delivered action's after its input turn (the driver).
            return request
        } catch {
            debugEndWork(&m, &side)
            throw error
        }
    }

    private func actionIntake(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ envelope: ActionEnvelope,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        enforcingLimits: Bool,
        isTickless: Bool
    ) throws -> ActionIntakeRequest {
        let typeIdentifier = envelope.typeIdentifier

        guard let handlerPosition = definition.actionHandlers.firstIndex(where: { handler in
            let actionType = handler.getActionType()
            let actionTypeName = String(describing: actionType)

            // Direct type name match (e.g., "AddGoldAction" == "AddGoldAction")
            if actionTypeName == typeIdentifier {
                return true
            }

            // Match last component (e.g., "Module.AddGoldAction" == "AddGoldAction")
            if actionTypeName.split(separator: ".").last == typeIdentifier.split(separator: ".").last {
                return true
            }

            // Match schema format (camelCase, without "Action" suffix)
            // e.g., "AddGoldAction" -> "AddGold" matches "AddGold"
            let schemaActionID = generateActionIDForMatching(from: actionType)
            if schemaActionID == typeIdentifier {
                return true
            }

            // Also support case-insensitive matching for backward compatibility
            if schemaActionID.lowercased() == typeIdentifier.lowercased() {
                return true
            }

            return false
        }) else {
            throw LandError.actionNotRegistered
        }
        let handler = definition.actionHandlers[handlerPosition]

        let actionType = handler.getActionType()
        guard let actionPayloadType = actionType as? any ActionPayload.Type else {
            throw LandError.actionNotRegistered
        }

        // Decoded once, here (#521): the apply step runs this value. The source refuses what
        // today's round trip refuses in the whole tree first, so nothing is refused at apply.
        let source = envelope.source
        try source.validateRecordable()
        let decodedAction = try source.decodeAction(actionPayloadType)
        // The bytes the record keeps (#700 K1a), only when something reads records: those of the
        // decoder this action was just decoded with.
        let recorded = recordsInputs ? try RecordedPayloadBytes(of: source) : nil

        // Intake segment: the sender check, the sequence and the ticket (the sender's entry
        // generation). After the resolvers' await, only `deliverResolvedAction` runs, which
        // validates the ticket against the current state and appends the input.
        try rejectIfLandClosed()
        try rejectSenderIfSuperseded(&m, playerID: playerID, clientID: clientID, sessionID: sessionID, input: typeIdentifier)
        // The resolver values are built first, here in the intake segment, from the State the
        // action is admitted against (#769 §3.2). The closure reads the State and must not mutate
        // it (a reference-backed State is not stopped from it). It runs for every admitted action
        // with resolvers, so also for one the job caps then refuse. An action whose closure built
        // no value (a cache hit) has nothing to wait for: it is delivered here, as an action
        // without resolvers, outside the job lane and its caps (#825).
        var job: (executors: [any AnyResolverExecutor], ctx: LandContext)?
        if let resolvers = handler.resolvers {
            let ctx = makeContext(&m,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                tickId: m.lastCommittedTickId
            )
            let executors = resolvers.build((m.state, decodedAction), ValidateContext(ctx))
            if !executors.isEmpty { job = (executors, ctx) }
        }
        let becomesJob = job != nil
        if becomesJob, enforcingLimits {
            try rejectIfOverActionJobLimits(m, sessionID: sessionID, input: typeIdentifier)
        }

        // Allocate sequence number (shared across Action + ClientEvent + ServerEvent)
        let sequence = outputCollector.takeNextSequence()
        let ticket = actionTicket(m, for: playerID, clientID: clientID)

        // An action with built resolver values runs them in a job (`startActionJob`), off the
        // caller's wait; one without is delivered here.
        if let job {
            // A cancelled caller's job is never started or delivered, as when its resolvers ran
            // in the caller's task: the job's task wouldn't inherit the cancellation. An action
            // delivered below isn't checked: one whose closure built nothing is handled like an
            // action without resolvers, which a cancelled caller's submit still delivers.
            try Task.checkCancellation()
            // A tickless job's work ends when its response exists (`fillActionSlot`).
            if isTickless { m.ticklessJobWork.insert(sequence) }
            startActionJob(&m, &side,
                PendingActionItem(
                    sequence: sequence,
                    decoded: .value(decodedAction),
                    handlerIndex: ActionHandlerIndex(handlerPosition),
                    recorded: recorded,
                    playerID: playerID,
                    clientID: clientID,
                    sessionID: sessionID,
                    heldResolverOutputs: [:],
                    resolvedAtTick: m.lastCommittedTickId
                ),
                executors: job.executors,
                ctx: job.ctx,
                ticket: ticket,
                input: typeIdentifier
            )
            return .done(.pending(sequence: sequence))
        }

        try deliverResolvedAction(&m, &side,
            PendingActionItem(
                sequence: sequence,
                decoded: .value(decodedAction),
                handlerIndex: ActionHandlerIndex(handlerPosition),
                recorded: recorded,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                heldResolverOutputs: [:],
                // Rebound to the tick current at delivery (`deliverResolvedAction`).
                resolvedAtTick: m.lastCommittedTickId
            ),
            ticket: ticket,
            input: typeIdentifier
        )

        // A tickless land's delivered action waits for the input turn that applies it; a tick
        // land's is acknowledged now (its handler runs in a tick).
        return isTickless ? .awaitInputTurn(sequence: sequence) : .done(.completed(.none))
    }

    /// Generate action ID for matching (same format as schema generation).
    ///
    /// Converts type name to camelCase action ID format (without "Action" suffix).
    /// Example: "AddGoldAction" -> "AddGold"
    private func generateActionIDForMatching(from actionType: Any.Type) -> String {
        // The schema's action rule (#521): one definition, so the IDs can't drift apart.
        payloadActionName(for: actionType)
    }

    /// Handles a client event from a player.
    ///
    /// In `.live` mode, a tick land queues the event for its next tick and returns. A tickless
    /// land applies it in an input turn and returns once that turn applied it, as `sendAction`
    /// does (#55). In `.reevaluation` mode, returns immediately.
    ///
    /// - Parameters:
    ///   - event: The client event (type-erased).
    ///   - playerID: The player sending the event.
    ///   - clientID: The client instance.
    ///   - sessionID: The session identifier.
    /// - Throws: Errors from event validation (e.g., event not registered)
    ///
    /// **Error Handling**:
    /// - On a tickless land, a handler's error is thrown to the caller, once: the event fails
    ///   alone and is not run again.
    /// - On a tick land a handler's error is logged where the event is applied (the tick); this
    ///   call has already returned.
    /// - The caller (TransportAdapter) sends a thrown error to the client.
    public func handleClientEvent(
        _ event: AnyClientEvent,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) async throws {
        try await ensureInitialized()
        // In re-evaluation mode, events come from ReevaluationSource, not from transport.
        guard behavior.config.mode == .live else {
            return
        }

        // Tickless lands apply events right away (in a task below): hold them while frozen.
        if definition.lifetimeHandlers.tickHandler == nil {
            try rejectIfLandClosed()
            await debugWaitWhileFrozen()
        }

        // The intake's segment (C1), in the same actor segment as the wait above.
        let awaited = try withTurn { m, side, _ in
            try clientEventIntake(&m, &side, event, playerID: playerID, clientID: clientID, sessionID: sessionID)
        }
        // A tickless land applies the event now, in an input turn the caller waits for, as an
        // action's caller does (#55): it returns once the event is applied, or throws the
        // handler's error. The segment registered the event and began its work count; the
        // count ends after the turn, on success and on a throw.
        if let sequence = awaited {
            defer { debugEndWork() }
            try rejectIfAppendedInputDropped(sequence)
            _ = try await awaitInputTurn(sequence: sequence)
        }
        // A tick land applies the event in its next tick.
    }

    /// The client event intake's segment (C1): the descriptor, the decode, the bytes, the sender
    /// check, the sequence and the append. On a tickless land it begins the event's work count
    /// and returns the sequence the driver waits for; nil on a tick land.
    private func clientEventIntake(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ event: AnyClientEvent,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID
    ) throws -> Int64? {
        // Check if event is registered in the client event registry
        guard let descriptor = definition.clientEventRegistry.findDescriptor(for: event.type) else {
            behavior.logger.error(
                "Client event type '\(event.type)' is not registered in ClientEvents { Register(...) }",
                metadata: [
                    "eventType": .string(event.type),
                    "landID": .string(definition.id),
                    "playerID": .string(playerID.rawValue),
                ]
            )
            throw LandError.eventNotRegistered
        }

        // One handler per event type (#586).
        guard definition.eventHandlers.contains(where: { $0.canHandle(descriptor.type) }) else {
            behavior.logger.error(
                "No handler found for client event type '\(event.type)'",
                metadata: [
                    "eventType": .string(event.type),
                    "landID": .string(definition.id),
                    "playerID": .string(playerID.rawValue),
                ]
            )
            throw LandError.eventNotRegistered
        }

        //
        // A descriptor with a decode keeps today's order: decode first, refusing a payload that
        // doesn't decode (#521, #537), then the bytes the record keeps (#700 K1a).
        // One without (the public descriptor init's) takes the bytes first, so their refusal of a
        // payload the record can't hold (too deep, a non-finite number) stays ahead of the decode,
        // as before. Then it decodes with the descriptor's type, as its handler did at apply, and
        // holds a failure as `.failed`: the event is recorded and dropped at apply, with no error
        // to the client, as before (#700 K1b-1, F11).
        func recordedBytes() throws -> RecordedPayloadBytes? {
            do {
                return recordsInputs ? try RecordedPayloadBytes(of: event.source) : nil
            } catch {
                throw ClientEventPayloadError(eventType: event.type, underlying: error)
            }
        }
        let payload: PendingClientEventPayload
        let recorded: RecordedPayloadBytes?
        if let decode = descriptor.decodeClientEvent {
            do {
                try event.source.validateRecordable()
                payload = .decoded(try decode(event.source))
            } catch {
                throw ClientEventPayloadError(eventType: event.type, underlying: error)
            }
            recorded = try recordedBytes()
        } else {
            recorded = try recordedBytes()
            payload = Self.decodeWithDescriptorType(descriptor, event.source)
        }

        try rejectIfLandClosed()
        try rejectSenderIfSuperseded(&m, playerID: playerID, clientID: clientID, sessionID: sessionID, input: event.type)

        // Allocate sequence number (shared across Action + ClientEvent + ServerEvent)
        let sequence = outputCollector.takeNextSequence()

        // Bind event to lastCommittedTickId for replay logging
        let resolvedAtTick = m.lastCommittedTickId

        // Create pending item and add to queue
        let pendingItem = PendingItem.clientEvent(
            PendingClientEventItem(
                sequence: sequence,
                typeIdentifier: event.type,
                payload: payload,
                recorded: recorded,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                resolvedAtTick: resolvedAtTick
            )
        )
        m.pendingItems.append(pendingItem)

        guard definition.lifetimeHandlers.tickHandler == nil else { return nil }
        // Counted as in-flight from now until the event is applied, so `debugFreeze` drains it.
        debugBeginWork(&m)
        // The waiter is registered right after this segment, before any suspension, so a drain
        // started by another input can't apply the event before anyone waits for it. The probe
        // is synchronous: a test learns the event is queued without a suspension between the
        // append and the waiter's registration.
        side.probe?("client-event-queued")
        return sequence
    }

    // MARK: - Server inputs (#387)

    /// Submits a server input: a value the server delivers to the land as a turn input, outside
    /// any client (the result of work a turn requested, for example).
    ///
    /// In one synchronous segment it checks the land can take it, takes the input's sequence from
    /// the counter actions and client events use, and queues it; the keeper applies it in a turn
    /// of its own, in `(resolvedAtTick, sequence)` order with the land's other inputs, with the
    /// system identity, and records it. It returns without waiting for that turn.
    ///
    /// - Returns: `.accepted(sequence:)`, or `.refused(_)` with nothing queued: the keeper isn't
    ///   live, the land declares no `HandleServerInput` for `I`, it is draining, the input has no
    ///   record form or its record form doesn't decode back to `I` (`.unencodable`), or the land
    ///   already holds `SERVER_INPUT_IN_FLIGHT_MAX_PER_LAND` unapplied server inputs. A debug
    ///   freeze doesn't refuse: the input is held and applied after the resume.
    public func submitServerInput<I: ServerInputPayload>(_ input: I) async -> ServerInputOutcome {
        await submitServerInputErased(input)
    }

    private func submitServerInputErased(_ input: any ServerInputPayload) async -> ServerInputOutcome {
        do {
            try await ensureInitialized()
        } catch {
            return .refused(.draining)
        }
        // From here to the append, one synchronous segment (S1).
        return withTurn { m, _, _ in serverInputIntake(&m, input) }
    }

    /// The server input intake's segment (S1): the checks, the decode, the sequence and the
    /// append, or the hold while frozen. Exempt from the freeze; its kick starts the turn.
    private func serverInputIntake(_ m: inout KeeperModel<State>, _ input: any ServerInputPayload) -> ServerInputOutcome {
        guard behavior.config.mode == .live else { return .refused(.notLive) }
        let typeIdentifier = String(describing: type(of: input))
        // Declared by identity, not by name alone: a same-named type from another module or
        // scope isn't the declared one.
        guard let handler = definition.serverInputHandlers[typeIdentifier],
              ObjectIdentifier(handler.inputType) == ObjectIdentifier(type(of: input))
        else { return .refused(.unknownType) }
        guard !isDraining else { return .refused(.draining) }
        // Live applies the form the record holds, so replay applies the same value (#387).
        let bytes: Data
        do {
            bytes = try ServerInputCodec.recordedForm(of: input)
        } catch {
            behavior.logger.error("Server input refused: its payload has no record form", metadata: [
                "landID": .string(behavior.config.actualLandID ?? definition.id),
                "inputType": .string(typeIdentifier),
                "error": .string("\(error)"),
            ])
            return .refused(.unencodable)
        }
        if serverInputMaxInFlight > 0, m.serverInputsInFlight >= serverInputMaxInFlight {
            m.serverInputCapRejections += 1
            behavior.logger.debug("Server input refused: the land's in-flight limit is reached", metadata: [
                "landID": .string(behavior.config.actualLandID ?? definition.id),
                "inputType": .string(typeIdentifier),
                "limit": .stringConvertible(serverInputMaxInFlight),
            ])
            return .refused(.overCap)
        }
        // Decoded once, here: the value live applies is the one replay decodes from the record.
        // After the cap, so an input refused for the cap costs no decode; before the sequence, so
        // a refused input leaves no gap in it.
        let decoded: any ServerInputPayload
        do {
            decoded = try handler.decode(bytes)
        } catch {
            behavior.logger.error("Server input refused: its record form doesn't decode back to its type", metadata: [
                "landID": .string(behavior.config.actualLandID ?? definition.id),
                "inputType": .string(typeIdentifier),
                "error": .string("\(error)"),
            ])
            return .refused(.unencodable)
        }

        let sequence = outputCollector.takeNextSequence()
        let item = PendingItem.serverInput(PendingServerInputItem(
            sequence: sequence,
            typeIdentifier: typeIdentifier,
            bytes: bytes,
            decoded: .value(decoded),
            resolvedAtTick: m.lastCommittedTickId
        ))
        m.serverInputsInFlight += 1
        // A debug freeze doesn't refuse: the input keeps its sequence and waits outside the
        // queue until the resume. In the queue, a drain or pass already running would apply it
        // (they apply every ready input and don't stop for a freeze).
        if m.debugFrozen {
            m.serverInputsHeldWhileFrozen.append(item)
            return .accepted(sequence: sequence)
        }
        m.pendingItems.append(item)
        kickServerInputTurn(&m, upTo: sequence)
        return .accepted(sequence: sequence)
    }


    /// A tickless land applies server inputs in an input turn, as it does client events: a task,
    /// counted as in-flight work from now (`debugFreeze` drains it), that waits for the turn
    /// applying `sequence`. A tick land's next tick applies them.
    private func kickServerInputTurn(upTo sequence: Int64) {
        kickServerInputTurn(&model, upTo: sequence)
    }

    /// `kickServerInputTurn(upTo:)` on the model a turn body holds. The work count begins
    /// inline; the task starts inline too, as before: it reaches the keeper only through an
    /// await, so nothing of it runs on the keeper before the segment ends.
    private func kickServerInputTurn(_ m: inout KeeperModel<State>, upTo sequence: Int64) {
        guard definition.lifetimeHandlers.tickHandler == nil else { return }
        debugBeginWork(&m)
        Task { [weak self] in
            guard let self else { return }
            await self.holds.at(.serverInputKick)
            _ = try? await self.awaitInputTurn(sequence: sequence)
            await self.debugEndWork()
        }
    }

    /// At the resume: queues the server inputs accepted during the freeze and starts their turn.
    private func releaseServerInputsHeldWhileFrozen() {
        guard !model.serverInputsHeldWhileFrozen.isEmpty else { return }
        let held = model.serverInputsHeldWhileFrozen
        model.serverInputsHeldWhileFrozen.removeAll()
        model.pendingItems.append(contentsOf: held)
        if let last = held.last { kickServerInputTurn(upTo: last.sequence) }
    }

    /// When the land drains: the server inputs held during a freeze are never applied.
    private func dropServerInputsHeldWhileFrozen(_ m: inout KeeperModel<State>) {
        guard !m.serverInputsHeldWhileFrozen.isEmpty else { return }
        m.serverInputsInFlight -= m.serverInputsHeldWhileFrozen.count
        behavior.logger.info("Server inputs dropped: the land is closing during a debug freeze", metadata: [
            "dropped": .stringConvertible(m.serverInputsHeldWhileFrozen.count),
        ])
        m.serverInputsHeldWhileFrozen.removeAll()
    }

    /// Tests only: overrides `SERVER_INPUT_IN_FLIGHT_MAX_PER_LAND` for this keeper.
    package func setServerInputMaxInFlightForTesting(_ limit: Int) {
        serverInputMaxInFlight = limit
    }

    /// Tests only: server inputs submitted and not yet applied.
    package func serverInputsInFlightForTesting() -> Int {
        model.serverInputsInFlight
    }

    /// The submitter handed to handlers in `LandContext.serverInputs`: it holds this keeper
    /// weakly, so a submit after the keeper is gone is refused instead of keeping it alive.
    private nonisolated var serverInputSubmitter: ServerInputSubmitter {
        ServerInputSubmitter { [weak self] input in
            guard let self else { return .refused(.draining) }
            return await self.submitServerInputErased(input)
        }
    }

    // MARK: - Helpers

    /// The context a resolver group runs with: the land's services value for `Resolver` values
    /// (#769), and today's fields for the `ContextResolver`s of CanJoin, OnJoin and OnLeave.
    private func makeResolverContext(_ ctx: LandContext) -> ResolverContext {
        makeResolverContext(model, ctx)
    }

    /// `makeResolverContext(_:)` on the model a turn body holds.
    private func makeResolverContext(_ m: KeeperModel<State>, _ ctx: LandContext) -> ResolverContext {
        var resolverContext = ResolverContext(landContext: ctx, currentState: m.state)
        resolverContext.resolverServices = behavior.resolverServices
        return resolverContext
    }

    private func makeContext(
        _ m: inout KeeperModel<State>,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        servicesOverride: LandServices? = nil,
        deviceID: String? = nil,
        isGuest: Bool? = nil,
        metadata: [String: String] = [:],
        tickId: Int64? = nil,
        resolverOutputs: [String: HeldResolverOutput] = [:]
    ) -> LandContext {
        let baseServices = servicesOverride ?? LandServices()
        // One lookup of the entry: its services are the table's only for its generation.
        let playerSession = m.players[playerID]
        let playerServices = playerSession.flatMap { currentPlayerServices(of: playerID, entry: $0) }
        // A `DeterministicRngService` registered in an override or in a player's services is
        // removed too, so no context or resolver reaches an RNG instance: handlers draw from the
        // one `withHandlerStep` binds.
        let resolvedServices = behavior.services.merging(baseServices).merging(playerServices ?? LandServices())
            .removing(DeterministicRngService.self)
        // Use actual land instance ID if available, otherwise fall back to definition.id (land type)
        let landID = behavior.config.actualLandID ?? definition.id
        let eventRecordingTickId = tickId ?? m.lastCommittedTickId
        let collector = outputCollector
        return LandContext(
            landID: landID,
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            services: resolvedServices,
            logger: behavior.logger,
            deviceID: deviceID ?? playerSession?.deviceID,
            isGuest: isGuest ?? playerSession?.isGuest ?? false,
            metadata: metadata.isEmpty ? (playerSession?.metadata ?? [:]) : metadata,
            tickId: tickId,
            emitEventHandler: { anyEvent, target in
                collector.enqueueEmittedEvent(anyEvent, to: target, tickId: eventRecordingTickId)
            },
            requestSyncNowHandler: {
                collector.requestSyncNow(tickId: eventRecordingTickId)
            },
            requestSyncBroadcastOnlyHandler: {
                collector.requestSyncBroadcastOnly(tickId: eventRecordingTickId)
            },
            resolverOutputs: resolverOutputs,
            serverInputs: serverInputSubmitter
        )
    }

    /// Where a handler call's `ctx.random` draws from.
    enum HandlerRandom {
        /// The land's generator: a handler that replay repeats from the record. The draws are
        /// written back to `landRandom` when the call returns.
        case step
        /// A service that isn't written back: a handler that replay doesn't repeat (CanJoin,
        /// the sync handler, the drain's handlers).
        case detached(DeterministicRngService)
    }

    /// Runs a handler on the model's state, in place, with `ctx.random` bound for this call:
    /// handlers are synchronous, so the body can't suspend and the model is mutated directly.
    ///
    /// The body gets the model `inout`, once per step, and passes `&m.state` to the handler: the
    /// access covers the whole model, so the body reaches any other field through `m`, never
    /// through `model`, and nothing the handler calls may read the keeper's model (a dynamic
    /// exclusivity trap, in release builds too). Calls don't nest.
    ///
    /// `m` is the model its caller holds: an input turn's body passes its own binding (#700
    /// K1b-5a), other callers `&model`. With `.step`, the service is built from `m.landRandom`
    /// and its generator is written back in the same segment, after the body returns; a `defer`
    /// keeps draws made before a throw.
    ///
    /// Handlers throw only from `validate`, before they write: the input handlers (#586) and
    /// OnInitialize (#593). The destroy handlers don't throw.
    private func withHandlerStep<R>(
        _ m: inout KeeperModel<State>,
        _ ctx: LandContext,
        random: HandlerRandom = .step,
        dropsOutputs: Bool = false,
        _ body: (inout KeeperModel<State>, LandContext) throws -> R
    ) rethrows -> R {
        switch random {
        case .detached(let service):
            let (bound, scope) = openStepScope(ctx, random: service, dropsOutputs: dropsOutputs)
            defer { scope.close() }
            return try body(&m, bound)
        case .step:
            let service = DeterministicRngService(continuing: m.landRandom, seed: behavior.config.landRandomSeed)
            let (bound, scope) = openStepScope(ctx, random: service, dropsOutputs: dropsOutputs)
            // After the body's access to the model ends: it doesn't overlap.
            defer {
                scope.close()
                m.landRandom = service.generator
            }
            return try body(&m, bound)
        }
    }

    /// Opens a handler call's scope (#700 K2-E) and binds it to a copy of `ctx`; the caller
    /// closes it when the handler returns. Outputs made through the copy before the close go
    /// where they go today, numbered at emit time; later ones are dropped and counted in
    /// `lateStepOutputs`. With `dropsOutputs` (a destroy handler, #893), every output is dropped
    /// and counted in `destroyHandlerOutputsDropped`.
    private func openStepScope(
        _ ctx: LandContext,
        random: DeterministicRngService,
        dropsOutputs: Bool = false
    ) -> (LandContext, StepScope) {
        let scope = StepScope(
            random: random,
            late: lateStepOutputs,
            assertsOnLateOutput: lateStepOutputAssertsForTesting,
            dropsOutputs: dropsOutputs ? destroyHandlerOutputsDropped : nil
        )
        var bound = ctx
        bound.stepScope = scope
        return (bound, scope)
    }

    /// Outputs dropped because their `LandContext` outlived its handler call (#700 K2-E).
    package nonisolated let lateStepOutputs = LateStepOutputCounter()

    /// The destroy handlers' outputs (OnDestroyWhenEmpty, OnFinalize, AfterFinalize), all
    /// dropped (#893). They run after the drain began, when no tick, sync or input turn will
    /// take an event or a sync request again.
    package nonisolated let destroyHandlerOutputsDropped = LateStepOutputCounter()

    /// Whether a late output stops a debug build. Tests that pin the drop turn it off.
    private var lateStepOutputAssertsForTesting = true

    /// Tests only: lets a late output be dropped and counted without stopping a debug build.
    func setLateStepOutputAssertsForTesting(_ asserts: Bool) {
        lateStepOutputAssertsForTesting = asserts
    }

    /// A service for a handler that replay doesn't repeat: a copy of the land's generator,
    /// never written back.
    private func detachedRandom() -> DeterministicRngService {
        detachedRandom(model)
    }

    private func detachedRandom(_ m: KeeperModel<State>) -> DeterministicRngService {
        DeterministicRngService(continuing: m.landRandom, seed: behavior.config.landRandomSeed)
    }

    // MARK: - Tick & Lifetime

    /// Ensure tick ID is advanced for tickless lands (no tick handler)
    /// This prevents all records from ending up with tickId = -1
    private func ensureTickIdForTicklessLand() {
        // Advance tick counter to ensure records use a valid tick ID
        // Use max(lastCommittedTickId+1, 0) to ensure non-negative tick IDs
        if model.nextTickId <= model.lastCommittedTickId {
            model.nextTickId = max(model.lastCommittedTickId + 1, 0)
        }
    }

    /// Offsets the tick and sync loops captured when they were configured (nil: not started).
    private(set) var appliedTickPhaseOffset: Duration?

    /// When the tick loop was last configured: the reference its phase offset and first
    /// interval are measured from (tests).
    private(set) var tickLoopConfiguredAt: ContinuousClock.Instant?
    private(set) var appliedSyncPhaseOffset: Duration?

    /// Delay before the first iteration of a loop with `interval`: `LandLoopPhase.offset` of
    /// this land's instance ID, or `.zero` when disabled. A keeper created without `landID:`
    /// uses the land type.
    func loopPhaseOffset(interval: Duration) -> Duration {
        guard behavior.config.enableLoopPhaseOffset else { return .zero }
        return LandLoopPhase.offset(landID: behavior.config.actualLandID ?? definition.id, interval: interval)
    }

    /// The clock the tick loop reads and sleeps on: `TickLoopClock.forNewKeepers` when this
    /// keeper was created (the continuous clock, unless a test bound a manual one).
    private let tickLoopClock = TickLoopClock.forNewKeepers

    private func configureTickLoop(interval: Duration) async {
        tickTask?.cancel()
        let phaseOffset = loopPhaseOffset(interval: interval)
        let clock = tickLoopClock
        appliedTickPhaseOffset = phaseOffset
        tickLoopConfiguredAt = clock.now()
        tickTask = Task { [weak self] in
            if phaseOffset > .zero {
                await clock.sleepFor(phaseOffset)
            }
            guard let self = self else { return }

            var nextTickTime = clock.now() + interval
            await self.noteNextTickDeadline(nextTickTime)

            while !Task.isCancelled {
                // If we're already past the scheduled time, execute immediately
                // Otherwise, sleep until the scheduled time
                if clock.now() < nextTickTime {
                    await clock.sleepUntil(nextTickTime)
                }

                await self.runTick(allowWhenNoTickTask: false)

                // Fixed-rate scheduling: calculate next time from the scheduled time, not from now
                // This maintains a consistent tick rate even if execution takes longer than interval
                // If execution time exceeds interval, we skip ahead to maintain the rate
                nextTickTime = nextTickTime + interval

                // If we're still behind schedule after skipping, continue skipping
                // This prevents the loop from getting stuck if execution time consistently exceeds interval
                while nextTickTime <= clock.now() {
                    nextTickTime = nextTickTime + interval
                }
                await self.noteNextTickDeadline(nextTickTime)
            }
        }
    }

    private func noteNextTickDeadline(_ deadline: ContinuousClock.Instant) {
        nextTickDeadline = deadline
    }

    /// Manually execute a single tick (for deterministic tests/tools).
    ///
    /// This bypasses the internal tick loop guard and allows stepping a land deterministically
    /// without relying on wall-clock time.
    ///
    /// With in-turn sync this is one tick turn: ready inputs, the tick handler,
    /// the emitted events and, only when a sync is due (coincident-sync rule) or a handler
    /// requested one, the sync phase. The phase can be deferred by writer back-pressure, and
    /// returning does not mean the writer has sent the frames. On a tickless land it runs the
    /// ready inputs as input turns; when an input drain is already scheduled but has not run
    /// yet, it can return before those inputs are applied (the drain applies them).
    public func stepTickOnce() async {
        guard (try? await ensureInitialized()) != nil else { return }
        await runTick(allowWhenNoTickTask: true)
    }

    /// What applying pending items produced, for recording and output.
    private struct AppliedInputs {
        let executingTickId: Int64
        var recordedActions: [ReevaluationRecordedAction] = []
        var recordedClientEvents: [ReevaluationRecordedClientEvent] = []
        var recordedLifecycleEvents: [ReevaluationRecordedLifecycleEvent] = []
        var recordedServerInputs: [ReevaluationRecordedServerInput] = []
        /// The recorded inputs' sequences in apply order, across the four lists (a tickless
        /// land's pass, `ReevaluationRecordedPass`).
        var appliedOrder: [Int64] = []
        /// A leave ran: the legacy path follows with a broadcast-only sync.
        var shouldSyncBroadcastOnly = false
        /// The inputs whose handler refused them (`validate` threw), in apply order (#586).
        var rejected: [Int64] = []

        init(executingTickId: Int64) {
            self.executingTickId = executingTickId
        }

        var isEmpty: Bool {
            recordedActions.isEmpty && recordedClientEvents.isEmpty && recordedLifecycleEvents.isEmpty
                && recordedServerInputs.isEmpty
        }
    }

    private enum AppliedItem {
        case action(response: any ResponsePayload)
        case other
        case skipped
    }

    /// Tests: what `applyPendingItemForTesting` applied.
    package struct AppliedItemForTesting {
        package let isSkipped: Bool
        package let recordedActions: [ReevaluationRecordedAction]
    }

    /// Tests: one input turn on `batch` (hand-built items, not taken from the queue), as the
    /// live drain runs one, then the waiters' step that clears the turn's outcomes. Returns the
    /// turn's recorded actions.
    package func runInputTurnForTesting(_ batch: [PendingItem]) -> [ReevaluationRecordedAction] {
        let outcome = runInputTurn(batch, removingFromQueue: false)
        resumeInputTurnWaiters(for: outcome.appliedItems)
        return outcome.record.actions
    }

    /// Tests: runs the real `applyPendingItem` on one item, outside a turn, into a fresh
    /// `AppliedInputs` at the last committed tick.
    package func applyPendingItemForTesting(_ item: PendingItem) throws -> AppliedItemForTesting {
        var applied = AppliedInputs(executingTickId: max(model.lastCommittedTickId, 0))
        let outcome = try applyPendingItem(&model, item, executingTickId: applied.executingTickId, into: &applied)
        if case .skipped = outcome {
            return AppliedItemForTesting(isSkipped: true, recordedActions: applied.recordedActions)
        }
        return AppliedItemForTesting(isSkipped: false, recordedActions: applied.recordedActions)
    }

    /// The tick a tickless drain (or a pending-items pass) records under: `nextTickId - 1`,
    /// advancing `nextTickId` first when no tick has been taken yet, so records never use -1.
    private func executingTickIdForPendingItems(_ m: inout KeeperModel<State>) -> Int64 {
        var executingTickId = m.nextTickId - 1
        if executingTickId < 0 {
            m.nextTickId = max(m.lastCommittedTickId + 1, 0)
            executingTickId = m.nextTickId - 1
            // If still negative (lastCommittedTickId was -1), use 0
            if executingTickId < 0 {
                m.nextTickId = 1
                executingTickId = 0
            }
        }
        return executingTickId
    }

    /// The pending items ready to execute (`resolvedAtTick < nextTickId`), in execution order:
    /// by `resolvedAtTick`, then by sequence.
    private func readyPendingItemsInOrder(_ m: KeeperModel<State>) -> [PendingItem] {
        m.pendingItems
            .filter { $0.resolvedAtTick < m.nextTickId }
            .sorted { lhs, rhs in
                if lhs.resolvedAtTick != rhs.resolvedAtTick {
                    return lhs.resolvedAtTick < rhs.resolvedAtTick
                }
                return lhs.sequence < rhs.sequence
            }
    }

    /// Removes `items` from the pending queue (by sequence).
    private func removePendingItems(_ m: inout KeeperModel<State>, _ items: [PendingItem]) {
        guard !items.isEmpty else { return }
        let executedSequences = Set(items.map(\.sequence))
        m.pendingItemScans += m.pendingItems.count
        m.pendingItems.removeAll { executedSequences.contains($0.sequence) }
    }


    /// Tests only: `pendingItemScans` so far.
    func pendingItemScansForTesting() -> Int {
        model.pendingItemScans
    }

    /// Tests only: removes the queued input with `sequence` (a queue changed across an await).
    func removePendingItemForTesting(sequence: Int64) {
        model.pendingItems.removeAll { $0.sequence == sequence }
    }

    /// Applies one pending item to the state (synchronous) and appends its record to `applied`.
    /// The record is appended before the handler runs, so an item whose `validate` throws is
    /// recorded too (replay refuses it the same way); the error propagates to `applyInputs`.
    private func applyPendingItem(
        _ m: inout KeeperModel<State>,
        _ item: PendingItem,
        executingTickId: Int64,
        into applied: inout AppliedInputs,
        preparedRecordBytes: [Int64: Result<Data, any Error>] = [:]
    ) throws -> AppliedItem {
        // A server input leaves the in-flight count once it is taken out to apply, whatever the
        // outcome (replay's items were never counted).
        if case .serverInput = item, m.serverInputsInFlight > 0 {
            m.serverInputsInFlight -= 1
        }
        if skipsAfterDestroy(&m, item) { return .skipped }
        switch item {
        case let .action(actionItem):
            // The handler at the item's position (#700 K1b-1, F9); a hand-built item's is found
            // by its value's type.
            let handler: AnyActionHandler<State>
            if let index = actionItem.handlerIndex {
                guard definition.actionHandlers.indices.contains(index.position) else {
                    behavior.logger.error("Handler index out of range", metadata: [
                        "sequence": .stringConvertible(actionItem.sequence),
                        "position": .stringConvertible(index.position),
                    ])
                    return .skipped
                }
                handler = definition.actionHandlers[index.position]
            } else {
                let valueType = type(of: try actionItem.decoded.get())
                guard let found = definition.actionHandlers.first(where: { $0.canHandle(valueType) }) else {
                    behavior.logger.error("Handler not found for action type", metadata: [
                        "actionType": .string(String(describing: valueType)),
                    ])
                    return .skipped
                }
                handler = found
            }

            // Decoded at intake (#521), or when replay built the item (#700 K1a). A recorded
            // payload that didn't decode throws here, before the record, where its decode threw.
            let decodedAction = try actionItem.decoded.get()

            // Create context with resolver outputs
            let ctx = makeContext(&m,
                playerID: actionItem.playerID,
                clientID: actionItem.clientID,
                sessionID: actionItem.sessionID,
                tickId: executingTickId,
                resolverOutputs: actionItem.heldResolverOutputs
            )

            // Recorded before the handler runs: an input whose `validate` throws is recorded too, so
            // replay runs it again and it fails the same way (`applyInputs`). Built only when
            // something reads records (#521): the payload's tree may have to be built for it.
            if recordsInputs {
                let resolverOutputsDict = actionItem.heldResolverOutputs.recordedEntries
                applied.recordedActions.append(ReevaluationRecordedAction(
                    kind: "action",
                    sequence: actionItem.sequence,
                    typeIdentifier: String(describing: handler.getActionType()),
                    payload: try actionItem.recorded?.bytes
                        ?? Self.recordBytes(actionItem.sequence, prepared: preparedRecordBytes) { try Self.fallbackRecordBytes(decodedAction) },
                    payloadEncoding: actionItem.recorded?.encoding ?? .json,
                    playerID: actionItem.playerID.rawValue,
                    clientID: actionItem.clientID.rawValue,
                    sessionID: actionItem.sessionID.rawValue,
                    resolverOutputs: resolverOutputsDict,
                    resolvedAtTick: actionItem.resolvedAtTick
                ))
            }
            applied.appliedOrder.append(actionItem.sequence)

            // Execute handler and capture response
            // Throws only from the type check or `validate`, before anything is written (#586).
            let response = try withHandlerStep(&m, ctx) { m, ctx in
                try handler.invokeTyped(&m.state, action: decodedAction, ctx: ctx)
            }
            return .action(response: response)



        case let .clientEvent(eventItem):
            // Find handlers for this event type
            guard let descriptor = definition.clientEventRegistry.findDescriptor(for: eventItem.typeIdentifier) else {
                behavior.logger.error("Event descriptor not found", metadata: [
                    "eventType": .string(eventItem.typeIdentifier),
                ])
                return .skipped
            }

            // One handler per event type (#586).
            guard let handler = definition.eventHandlers.first(where: { $0.canHandle(descriptor.type) }) else {
                behavior.logger.error("No handler found for client event", metadata: [
                    "eventType": .string(eventItem.typeIdentifier),
                ])
                return .skipped
            }

            // Create context (client events don't have resolver outputs)
            let ctx = makeContext(&m,
                playerID: eventItem.playerID,
                clientID: eventItem.clientID,
                sessionID: eventItem.sessionID,
                tickId: executingTickId,
                resolverOutputs: [:]
            )

            // Recorded before the handlers run (see the action case).
            if recordsInputs {
                applied.recordedClientEvents.append(ReevaluationRecordedClientEvent(
                    kind: "clientEvent",
                    sequence: eventItem.sequence,
                    typeIdentifier: eventItem.typeIdentifier,
                    payload: try eventItem.recorded?.bytes
                        ?? Self.recordBytes(eventItem.sequence, prepared: preparedRecordBytes) { try Self.fallbackRecordBytes(eventItem.payload) },
                    payloadEncoding: eventItem.recorded?.encoding ?? .json,
                    playerID: eventItem.playerID.rawValue,
                    clientID: eventItem.clientID.rawValue,
                    sessionID: eventItem.sessionID.rawValue,
                    resolvedAtTick: eventItem.resolvedAtTick
                ))
            }
            applied.appliedOrder.append(eventItem.sequence)

            // An event runs the value decoded at intake (#521) or when replay built it (#700 K1a).
            // A payload that didn't decode is dropped, as its handler dropped it (#362 counts a
            // too-deep one), without entering the state wrapper: only a handler call does
            // (#700 K1b-1, S6).
            let decoded: any ClientEventPayload
            switch eventItem.payload {
            case .decoded(let value):
                decoded = value
            case .failed(let failure):
                if case .tooDeep(let limit) = failure {
                    PayloadNesting.noteDroppedClientEvent(
                        type: String(describing: handler.handledType), PayloadNesting.TooDeep(limit: limit)
                    )
                }
                return .other
            }
            // Throws only from `validate`, before anything is written (#586).
            var ranHandler = true
            try withHandlerStep(&m, ctx) { m, ctx in
                ranHandler = try handler.invokeDecoded(&m.state, event: decoded, ctx: ctx)
            }
            if !ranHandler {
                // A hand-built handler whose type differs from its descriptor's: skipped, as when
                // the handler decoded it (A7's land stop comes with A8's registration refusal).
                behavior.logger.error("Client event skipped: its handler's type differs from its descriptor's", metadata: [
                    "eventType": .string(eventItem.typeIdentifier),
                    "handlerType": .string(String(describing: handler.handledType)),
                ])
            }

        case let .serverInput(inputItem):
            guard let handler = definition.serverInputHandlers[inputItem.typeIdentifier] else {
                // Only replay gets here: live refuses an undeclared type at submit.
                behavior.logger.warning("Server input skipped: the land declares no handler for its type", metadata: [
                    "inputType": .string(inputItem.typeIdentifier),
                    "sequence": .stringConvertible(inputItem.sequence),
                ])
                return .skipped
            }
            let ctx = makeContext(&m,
                playerID: LandContext.systemPlayerID,
                clientID: LandContext.systemClientID,
                sessionID: LandContext.systemSessionID,
                tickId: executingTickId
            )
            // Recorded before the handlers run (see the action case).
            let recorded = ReevaluationRecordedServerInput(
                sequence: inputItem.sequence,
                typeIdentifier: inputItem.typeIdentifier,
                payload: inputItem.bytes,
                resolvedAtTick: inputItem.resolvedAtTick
            )
            applied.recordedServerInputs.append(recorded)
            applied.appliedOrder.append(recorded.sequence)
            // A recorded payload that failed to decode when replay built the item throws here,
            // after its record append and before the state wrapper: only a handler call enters
            // it (#700 K1b-1, S5).
            let input = try inputItem.decoded.get()
            // Throws only from `validate`, before anything is written (#586).
            try withHandlerStep(&m, ctx) { m, ctx in
                try handler.invoke(&m.state, input: input, ctx: ctx)
            }

        case .landFailure:
            // Not an input: nothing is applied or recorded. The batch ends at it, and the
            // failure ends the land after the loop (`applyInputs`).
            return .other

        case let .shutdown(shutdownItem):
            // Recorded like any input. No handler runs: a forced shutdown runs no OnLeave (#382).
            let recorded = ReevaluationRecordedLifecycleEvent(
                kind: Self.shutdownLifecycleKind,
                sequence: shutdownItem.sequence,
                tickId: executingTickId,
                playerID: nil,
                clientID: nil,
                sessionID: nil,
                deviceID: nil,
                isGuest: nil,
                metadata: [:],
                resolverOutputs: [:],
                resolvedAtTick: shutdownItem.resolvedAtTick
            )
            applied.recordedLifecycleEvents.append(recorded)
            applied.appliedOrder.append(recorded.sequence)
            // In re-evaluation `players` holds the replay's viewers: the shutdown only ends the
            // replay (`completeShutdownTurn`).
            if behavior.config.mode == .live { m.players.removeAll(); playerServices.removeAll(); m.rejoinReservations.removeAll() }

        case let .lifecycle(lifecycleItem):
            applyLifecycleItem(&m, lifecycleItem, executingTickId: executingTickId, into: &applied)
        }
        return .other
    }

    /// Skips `item` once the destroy handlers have started. Every append path checks
    /// `isDraining`; this guard keeps the guarantee if one doesn't.
    private func skipsAfterDestroy(_ m: inout KeeperModel<State>, _ item: PendingItem) -> Bool {
        guard m.destroyHandlersStarted else { return false }
        m.inputsSkippedAfterDestroy += 1
        behavior.logger.error("Input skipped: the land's destroy handlers have started", metadata: [
            "sequence": .stringConvertible(item.sequence),
        ])
        return true
    }

    /// Applies a lifecycle input: recorded, then its handler. It can't fail: OnJoin and OnLeave
    /// don't throw (#586), and a replayed OnInitialize whose `validate` throws writes nothing and
    /// is noted for the initialize check (#593).
    private func applyLifecycleItem(_ m: inout KeeperModel<State>, _ lifecycleItem: PendingLifecycleItem, executingTickId: Int64, into applied: inout AppliedInputs) {
        if skipsAfterDestroy(&m, .lifecycle(lifecycleItem)) { return }
        // Recorded before the handler runs (see the action case). Its outputs are projected only
        // when something reads records, as the action case's are.
        let resolverOutputsDict = recordsInputs ? lifecycleItem.heldResolverOutputs.recordedEntries : [:]
        let recordedLifecycleEvent = ReevaluationRecordedLifecycleEvent(
            kind: lifecycleItem.kind.rawValue,
            sequence: lifecycleItem.sequence,
            tickId: executingTickId,
            playerID: lifecycleItem.playerID?.rawValue,
            clientID: lifecycleItem.clientID?.rawValue,
            sessionID: lifecycleItem.sessionID?.rawValue,
            deviceID: lifecycleItem.deviceID,
            isGuest: lifecycleItem.isGuest,
            metadata: lifecycleItem.metadata,
            resolverOutputs: resolverOutputsDict,
            resolvedAtTick: lifecycleItem.resolvedAtTick
        )
        applied.recordedLifecycleEvents.append(recordedLifecycleEvent)
        applied.appliedOrder.append(recordedLifecycleEvent.sequence)

        switch lifecycleItem.kind {
        case .initialize:
            guard let handler = definition.lifetimeHandlers.onInitialize,
                  !replay.replayedInitializeBeforeTickZero else { break }
            // Only a record without an initialize record reaches this fallback, and a live run
            // writes one whenever it records: records before 2.1 no longer open
            // (`minimumReplayable`), so it is a crafted record. `ctx.tickId` is the executing tick
            // (0 for an item in tick 0, later for one a crafted record puts later), so the
            // outputs flush with that frame. The live run had the tick before it: with that ID,
            // OnInitialize's events would go to a tick whose outputs are already flushed (#593).
            let ctx = makeContext(&m,
                playerID: behavior.config.systemPlayerID,
                clientID: behavior.config.systemClientID,
                sessionID: behavior.config.systemSessionID,
                tickId: executingTickId,
                resolverOutputs: lifecycleItem.heldResolverOutputs
            )
            // Execute handler synchronously (resolver outputs already injected). Only
            // re-evaluation queues an initialize item, for a record without an initialize record
            // (a live run writes one whenever it records). `invoke` throws only from `validate`,
            // before `apply` writes and with nothing emitted (#593).
            do {
                try withHandlerStep(&m, ctx) { m, ctx in
                    try handler.invoke(&m.state, ctx)
                }
            } catch {
                noteReplayedInitializeRefusal(error)
            }
        case .join:
            guard
                let playerID = lifecycleItem.playerID,
                let clientID = lifecycleItem.clientID,
                let sessionID = lifecycleItem.sessionID,
                let handler = definition.lifetimeHandlers.onJoin
            else { break }
            let ctx = makeContext(&m,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                deviceID: lifecycleItem.deviceID,
                isGuest: lifecycleItem.isGuest,
                metadata: lifecycleItem.metadata,
                tickId: executingTickId,
                resolverOutputs: lifecycleItem.heldResolverOutputs
            )
            withHandlerStep(&m, ctx) { m, ctx in
                handler(&m.state, ctx)
            }
        case .leave:
            guard
                let playerID = lifecycleItem.playerID,
                let clientID = lifecycleItem.clientID,
                let sessionID = lifecycleItem.sessionID,
                let handler = definition.lifetimeHandlers.onLeave
            else { break }
            let ctx = makeContext(&m,
                playerID: playerID,
                clientID: clientID,
                sessionID: sessionID,
                deviceID: lifecycleItem.deviceID,
                isGuest: lifecycleItem.isGuest,
                metadata: lifecycleItem.metadata,
                tickId: executingTickId,
                resolverOutputs: lifecycleItem.heldResolverOutputs
            )
            // The player is gone: the broadcast-only sync follows the pass, deferred until after
            // the pending items' removal.
            applied.shouldSyncBroadcastOnly = true
            withHandlerStep(&m, ctx) { m, ctx in
                handler(&m.state, ctx)
            }
        }
    }

    /// A re-evaluation tick's inputs (`runTick`): applies the pending inputs that are ready, in
    /// order (`applyInputs`), then records them and runs the broadcast-only sync a leave asks for.
    /// The tick flushes the outputs after its handler, so they include its state changes. A live
    /// keeper applies inputs only in turns (#546 L2d); this is the re-evaluation keeper's legacy
    /// tick path until #612.
    ///
    /// An input whose `validate` throws fails alone and the pass goes on (`applyInputs`).
    private func processPendingActions() async {
        let executingTickId = executingTickIdForPendingItems(&model)
        beginPass(&model)
        let application = applyInputs(&model, &turnSide, readyPendingItemsInOrder(model), executingTickId: executingTickId, reportJoins: reportJoinsOutsideTurn)
        let applied = application.applied
        // Numbered in the apply segment, before any read after it (#563).
        _ = takePassOrdinal(&model, applied: applied)
        await holds.at(.turnRecord)
        let recordedActions = applied.recordedActions
        let recordedClientEvents = applied.recordedClientEvents
        let recordedLifecycleEvents = applied.recordedLifecycleEvents
        let recordedServerInputs = applied.recordedServerInputs
        let shouldSyncBroadcastOnly = applied.shouldSyncBroadcastOnly

        // Record inputs to ReevaluationRecorder
        if let recorder = reevaluationRecorder,
           !recordedActions.isEmpty || !recordedClientEvents.isEmpty || !recordedLifecycleEvents.isEmpty
            || !recordedServerInputs.isEmpty
        {
            // Use the tick ID that was used for processing (nextTickId - 1, since we incremented it before processing)
            let recordingTickId = model.nextTickId - 1
            await recorder.record(
                tickId: recordingTickId,
                actions: recordedActions,
                clientEvents: recordedClientEvents,
                lifecycleEvents: recordedLifecycleEvents,
                serverInputs: recordedServerInputs,
                // A tickless land records them on its pass instead (#586).
                rejected: isTickless ? [] : applied.rejected
            )

            // Flush if needed
            try? await recorder.flushIfNeeded(currentTick: recordingTickId)
        }

        if shouldSyncBroadcastOnly {
            await transport?.syncBroadcastOnlyFromTransport()
        }
    }

    /// What `applyInputs` did: the records (failed inputs included) and each input's outcome.
    private struct InputApplication {
        var applied: AppliedInputs
        /// Every input's outcome, by sequence: its response (empty for non-actions) or its error.
        var outcomes: [Int64: Result<InputOutcome, any Error>]
        var failureCount: Int
        /// How many of the batch's items were consumed: the batch ends at a shutdown or a land
        /// failure (#535), and the items after it were dropped by the settle, not applied.
        var consumed: Int
    }

    /// Applies `items` in order (synchronous), on every path (input turn, tick turn, a
    /// re-evaluation tick's inputs), and removes them all from the queue in the same segment.
    ///
    /// An input P whose `validate` throws (or whose payload doesn't decode) is refused alone
    /// (#586): its outcome is its error (its caller gets it), and the inputs after it continue in
    /// the same pass with their own outcomes. P wrote nothing and emitted nothing: handlers throw
    /// only before they write. P is not run again and blocks nothing. P is recorded like the
    /// others, in order (`applyPendingItem` records before the handler runs), and listed as
    /// rejected (`AppliedInputs.rejected`, record format 3.5), so replay runs it again and checks
    /// it is refused the same way. Lifecycle inputs can't fail: OnJoin and OnLeave don't throw.
    private func applyInputs(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ items: [PendingItem],
        executingTickId: Int64,
        removingFromQueue: Bool = true,
        preparedRecordBytes: [Int64: Result<Data, any Error>] = [:],
        reportJoins: (inout KeeperModel<State>, inout KeeperTurnSide, [JoinInputResult]) -> Void
    ) -> InputApplication {
        var applied = AppliedInputs(executingTickId: executingTickId)
        var outcomes: [Int64: Result<InputOutcome, any Error>] = [:]
        var failureCount = 0
        var joinResults: [JoinInputResult] = []
        // The shutdown is the last input a land applies (#382): the batch ends at it.
        var consumed = items.count
        var appliedShutdown = false
        // A transport-reported failure (#535) ends the batch too: the inputs behind it are
        // dropped with `landClosed` by the settle.
        var appliedFailure: LandFailure?
        for (index, item) in items.enumerated() {
            if case let .landFailure(failureItem) = item {
                consumed = index + 1
                appliedFailure = failureItem.failure
                break
            }
            // A lifecycle input can't fail: OnJoin and OnLeave don't throw (#586).
            if case let .lifecycle(lifecycle) = item {
                applyLifecycleItem(&m, lifecycle, executingTickId: executingTickId, into: &applied)
                if lifecycle.kind == .join { joinResults.append(JoinInputResult(sequence: item.sequence)) }
                outcomes[item.sequence] = .success(.none)
                continue
            }
            do {
                switch try applyPendingItem(&m, item, executingTickId: executingTickId, into: &applied, preparedRecordBytes: preparedRecordBytes) {
                case .action(let response): outcomes[item.sequence] = .success(.response(response))
                case .other, .skipped: outcomes[item.sequence] = .success(.none)
                }
            } catch {
                // Thrown by `validate` (or a payload check) before anything was written (#586).
                failureCount += 1
                outcomes[item.sequence] = .failure(error)
                // Listed only when it was recorded: a payload that doesn't decode throws before its
                // record, and the rejected list names recorded inputs only.
                if applied.appliedOrder.last == item.sequence {
                    applied.rejected.append(item.sequence)
                    if behavior.config.mode == .reevaluation { replay.replayRejected.append(item.sequence) }
                }
                behavior.logger.error("Input refused: its validate threw; the inputs after it continue", metadata: [
                    "sequence": .stringConvertible(item.sequence),
                    "error": .string(String(describing: error)),
                ])
            }
            if item.isShutdown {
                consumed = index + 1
                appliedShutdown = true
                break
            }
        }
        if removingFromQueue { removePendingItems(&m, Array(items.prefix(consumed))) }
        // A failure noted on the mailbox came first, even when another closer's submit queued its
        // item ahead of the noted one's (#704): the noted failure stays the cause. Applied before
        // the join report, so a re-entry refused in that report can't outrank it. (A batch holds
        // a failure item or a shutdown, never both: each ends it.)
        if let appliedFailure {
            failLand(&m, &side, pendingTransportFailure.failure ?? appliedFailure, endsInputs: true, appliedInputs: !applied.appliedOrder.isEmpty)
        }
        // A port call: in a turn body the caller reports through `callOut` (`reportJoinsInTurn`).
        // After a failure item the gate is closed already; the report still goes to the
        // transport, which only marks the joins consumed.
        reportJoins(&m, &side, joinResults)
        if appliedShutdown { completeShutdownTurn(&m, &side) }
        return InputApplication(applied: applied, outcomes: outcomes, failureCount: failureCount, consumed: consumed)
    }

    /// Re-evaluation only: replays a tickless frame's inputs pass by pass, in recorded order,
    /// each pass as an input turn (`runInputTurn`, the live drain's turn) with its inputs in
    /// listed order, right after restoring the pass's sequence watermark (#325, #321). Returns
    /// whether a leave asks for a broadcast-only sync.
    ///
    /// Linear in the frame's inputs (a tickless frame holds the whole session): they are indexed
    /// by sequence once, each pass takes its batch from the index, and the turns leave the queue
    /// alone; the frame's inputs are removed from it once, at the end.
    ///
    /// Holds at `.inputDrain` first and submits each turn's record (`.turnRecord`), as the live
    /// drain does; without a hook or a recorder neither suspends. The passes are checked against
    /// every input loaded for the frame before any turn runs: each loaded input must be ready,
    /// carry its own sequence, and be named by exactly one pass; no pass may name anything else;
    /// watermarks must not decrease. OnInitialize's lifecycle input is outside them: it was
    /// replayed before tick 0, and is applied (as a no-op) first. If the queue changed across
    /// the awaits between passes, the index is rebuilt from it, so a pass never applies an input
    /// that is no longer queued. When the passes don't match, no further input of the frame is
    /// applied (they are dropped from the queue) and the mismatch is kept for the engine and the
    /// hosted runner (`takeRecordedPassMismatch(for:)`), which fail the tick: a record whose
    /// order can't be trusted is never replayed in some other order.
    private func replayRecordedPasses(_ passes: [ReevaluationRecordedPass], tickId: Int64) async -> Bool {
        await holds.at(.inputDrain)
        let isInitialize: (PendingItem) -> Bool = { item in
            if case let .lifecycle(lifecycle) = item, lifecycle.kind == .initialize { return true }
            return false
        }
        let initializeItems = readyPendingItemsInOrder(model).filter(isInitialize)
        model.pendingItemScans += model.pendingItems.count
        let inputs = model.pendingItems.filter { !isInitialize($0) }.sorted { $0.sequence < $1.sequence }

        var mismatch: String?
        var bySequence: [Int64: PendingItem] = [:]
        for item in inputs where mismatch == nil {
            if bySequence.updateValue(item, forKey: item.sequence) != nil {
                mismatch = "the tick holds more than one input with sequence \(item.sequence)"
            } else if item.resolvedAtTick >= model.nextTickId {
                mismatch = "the input with sequence \(item.sequence) resolves at tick \(item.resolvedAtTick), after the tick"
            }
        }
        var named: Set<Int64> = []
        var previousWatermark = Int64.min
        // From record format 3.4 each pass carries its ordinal (#563); they must continue this
        // land's count with no gap, as the live land numbered them.
        let ordinalBase = model.passOrdinal
        for (index, pass) in passes.enumerated() where mismatch == nil {
            if let ordinal = pass.ordinal, ordinal != ordinalBase + Int64(index) + 1 {
                mismatch = "pass \(index) is numbered \(ordinal), expected \(ordinalBase + Int64(index) + 1)"
            } else if pass.ordinal == nil, replay.replayRecordsPassOrdinals {
                // A 3.4 record numbers every tickless pass: a missing ordinal is a malformed record.
                mismatch = "pass \(index) has no ordinal, which a record from 3.4 on always carries"
            }
            if pass.sequenceBefore < previousWatermark {
                mismatch = "pass \(index) starts at sequence \(pass.sequenceBefore), before the previous pass's \(previousWatermark)"
            }
            previousWatermark = pass.sequenceBefore
            if mismatch == nil, replay.replayRecordsRejected, let rejected = pass.rejected {
                mismatch = Self.malformedRejected(rejected, inputs: Set(pass.inputs), scope: "pass \(index)")
            }
            for sequence in pass.inputs where mismatch == nil {
                if bySequence[sequence] == nil {
                    mismatch = "pass \(index) names sequence \(sequence), which is not a recorded input of the tick"
                } else if !named.insert(sequence).inserted {
                    mismatch = "sequence \(sequence) is named by more than one pass"
                }
            }
        }
        if mismatch == nil, named.count != bySequence.count {
            let missing = bySequence.keys.filter { !named.contains($0) }.sorted()
            mismatch = "no pass names the recorded inputs \(missing)"
        }

        let executingTickId = executingTickIdForPendingItems(&model)
        var syncBroadcastOnly = applyInputs(&model, &turnSide, initializeItems, executingTickId: executingTickId, reportJoins: reportJoinsOutsideTurn)
            .applied.shouldSyncBroadcastOnly
        // The turns below leave the queue as it is; nothing else changes it during replay, but
        // if something did across an await, the index is rebuilt from what is still queued.
        let queuedCount = model.pendingItems.count
        var queued = bySequence
        for (index, pass) in passes.enumerated() where mismatch == nil {
            if model.pendingItems.count != queuedCount {
                model.pendingItemScans += model.pendingItems.count
                let still = Set(model.pendingItems.map(\.sequence))
                queued = queued.filter { still.contains($0.key) }
            }
            var batch: [PendingItem] = []
            for sequence in pass.inputs {
                guard let item = queued.removeValue(forKey: sequence) else {
                    mismatch = "pass \(index) names sequence \(sequence), which is no longer queued"
                    break
                }
                batch.append(item)
            }
            if mismatch != nil { break }
            // No await between the restore and the turn: the turn numbers from the watermark.
            restoreSequenceWatermark(pass.sequenceBefore, tickId: tickId, point: "pass")
            _ = takeReplayRejected()
            let outcome = runInputTurn(batch, removingFromQueue: false)
            let replayedRejected = takeReplayRejected()
            if replay.replayRecordsRejected,
               let divergence = Self.rejectedDivergence(recorded: pass.rejected ?? [], replayed: replayedRejected) {
                mismatch = "pass \(index): \(divergence)"
            }
            if outcome.syncBroadcastOnly { syncBroadcastOnly = true }
            // Live, a failure applied as an input in this pass ended it there: its inputs'
            // events were never sent, so the replayed pass sends none either (#535 D9).
            if let end = replay.replayFailureEnd, end.tickId == tickId, let failingPass = end.pass, failingPass == model.passOrdinal {
                outputCollector.emittedEvents.removeAll { $0.tickId == tickId && $0.sequence >= pass.sequenceBefore }
            }
            // The pass and the state after it, taken in the segment that applied it, for what
            // the record read after it (`afterPass`, #563).
            let ordinalAfter = model.passOrdinal
            let stateAfter = model.state
            if !outcome.record.isEmpty {
                await submitTurnRecord(outcome.record)
            }
            // Replay has no callers; this clears the turn's outcomes (`inputTurnResults`).
            resumeInputTurnWaiters(for: outcome.appliedItems)
            // The pass's events reach the sink now, not after the frame's last pass, so the
            // sync-output check sees each pass's events before the outputs read after it.
            await flushOutputs(forTick: tickId)
            if let observer = replay.replayPassObserver {
                await observer(ordinalAfter, stateAfter)
            }
        }
        if let mismatch {
            replay.recordedPassMismatches[tickId] = mismatch
            behavior.logger.error("Re-evaluation: the record's passes don't match its inputs", metadata: [
                "tickId": .stringConvertible(tickId),
                "reason": .string(mismatch),
            ])
        }
        // Every input loaded for the frame, applied or (after a mismatch) not, in one scan.
        removePendingItems(&model, inputs)
        return syncBroadcastOnly
    }




    /// Sets `replayRecordsPassOrdinals` from the record's version (re-evaluation only).
    package func setReplayRecordsPassOrdinals(_ value: Bool) {
        replay.replayRecordsPassOrdinals = value
    }


    /// Sets `replayRecordsRejected` from the record's version (re-evaluation only).
    package func setReplayRecordsRejected(_ value: Bool) {
        replay.replayRecordsRejected = value
    }


    private func takeReplayRejected() -> [Int64] {
        defer { replay.replayRejected = [] }
        return replay.replayRejected
    }

    /// Why a recorded `rejected` list is malformed for inputs `inputs` (#586): it names an input
    /// that isn't one of them, or one twice. Nil when it's well formed.
    private static func malformedRejected(_ rejected: [Int64], inputs: Set<Int64>, scope: String) -> String? {
        var seen: Set<Int64> = []
        for sequence in rejected {
            if !inputs.contains(sequence) {
                return "\(scope) lists sequence \(sequence) as rejected, which is not one of its inputs"
            }
            if !seen.insert(sequence).inserted {
                return "\(scope) lists sequence \(sequence) as rejected more than once"
            }
        }
        return nil
    }

    /// How the inputs refused in replay differ from those refused live (#586), or nil.
    private static func rejectedDivergence(recorded: [Int64], replayed: [Int64]) -> String? {
        let live = Set(recorded), again = Set(replayed)
        if let sequence = live.subtracting(again).min() {
            return "input \(sequence) was rejected live and applied in replay"
        }
        if let sequence = again.subtracting(live).min() {
            return "input \(sequence) was applied live and rejected in replay"
        }
        return nil
    }

    /// Installs `replayFailureEnd` (re-evaluation only).
    package func setReplayFailureEnd(tickId: Int64, pass: Int64?) {
        replay.replayFailureEnd = ReplayFailureEnd(tickId: tickId, pass: pass)
    }

    /// Re-evaluation only: whether a take found the sequence counter at `Int64.max` (#741). The run
    /// throws `ReevaluationRecordContentError.sequenceExhausted` at its next step boundary.
    package func replaySequenceExhausted() -> Bool {
        outputCollector.sequenceExhausted
    }

    /// Installs `replayPassObserver` (re-evaluation only).
    package func setReplayPassObserver(_ observer: (@Sendable (Int64, State) async -> Void)?) {
        replay.replayPassObserver = observer
    }


    /// Re-evaluation: takes why `tickId`'s recorded passes didn't match its inputs, if they didn't.
    package func takeRecordedPassMismatch(for tickId: Int64) -> String? {
        replay.recordedPassMismatches.removeValue(forKey: tickId)
    }

    /// Re-evaluation only: move the shared sequence counter forward to a recorded watermark.
    ///
    /// The counter is never moved back. If replay has already taken more numbers than live did,
    /// the extra server event shows up in the per-tick server-event comparison instead.
    private func restoreSequenceWatermark(_ watermark: Int64?, tickId: Int64, point: String) {
        guard behavior.config.mode == .reevaluation, let watermark else { return }
        if outputCollector.nextSequence <= watermark {
            outputCollector.nextSequence = watermark
        } else {
            // Replay has taken more numbers than live did; later ticks may mismatch because of
            // this, so log where it started.
            behavior.logger.warning("Re-evaluation sequence counter is past the recorded watermark", metadata: [
                "tickId": .stringConvertible(tickId),
                "point": .string(point),
                "counter": .stringConvertible(outputCollector.nextSequence),
                "watermark": .stringConvertible(watermark),
            ])
        }
    }

    private func runTick(allowWhenNoTickTask: Bool) async {
        // Check if task was cancelled before executing tick
        // This prevents ticks from running after shutdown has started
        guard !Task.isCancelled else { return }

        // The loop's tick is starting: a sync firing from now on no longer folds into it.
        if !allowWhenNoTickTask { nextTickDeadline = nil }

        // No tick body starts while frozen; a body already running is drained by `debugFreeze`.
        guard !model.debugFrozen else { return }
        debugBeginWork()
        defer { debugEndWork(&model, &turnSide) }

        // A tickless land in re-evaluation still steps through the recorded ticks: each step
        // applies that tick's recorded inputs and flushes their events under it (#268).
        let tickHandler = definition.lifetimeHandlers.tickHandler
        if tickHandler == nil, behavior.config.mode == .live {
            // Tickless: the ready inputs run as input turns (or join the drain in progress).
            if !model.inputDrainScheduled {
                model.inputDrainScheduled = true
                await runInputDrain()
            }
            return
        }

        // Double-check: if tickTask is nil, we're in shutdown, don't run (unless manually stepping)
        if !allowWhenNoTickTask {
            guard tickTask != nil else { return }
        }
        // A tick runs whole or not at all: none starts once the drain has started (a manual
        // step included), and the drain waits for one in flight before it takes the pending
        // inputs and runs the destroy handlers. Same synchronous segment as the start.
        // Re-evaluation: a replayed shutdown ended the replay; stop as past the recorded range.
        if behavior.config.mode == .reevaluation, model.shutdownTurnApplied {
            tickTask?.cancel()
            tickTask = nil
            return
        }
        // `shutdownRequested`: a forced shutdown waits for the tick in flight, then applies its
        // turn; no tick starts in between (#382).
        guard !isDraining, !model.shutdownRequested else { return }
        model.ticksInFlight += 1
        defer { endTickInFlight() }

        // Use tickId for deterministic replay (increments with each tick)
        // Increment BEFORE processing pending actions so they can execute in this tick
        let tickId = model.nextTickId
        model.nextTickId += 1

        // In re-evaluation mode, stop when we exceed the recorded tick range (prevent simulation beyond record)
        if behavior.config.mode == .reevaluation, let source = replay.reevaluationSource {
            let maxTickId = (try? await source.getMaxTickId()) ?? -1
            if tickId > maxTickId {
                tickTask?.cancel()
                tickTask = nil
                return
            }
        }

        // Every live tick is a turn (inputs, tick handler, events, and with a port the sync plan,
        // commit and writer enqueue), with no suspension point; the recorder follows the turn.
        if routesThroughTurn, let handler = tickHandler {
            turnSide.probe?("turn-begin")
            if inTurnYieldForTesting {
                // Negative control (tests only): a suspension point inside the turn, which the
                // reentrancy probe must detect.
                await Task.yield()
            }
            // The slot is read once, in this segment (#546 L2d).
            let output = runTickTurn(handler: handler, tickId: tickId, transport: syncsInTurn ? transport : nil)
            await finishTickTurn(output)
            return
        }

        // Recorded sequence watermarks for this tick (re-evaluation only; nil for older records).
        var replayWatermarks: ReevaluationSequenceWatermarks?
        // A tickless land's recorded passes for this tick (3.1 on; empty otherwise).
        var replayPasses: [ReevaluationRecordedPass] = []
        // A tick land's inputs refused live in this tick (3.5 on, #586; empty otherwise).
        var replayFrameRejected: [Int64] = []

        // In re-evaluation mode, load actions, client events, and lifecycle events from ReevaluationSource.
        if behavior.config.mode == .reevaluation, let source = replay.reevaluationSource {
            do {
                replayWatermarks = try await source.getSequenceWatermarks(for: tickId)
                replayPasses = try await source.getPasses(for: tickId)
                replayFrameRejected = try await source.getRejected(for: tickId)
                let recordedActions = try await source.getActions(for: tickId)
                let recordedClientEvents = try await source.getClientEvents(for: tickId)
                let recordedServerInputs = try await source.getServerInputs(for: tickId)
                let recordedLifecycleEvents = try await source.getLifecycleEvents(for: tickId)
                if replay.replayRecordsRejected, !replayFrameRejected.isEmpty {
                    let inputs = Set(recordedActions.map(\.sequence) + recordedClientEvents.map(\.sequence)
                        + recordedServerInputs.map(\.sequence) + recordedLifecycleEvents.map(\.sequence))
                    if let reason = Self.malformedRejected(replayFrameRejected, inputs: inputs, scope: "tick \(tickId)") {
                        replay.recordedPassMismatches[tickId] = replay.recordedPassMismatches[tickId] ?? reason
                        behavior.logger.error("Re-evaluation: the record's rejected inputs are malformed", metadata: [
                            "tickId": .stringConvertible(tickId),
                            "reason": .string(reason),
                        ])
                    }
                }

                // Convert recorded actions to PendingItem
                for recordedAction in recordedActions {
                    // Find the action type handler by matching type identifier
                    guard let handlerPosition = definition.actionHandlers.firstIndex(where: { handler in
                        let actionType = handler.getActionType()
                        let actionTypeName = String(describing: actionType)

                        // Direct type name match (e.g., "AddGoldAction" == "AddGoldAction")
                        if actionTypeName == recordedAction.typeIdentifier {
                            return true
                        }

                        // Match last component (e.g., "Module.AddGoldAction" == "AddGoldAction")
                        if actionTypeName.split(separator: ".").last == recordedAction.typeIdentifier.split(separator: ".").last {
                            return true
                        }

                        return false
                    }) else {
                        behavior.logger.warning("Handler not found for recorded action type", metadata: [
                            "typeIdentifier": .string(recordedAction.typeIdentifier),
                        ])
                        continue
                    }

                    let handler = definition.actionHandlers[handlerPosition]
                    // Get the action type from handler (we know it's ActionPayload.Type)
                    let actionTypeAny = handler.getActionType()
                    guard let actionType = actionTypeAny as? any ActionPayload.Type else {
                        behavior.logger.warning("Action type is not ActionPayload", metadata: [
                            "typeIdentifier": .string(recordedAction.typeIdentifier),
                        ])
                        continue
                    }

                    let resolverOutputs = replayedResolverOutputs(recordedAction.resolverOutputs)

                    // Decoded here, once, with the decoder its encoding's transport uses live
                    // (#700 K1a), never the record codec's byte-matching one (#806's class). A
                    // payload that doesn't decode is still queued, and fails when it is applied.
                    let recorded = RecordedPayloadBytes(
                        bytes: recordedAction.payload,
                        encoding: recordedAction.payloadEncoding ?? replay.replayHeaderPayloadEncoding
                    )
                    let decoded = DecodedAction(catching: {
                        let source = try behavior.payloadDecoders.makeSource(recorded.bytes, recorded.encoding)
                        try source.validateRecordable()
                        return try source.decodeAction(actionType)
                    })
                    let pendingItem = PendingItem.action(
                        PendingActionItem(
                            sequence: recordedAction.sequence,
                            decoded: decoded,
                            handlerIndex: ActionHandlerIndex(handlerPosition),
                            recorded: recorded,
                            playerID: PlayerID(recordedAction.playerID),
                            clientID: ClientID(recordedAction.clientID),
                            sessionID: SessionID(recordedAction.sessionID),
                            heldResolverOutputs: resolverOutputs,
                            resolvedAtTick: recordedAction.resolvedAtTick
                        )
                    )
                    model.pendingItems.append(pendingItem)
                }

                // Convert recorded client events to PendingItem: decoded here, as an action is.
                // A descriptor without the decode is decoded with its type, as at intake.
                for recordedClientEvent in recordedClientEvents {
                    let recorded = RecordedPayloadBytes(
                        bytes: recordedClientEvent.payload,
                        encoding: recordedClientEvent.payloadEncoding ?? replay.replayHeaderPayloadEncoding
                    )
                    let payload: PendingClientEventPayload
                    do {
                        let source = try behavior.payloadDecoders.makeSource(recorded.bytes, recorded.encoding)
                        let descriptor = definition.clientEventRegistry.findDescriptor(for: recordedClientEvent.typeIdentifier)
                        if let decode = descriptor?.decodeClientEvent {
                            try source.validateRecordable()
                            payload = .decoded(try decode(source))
                        } else if let descriptor,
                                  definition.eventHandlers.contains(where: { $0.canHandle(descriptor.type) }) {
                            payload = Self.decodeWithDescriptorType(descriptor, source)
                        } else {
                            // No handler: apply skips the event at its lookup, so nothing decodes it.
                            payload = .failed(.undecodable("no handler for \(recordedClientEvent.typeIdentifier)"))
                        }
                    } catch {
                        payload = .failed(RecordedPayloadDecodeFailure(error))
                    }
                    let pendingItem = PendingItem.clientEvent(
                        PendingClientEventItem(
                            sequence: recordedClientEvent.sequence,
                            typeIdentifier: recordedClientEvent.typeIdentifier,
                            payload: payload,
                            recorded: recorded,
                            playerID: PlayerID(recordedClientEvent.playerID),
                            clientID: ClientID(recordedClientEvent.clientID),
                            sessionID: SessionID(recordedClientEvent.sessionID),
                            resolvedAtTick: recordedClientEvent.resolvedAtTick
                        )
                    )
                    model.pendingItems.append(pendingItem)
                }

                // Recorded server inputs (#387): replay needs none of the outside work. One this
                // land doesn't declare can't be reproduced: it fails the tick.
                for recorded in recordedServerInputs {
                    guard let handler = definition.serverInputHandlers[recorded.typeIdentifier] else {
                        let reason = "recorded server input \(recorded.sequence) has type \(recorded.typeIdentifier), which the land doesn't declare"
                        replay.recordedPassMismatches[tickId] = replay.recordedPassMismatches[tickId] ?? reason
                        behavior.logger.error("Re-evaluation: a recorded server input can't be applied", metadata: [
                            "tickId": .stringConvertible(tickId),
                            "reason": .string(reason),
                        ])
                        continue
                    }
                    // Decoded once, here, from the recorded bytes (canonical MessagePack in every
                    // record, #700 K1a). A payload that doesn't decode is still queued: it fails
                    // alone when it is applied, with the error a decode there would throw.
                    let decoded = DecodedServerInput(catching: { try handler.decode(recorded.payload) })
                    model.pendingItems.append(.serverInput(PendingServerInputItem(
                        sequence: recorded.sequence,
                        typeIdentifier: recorded.typeIdentifier,
                        bytes: recorded.payload,
                        decoded: decoded,
                        resolvedAtTick: recorded.resolvedAtTick
                    )))
                }

                // Convert recorded lifecycle events to PendingItem
                for recordedLifecycleEvent in recordedLifecycleEvents {
                    if recordedLifecycleEvent.kind == Self.shutdownLifecycleKind {
                        model.pendingItems.append(.shutdown(PendingShutdownItem(
                            sequence: recordedLifecycleEvent.sequence,
                            resolvedAtTick: recordedLifecycleEvent.resolvedAtTick
                        )))
                        continue
                    }
                    // A kind this build doesn't know can't be reproduced: it fails the tick,
                    // rather than being replayed as something else.
                    guard let kind = LifecycleKind(rawValue: recordedLifecycleEvent.kind) else {
                        let reason = "recorded lifecycle event \(recordedLifecycleEvent.sequence) has kind \(recordedLifecycleEvent.kind), which this build doesn't know"
                        replay.recordedPassMismatches[tickId] = replay.recordedPassMismatches[tickId] ?? reason
                        behavior.logger.error("Re-evaluation: a recorded lifecycle event can't be applied", metadata: [
                            "tickId": .stringConvertible(tickId),
                            "reason": .string(reason),
                        ])
                        continue
                    }

                    let resolverOutputs = replayedResolverOutputs(recordedLifecycleEvent.resolverOutputs)

                    let pendingItem = PendingItem.lifecycle(
                        PendingLifecycleItem(
                            sequence: recordedLifecycleEvent.sequence,
                            kind: kind,
                            playerID: recordedLifecycleEvent.playerID.map(PlayerID.init),
                            clientID: recordedLifecycleEvent.clientID.map(ClientID.init),
                            sessionID: recordedLifecycleEvent.sessionID.map { SessionID($0) },
                            deviceID: recordedLifecycleEvent.deviceID,
                            isGuest: recordedLifecycleEvent.isGuest,
                            metadata: recordedLifecycleEvent.metadata,
                            heldResolverOutputs: resolverOutputs,
                            resolvedAtTick: recordedLifecycleEvent.resolvedAtTick
                        )
                    )
                    model.pendingItems.append(pendingItem)
                }
            } catch {
                behavior.logger.error("Error loading actions from ReevaluationSource", metadata: [
                    "tickId": .stringConvertible(tickId),
                    "error": .string(String(describing: error)),
                ])
            }
        }

        // Sequence watermark W1 (before inputs). Live: captured synchronously, with no await
        // since `nextTickId += 1`. Re-evaluation: restored after the source-loading awaits.
        restoreSequenceWatermark(replayWatermarks?.beforeInputs, tickId: tickId, point: "beforeInputs")
        let sequenceBeforeInputs = outputCollector.nextSequence

        // Process pending actions before tick handler
        // Don't flush outputs yet - defer until after tick handler to ensure
        // outputs include state changes from the tick handler
        // A failing input fails alone; the others and the tick handler still run.
        if replayPasses.isEmpty {
            _ = takeReplayRejected()
            await processPendingActions()
            // A tick land's refused inputs are on its frame (#586); a tickless frame without
            // passes (an older record) has none to compare.
            if behavior.config.mode == .reevaluation, replay.replayRecordsRejected, !isTickless,
               let divergence = Self.rejectedDivergence(recorded: replayFrameRejected, replayed: takeReplayRejected()) {
                let reason = "tick \(tickId): \(divergence)"
                replay.recordedPassMismatches[tickId] = replay.recordedPassMismatches[tickId] ?? reason
                behavior.logger.error("Re-evaluation: an input's validate decided differently than live", metadata: [
                    "tickId": .stringConvertible(tickId),
                    "reason": .string(reason),
                ])
            }
        } else if await replayRecordedPasses(replayPasses, tickId: tickId) {
            await transport?.syncBroadcastOnlyFromTransport()
        }
        // Replay of a tick land whose recorded failure ended this tick's inputs ends it the same way.
        let replayEndsHere = behavior.config.mode == .reevaluation && !isTickless && replay.replayFailureEnd?.tickId == tickId
        if failure != nil || replayEndsHere {
            // The land failed in this tick's inputs (#535, a legacy failure arrives here as a
            // `landFailure` item): no tick handler, no state hash, no W2 and no outputs, as the
            // in-turn tick (`runTickTurn`). The inputs applied before it were recorded.
            model.lastCommittedTickId = tickId
            _ = takeEmittedEvents(&model, forTick: tickId)
            _ = outputCollector.syncRequestsByTick.removeValue(forKey: tickId)
            return
        }

        let ctx = makeContext(&model,
            playerID: behavior.config.systemPlayerID,
            clientID: behavior.config.systemClientID,
            sessionID: behavior.config.systemSessionID,
            tickId: tickId
        )

        // Sequence watermark W2 (before the tick handler). processPendingActions awaits after
        // its item loop, so inputs arriving then may have taken numbers since W1.
        restoreSequenceWatermark(replayWatermarks?.beforeTickHandler, tickId: tickId, point: "beforeTickHandler")
        let sequenceBeforeTickHandler = outputCollector.nextSequence

        // The handler runs on the state in place, in one synchronous segment, with the land's
        // generator bound (`withHandlerStep`). A replayed shutdown frame (#382) runs no tick
        // handler: live applied the shutdown as a turn of its own, between ticks. A tickless or
        // shutdown frame binds nothing.
        if !model.shutdownTurnApplied, let tickHandler {
            withHandlerStep(&model, ctx) { m, ctx in
                tickHandler(&m.state, ctx)
            }
        }

        // Update lastCommittedTickId after tick execution completes
        // This represents the world state's current committed tick
        model.lastCommittedTickId = tickId

        // Optionally record live per-tick state hash as ground truth for deterministic re-evaluation.
        if behavior.config.enableLiveStateHashRecording, let recorder = reevaluationRecorder {
            let enableStateSnapshotRecording = EnvHelpers.getEnvBool(
                key: EnvKeys.Runtime.stateSnapshotRecording,
                defaultValue: false
            )
            let (hash, snapshot) = liveStateHash(&model, tickId: tickId)
            await recorder.setStateHash(tickId: tickId, stateHash: hash)
            if enableStateSnapshotRecording {
                await recorder.recordStateSnapshot(tickId: tickId, stateSnapshot: snapshot)
            }
        }

        // Flush deterministic outputs (emitted events + sync requests) for this tick.
        await flushOutputs(forTick: tickId)

        // Ensure we have a frame for every tick in live mode, even if no inputs occurred,
        // and store this tick's sequence watermarks on it.
        if let recorder = reevaluationRecorder {
            await recorder.record(
                tickId: tickId,
                actions: [],
                clientEvents: [],
                lifecycleEvents: [],
                sequenceBeforeInputs: sequenceBeforeInputs,
                sequenceBeforeTickHandler: sequenceBeforeTickHandler
            )
        }

        // Note: Tick handler does NOT trigger automatic network sync
        // Network synchronization is handled separately by the sync mechanism
    }

    // MARK: - In-turn sync: turns

    /// The events emitted for `tickId` (with a sequence below `sequenceBound`, when given), in
    /// sequence order, removed from the collector.
    private func takeEmittedEvents(_ m: inout KeeperModel<State>, forTick tickId: Int64, before sequenceBound: Int64? = nil) -> [EmittedEvent] {
        let taken: (EmittedEvent) -> Bool = { item in
            item.tickId == tickId && (sequenceBound.map { item.sequence < $0 } ?? true)
        }
        let emitted = outputCollector.emittedEvents
            .filter(taken)
            .sorted { $0.sequence < $1.sequence }
        if !emitted.isEmpty {
            outputCollector.emittedEvents.removeAll(where: taken)
        }
        return emitted
    }

    /// Whether the sync requests handlers made for `tickId` (taken from the collector) or a
    /// leave in `applied` ask for a sync phase. A broadcast-only request runs the full phase in a
    /// turn: the leave's effects go out with the turn's frames.
    private func takeSyncRequest(forTick tickId: Int64, applied: AppliedInputs?) -> Bool {
        let requests = outputCollector.syncRequestsByTick.removeValue(forKey: tickId)
        return requests?.syncNow == true
            || requests?.syncBroadcastOnly == true
            || applied?.shouldSyncBroadcastOnly == true
    }


    /// The output step of a turn, synchronous: the turn's events, then (when `wantsSync`) the sync
    /// phase, handed to the transport in this actor turn, and the result applied in it.
    /// `runTurnOutputs` for a turn body: the transport's phase and the joins-awaiting read go
    /// through `callOut`, so a re-entry in either ends the land in that call and its answer is
    /// never read; the phase's draft factories run in the body, with the sync-only turn's check.
    private func runTurnOutputs(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        transport: any LandKeeperTransport,
        events: [EmittedEvent],
        wantsSync: Bool,
        joinSyncOnly: Bool = false
    ) {
        // A failure a transport noted since this turn's apply ended ends the land here, as a
        // failed phase would (#704): no event and no phase.
        guard !applyPendingTransportFailure(&m, &side) else { return }
        // A land without periodic sync runs the phase for joins waiting on it (#69): the turn
        // that consumed a join's input completes it in its own output step.
        var includeSync = wantsSync
        if !includeSync && !hasPeriodicSync {
            guard let awaiting = joinsAwaitingSync(&m, &side, &outputs, transport: transport) else {
                // Refused: the land ended in the call, as after a failed phase.
                m.inTurnSyncDue = false
                return
            }
            includeSync = awaiting
        }
        guard case .answered(let recording) = callOut(&m, &side, &outputs, { m in inTurnSyncRecording(m) }) else {
            // Refused: the land ended in the call, before the phase.
            m.inTurnSyncDue = false
            return
        }
        let inTurnEvents = events.map { InTurnServerEvent(event: $0.event, target: $0.target, sequence: $0.sequence) }
        switch callOut(&m, &side, &outputs, { m in
            transport.runSyncPhaseInTurn(state: m.state, events: inTurnEvents, includeSync: includeSync, recording: recording)
        }) {
        case .refused:
            // The land ended in the call; nothing of the phase is recorded or applied.
            m.inTurnSyncDue = false
        case .answered(let output):
            let beforeRecording = sentinel.reentryViolations
            recordSyncStream(&m, output.syncStream)
            guard sentinel.reentryViolations == beforeRecording else {
                _ = applyReentryFailure(&m, &side)
                m.inTurnSyncDue = false
                return
            }
            var refusedRead = false
            applyInTurnSyncResult(
                &m,
                &side,
                output.result,
                transport: transport,
                joinSyncOnly: joinSyncOnly,
                keepsEvents: output.keepsEvents,
                joinsAwaitingSync: { m, side in
                    let awaiting = joinsAwaitingSync(&m, &side, &outputs, transport: transport)
                    if awaiting == nil { refusedRead = true }
                    return awaiting
                }
            )
            if refusedRead { m.inTurnSyncDue = false }
        }
    }

    /// `transportHasJoinsAwaitingSync` in a turn body, one `callOut` per witness: whether the
    /// transport runs this keeper's phase, then whether joins wait. Nil when either call was
    /// refused (the land ended in it).
    private func joinsAwaitingSync(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        transport: any LandKeeperTransport
    ) -> Bool? {
        guard case .answered(let runsPhase) = callOut(&m, &side, &outputs, { _ in syncsInTurn }) else { return nil }
        guard runsPhase, behavior.config.mode == .live, let attached = self.transport else { return false }
        guard case .answered(let awaiting) = callOut(&m, &side, &outputs, { _ in attached.hasJoinsAwaitingSync }) else { return nil }
        return awaiting
    }


    /// Applies what an in-turn sync phase did, in the same turn.
    ///
    /// - committed: the dirty flags are cleared now when the plan diffed every synced field.
    /// - deferred by back-pressure: nothing was planned, so the dirty flags and the adapter's
    ///   queued events stay. A land with periodic sync relies on its next sync-only turn; one
    ///   without gets one sync-only turn once the writer drains.
    /// - failed or landFailed: the land ends in this turn (#535); nothing was committed.
    ///
    /// `joinSyncOnly`: the phase ran only for ready joins, outside a periodic land's cadence; if
    /// back-pressure defers it, such phases stop until a sync commits (`periodicJoinSyncAllowed`).
    ///
    /// `joinsAwaitingSync` asks the transport whether joins are left over a commit's budget; nil
    /// means the ask was refused as a re-entry and the land has ended (`callOut`), so no
    /// follow-up turn is requested.
    private func applyInTurnSyncResult(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ result: InTurnSyncResult,
        transport: any LandKeeperTransport,
        joinSyncOnly: Bool = false,
        keepsEvents: Bool = false,
        joinsAwaitingSync: (inout KeeperModel<State>, inout KeeperTurnSide) -> Bool?
    ) {
        switch result {
        case let .committed(clearDirtyFlags):
            if clearDirtyFlags {
                m.state.clearDirty()
            }
            m.inTurnSyncDue = false
            m.joinSyncWaitsForCommit = false
            side.probe?("sync-committed")
            // Joins left over a commit's budget: the next sync-only turn completes them.
            if !hasPeriodicSync {
                guard let awaiting = joinsAwaitingSync(&m, &side) else { return }
                if awaiting { scheduleJoinSyncTurn(&m, after: .zero, transport: transport) }
            }
            // Events still queued after the commit (kept by it, or queued after it): on a land
            // without periodic sync nothing else would deliver them, so one sync-only turn does,
            // right after this turn (the legacy follow-up's rule, #546 L2a).
            if keepsEvents && !hasPeriodicSync {
                requestSyncTurnAfterThisTurn(&m, transport: transport, reason: .keptEvents)
            }
        case .skipped:
            m.inTurnSyncDue = false
        case .deferredBackPressure:
            m.inTurnSyncDue = false
            m.inTurnDeferredTurns += 1
            if joinSyncOnly { m.joinSyncWaitsForCommit = true }
            if !hasPeriodicSync {
                retrySyncOnlyTurnAfterWriterDrain(&m, transport: transport)
            }
        case .failed:
            // A transport that reports a thrown plan without its failure: the first throw ends
            // the land, as `.landFailed` does (#535).
            m.inTurnSyncDue = false
            failLand(&m, &side, LandFailure(
                kind: .syncPlan,
                detail: "the transport reported a failed sync plan",
                position: LandFailurePosition(stage: .syncPhase)
            ))
        case let .landFailed(reported):
            m.inTurnSyncDue = false
            failLand(&m, &side, reported)
        case .notRequested, .unsupported:
            break
        }
    }

    /// What a tick turn leaves for the work after it (the recorder).
    private struct TickTurnOutput {
        let record: ReevaluationTickRecord
    }

    /// One tick turn, synchronous from the first input to the writer enqueue.
    ///
    /// Applies the ready inputs, runs the tick handler, takes the events emitted in this tick and
    /// hands them to the transport in emit order, with the sync phase when it is due
    /// (coincident-sync rule) or a handler requested one, all in this actor turn. Being
    /// non-async, it cannot contain an `await`; the recorder submission is returned for
    /// `finishTickTurn`.
    private func runTickTurn(
        handler: (inout State, LandContext) -> Void,
        tickId: Int64,
        transport: (any LandKeeperTransport)?
    ) -> TickTurnOutput {
        withTurn { m, side, outputs in
            tickTurnBody(&m, &side, &outputs, handler: handler, tickId: tickId, transport: transport)
        }
    }

    /// `runTickTurn`'s body, on the model the turn holds (#700 K1b-5a step 2). The tick handler
    /// runs in the hold, as an input's handler does (`withHandlerStep`); so does the state hash,
    /// whose conversion is the sync phase's.
    private func tickTurnBody(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        handler: (inout State, LandContext) -> Void,
        tickId: Int64,
        transport: (any LandKeeperTransport)?
    ) -> TickTurnOutput {
        // No port: no fold to report and no sync phase; the tick's events and sync request are
        // still taken below and recorded, so the collector is drained (#546 L2d). A sync folded
        // into this tick ends with it: kept, it would be reported, and its due sync run, by the
        // first tick turn after a later attach, as that turn's.
        // A refused fold report ends the land in the call; its inputs are dropped then, so the
        // failure branch below records the tick with none.
        if let transport {
            takePendingFold(&m, &side, &outputs, transport: transport)
        } else {
            pendingFold = nil
            m.inTurnSyncDue = false
        }
        // Sequence watermark W1 (before inputs).
        let sequenceBeforeInputs = outputCollector.nextSequence
        // A failing input fails alone; the others and the tick handler still run (`applyInputs`).
        let applied = applyInputs(&m, &side, readyPendingItemsInOrder(m), executingTickId: tickId, reportJoins: { m, side, results in
            reportJoinsInTurn(&m, &side, &outputs, results)
        }).applied
        // A failure a transport noted outside the turn ends this tick's inputs here, before the
        // handler (#704), as a failure item in the batch does: the record then matches what replay
        // does at a failure that ended a tick's inputs, which skips the handler.
        if failure == nil { _ = finishApply(&m, &side, appliedInputs: !applied.appliedOrder.isEmpty) }
        if failure != nil {
            // The land failed in this batch (#535): no tick handler, no events, no sync. The
            // inputs applied before it are recorded; no state hash and no W2 (it never ran).
            m.lastCommittedTickId = tickId
            // The prefix's events and sync requests are taken and not sent: no output after a
            // failure (§3.2 step 4).
            _ = takeEmittedEvents(&m, forTick: tickId)
            _ = takeSyncRequest(forTick: tickId, applied: applied)
            var record = makeTurnRecord(tickId: tickId, applied: applied, emitted: [])
            record.sequenceBeforeInputs = sequenceBeforeInputs
            return TickTurnOutput(record: record)
        }

        let ctx = makeContext(&m,
            playerID: behavior.config.systemPlayerID,
            clientID: behavior.config.systemClientID,
            sessionID: behavior.config.systemSessionID,
            tickId: tickId
        )
        // Sequence watermark W2 (before the tick handler).
        let sequenceBeforeTickHandler = outputCollector.nextSequence
        withHandlerStep(&m, ctx) { m, ctx in
            handler(&m.state, ctx)
        }
        m.lastCommittedTickId = tickId

        var stateHash: String?
        var stateSnapshot: StateSnapshot?
        if behavior.config.enableLiveStateHashRecording, reevaluationRecorder != nil {
            let (hash, snapshot) = liveStateHash(&m, tickId: tickId)
            stateHash = hash
            if EnvHelpers.getEnvBool(key: EnvKeys.Runtime.stateSnapshotRecording, defaultValue: false) {
                stateSnapshot = snapshot
            }
        }

        let emitted = takeEmittedEvents(&m, forTick: tickId)
        // Always take this tick's requests, so a folded sync does not leave them in the collector.
        let requested = takeSyncRequest(forTick: tickId, applied: applied)
        // A join this turn made ready (its OnJoin consumed, its session registered) flips in
        // this turn's sync phase rather than at the next periodic sync (#69): its JoinResponse
        // then waits for the tick that applies OnJoin only. The turn's sync is a full one, so
        // the members get this turn's changes now too, one sync earlier than the cadence.
        // (A land without periodic sync runs the phase for joins anyway: `runTurnOutputs`.)
        let cadenceSync = m.inTurnSyncDue || requested
        // A refused port call ends the land in that call: no output step follows, as after a
        // failed phase. The tick's events are recorded, taken and not sent.
        var refused = false
        var joinSync = false
        if !cadenceSync {
            if let allowed = periodicJoinSyncAllowed(&m, &side, &outputs, transport: transport) {
                joinSync = allowed
            } else {
                refused = true
            }
        }
        if joinSync {
            // Tick and sync work in one turn that is not a fold: counted apart, so turn timing
            // can tell these turns from folded ones.
            m.joinSyncTicks += 1
            if m.transportRecordsFolds, let transport,
               case .refused = callOut(&m, &side, &outputs, { _ in transport.noteInTurnJoinSyncTick() }) {
                refused = true
            }
        }
        if refused {
            m.inTurnSyncDue = false
        } else if let transport {
            runTurnOutputs(&m, &side, &outputs, transport: transport, events: emitted, wantsSync: cadenceSync || joinSync, joinSyncOnly: joinSync)
        }
        side.probe?("turn-end")

        var record = makeTurnRecord(tickId: tickId, applied: applied, emitted: emitted)
        record.stateHash = stateHash
        record.stateSnapshot = stateSnapshot
        record.sequenceBeforeInputs = sequenceBeforeInputs
        record.sequenceBeforeTickHandler = sequenceBeforeTickHandler
        return TickTurnOutput(record: record)
    }

    /// At a tick turn's start: the fold it carries, if any, with how late the turn started
    /// against the deadline the sync folded on (#232). Once per turn. A fold whose sync already
    /// ran in a sync-only turn (`inTurnSyncDue` cleared) is not this turn's and is dropped.
    private func takePendingFold(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        transport: any LandKeeperTransport
    ) {
        guard let fold = pendingFold else { return }
        pendingFold = nil
        guard m.inTurnSyncDue else { return }
        let start = tickClockForTesting ?? ContinuousClock.now
        let report = InTurnSyncFold(
            overdueAtFold: fold.overdueAtFold,
            tickLateness: start - fold.deadline,
            coincidentWindow: coincidentSyncWindow
        )
        if report.isLate { m.lateFoldedSyncs += 1 }
        // A refusal ends the land in the call (`callOut`), before the tick's inputs: the caller's
        // failure branch skips them and the handler, so the position says the failure ended
        // the tick's inputs (`endsInputs`), with none applied, and replay skips them too.
        if m.transportRecordsFolds {
            _ = callOut(&m, &side, &outputs, endsInputs: true, appliedInputs: false, { _ in transport.noteInTurnSyncFold(report) })
        }
    }

    /// After a tick turn: one recorder submission with everything the turn recorded. Live mode
    /// records a frame for every tick, even without inputs.
    private func finishTickTurn(_ output: TickTurnOutput) async {
        await submitTurnRecord(output.record)
    }

    /// The record of a turn's inputs and server events for `tickId`.
    private func makeTurnRecord(
        tickId: Int64,
        applied: AppliedInputs,
        emitted: [EmittedEvent]
    ) -> ReevaluationTickRecord {
        ReevaluationTickRecord(
            tickId: tickId,
            actions: applied.recordedActions,
            clientEvents: applied.recordedClientEvents,
            lifecycleEvents: applied.recordedLifecycleEvents,
            serverEvents: emitted.map { item in
                ReevaluationRecordedServerEvent(
                    kind: "serverEvent",
                    sequence: item.sequence,
                    tickId: item.tickId,
                    typeIdentifier: item.event.type,
                    payload: item.event.payload,
                    target: ReevaluationEventTargetRecord.from(item.target)
                )
            },
            serverInputs: applied.recordedServerInputs,
            // A tickless land records them on its pass instead (#586).
            rejected: isTickless ? [] : applied.rejected
        )
    }

    /// What initialization's turn body leaves for the work after it.
    private struct InitializeTurnOutput {
        let record: ReevaluationRecordedInitialize?
        let marker: ReevaluationRecordedSyncMarker?
    }

    /// Initialization's turn, from OnInitialize's step through its output step, on the model the
    /// turn holds (#700 K1b-5a step 2). The failure is the error `validate` threw: nothing was
    /// written then. Each port call goes through `callOut`; a refusal ends the land in that call,
    /// and the turn then runs no output step, as after a failed phase.
    private func initializeTurnBody(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        handler: InitializeHandler<State>,
        ctx: LandContext,
        sequence: Int64
    ) -> Result<InitializeTurnOutput, any Error> {
        do {
            // `invoke` throws only from `validate`, before `apply` writes (#593).
            try withHandlerStep(&m, ctx) { m, ctx in
                try handler.invoke(&m.state, ctx)
            }
        } catch {
            return .failure(error)
        }
        let tickId = ctx.tickId ?? m.lastCommittedTickId
        // Recorded in the same synchronous segment as the state write: sync outputs before
        // this point read the state before OnInitialize, outputs after it the state after.
        let record = reevaluationRecorder == nil ? nil : makeInitializeRecord(&m, sequence: sequence, tickId: tickId)
        // The marker reads the port's witness (`recordsSyncStream`).
        var refused = false
        var marker: ReevaluationRecordedSyncMarker?
        switch callOut(&m, &side, &outputs, { _ in recordsSyncStream }) {
        case .refused:
            refused = true
        case .answered(true):
            marker = ReevaluationRecordedSyncMarker(
                kind: .initialize, streamIndex: takeSyncStreamIndex(&m), sequence: sequence,
                afterPass: isTickless ? m.passOrdinal : nil
            )
        case .answered(false):
            break
        }
        // OnInitialize is a turn on every live keeper: its events and sync request are taken
        // here, after its record read them. With a port they go out in this turn; without one
        // (not attached yet) they are delivered nowhere (#546 L2d).
        if routesThroughTurn {
            let emitted = takeEmittedEvents(&m, forTick: tickId)
            let wantsSync = takeSyncRequest(forTick: tickId, applied: nil)
            if !refused, let transport {
                switch callOut(&m, &side, &outputs, { _ in syncsInTurn }) {
                case .refused:
                    refused = true
                case .answered(true):
                    runTurnOutputs(&m, &side, &outputs, transport: transport, events: emitted, wantsSync: wantsSync)
                case .answered(false):
                    break
                }
            }
            if refused { m.inTurnSyncDue = false }
        }
        return .success(InitializeTurnOutput(record: record, marker: marker))
    }

    /// What OnInitialize did, read right after it: the server events emitted for `tickId` after
    /// its lifecycle `sequence` (not removed from the collector) and the state hash.
    private func makeInitializeRecord(_ m: inout KeeperModel<State>, sequence: Int64, tickId: Int64) -> ReevaluationRecordedInitialize {
        let events = outputCollector.emittedEvents
            .filter { $0.tickId == tickId && $0.sequence > sequence }
            .sorted { $0.sequence < $1.sequence }
        return ReevaluationRecordedInitialize(
            sequence: sequence,
            serverEvents: events.map { item in
                ReevaluationRecordedServerEvent(
                    kind: "serverEvent",
                    sequence: item.sequence,
                    tickId: item.tickId,
                    typeIdentifier: item.event.type,
                    payload: item.event.payload,
                    target: ReevaluationEventTargetRecord.from(item.target)
                )
            },
            stateHash: behavior.config.enableLiveStateHashRecording ? liveStateHash(&m, tickId: tickId).hash : nil
        )
    }

    /// Ticks (and initialize) whose live state hash could not be computed and were recorded as
    /// `ReevaluationEngine.unavailableHash`.
    public var stateHashUnavailableCount: Int { model.stateHashUnavailableTotal }

    /// The full-state hash of the current state for live recording (#180). A conversion that
    /// throws never stops the tick: the hash is recorded as unavailable, logged and counted, and
    /// replay reports that tick as unverifiable.
    private func liveStateHash(_ m: inout KeeperModel<State>, tickId: Int64) -> (hash: String, snapshot: StateSnapshot) {
        let (hash, snapshot) = ReevaluationEngine.calculateStateHashAndSnapshot(m.state)
        if ReevaluationEngine.isUnavailableHash(hash) {
            m.stateHashUnavailableTotal += 1
            behavior.logger.error("State hash unavailable; tick recorded without a hash", metadata: [
                "tickId": .stringConvertible(tickId),
                "reason": .string(hash),
                "unavailableCount": .stringConvertible(m.stateHashUnavailableTotal),
            ])
        }
        return (hash, snapshot)
    }

    /// The next sync-stream position. Callers take it only while the land records its sync
    /// stream, in the same synchronous segment as the entry.
    private func takeSyncStreamIndex(_ m: inout KeeperModel<State>) -> UInt64 {
        let index = m.syncStreamCounter
        m.syncStreamCounter += 1
        return index
    }

    // MARK: - Sync stream (record format 2.1), for the adapter while in-turn sync is on

    /// Whether this keeper records its sync stream: live, with a recorder, and in-turn sync on.
    /// The adapter asks it (through `assumeIsolated`, on the shared executor) before planning.
    package var recordsSyncStream: Bool {
        behavior.config.mode == .live && reevaluationRecorder != nil && syncsInTurn
    }

    /// Where a plan reading the state now reads it, on the model a turn body holds.
    private func syncReadPosition(_ m: KeeperModel<State>) -> SyncReadPosition {
        SyncReadPosition(
            observedTickId: m.lastCommittedTickId,
            sequence: outputCollector.nextSequence,
            afterPass: isTickless ? m.passOrdinal : nil
        )
    }

    /// Numbers a tickless land's pass (#563): called in the synchronous segment that applied
    /// `applied`, before anything reads the state after it, never after an await. Nil for a pass
    /// that applied nothing (no pass is recorded) and on a tick land (no passes).
    private func takePassOrdinal(_ m: inout KeeperModel<State>, applied: AppliedInputs) -> Int64? {
        m.passInProgress = nil
        guard countsPasses, !applied.appliedOrder.isEmpty else { return nil }
        m.passOrdinal += 1
        return m.passOrdinal
    }

    /// Marks a tickless pass as applying, so a failure while it applies names it (`failLand`).
    /// `takePassOrdinal` ends it in the same segment.
    private func beginPass(_ m: inout KeeperModel<State>) {
        m.passInProgress = countsPasses ? m.passOrdinal + 1 : nil
    }

    /// Whether passes are numbered: a tickless land that records (live, with a recorder) or
    /// replays. Without a recorder nothing reads the ordinal, so the default path doesn't count.
    private var countsPasses: Bool {
        isTickless && (reevaluationRecorder != nil || behavior.config.mode == .reevaluation)
    }

    /// What the sync stream records of the current turn's sync phase, nil when it isn't
    /// recorded: the turn's kind (`tick` or `syncOnly`) and where the phase reads the state.
    private func inTurnSyncRecording(_ m: KeeperModel<State>) -> InTurnSyncRecording? {
        guard recordsSyncStream else { return nil } // lint-allow: bare-port: every caller calls this inside callOut
        return InTurnSyncRecording(turnKind: m.inTurnSyncTurnKind, position: syncReadPosition(m))
    }

    // MARK: - Turn bodies: the side, the staged outputs, calls out (#700 K1b-5a)

    /// Runs one turn body. The body gets the turn side and a fresh `TurnOutputs`, both `inout`.
    /// Before this returns, and before any suspension in the caller: the depth drops, the
    /// staged outputs flush (once, in staging order), and the backstop applies a refused
    /// re-entry the body didn't apply. A throwing body flushes the same way.
    ///
    /// The result is fixed before the `defer`s run, so it can't carry anything the flush makes
    /// (a submission's task): `withTurnSubmitting` returns that. The final flush runs on a copy
    /// of the side, so no access to `turnSide` is held while its actions run.
    @discardableResult
    private func withTurn<R>(_ body: (inout KeeperModel<State>, inout KeeperTurnSide, inout TurnOutputs) throws -> R) rethrows -> R {
        assert(sentinel.bodyDepth == 0, "turn bodies don't nest")
        var outputs = TurnOutputs()
        let violationsBefore = sentinel.reentryViolations
        defer {
            let side = turnSide
            side.flush(&outputs)
            applyLateReentry(since: violationsBefore)
        }
        sentinel.bodyDepth += 1
        defer { sentinel.bodyDepth -= 1 }
        return try body(&model, &turnSide, &outputs)
    }

    /// `withTurn` for a body whose flush makes the submission its caller awaits: the body runs
    /// in an inner scope (the depth drops when it ends), then an explicit flush, and this returns
    /// the turn's last submission (from any of its flushes, `callOut`'s included) with the body's
    /// result. A throw flushes in the `defer` instead.
    private func withTurnSubmitting<R>(
        _ body: (inout KeeperModel<State>, inout KeeperTurnSide, inout TurnOutputs) throws -> R
    ) rethrows -> (result: R, submission: Task<Void, Never>?) {
        assert(sentinel.bodyDepth == 0, "turn bodies don't nest")
        var outputs = TurnOutputs()
        let violationsBefore = sentinel.reentryViolations
        var flushed = false
        defer {
            if !flushed {
                let side = turnSide
                side.flush(&outputs)
            }
            applyLateReentry(since: violationsBefore)
        }
        let result: R
        do {
            sentinel.bodyDepth += 1
            defer { sentinel.bodyDepth -= 1 }
            result = try body(&model, &turnSide, &outputs)
        }
        let side = turnSide
        side.flush(&outputs)
        flushed = true
        return (result, outputs.lastSubmission)
    }

    /// What a call out of the keeper returned: its answer, or, when the callee re-entered the
    /// keeper and was refused, only the failure. A refused call's answer is never readable.
    private enum CallOutcome<Answer> {
        case answered(Answer)
        case refused(LandFailure)
    }

    /// A call out of the keeper during a turn body (a port call, a transport's property read).
    /// The body's staged outputs flush first, so the callee sees today's order. If the flush's
    /// actions re-entered the keeper and were refused (`noteReentry`), the land ends there and
    /// the call isn't made. If the callee re-entered, the land ends after the call, before the
    /// body could read the answer. Either way the outcome is `.refused`.
    private func callOut<Answer>(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        endsInputs: Bool = false,
        appliedInputs: Bool = false,
        _ call: (KeeperModel<State>) -> Answer
    ) -> CallOutcome<Answer> {
        let before = sentinel.reentryViolations
        side.flush(&outputs)
        guard sentinel.reentryViolations == before else {
            sentinel.reentriesAppliedInCall += 1
            return .refused(applyReentryFailure(&m, &side, endsInputs: endsInputs, appliedInputs: appliedInputs))
        }
        let answer = call(m)
        guard sentinel.reentryViolations == before else {
            sentinel.reentriesAppliedInCall += 1
            return .refused(applyReentryFailure(&m, &side, endsInputs: endsInputs, appliedInputs: appliedInputs))
        }
        return .answered(answer)
    }

    /// Refuses a synchronous re-entry during a turn body, from an adapter-facing entry. The
    /// entry changes nothing; this:
    /// 1. notes the failure in the set-once mailbox (the first cause noted wins);
    /// 2. closes the output gate (the attached transport, or else the bound requester), as the
    ///    adapter's own failure path does, so nothing of the interrupted turn goes out;
    /// 3. counts it.
    /// It calls nothing outside the keeper but the gate's close: the log line is written when
    /// the keeper applies the failure (`applyReentryFailure`), after control is back. The body's
    /// `callOut` sees the count grow and ends the land before the body reads the call's answer;
    /// `withTurn`'s backstop does it for any other path.
    private func noteReentry(through entry: String) {
        sentinel.reentryViolations += 1
        let reported = LandFailure(
            kind: .keeperReentry,
            detail: "\(entry) was called while a turn body ran",
            position: LandFailurePosition(stage: .syncPhase)
        )
        if sentinel.reentryFailure == nil { sentinel.reentryFailure = reported }
        notePendingFailure(reported)
        // A gate the sentinel already closed isn't closed again by a further refusal in the turn.
        // The check needs class identity: a value-type port, or a close that re-enters during
        // `failLand`'s own close, can close the gate twice.
        if let gate = transport ?? boundSyncRequester, !sentinel.closingGateForReentry,
           !(Self.gateObject(gate).map { $0 === sentinel.reentryClosedGate } ?? false) {
            sentinel.closingGateForReentry = true
            defer { sentinel.closingGateForReentry = false }
            gate.closeOutputs(for: reported)
            sentinel.reentryGateClosed = true
            sentinel.reentryClosedGate = Self.gateObject(gate)
        }
    }

    /// A gate as an object when it is a class instance. A value-type gate has no identity, so it
    /// is closed again by `failLand`, as before the skip.
    private static func gateObject(_ gate: any LandKeeperTransport) -> AnyObject? {
        guard type(of: gate) is AnyObject.Type else { return nil }
        return gate as AnyObject
    }

    /// Ends the land on a refused re-entry: the mailbox's first failure (the sentinel's, unless
    /// a transport noted one before it). Returns the failure to report: the land's, or the
    /// sentinel's on a land that was already draining (`failLand` keeps the first cause, so
    /// `failure` stays nil there; the gate is closed all the same).
    /// `endsInputs` and `appliedInputs` are `failLand`'s: the refusal ended its turn's inputs
    /// (the fold report, before them; the join report, after the pass applied its joins), and
    /// whether inputs were applied before it, so the position says what replay must skip.
    private func applyReentryFailure(_ m: inout KeeperModel<State>, _ side: inout KeeperTurnSide, endsInputs: Bool = false, appliedInputs: Bool = false) -> LandFailure {
        let reported = sentinel.reentryFailure ?? LandFailure(
            kind: .keeperReentry,
            detail: "a call was refused while a turn body ran",
            position: LandFailurePosition(stage: .syncPhase)
        )
        behavior.logger.error("A transport re-entered the keeper during a turn; ending the land", metadata: [
            "landID": .string(behavior.config.actualLandID ?? "-"),
            "failure": .string(reported.description),
            "gateClosed": .stringConvertible(sentinel.reentryGateClosed),
        ])
        if failure == nil {
            failLand(&m, &side, pendingTransportFailure.failure ?? reported, endsInputs: endsInputs, appliedInputs: appliedInputs)
        }
        return failure ?? reported
    }

    /// The backstop: a re-entry refused during a body that didn't apply it (a call not made
    /// through `callOut`). The body's result was already fixed, so this is logged as late.
    private func applyLateReentry(since violationsBefore: Int) {
        guard sentinel.reentryViolations != violationsBefore, failure == nil, !isDraining else { return }
        let applied = applyReentryFailure(&model, &turnSide)
        sentinel.lateReentriesApplied += 1
        behavior.logger.error("A refused re-entry was applied after its turn body returned", metadata: [
            "landID": .string(behavior.config.actualLandID ?? "-"),
            "failure": .string(applied.description),
        ])
    }

    /// Tests: re-entries refused so far.
    package var reentryViolationsForTesting: Int { sentinel.reentryViolations }

    /// Tests: refused re-entries the backstop applied (`applyLateReentry`).
    package var lateReentriesAppliedForTesting: Int { sentinel.lateReentriesApplied }
    /// Tests: how many refused re-entries a `callOut` applied in its own call.
    package var reentriesAppliedInCallForTesting: Int { sentinel.reentriesAppliedInCall }

    /// Tests: turn bodies running now (0 outside a body).
    package var bodyDepthForTesting: Int { sentinel.bodyDepth }

    /// Tests: the recorder submission tracker (its count and trace).
    package var recorderSubmissionsForTesting: ReevaluationSubmissionTracker { recorderSubmissions }

    /// Tests: a turn body that stages `count` effects (`effect` gets each one's index), then, if
    /// `callingOut` is given, calls it through `callOut`, then runs `observe` with the depth,
    /// then throws `error` if given. Returns whether the call out was refused.
    @discardableResult
    package func runTestBodyForTesting(
        staging count: Int,
        effect: @escaping (_ index: Int) -> Void,
        callingOut: (() -> Void)? = nil,
        observe: (_ bodyDepth: Int) -> Void = { _ in },
        throwing error: (any Error)? = nil
    ) throws -> Bool {
        try withTurn { m, side, outputs in
            for index in 0..<count { outputs.stage { effect(index) } }
            var refused = false
            if let callingOut, case .refused = callOut(&m, &side, &outputs, { _ in callingOut() }) { refused = true }
            observe(sentinel.bodyDepth)
            if let error { throw error }
            return refused
        }
    }

    /// Tests: join sync turns scheduled, counted where they are scheduled (before the turn's own
    /// guards could retire it).
    package var joinSyncTurnsScheduledForTesting: Int { model.joinSyncTurnsScheduledForTesting }

    /// Tests: `submitTurnRecord` on an empty record of `tickId`.
    package func submitTurnRecordForTesting(tickId: Int64) async {
        await submitTurnRecord(ReevaluationTickRecord(tickId: tickId))
    }

    /// Tests: marks the land draining with `cause`, as the land's stop does first, without
    /// starting the drain.
    package func markDrainingForTesting(cause: LandDestructionCause) {
        drainFlag.set(cause: cause)
    }

    /// Numbers and submits sync-stream drafts in order: an in-turn phase's (returned from
    /// `runSyncPhaseInTurn`, in the same turn), and those the adapter makes outside a phase in
    /// turn: a legacy cycle's or an initial sync's commit, a disconnect's or a superseded
    /// session's clear, each in the synchronous segment of what it describes. `outsideTurn`: as
    /// `recordSyncMarker`'s.
    ///
    /// The sync stream ends at the land failure (#535 D9): once `failure` is set nothing more
    /// is numbered or recorded, outputs, seeds and clears alike (the clears of the sessions the
    /// failure's teardown closes included). Replay stops at the failure's tick, so nothing after
    /// it is verified. The failing turn's drafts submitted before `failLand` are kept.
    ///
    /// The adapter's entry. A call made while a turn body runs (a callback during one of the
    /// keeper's port calls) is refused and ends the land (`noteReentry`); the bodies record
    /// through `recordSyncStream`.
    package func submitSyncStream(_ drafts: [SyncStreamDraft], outsideTurn: Bool = false) {
        guard sentinel.bodyDepth == 0 else {
            noteReentry(through: "submitSyncStream")
            return
        }
        withTurn { m, side, _ in
            // The drafts' factories run here; one that re-entered ends the land in this body.
            let before = sentinel.reentryViolations
            recordSyncStream(&m, drafts, outsideTurn: outsideTurn)
            if sentinel.reentryViolations != before { _ = applyReentryFailure(&m, &side) }
        }
    }

    /// `submitSyncStream`'s work, for the keeper's own turns.
    private func recordSyncStream(_ m: inout KeeperModel<State>, _ drafts: [SyncStreamDraft], outsideTurn: Bool = false) {
        guard reevaluationRecorder != nil, failure == nil else { return }
        for draft in drafts {
            switch draft.entry {
            case let .output(observedTickId, make):
                recordSyncOutput(&m, observedTickId: observedTickId, make)
            case let .marker(make):
                let position = syncReadPosition(m)
                recordSyncMarker(&m, outsideTurn: outsideTurn) { make($0, position) }
            }
        }
    }

    /// Numbers and records one sync output: `make` gets its `streamIndex` and `index`. Called in
    /// the same synchronous segment as the commit it describes; the record is submitted after
    /// every earlier submission without waiting.
    private func recordSyncOutput(
        _ m: inout KeeperModel<State>,
        observedTickId: Int64?,
        _ make: (_ streamIndex: UInt64, _ index: Int) -> ReevaluationRecordedSyncOutput
    ) {
        guard reevaluationRecorder != nil else { return }
        let index: Int
        if let cursorTick = m.syncOutputIndexCursor.observedTickId, cursorTick == observedTickId {
            index = m.syncOutputIndexCursor.count
        } else {
            index = 0
        }
        m.syncOutputIndexCursor = SyncOutputIndexCursor(observedTickId: observedTickId, count: index + 1)
        let output = make(takeSyncStreamIndex(&m), index)
        enqueueRecorderSubmission(&m, ReevaluationTickRecord(
            tickId: max(observedTickId ?? m.lastCommittedTickId, 0),
            syncOutputs: [output]
        ))
    }

    /// Numbers and records one marker: `make` gets its `streamIndex`. A seed goes into the frame
    /// of its `observedTickId`, a clear into the current tick's.
    ///
    /// `outsideTurn`: the marker is recorded outside any keeper turn (a disconnect's or a
    /// superseded session's clear). On a tickless land it is then its own turn record, so no
    /// later turn has to close it (#327).
    private func recordSyncMarker(
        _ m: inout KeeperModel<State>,
        outsideTurn: Bool = false,
        _ make: (_ streamIndex: UInt64) -> ReevaluationRecordedSyncMarker
    ) {
        guard reevaluationRecorder != nil else { return }
        let marker = make(takeSyncStreamIndex(&m))
        enqueueRecorderSubmission(&m, ReevaluationTickRecord(
            tickId: max(marker.observedTickId ?? m.lastCommittedTickId, 0),
            syncMarkers: [marker]
        ), endsTurn: outsideTurn && isTickless)
    }

    /// Submits `record` after every earlier submission, without waiting for it; returns the
    /// submission (nil without a recorder).
    @discardableResult
    private func enqueueRecorderSubmission(_ m: inout KeeperModel<State>, _ record: ReevaluationTickRecord, endsTurn: Bool = false) -> Task<Void, Never>? {
        guard let recorder = reevaluationRecorder else { return nil }
        m.recorderSubmissionCount += 1
        return recorderSubmissions.submit(label: Self.submissionLabel(of: record)) {
            await recorder.recordTick(record, endsTurn: endsTurn)
        }
    }

    /// Ends a tickless land's turn record after every earlier submission, if the turn enqueued
    /// anything since `mark` (`recorderSubmissionCount` at its start). Called in the turn's
    /// synchronous segment, as its last enqueue.
    private func enqueueTicklessTurnEnd(_ m: inout KeeperModel<State>, since mark: Int) {
        guard isTickless, m.recorderSubmissionCount != mark, let recorder = reevaluationRecorder else { return }
        m.recorderSubmissionCount += 1
        recorderSubmissions.submit(label: "endTurn") { await recorder.endTurn() }
    }

    /// Tests only: waits until every recorder submission so far is recorded.
    func waitForRecorderSubmissionsForTesting() async {
        await recorderSubmissions.waitForAll()
    }

    /// Tests only: waits until no tickless input task is in flight (`debugBeginWork`, counted
    /// before the call that started it returned), then until its recorder submissions are in.
    func waitForInFlightWorkForTesting() async {
        while model.debugInFlightWork > 0 {
            model.debugNextWaiterID &+= 1
            let waiterID = model.debugNextWaiterID
            await withCheckedContinuation { continuation in
                turnSide.debugDrainWaiters[waiterID] = continuation
            }
        }
        await recorderSubmissions.waitForAll()
    }

    /// Tests only: the next sync-stream position (how many entries were numbered).
    func syncStreamCounterForTesting() -> UInt64 {
        model.syncStreamCounter
    }

    /// Submits `record` after every earlier submission (turn order) and returns once it is
    /// recorded. No-op without a recorder. On a tickless land the record ends the turn's
    /// record (#327). It is enqueued before the first `await`, in the caller's synchronous
    /// segment, so it is the turn's last enqueue; the hold (tests) comes after it.
    ///
    /// The submission is staged in its own turn body and flushed before the hold, and this
    /// awaits that exact task, never the tracker's tail after the hold, which could be a later
    /// turn's. Without a recorder there is no task, and the hold is still entered.
    private func submitTurnRecord(_ record: ReevaluationTickRecord) async {
        let (_, submission) = withTurnSubmitting { m, _, outputs in
            stageRecorderSubmission(&m, record, endsTurn: isTickless, outputs: &outputs)
        }
        await holds.at(.turnRecord)
        await submission?.value
    }

    /// `enqueueRecorderSubmission` for a turn body: the count moves now, the submission is
    /// staged into `outputs`.
    private func stageRecorderSubmission(_ m: inout KeeperModel<State>, _ record: ReevaluationTickRecord, endsTurn: Bool, outputs: inout TurnOutputs) {
        guard let recorder = reevaluationRecorder else { return }
        m.recorderSubmissionCount += 1
        outputs.stageSubmission(Self.submissionLabel(of: record)) {
            await recorder.recordTick(record, endsTurn: endsTurn)
        }
    }

    /// The submission trace's name for `record` (tests).
    private static func submissionLabel(of record: ReevaluationTickRecord) -> String {
        if record.landFailure != nil { return "terminal" }
        if !record.syncOutputs.isEmpty { return "sync-output" }
        if !record.syncMarkers.isEmpty { return "sync-marker" }
        return "turn-record"
    }

    /// How a turn goes on after its apply segment (#704; #716 adds its depth check).
    enum ApplyEnd: Equatable {
        /// Nothing ended the land: the turn's outputs go out.
        case proceed
        /// The land ended in this step: the turn takes its failure branch, with no events and
        /// no sync.
        case ended
    }

    /// The end of an apply segment, before anything of the turn goes out: its events, its sync
    /// phase and its record entry with the hash. Called only when the apply hasn't already
    /// failed the land. It ends the land with a failure a transport noted outside the turn
    /// (`applyPendingTransportFailure`). `appliedInputs`: the segment applied inputs, so the
    /// failure's position names this pass.
    private func finishApply(_ m: inout KeeperModel<State>, _ side: inout KeeperTurnSide, appliedInputs: Bool) -> ApplyEnd {
        applyPendingTransportFailure(&m, &side, endsInputs: true, appliedInputs: appliedInputs) ? .ended : .proceed
    }

    /// Ends the land with the failure a transport noted outside a turn (`notePendingFailure`), if
    /// there is one and the land hasn't failed yet. The failure keeps its own stage
    /// (`actionResponse`, `syncPhase` or `eventFlush`). Returns whether the land has failed.
    private func applyPendingTransportFailure(endsInputs: Bool = false, appliedInputs: Bool = false) -> Bool {
        applyPendingTransportFailure(&model, &turnSide, endsInputs: endsInputs, appliedInputs: appliedInputs)
    }

    /// `applyPendingTransportFailure` on the model a turn body holds.
    private func applyPendingTransportFailure(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        endsInputs: Bool = false,
        appliedInputs: Bool = false
    ) -> Bool {
        if failure == nil, let noted = pendingTransportFailure.failure {
            failLand(&m, &side, noted, endsInputs: endsInputs, appliedInputs: appliedInputs)
        }
        return failure != nil
    }

    /// A sync-only turn (no inputs, no tick): the sync phase on the current state, synchronous,
    /// with the dirty-flag clear in the same turn.
    @discardableResult
    private func runSyncOnlyTurn(transport: any LandKeeperTransport, joinSyncOnly: Bool = false) -> InTurnSyncResult {
        // A failed land sends nothing more (#535): a scheduled repair, writer-drain retry or
        // join-sync turn that runs after the failure returns here.
        guard failure == nil else { return .skipped }
        let markBeforeNote = model.recorderSubmissionCount
        // A failure a transport noted outside a turn ends the land first (#704): no phase runs. A
        // tickless land's turn still ends its record, as after a failed phase.
        if applyPendingTransportFailure(), let failure {
            enqueueTicklessTurnEnd(&model, since: markBeforeNote)
            return .landFailed(failure)
        }
        return withTurn { m, side, outputs in
            side.probe?("turn-begin")
            m.inTurnSyncTurnKind = .syncOnly
            defer { m.inTurnSyncTurnKind = .tick }
            let mark = m.recorderSubmissionCount
            // The sync phase, and the recording it gets, each through `callOut`: a refused
            // re-entry in either ends the land in that call, and the phase's answer is never read.
            var reentry: LandFailure?
            var result = InTurnSyncResult.skipped
            switch callOut(&m, &side, &outputs, { m in inTurnSyncRecording(m) }) {
            case .refused(let refused):
                reentry = refused
            case .answered(let recording):
                switch callOut(&m, &side, &outputs, { m in
                    transport.runSyncPhaseInTurn(state: m.state, events: [], includeSync: true, recording: recording)
                }) {
                case .refused(let refused):
                    reentry = refused
                case .answered(let output):
                    // The transport's draft factories run here, in the body and outside any call
                    // out: a factory that re-entered ends the land before the commit is applied.
                    // The batch is recorded whole first, as a failing phase's is.
                    let beforeRecording = sentinel.reentryViolations
                    recordSyncStream(&m, output.syncStream)
                    guard sentinel.reentryViolations == beforeRecording else {
                        reentry = applyReentryFailure(&m, &side)
                        break
                    }
                    result = output.result
                    applyInTurnSyncResult(
                        &m,
                        &side,
                        output.result,
                        transport: transport,
                        joinSyncOnly: joinSyncOnly,
                        keepsEvents: output.keepsEvents,
                        joinsAwaitingSync: { m, side in
                            // `transportHasJoinsAwaitingSync`, one check per witness: whether the
                            // transport runs this keeper's phase, then whether joins wait.
                            switch callOut(&m, &side, &outputs, { _ in syncsInTurn }) {
                            case .refused(let refused):
                                reentry = refused
                                return nil
                            case .answered(let runsPhase):
                                guard runsPhase, behavior.config.mode == .live, let attached = self.transport else { return false }
                                switch callOut(&m, &side, &outputs, { _ in attached.hasJoinsAwaitingSync }) {
                                case .answered(let awaiting):
                                    return awaiting
                                case .refused(let refused):
                                    reentry = refused
                                    return nil
                                }
                            }
                        }
                    )
                }
            }
            // A refused call leaves the turn as a failed phase does: no sync is due any more.
            // Nothing of a refused phase is recorded or applied. A factory's re-entry keeps the
            // whole batch recorded, the drafts after the trip included, as a failing phase's
            // drafts are; it applies nothing.
            if reentry != nil { m.inTurnSyncDue = false }
            // The common tail, on every path. A tickless land's sync-only turn is its own turn
            // record (#327); a tick land's sync outputs stay with the current tick's.
            enqueueTicklessTurnEnd(&m, since: mark)
            side.probe?("turn-end")
            if let reentry { return .landFailed(failure ?? reentry) }
            return result
        }
    }

    /// A sync-only turn, if this keeper still runs in-turn sync (scheduled turns).
    private func runSyncOnlyTurnIfInTurn() {
        guard syncsInTurn, let transport else { return }
        runSyncOnlyTurn(transport: transport)
    }

    /// After a deferred phase on a land without periodic sync: one sync-only turn once the writer
    /// has drained its sync cycle elements (at most one pending per binding), through the same port.
    private func retrySyncOnlyTurnAfterWriterDrain(_ m: inout KeeperModel<State>, transport: any LandKeeperTransport) {
        guard m.inTurnDrainRetryBinding != m.syncBinding.current else { return }
        m.inTurnDrainRetryBinding = m.syncBinding.current
        beginRequestedSyncWork(&m)
        let followUp = SyncTurnFollowUp(port: transport, binding: m.syncBinding.current)
        Task { [weak self] in
            // Returns when the writer drained or its consumer ended (a teardown), so an
            // invalidated retry still retires.
            await transport.waitForWriterDrainForInTurnSync()
            await self?.runRetriedSyncOnlyTurn(followUp)
        }
    }

    private func runRetriedSyncOnlyTurn(_ followUp: SyncTurnFollowUp) {
        // A newer binding's retry owns the mark; this one only retires its own.
        if model.inTurnDrainRetryBinding == followUp.binding { model.inTurnDrainRetryBinding = nil }
        defer { endRequestedSyncWork() }
        runFollowUpSyncOnlyTurn(followUp)
    }


    /// One sync-only turn for joins waiting on a committed sync phase, after `delay` (at most one
    /// pending per binding). It runs only if joins still wait then.
    private func scheduleJoinSyncTurn(_ m: inout KeeperModel<State>, after delay: Duration, transport port: any LandKeeperTransport) {
        guard m.joinSyncTurnBinding != m.syncBinding.current else { return }
        m.joinSyncTurnBinding = m.syncBinding.current
        m.joinSyncTurnsScheduledForTesting += 1
        beginRequestedSyncWork(&m)
        let followUp = SyncTurnFollowUp(port: port, binding: m.syncBinding.current)
        Task { [weak self] in
            if delay > .zero {
                try? await safeTaskSleep(for: delay)
            }
            await self?.runJoinSyncTurn(followUp)
        }
    }

    private func runJoinSyncTurn(_ followUp: SyncTurnFollowUp) {
        if model.joinSyncTurnBinding == followUp.binding { model.joinSyncTurnBinding = nil }
        defer { endRequestedSyncWork() }
        // `transportHasJoinsAwaitingSync` reads the slot: a keeper with no slot admits no in-turn
        // join (`admitJoiningInTurn`), so it has none waiting.
        guard !isDraining, transportHasJoinsAwaitingSync, acceptsSyncTurn(through: followUp) else { return }
        model.joinSyncTurnsForTesting += 1
        runSyncOnlyTurn(transport: followUp.port)
    }

    // MARK: - Requested sync turns (#546 L2a)

    /// A follow-up a turn armed (the writer-drain retry, the join-sync turn, a requested
    /// turn after this one): the port of the turn that armed it, and the binding it was
    /// armed under. It runs only while that binding holds.
    private struct SyncTurnFollowUp {
        let port: any LandKeeperTransport
        let binding: SyncTurnTicket
    }

    /// The adapter bound by the first sync request of a keeper never attached. Weak: the adapter
    /// holds this keeper. Cleared at the destruction's end.
    private weak var boundSyncRequesterObject: AnyObject?
    private var boundSyncRequester: (any LandKeeperTransport)? {
        boundSyncRequesterObject as? any LandKeeperTransport
    }

    private func noteTransportBound() {
        model.hasHeldTransport = true
        boundSyncRequesterObject = nil
        model.syncBinding.rebind()
    }

    /// Whether `port` is the port this keeper syncs through for a request: the attached transport,
    /// or, on a keeper never attached, its first requester (bound now when none is). One
    /// requester per keeper at a time. The follow-ups' pending state is kept per binding
    /// generation, so a follow-up armed under an older binding never blocks the current one's.
    private func bindSyncRequester(_ port: any LandKeeperTransport) -> Bool {
        bindSyncRequester(&model, port)
    }

    /// `bindSyncRequester` on the model a turn body holds.
    private func bindSyncRequester(_ m: inout KeeperModel<State>, _ port: any LandKeeperTransport) -> Bool {
        let identity = ObjectIdentifier(port as AnyObject)
        if let transport {
            return ObjectIdentifier(transport as AnyObject) == identity
        }
        guard !m.hasHeldTransport else { return false }
        if let bound = boundSyncRequesterObject {
            return ObjectIdentifier(bound) == identity
        }
        boundSyncRequesterObject = port as AnyObject
        m.syncBinding.rebind()
        return true
    }

    /// `bindSyncRequester`'s answer without its binding: whether `port` is, or would become, the
    /// port this keeper syncs through.
    private func isSyncPort(_ m: KeeperModel<State>, _ port: any LandKeeperTransport) -> Bool {
        let identity = ObjectIdentifier(port as AnyObject)
        if let transport { return ObjectIdentifier(transport as AnyObject) == identity }
        guard !m.hasHeldTransport else { return false }
        guard let bound = boundSyncRequesterObject else { return true }
        return ObjectIdentifier(bound) == identity
    }

    /// The checks every requested turn and follow-up makes in its synchronous job: a live land,
    /// not failed or draining, the port in-turn for this keeper (identity and the shared executor,
    /// so its `assumeIsolated` is valid) and this keeper's binding, under the same binding
    /// generation.
    private func acceptsSyncTurn(through port: any LandKeeperTransport, binding: SyncTurnTicket?) -> Bool {
        guard behavior.config.mode == .live, failure == nil, !isDraining else { return false }
        guard port.runsSyncPhaseInTurn(of: self), bindSyncRequester(port) else { return false }
        if let binding, !model.syncBinding.isCurrent(binding) { return false }
        return true
    }

    private func acceptsSyncTurn(through followUp: SyncTurnFollowUp) -> Bool {
        acceptsSyncTurn(through: followUp.port, binding: followUp.binding)
    }

    private func runFollowUpSyncOnlyTurn(_ followUp: SyncTurnFollowUp) {
        guard acceptsSyncTurn(through: followUp) else { return }
        runSyncOnlyTurn(transport: followUp.port)
    }

    /// A request's ticket: the binding generation, captured by a delayed request before its delay
    /// (the repair, the lag timer's). `nil` when `port` may not request on this keeper. Failure
    /// and the drain are final, so the job reads them directly.
    package func syncTurnTicket(via port: any LandKeeperTransport) -> SyncTurnTicket? {
        // A failed or draining land binds no late requester (it would get `onLandDestroyed` without
        // its outputs closed); the job would reject the request anyway.
        guard behavior.config.mode == .live, failure == nil, !isDraining, port.runsSyncPhaseInTurn(of: self), bindSyncRequester(port) else { return nil }
        return model.syncBinding.current
    }

    /// One requested sync-only turn through `port`, now, in this job: an outside request
    /// (`syncNow()`, the adapter's lag timer and behind-commit repair, the resume). Validated, run and retired here; it never returns early because an
    /// earlier request is pending: it consumes that one (same port) before its phase runs, so the
    /// phase can arm a successor. `ticket`: a delayed request's binding generation, `nil` for an
    /// immediate one. Returns the phase's outcome, which names who delivers (`.committed`: this
    /// phase; `.deferredBackPressure`: the writer-drain retry, or the next periodic phase;
    /// `.skipped` while frozen: the resume).
    package func syncTurnNow(
        via port: any LandKeeperTransport,
        reason: SyncTurnReason,
        ticket: SyncTurnTicket? = nil
    ) -> InTurnSyncResult {
        // A request made while a turn body runs (a callback during a port call) would nest a
        // second body: refused, changing nothing here, and the land ends (`noteReentry`).
        guard sentinel.bodyDepth == 0 else {
            noteReentry(through: "syncTurnNow")
            return .skipped
        }
        model.requestedSyncTurnsForTesting[reason, default: 0] += 1
        guard acceptsSyncTurn(through: port, binding: ticket) else { return .skipped }
        if let pending = pendingSyncTurnAfterTurn,
           ObjectIdentifier(pending.port as AnyObject) == ObjectIdentifier(port as AnyObject) {
            pendingSyncTurnAfterTurn = nil
            endRequestedSyncWork()
        }
        return runSyncOnlyTurn(transport: port)
    }

    /// An inside request: a turn asks for a sync-only turn right after it (a turn can't run inside
    /// a turn). One pending; a later inside request of the same binding joins it, one of a newer
    /// binding replaces it (the scheduled task reads the slot when it runs), and an outside request
    /// through the same port consumes it.
    private var pendingSyncTurnAfterTurn: SyncTurnFollowUp?

    private func requestSyncTurnAfterThisTurn(_ m: inout KeeperModel<State>, transport: any LandKeeperTransport, reason: SyncTurnReason) {
        m.requestedSyncTurnsForTesting[reason, default: 0] += 1
        if let pending = pendingSyncTurnAfterTurn {
            if pending.binding != m.syncBinding.current {
                pendingSyncTurnAfterTurn = SyncTurnFollowUp(port: transport, binding: m.syncBinding.current)
            }
            return
        }
        pendingSyncTurnAfterTurn = SyncTurnFollowUp(port: transport, binding: m.syncBinding.current)
        beginRequestedSyncWork(&m)
        Task { [weak self] in
            await self?.runPendingSyncTurnAfterTurn()
        }
    }

    private func runPendingSyncTurnAfterTurn() {
        // Consumed by an outside request meanwhile: retired without a turn.
        guard let followUp = pendingSyncTurnAfterTurn else { return }
        pendingSyncTurnAfterTurn = nil
        defer { endRequestedSyncWork() }
        runFollowUpSyncOnlyTurn(followUp)
    }

    /// Tests: the binding a pending writer-drain retry was armed under, and the current binding.
    package var inTurnDrainRetryBindingForTesting: SyncTurnTicket? { model.inTurnDrainRetryBinding }
    package var syncBindingForTesting: SyncTurnTicket { model.syncBinding.current }


    // MARK: Requested sync work, for the test wait

    /// Test waiters, by id: each returns once at most its `atMost` follow-ups are pending, or when
    /// its task is cancelled (a test bounds the wait with `withinHangBound`).
    private var requestedSyncWorkWaitersForTesting: [Int: (atMost: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var nextRequestedSyncWorkWaiterForTesting = 0

    private func beginRequestedSyncWork(_ m: inout KeeperModel<State>) {
        m.requestedSyncWork += 1
    }

    private func endRequestedSyncWork() {
        model.requestedSyncWork -= 1
        assert(model.requestedSyncWork >= 0, "requested sync work ended twice")
        guard !requestedSyncWorkWaitersForTesting.isEmpty else { return }
        let reached = requestedSyncWorkWaitersForTesting.filter { model.requestedSyncWork <= $0.value.atMost }
        for (id, waiter) in reached {
            requestedSyncWorkWaitersForTesting.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    /// Tests: returns once no requested sync work is pending: no writer-drain retry, join-sync
    /// turn or requested turn armed and not yet run (its frames then are with the
    /// writer) or retired. Also returns when its task is cancelled.
    package func waitForRequestedSyncTurnsForTesting() async {
        await waitForRequestedSyncTurnsForTesting(atMost: 0)
    }

    /// Tests only. Returns once at most `count` requested follow-ups are pending (one still held,
    /// for example, while another retires), or when its task is cancelled. Interim: the core's
    /// quiescence wait (#702) replaces this.
    package func waitForRequestedSyncTurnsForTesting(atMost count: Int) async {
        guard model.requestedSyncWork > count else { return }
        let id = nextRequestedSyncWorkWaiterForTesting
        nextRequestedSyncWorkWaiterForTesting += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || model.requestedSyncWork <= count {
                    continuation.resume()
                    return
                }
                requestedSyncWorkWaitersForTesting[id] = (count, continuation)
            }
        } onCancel: {
            Task { await self.cancelRequestedSyncWorkWaiterForTesting(id) }
        }
    }

    private func cancelRequestedSyncWorkWaiterForTesting(_ id: Int) {
        requestedSyncWorkWaitersForTesting.removeValue(forKey: id)?.continuation.resume()
    }

    /// Tests: whether requested sync work is pending, without waiting.
    package var hasRequestedSyncWorkForTesting: Bool { model.requestedSyncWork > 0 }

    // MARK: - In-turn sync: tickless input turns

    private var tickIdleWaiters: [CheckedContinuation<Void, Never>] = []

    private func endTickInFlight() {
        model.ticksInFlight -= 1
        guard model.ticksInFlight == 0 else { return }
        let waiters = tickIdleWaiters
        tickIdleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Returns once no tick is in flight. Called by the drain after `isDraining` is set, so no
    /// new tick starts meanwhile.
    private func waitForTickInFlight() async {
        guard model.ticksInFlight > 0 else { return }
        await withCheckedContinuation { tickIdleWaiters.append($0) }
    }


    /// Lets tickless intake held by a freeze (`debugWaitWhileFrozen`) continue when the drain
    /// starts: each re-checks `rejectIfLandClosed` and gets `.landClosed`, instead of waiting for
    /// a resume that never comes.
    private func releaseHeldInputsForDrain(_ m: inout KeeperModel<State>) {
        dropServerInputsHeldWhileFrozen(&m)
        let held = debugHeldInputs
        debugHeldInputs.removeAll()
        held.forEach { $0.resume() }
    }

    /// The rest of the shutdown turn (#382), in the segment that applied its input
    /// (`applyInputs`): the players are cleared there; here every input still queued is
    /// dropped (its caller gets `.landClosed`), the drain flag is set, so intake is closed and
    /// no tick starts, and intake held by a freeze is released to be rejected. The destroy
    /// follows in `forceShutdown`. The turn changes no land state and requests no sync.
    ///
    /// In re-evaluation the shutdown only ends the replay: the recorded inputs left are dropped,
    /// the tick that replays it runs no tick handler, and no later tick runs (`runTick`). The
    /// viewers stay, the land stays open, and its own empty-room destroy still applies. The
    /// destroy runs, but runs no handlers (#826).
    private func completeShutdownTurn(_ m: inout KeeperModel<State>, _ side: inout KeeperTurnSide) {
        m.shutdownTurnApplied = true
        guard behavior.config.mode == .live else {
            m.pendingItems.removeAll()
            return
        }
        dropPendingInputs(&m, &side, reason: "forceShutdown")
        drainFlag.set(cause: .forceShutdown)
        releaseHeldInputsForDrain(&m)
        resumeShutdownTurnWaiters()
    }

    /// Ends the land on a failure it can't recover from (#535). Synchronous, and called only
    /// inside a turn, in the segment where the failure is seen, so no await separates any of
    /// this from the failure:
    /// - the mark: the drain flag is set with cause `.failed` and the failure stored (the first
    ///   failure wins; a land already draining for another cause keeps that cause), so every
    ///   `isDraining` check refuses from here and no tick starts;
    /// - the settle: every queued input is dropped (its caller gets `.landClosed`), action jobs
    ///   in their resolvers are cancelled, held intake is released to be rejected, and
    ///   `forceShutdown` waiters are resumed;
    /// - the teardown's synchronous part: the players are cleared without OnLeave (decision D4),
    ///   and `drainTask` is installed, so a later `forceShutdown` or `shutdownIfIdle` joins it.
    ///   The task tells the transport (`landDidFail`, which returns once the sessions are
    ///   closed) and then runs the existing drain: destroy handlers and save see `.failed`.
    ///
    /// The position's tick is filled here when the reporter didn't know it.
    /// The transport reports a failure that ends the land (#535), from outside a turn: the legacy
    /// sync path's plan throw, or an output it couldn't encode. The failure is queued as a turn
    /// input; the turn that applies it ends the land (`failLand`), so keeper state changes only in
    /// a turn. Dropped when the land is already draining: the first cause stays.
    ///
    /// The plan's lifecycle ticket isn't needed: a transport serves one keeper instance, and a
    /// further failure of the same instance is a no-op (the first failure wins).
    package func submitLandFailure(_ failure: LandFailure) {
        guard behavior.config.mode == .live else { return }
        guard !isDraining else {
            behavior.logger.debug("A land failure after the land started ending; the first cause stays", metadata: [
                "failure": .string(failure.description),
            ])
            return
        }
        let sequence = outputCollector.takeNextSequence()
        model.pendingItems.append(.landFailure(PendingLandFailureItem(
            sequence: sequence,
            resolvedAtTick: model.lastCommittedTickId,
            failure: failure
        )))
        kickServerInputTurn(upTo: sequence)
    }

    /// Callers of `waitForFailureForTesting`, resumed when the land fails.
    private var failureWaitersForTesting: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    private var nextFailureWaiterForTesting: UInt64 = 0

    /// Test hook: returns true once the land has failed (at once if it already has), or false
    /// after `hangBound` if it never does, so a test of a failure that doesn't happen fails
    /// instead of hanging. Event-driven: a submitted failure is applied by a turn that runs
    /// after the submitter returns; the bound is only a hang guard.
    @discardableResult
    package func waitForFailureForTesting(hangBound: Duration = .seconds(30)) async -> Bool {
        guard failure == nil else { return true }
        nextFailureWaiterForTesting += 1
        let id = nextFailureWaiterForTesting
        let expiry = Task { [weak self] in
            try? await safeTaskSleep(for: hangBound)
            await self?.expireFailureWaiterForTesting(id)
        }
        defer { expiry.cancel() }
        return await withCheckedContinuation { failureWaitersForTesting[id] = $0 }
    }

    private func expireFailureWaiterForTesting(_ id: UInt64) {
        failureWaitersForTesting.removeValue(forKey: id)?.resume(returning: false)
    }

    /// Test hook: reports `failure` as a further producer would (part A has one producer, the
    /// in-turn plan throw), so a test can drive a second failure or one after a stop began.
    package func failLandForTesting(_ failure: LandFailure) {
        failLand(&model, &turnSide, failure)
    }

    /// Ends the land on `reported` (#535). `endsInputs`: applied as an input (`applyInputs`),
    /// the failure ended its turn's batch there; `appliedInputs`: the batch applied inputs
    /// before it. The recorded position says so (`LandFailurePosition.endsInputs`), so replay
    /// ends that tick or pass the same way.
    private func failLand(_ m: inout KeeperModel<State>, _ side: inout KeeperTurnSide, _ reported: LandFailure, endsInputs: Bool = false, appliedInputs: Bool = false) {
        // A tickless land counts by pass (#535 D9): the pass that applied inputs before the
        // failure, else the last one recorded. A pass that applied nothing is never recorded.
        let lastPass: Int64? = m.passOrdinal > 0 ? m.passOrdinal : nil
        let pass: Int? = isTickless ? ((endsInputs && appliedInputs ? m.passInProgress : nil) ?? lastPass).map(Int.init) : nil
        // On a tickless land a failure ends work only in a pass that applied something; on a
        // tick land it also skips the tick handler.
        let ended = endsInputs && (!isTickless || appliedInputs)
        let base = reported.position
        let position = LandFailurePosition(
            tickId: base.tickId == nil && base.pass == nil ? (m.lastCommittedTickId >= 0 ? m.lastCommittedTickId : nil) : base.tickId,
            pass: base.tickId == nil && base.pass == nil ? pass : base.pass,
            sequence: base.sequence,
            stage: base.stage,
            endsInputs: ended ? true : nil
        )
        let failure = LandFailure(kind: reported.kind, field: reported.field, detail: reported.detail, position: position)
        guard behavior.config.mode == .live else {
            behavior.logger.error("A land failure in re-evaluation; replay doesn't end the land", metadata: [
                "failure": .string(failure.description),
            ])
            return
        }
        guard drainFlag.setFailed(failure) else {
            behavior.logger.debug("A further land failure after the land started ending; the first cause stays", metadata: [
                "failure": .string(failure.description),
            ])
            return
        }
        behavior.logger.error("Land failed; ending it", metadata: [
            "landID": .string(behavior.config.actualLandID ?? "-"),
            "kind": .string(failure.kind.rawValue),
            "field": .string(failure.field ?? "-"),
            "position": .string(failure.position.description),
            "error": .string(failure.detail),
        ])
        // The terminal entry (#535 D9), in the failing segment: before every teardown entry. It
        // goes into the frame of the executing tick (frame 0 on a tickless land), where replay
        // stops.
        enqueueRecorderSubmission(&m, ReevaluationTickRecord(
            tickId: isTickless ? 0 : max(m.nextTickId - 1, 0),
            landFailure: failure
        ))
        dropPendingInputs(&m, &side, reason: "landFailed")
        cancelAllActionJobs(&m, &side)
        releaseHeldInputsForDrain(&m)
        resumeShutdownTurnWaiters()
        m.players.removeAll()
        playerServices.removeAll()
        m.rejoinReservations.removeAll()
        // A keeper never attached reaches the adapter bound by its first sync request (#546 L2a).
        let transport = self.transport ?? boundSyncRequester
        // The output gate closes in the mark: no new state or event frame from here (§3.2 step 4).
        // The sentinel already closed it for a re-entry when it is the same gate; a second close
        // outside the sentinel's guard could nest a re-entry through a misbehaving port.
        if let transport, !(Self.gateObject(transport).map { $0 === sentinel.reentryClosedGate } ?? false) {
            transport.closeOutputs(for: failure) // lint-allow: bare-port: the gate close a land failure performs; a re-entry from it finds the land already failed
        }
        drainTask = Task {
            await holds.at(.landFailedTeardown)
            if let transport { await transport.landDidFail(failure) }
            await self.drainAfterIdleCheck()
        }
        resumeDrainStartedWaitersForTesting()
        let waiters = failureWaitersForTesting.values
        failureWaitersForTesting.removeAll()
        waiters.forEach { $0.resume(returning: true) }
    }

    /// `forceShutdown` on a tickless land, waiting for its shutdown input's turn, or for the
    /// input to be dropped by a drain that started first.
    private var shutdownTurnWaiters: [CheckedContinuation<Void, Never>] = []

    private func resumeShutdownTurnWaiters() {
        let waiters = shutdownTurnWaiters
        shutdownTurnWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }


    /// Removes every pending input and fails the callers waiting for those inputs' turns with
    /// `LandInputRejection.landClosed`. Callers of inputs already applied (their outcome in
    /// `inputTurnResults`, waiting for the turn's record) are left to that turn.
    private func dropPendingInputs(_ m: inout KeeperModel<State>, _ side: inout KeeperTurnSide, reason: String) {
        guard !m.pendingItems.isEmpty else { return }
        let dropped = m.pendingItems
        m.pendingItems.removeAll()
        // A drain that started before the shutdown turn: `forceShutdown` waits for it instead.
        if dropped.contains(where: \.isShutdown) { resumeShutdownTurnWaiters() }
        let droppedServerInputs = dropped.filter { if case .serverInput = $0 { true } else { false } }.count
        m.serverInputsInFlight = max(0, m.serverInputsInFlight - droppedServerInputs)
        var failed: [CheckedContinuation<InputOutcome, any Error>] = []
        for item in dropped {
            if let waiter = inputTurnWaiters.removeValue(forKey: item.sequence) {
                failed.append(waiter)
            }
            if m.ticklessJobTurns.remove(item.sequence) != nil {
                fillActionSlot(&m, &side, item.sequence, with: .failure(LandInputRejection.landClosed))
            }
        }
        behavior.logger.info("Pending inputs dropped: the land is closing", metadata: [
            "reason": .string(reason),
            "dropped": .stringConvertible(dropped.count),
            "failedWaiters": .stringConvertible(failed.count),
        ])
        failed.forEach { $0.resume(throwing: LandInputRejection.landClosed) }
    }

    /// Waits until the input with `sequence` has run in an input turn, and returns its response:
    /// the action's response, an empty one for other inputs, or the handler's error.
    ///
    /// Returns an empty response at once when the input is neither pending nor waiting for its
    /// turn's record: a turn already applied it and nobody kept its outcome. Only a server
    /// input's task registers late (its outcome is empty); actions, client events, joins and
    /// leaves register in the same synchronous segment as their append, so their caller always
    /// gets its own outcome, an error included.
    /// An intake's driver, right after its segment: if the land failed in that segment's
    /// backstop (`applyLateReentry`, in `withTurn`'s defer) and the failure dropped the input it
    /// appended, the caller gets `landClosed`, not the `.none` that `awaitInputTurn` returns for
    /// a sequence it can't find.
    private func rejectIfAppendedInputDropped(_ sequence: Int64) throws {
        guard failure != nil,
              model.inputTurnResults[sequence] == nil,
              !model.pendingItems.contains(where: { $0.sequence == sequence })
        else { return }
        throw LandInputRejection.landClosed
    }

    private func awaitInputTurn(sequence: Int64) async throws -> InputOutcome {
        try await withCheckedThrowingContinuation { continuation in
            guard model.inputTurnResults[sequence] != nil
                || model.pendingItems.contains(where: { $0.sequence == sequence })
            else {
                continuation.resume(returning: .none)
                return
            }
            inputTurnWaiters[sequence] = continuation
            scheduleInputDrain()
        }
    }

    /// Schedules the input drain unless one is scheduled or running.
    private func scheduleInputDrain() {
        guard !model.inputDrainScheduled else { return }
        model.inputDrainScheduled = true
        Task { [weak self] in
            await self?.runInputDrain()
        }
    }

    /// `scheduleInputDrain()` in a turn body: the flag inline, the drain's task staged.
    private func scheduleInputDrain(_ m: inout KeeperModel<State>, _ outputs: inout TurnOutputs) {
        guard !m.inputDrainScheduled else { return }
        m.inputDrainScheduled = true
        outputs.stage { [weak self] in
            Task { await self?.runInputDrain() }
        }
    }

    /// Runs input turns until no ready input is left. Each turn takes an ordered snapshot of at
    /// most `inputTurnBatchLimit` ready inputs; inputs arriving during a turn go to a later one.
    /// Between turns the drain yields, so sync-only turns and other jobs interleave whether or
    /// not a recorder is attached. The caller has set `inputDrainScheduled`.
    private func runInputDrain() async {
        await holds.at(.inputDrain)
        while true {
            let batch = Array(readyPendingItemsInOrder(model).prefix(Self.inputTurnBatchLimit))
            if batch.isEmpty { break }
            let mark = model.recorderSubmissionCount
            let outcome = runInputTurn(batch)
            if !outcome.record.isEmpty {
                await submitTurnRecord(outcome.record)
            } else {
                enqueueTicklessTurnEnd(&model, since: mark)
            }
            resumeInputTurnWaiters(for: outcome.appliedItems)
            await Task.yield()
        }
        model.inputDrainScheduled = false
        turnSide.probe?("input-drain-end")
        let idleWaiters = inputDrainIdleWaitersForTesting
        inputDrainIdleWaitersForTesting.removeAll()
        idleWaiters.forEach { $0.resume() }
    }


    /// What an input turn did: its record and the inputs it applied (a failed one included).
    private struct InputTurnOutcome {
        var record: ReevaluationTickRecord
        var appliedItems: [PendingItem]
        /// Whether a leave asks for a broadcast-only sync (the legacy path's flag).
        var syncBroadcastOnly: Bool
    }

    /// One tickless input turn, synchronous: applies `batch`, takes the events emitted and the
    /// sync requests made, and hands them to the transport with the sync phase when requested.
    /// The outcomes of the applied inputs wait in `inputTurnResults` until the record is in.
    ///
    /// An input P whose `validate` throws is refused alone, as on the legacy path (`applyInputs`):
    /// P's caller gets P's error, and every other input of the batch is applied and its caller
    /// gets its own outcome. P wrote nothing and requested nothing (#586). P is recorded in
    /// order, as rejected, so replay checks it is refused the same way.
    ///
    /// A turn that ends the land (a failure item in the batch, a failure a transport noted
    /// outside the turn, or a failed sync phase) sends nothing, and every consumed caller gets
    /// `landClosed` instead of its outcome. The record keeps those inputs as applied: a recorded
    /// input carries no outcome, so replay has none to compare.
    private func runInputTurn(_ batch: [PendingItem], removingFromQueue: Bool = true) -> InputTurnOutcome {
        // The record's bytes for an input that holds none are encoded here, before the body
        // holds the model: the encode runs the payload's own `encode(to:)` (#700 K1b-5a, MF1).
        let preparedRecordBytes = prepareFallbackRecordBytes(batch)
        return withTurn { m, side, outputs in
            inputTurnBody(&m, &side, &outputs, batch, removingFromQueue: removingFromQueue, preparedRecordBytes: preparedRecordBytes)
        }
    }

    /// `runInputTurn`'s body, on the model the turn holds. The handlers run inside the hold, as
    /// they have since #877 (`withHandlerStep`); the transport's phase goes through `callOut`.
    private func inputTurnBody(
        _ m: inout KeeperModel<State>,
        _ side: inout KeeperTurnSide,
        _ outputs: inout TurnOutputs,
        _ batch: [PendingItem],
        removingFromQueue: Bool,
        preparedRecordBytes: [Int64: Result<Data, any Error>]
    ) -> InputTurnOutcome {
        side.probe?("turn-begin")
        side.probe?("input-batch-\(batch.count)")
        let failedBefore = failure != nil
        let executingTickId = executingTickIdForPendingItems(&m)
        let sequenceBefore = outputCollector.nextSequence
        beginPass(&m)
        // A failing input fails alone (its caller gets its error); the rest of the batch goes
        // on (`applyInputs`). Its events were dropped there.
        let application = applyInputs(&m, &side,
            batch, executingTickId: executingTickId, removingFromQueue: removingFromQueue,
            preparedRecordBytes: preparedRecordBytes,
            reportJoins: { m, side, results in reportJoinsInTurn(&m, &side, &outputs, results) }
        )
        let applied = application.applied
        // Numbered in the segment that applied it, before this turn's sync phase reads (#563).
        let passOrdinal = takePassOrdinal(&m, applied: applied)
        // After the ordinal is taken, so a failure noted outside the turn names this pass (#704).
        if failure == nil { _ = finishApply(&m, &side, appliedInputs: !applied.appliedOrder.isEmpty) }
        // Only the consumed prefix is this turn's: the suffix was dropped (`landClosed`) by a
        // failure's settle, and its callers must not be resumed again with a success (#535).
        let consumedItems = Array(batch.prefix(application.consumed))
        var emitted: [EmittedEvent] = []
        if failure != nil {
            // The land failed in this turn: no events and no sync (§3.2 step 4).
            _ = takeEmittedEvents(&m, forTick: executingTickId)
            _ = takeSyncRequest(forTick: executingTickId, applied: applied)
        } else if !batch.isEmpty, routesThroughTurn {
            // A live turn takes them whatever the delivery, so the turn record holds them and the
            // collector is drained; delivered only through a port (#546 L2d). A replayed pass
            // leaves them for the replay's flush to the sink.
            emitted = takeEmittedEvents(&m, forTick: executingTickId)
            let wantsSync = takeSyncRequest(forTick: executingTickId, applied: applied)
            if let transport {
                switch callOut(&m, &side, &outputs, { _ in syncsInTurn }) {
                case .refused:
                    // The land ended in the call: no output step, and the consumed callers get
                    // `landClosed` below.
                    m.inTurnSyncDue = false
                case .answered(true):
                    runTurnOutputs(&m, &side, &outputs, transport: transport, events: emitted, wantsSync: wantsSync)
                case .answered(false):
                    break
                }
            }
        }
        side.probe?("turn-end")
        // A turn that ended the land answers every consumed caller with `landClosed`, a caller
        // whose handler threw included: none of the turn's outputs went out, so a success would
        // promise effects the land never sends (#704, #716). The failure item has no caller.
        let endedInTurn = !failedBefore && failure != nil
        for item in consumedItems {
            setInputTurnResult(&m, &side, item.sequence, endedInTurn
                ? .failure(LandInputRejection.landClosed)
                : application.outcomes[item.sequence])
        }
        checkActionTables(&m, &side, #function)
        var record = makeTurnRecord(tickId: executingTickId, applied: applied, emitted: emitted)
        // A tickless land's turn is one pass (#325, #321).
        if !applied.appliedOrder.isEmpty {
            record.passes = [ReevaluationRecordedPass(sequenceBefore: sequenceBefore, inputs: applied.appliedOrder, ordinal: passOrdinal, rejected: applied.rejected.isEmpty ? nil : applied.rejected)]
        }
        return InputTurnOutcome(record: record, appliedItems: consumedItems, syncBroadcastOnly: applied.shouldSyncBroadcastOnly)
    }

    /// Resumes the callers of `batch` with their outcomes, after the turn was recorded: a
    /// response never leaves before its input is recorded.
    private func resumeInputTurnWaiters(for batch: [PendingItem]) {
        for item in batch {
            // The result, and its error, are taken before the branch.
            let result: Result<InputOutcome, any Error> = model.inputTurnResults.removeValue(forKey: item.sequence)
                .map { taken(&model, &turnSide, $0, path: .inputTurn, sequence: item.sequence) } ?? .success(.none)
            if model.ticklessJobTurns.remove(item.sequence) != nil {
                // No waiter on the slot yet: held under a fresh ID.
                fillActionSlot(&model, &turnSide, item.sequence, with: result)
            } else {
                inputTurnWaiters.removeValue(forKey: item.sequence)?.resume(with: result)
            }
        }
        checkActionTables(&model, &turnSide, #function)
    }

    private func configureSyncLoop(interval: Duration) async {
        syncTask?.cancel()
        let phaseOffset = loopPhaseOffset(interval: interval)
        appliedSyncPhaseOffset = phaseOffset
        syncTask = Task { [weak self] in
            if phaseOffset > .zero {
                try? await safeTaskSleep(for: phaseOffset)
            }
            guard let self = self else { return }

            var nextSyncTime = ContinuousClock.now + interval

            while !Task.isCancelled {
                let now = ContinuousClock.now

                // If we're already past the scheduled time, execute immediately
                // Otherwise, sleep until the scheduled time
                if now < nextSyncTime {
                    try? await Task.sleep(until: nextSyncTime, clock: .continuous)
                }

                await self.runSync()

                // Fixed-rate scheduling: calculate next time from the scheduled time, not from now
                // This maintains a consistent sync rate even if execution takes longer than interval
                // If execution time exceeds interval, we skip ahead to maintain the rate
                nextSyncTime = nextSyncTime + interval

                // If we're still behind schedule after skipping, continue skipping
                // This prevents the loop from getting stuck if execution time consistently exceeds interval
                while nextSyncTime <= ContinuousClock.now {
                    nextSyncTime = nextSyncTime + interval
                }
            }
        }
    }

    private func runSync() async {
        // Check if task was cancelled before executing sync
        // This prevents sync from running after shutdown has started
        guard !Task.isCancelled else { return }

        // Double-check: if syncTask is nil, we're in shutdown, don't run
        guard syncTask != nil else { return }

        // The only sync while frozen is the settle cycle run by the transport.
        guard !model.debugFrozen else { return }

        // Execute optional read-only callback if provided
        // This callback is read-only and should NOT modify state
        if let handler = definition.lifetimeHandlers.syncHandler {
            let ctx = makeContext(&model,
                playerID: behavior.config.systemPlayerID,
                clientID: behavior.config.systemClientID,
                sessionID: behavior.config.systemSessionID,
                servicesOverride: LandServices(),
                tickId: model.lastCommittedTickId
            )
            // The sync handler isn't repeated from the record, so it draws from a copy of the
            // land's generator, never written back.
            let (scoped, scope) = openStepScope(ctx, random: detachedRandom())
            defer { scope.close() }
            // Pass state as value (read-only) to emphasize that it should not be modified
            handler(model.state, scoped)
        }

        // In-turn sync: a sync-only turn at the sync loop's own interval, unless a tick is due
        // within the coincident-sync window: then the sync folds into that tick turn, so it
        // never overtakes a tick due at the same instant. An overdue tick (deadline already
        // past, the tick loop late) counts as due: the frame then waits for that late tick,
        // where the legacy path would send it now with the pre-tick state. Kept by design.
        if syncsInTurn, let transport {
            let now = syncClockForTesting ?? ContinuousClock.now
            if tickTask != nil, let deadline = nextTickDeadline,
               deadline - now <= coincidentSyncWindow
            {
                // Counted once per tick turn the sync waits for: a tick late by more than a sync
                // interval folds the next iteration into the same turn, which is one cycle.
                // The transport hears of it when that tick turn starts (`takePendingFold`).
                // Keyed on the pending fold, not on `inTurnSyncDue`: a freeze drops the
                // pending fold but keeps the due sync, and the fold after the resume counts.
                if pendingFold == nil {
                    model.foldedSyncs += 1
                    let overdue = deadline < now
                    if overdue { model.overdueFoldedSyncs += 1 }
                    pendingFold = PendingFold(deadline: deadline, overdueAtFold: overdue)
                }
                model.inTurnSyncDue = true
                return
            }
            runSyncOnlyTurn(transport: transport)
        } else if behavior.config.mode == .reevaluation {
            // A re-evaluation keeper may hold a transport (`ReevaluationOutputMode.transportAndSink`;
            // the attach check exempts it): its sync loop syncs through the legacy call until #612.
            await transport?.syncNowFromTransport()
        }
        // A live keeper without a port has nothing to sync through: its transport runs its sync
        // phase in turn or is refused at the attach (#546 L2d).
    }

    /// `scheduleDestroyIfNeeded` in a turn body: the decision inline, the timer's start staged
    /// (it captures the keeper). A `cancelDestroy` before the flush stops it.
    private func scheduleDestroyIfNeeded(_ m: inout KeeperModel<State>, _ outputs: inout TurnOutputs) {
        guard m.players.isEmpty, let delay = definition.config.destroyWhenEmptyAfter else { return }
        let ticket = replaceDestroyTicket()
        outputs.stage { [weak self] in
            ticket.install(Self.destroyTimer(after: delay, keeper: self))
        }
    }

    /// Cancels the empty-land destroy timer, and a start staged before this that hasn't
    /// installed its task yet (D16).
    private func cancelDestroy(_ m: inout KeeperModel<State>, _ side: inout KeeperTurnSide) {
        destroyTicket?.cancel()
        destroyTicket = nil
    }

    private func scheduleDestroyIfNeeded() {
        guard model.players.isEmpty, let delay = definition.config.destroyWhenEmptyAfter else { return }
        replaceDestroyTicket().install(Self.destroyTimer(after: delay, keeper: self))
    }

    /// A new ticket in the slot; the old one's timer is cancelled.
    private func replaceDestroyTicket() -> DestroyTicket {
        destroyTicket?.cancel()
        let ticket = DestroyTicket()
        destroyTicket = ticket
        return ticket
    }

    private static func destroyTimer(after delay: Duration, keeper: LandKeeper?) -> Task<Void, Never> {
        Task { [weak keeper] in
            do {
                try await safeTaskSleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await keeper?.shutdownIfIdle(cause: .emptyTimeout)
        }
    }

    private func shutdownIfIdle(cause: LandDestructionCause) async {
        // Destruction runs once; a second caller (the empty-room timer and `forceShutdown`)
        // waits for the one in progress.
        if let drainTask {
            await drainTask.value
            return
        }
        guard model.players.isEmpty else { return }
        // Same synchronous segment as the emptiness check: joins from now on are rejected.
        drainFlag.set(cause: cause)
        releaseHeldInputsForDrain(&model)
        // No action job can be delivered any more; their callers get `.landClosed`.
        cancelAllActionJobs(&model, &turnSide)
        let task = Task { await self.drainAfterIdleCheck() }
        drainTask = task
        resumeDrainStartedWaitersForTesting()
        await task.value
    }

    /// The destruction proper: stop the loops, run the destroy handlers, notify the transport.
    /// A reevaluation keeper skips all destroy handlers and goes straight to transport notification
    /// (#826): the record holds no finalize event, so there is nothing to verify them against, and
    /// their resolvers and AfterFinalize could reach outside services.
    private func drainAfterIdleCheck() async {
        await holds.at(.drainStart)
        // Cancel tick and sync tasks FIRST to prevent any new ticks/syncs from starting
        // This must be done before executing destroy handlers to ensure no ticks/syncs run after destroy
        tickTask?.cancel()
        tickTask = nil
        syncTask?.cancel()
        syncTask = nil

        destroyTicket?.cancel()
        destroyTicket = nil

        // No tick starts from now on (`isDraining`); one already running finishes whole.
        await waitForTickInFlight()
        // Intake has been closed since `isDraining` was set, so the pending inputs are all
        // there will be: they are dropped and their waiting callers get `.landClosed`.
        dropPendingInputs(&model, &turnSide, reason: "drain")
        model.destroyHandlersStarted = true

        // A land whose initialization failed (#104) never ran OnInitialize: its destroy handlers
        // would act on (or save) a state that was never set up, so they are skipped.
        guard model.initializationFailure == nil else {
            await notifyTransportDestroyedAndRelease()
            return
        }

        // A reevaluation keeper runs land code only for recorded inputs: the record holds no
        // destroy or finalize event, so nothing would verify these handlers against the record,
        // and their resolvers and AfterFinalize could reach outside services (#826).
        guard behavior.config.mode == .live else {
            await notifyTransportDestroyedAndRelease()
            return
        }

        // Each destroy handler: its resolvers first, then the handler in one synchronous
        // segment. Nothing else changes the state across those awaits: intake, deliveries and
        // every lifecycle append are rejected while draining, no tick starts, and no input is
        // pending. That is why the handlers need no ticket.
        //
        // The drain's handlers aren't repeated from the record, so their draws come from one
        // copy of the land's generator, never written back: OnDestroyWhenEmpty, OnFinalize and
        // AfterFinalize continue one sequence instead of repeating each other's.
        let drainRandom = detachedRandom()
        if let onDestroyWhenEmptyHandler = definition.lifetimeHandlers.onDestroyWhenEmpty {
            let handlers = definition.lifetimeHandlers
            await runDestroyHandler(
                "onDestroyWhenEmpty",
                resolvers: { _, _ in handlers.onDestroyWhenEmptyResolverExecutors },
                random: drainRandom,
                handler: onDestroyWhenEmptyHandler
            )
        }
        if let onFinalizeHandler = definition.lifetimeHandlers.onFinalize {
            let handlers = definition.lifetimeHandlers
            await runDestroyHandler(
                "OnFinalize",
                resolvers: { state, ctx in handlers.onFinalizeResolvers?.build(state, ctx) ?? [] },
                random: drainRandom,
                handler: onFinalizeHandler
            )
        }

        // Execute AfterFinalize handler (async cleanup)
        if let afterFinalizeHandler = definition.lifetimeHandlers.afterFinalize {
            let snapshot = model.state
            let ctx = makeContext(&model,
                playerID: behavior.config.systemPlayerID,
                clientID: behavior.config.systemClientID,
                sessionID: behavior.config.systemSessionID
            )
            // Its outputs are dropped: nothing takes them after the drain began, and one made
            // after an internal await would reach the collector off the keeper (#893).
            let (scoped, scope) = openStepScope(ctx, random: drainRandom, dropsOutputs: true)
            defer { scope.close() }
            await afterFinalizeHandler(snapshot, scoped)
        }

        // Notify transport that land has been destroyed
        // This allows transport layer to perform cleanup (e.g., remove from LandManager)
        // Note: tickTask and syncTask were already cancelled at the start of shutdownIfIdle
        await notifyTransportDestroyedAndRelease()
    }

    /// The destruction's last call to the transport, `onLandDestroyed`, then this instance drops
    /// its link to it. The transport (the adapter) holds this keeper, so the link is a reference
    /// cycle: kept, it would keep the keeper, its state and the adapter alive after the land is
    /// gone (#346). Dropped by this instance at the end of its own teardown, after the last call.
    private func notifyTransportDestroyedAndRelease() async {
        // A keeper never attached tells the adapter bound by its first sync request (#546 L2a).
        await (transport ?? boundSyncRequester)?.onLandDestroyed()
        boundSyncRequesterObject = nil
        model.destructionFinished = true
        releasedTransport = ReleasedLandTransport(landID: behavior.config.actualLandID ?? definition.id, logger: behavior.logger)
        setTransport(nil)
    }

    /// One destroy handler (OnDestroyWhenEmpty, OnFinalize): its resolvers, then the handler
    /// in one synchronous segment. A resolver failure is logged and skips the handler; the drain
    /// goes on.
    ///
    /// No ticket is captured across the resolvers: by now intake is closed (every input and
    /// lifecycle append checks `isDraining`), no tick runs and nothing is pending, so nothing
    /// else can change the state before the handler's segment.
    private func runDestroyHandler(
        _ name: String,
        resolvers buildResolvers: (State, ValidateContext) -> [any AnyResolverExecutor],
        random: DeterministicRngService,
        handler: @Sendable (inout State, LandContext) -> Void
    ) async {
        let ctx = makeContext(&model,
            playerID: behavior.config.systemPlayerID,
            clientID: behavior.config.systemClientID,
            sessionID: behavior.config.systemSessionID
        )
        var updatedCtx = ctx
        // Built from the State the handler will see: nothing changes it before the handler's
        // segment (see the caller).
        let resolvers = buildResolvers(model.state, ValidateContext(ctx))
        if !resolvers.isEmpty {
            let resolverContext = makeResolverContext(ctx)
            do {
                updatedCtx = try await ResolverExecutor.executeResolversWithoutDeadline(
                    executors: resolvers,
                    resolverContext: resolverContext,
                    landContext: ctx
                )
            } catch {
                behavior.logger.error("❌ \(name) resolvers failed: the handler is skipped", metadata: [
                    "error": .string(String(describing: error)),
                ])
                return
            }
        }
        // The handler can't throw (#593): the land is ending, so nothing would act on a refusal.
        // Its outputs are dropped: nothing takes them after the drain began (#893).
        withHandlerStep(&model, updatedCtx, random: .detached(random), dropsOutputs: true) { m, ctx in
            handler(&m.state, ctx)
        }
    }

    // Note: isEventAllowed is no longer needed as we use registry-based validation
}

/// Set-once flag readable from any isolation (`LandKeeper.isDraining`).
private final class DrainFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var setCause: LandDestructionCause?
    private var setFailure: LandFailure?

    var isSet: Bool { cause != nil }

    var cause: LandDestructionCause? {
        lock.lock()
        defer { lock.unlock() }
        return setCause
    }

    var failure: LandFailure? {
        lock.lock()
        defer { lock.unlock() }
        return setFailure
    }

    /// Sets the flag; the first cause stays.
    func set(cause: LandDestructionCause) {
        lock.lock()
        if setCause == nil { setCause = cause }
        lock.unlock()
    }

    /// Sets the flag with cause `.failed` and stores `failure`, if no cause was set yet.
    /// Returns whether this call set it.
    func setFailed(_ failure: LandFailure) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard setCause == nil else { return false }
        setCause = .failed
        setFailure = failure
        return true
    }
}

/// Why a land's destruction started (`LandKeeper.destructionCause`).
public enum LandDestructionCause: String, Codable, Sendable, Hashable {
    /// The land stayed empty for its `DestroyWhenEmpty` delay.
    case emptyTimeout
    /// `forceShutdown`: a server shutdown (`LandManager.shutdownAllLands`) or a test harness.
    case forceShutdown
    /// Its initialization failed (#104): torn down without the destroy handlers.
    case initializationFailed
    /// A failure it couldn't recover from ended it (#535, `LandKeeper.failure`): its sessions
    /// closed with 4016, and no OnLeave ran.
    case failed
}

extension LandKeeper.PendingItem {
    /// The input's sequence number (shared counter across inputs and server events).
    var sequence: Int64 {
        switch self {
        case let .action(item): return item.sequence
        case let .clientEvent(item): return item.sequence
        case let .lifecycle(item): return item.sequence
        case let .serverInput(item): return item.sequence
        case let .shutdown(item): return item.sequence
        case let .landFailure(item): return item.sequence
        }
    }

    /// Whether this is the forced shutdown's input (#382).
    var isShutdown: Bool {
        if case .shutdown = self { return true }
        return false
    }

    /// The committed tick the input is bound to; it runs in the first tick after it.
    var resolvedAtTick: Int64 {
        switch self {
        case let .action(item): return item.resolvedAtTick
        case let .clientEvent(item): return item.resolvedAtTick
        case let .lifecycle(item): return item.resolvedAtTick
        case let .serverInput(item): return item.resolvedAtTick
        case let .shutdown(item): return item.resolvedAtTick
        case let .landFailure(item): return item.resolvedAtTick
        }
    }
}

// MARK: - Keeper fields as plain structs (#700 K1b-1, F3)

/// The last recorded sync output's `observedTickId`, and how many outputs were recorded after it.
@PlainData
struct SyncOutputIndexCursor: Sendable {
    var observedTickId: Int64?
    var count: Int
}

/// Where a replayed record's land failure ended it: its tick, and on a tickless land its pass.
@PlainData
struct ReplayFailureEnd: Sendable {
    let tickId: Int64
    let pass: Int64?
}

/// A sync folded into the next tick: the deadline it had, and whether it was already overdue.
/// Not plain: `ContinuousClock.Instant` (F4's exception, until K2 passes the time in).
struct PendingFold: Sendable {
    let deadline: ContinuousClock.Instant
    let overdueAtFold: Bool
}
