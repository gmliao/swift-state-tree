import Foundation
import SwiftStateTree

/// Where a server event in a replay frame comes from.
public enum ReevaluationReplayEventOrigin: String, Sendable, Equatable {
    /// Read from the record.
    case recorded
    /// Emitted by the replay's own keeper.
    case replayed
}

/// Why a replay tick couldn't be resolved into what the replay land shows (#521 PR 1b, D14 (a′)).
/// It fails the replay run: the record and the code disagree, so later ticks would compare
/// against events or state the code can't produce.
public enum ReevaluationReplayResolutionError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// A recorded or projected server event whose name isn't in the base land's registry (EV7).
    case unregisteredEvent(tickId: Int64, origin: ReevaluationReplayEventOrigin, sequence: Int64, name: String)
    /// A server event whose payload doesn't decode into its registered type (EV7), or whose
    /// descriptor has no decoder (a custom runner that skipped the registration check, EV8).
    case eventDecode(tickId: Int64, origin: ReevaluationReplayEventOrigin, sequence: Int64, name: String, error: String)
    /// The runner couldn't read the tick's recorded server events or state hash (A9).
    case recordRead(tickId: Int64, read: String, error: String)
    /// The runner's snapshot of the replayed state didn't encode (A10).
    case stateEncode(tickId: Int64, error: String)
    /// The replayed state couldn't be built back from its snapshot (A11).
    case stateDecode(tickId: Int64, error: String)
    /// A replay land's tick has no state to show: the runner had no snapshot, for example when
    /// the state hash couldn't be computed (a NaN, keys that collide as strings, #180). A run
    /// that feeds no replay land reports such a tick as unverifiable and goes on.
    case stateUnavailable(tickId: Int64, reason: String)
    /// A result reached the replay land's queue without a resolved frame (a custom runner that
    /// didn't call `ReevaluationReplayFrame.resolve`).
    case unresolvedResult(tickId: Int64)
    /// The runner's state type differs from the replay land's.
    case stateTypeMismatch(tickId: Int64, runner: String, replayLand: String)

    public var description: String {
        switch self {
        case let .unregisteredEvent(tickId, origin, sequence, name):
            return "replay tick \(tickId): \(origin.rawValue) server event \(sequence) '\(name)' isn't registered on the land"
        case let .eventDecode(tickId, origin, sequence, name, error):
            return "replay tick \(tickId): \(origin.rawValue) server event \(sequence) '\(name)' doesn't decode: \(error)"
        case let .recordRead(tickId, read, error):
            return "replay tick \(tickId): can't read the recorded \(read): \(error)"
        case let .stateEncode(tickId, error):
            return "replay tick \(tickId): the replayed state's snapshot doesn't encode: \(error)"
        case let .stateDecode(tickId, error):
            return "replay tick \(tickId): the replayed state can't be built from its snapshot: \(error)"
        case let .stateUnavailable(tickId, reason):
            return "replay tick \(tickId): no state to show: \(reason)"
        case let .unresolvedResult(tickId):
            return "replay tick \(tickId): result not resolved (the runner didn't call ReevaluationReplayFrame.resolve)"
        case let .stateTypeMismatch(tickId, runner, replayLand):
            return "replay tick \(tickId): runner state \(runner), replay land \(replayLand)"
        }
    }

    public var errorDescription: String? { description }
}

/// What the replay land shows for one tick: its server events decoded into their registered
/// types, and its state built back from the runner's snapshot (#521 PR 1b, D14 (a′)). Built in
/// the runner's `step()` by `resolve`, so a record/code mismatch fails the run there; the replay
/// land's tick only reads it and can't fail.
public struct ReevaluationReplayFrame: Sendable {
    /// A server event decoded into its registered type, with its recorded target.
    package struct ResolvedEvent: Sendable {
        package let sequence: Int64
        package let typeIdentifier: String
        package let event: any ServerEventPayload
        package let target: ReevaluationEventTargetRecord
    }

    package let tickId: Int64
    /// The tick's recorded server events, in record order.
    package let recordedEvents: [ResolvedEvent]
    /// The events the replay emitted (the runner's keeper), in order.
    package let projectedEvents: [ResolvedEvent]
    /// The replayed state, built back from its snapshot; nil for a state type that can't be
    /// (`StateFromSnapshotDecodable`), which has no replay land, or when there was no snapshot
    /// (`stateUnavailable`).
    package let state: (any StateNodeProtocol)?
    /// Why a `StateFromSnapshotDecodable` state is missing: no snapshot was given, or the runner
    /// couldn't compute one (the hash error). A replay land refuses such a frame
    /// (`ReevaluationReplayResolutionError.stateUnavailable`); a monitor-only run goes on.
    package let stateUnavailable: String?
    /// The state's type, checked against the replay land's before the result is queued.
    package let stateType: ObjectIdentifier?
    package let stateTypeName: String?

    /// Resolves a tick: every recorded and projected server event is looked up by name in
    /// `definition`'s registry and decoded into its type, and the state is built back from
    /// `actualState` (the runner's snapshot JSON) when `State` is `StateFromSnapshotDecodable`.
    /// Without a snapshot the frame has no state, and a replay land refuses it. Recorded payloads
    /// decode with the record codec, strictly. Custom runners call it to give their results a
    /// frame; a result without one isn't queued for a replay land.
    public static func resolve<State: StateNodeProtocol>(
        tickId: Int64,
        recordedServerEvents: [ReevaluationRecordedServerEvent],
        emittedServerEvents: [ReevaluationRecordedServerEvent],
        actualState: AnyCodable?,
        definition: LandDefinition<State>
    ) throws -> ReevaluationReplayFrame {
        try resolve(
            tickId: tickId, recordedServerEvents: recordedServerEvents, emittedServerEvents: emittedServerEvents,
            actualState: actualState, definition: definition, integralFloats: false, stateUnavailable: nil
        )
    }

    /// `resolve`, with the JSON record view's allowance when `integralFloats` is set (an integer
    /// decodes into `Double` or `Float` when it converts exactly). `stateUnavailable` is why the
    /// runner has no snapshot (the hash error), kept in the frame.
    package static func resolve<State: StateNodeProtocol>(
        tickId: Int64,
        recordedServerEvents: [ReevaluationRecordedServerEvent],
        emittedServerEvents: [ReevaluationRecordedServerEvent],
        actualState: AnyCodable?,
        definition: LandDefinition<State>,
        integralFloats: Bool,
        stateUnavailable: String? = nil
    ) throws -> ReevaluationReplayFrame {
        let recorded = try resolveEvents(
            recordedServerEvents, origin: .recorded, tickId: tickId, definition: definition, integralFloats: integralFloats)
        let projected = try resolveEvents(
            emittedServerEvents, origin: .replayed, tickId: tickId, definition: definition, integralFloats: integralFloats)
        guard let decodable = State.self as? any StateFromSnapshotDecodable.Type else {
            return ReevaluationReplayFrame(
                tickId: tickId, recordedEvents: recorded, projectedEvents: projected,
                state: nil, stateUnavailable: nil, stateType: nil, stateTypeName: nil
            )
        }
        var state: (any StateNodeProtocol)?
        var unavailable: String?
        if let actualState {
            state = try decodeState(decodable, tickId: tickId, actualState: actualState)
        } else {
            unavailable = stateUnavailable ?? "no snapshot"
        }
        return ReevaluationReplayFrame(
            tickId: tickId, recordedEvents: recorded, projectedEvents: projected,
            state: state, stateUnavailable: unavailable,
            stateType: ObjectIdentifier(State.self), stateTypeName: String(reflecting: State.self)
        )
    }

    /// Why a replay land of state type `stateType` can't show `result`: no frame, a frame of
    /// another state type, or one without a state. Nil when it can. The service checks it
    /// before queueing (`expectReplayLandState`), and the land again when it reads the result,
    /// so a land built with `GenericReplayLand.makeLand` alone fails the run too.
    package static func refusal(
        of result: ReevaluationStepResult,
        forStateType stateType: ObjectIdentifier,
        named name: String
    ) -> ReevaluationReplayResolutionError? {
        guard let frame = result.replayFrame else {
            return .unresolvedResult(tickId: result.tickId)
        }
        guard frame.stateType == stateType else {
            return .stateTypeMismatch(tickId: result.tickId, runner: frame.stateTypeName ?? "none (events only)", replayLand: name)
        }
        guard frame.state != nil else {
            return .stateUnavailable(tickId: result.tickId, reason: frame.stateUnavailable ?? "no snapshot")
        }
        return nil
    }

    /// Whether a runner reading `source` decodes with the JSON record view's allowance: only the
    /// JSON view (`JSONReevaluationSource`), whose numbers lost the float/integer split. Any other
    /// source, a custom one included, is strict.
    package static func integralFloats(for source: any ReevaluationSource) -> Bool {
        source is JSONReevaluationSource
    }

    private static func resolveEvents<State: StateNodeProtocol>(
        _ events: [ReevaluationRecordedServerEvent],
        origin: ReevaluationReplayEventOrigin,
        tickId: Int64,
        definition: LandDefinition<State>,
        integralFloats: Bool
    ) throws -> [ResolvedEvent] {
        let registry = definition.serverEventRegistry
        return try events.map { recorded in
            guard let descriptor = registry.findDescriptor(for: recorded.typeIdentifier) else {
                throw ReevaluationReplayResolutionError.unregisteredEvent(
                    tickId: tickId, origin: origin, sequence: recorded.sequence, name: recorded.typeIdentifier
                )
            }
            guard let decode = descriptor.decodeServerEvent else {
                throw ReevaluationReplayResolutionError.eventDecode(
                    tickId: tickId, origin: origin, sequence: recorded.sequence, name: recorded.typeIdentifier,
                    error: "its type \(String(reflecting: descriptor.type)) has no decoder (EV8)"
                )
            }
            let event: any ServerEventPayload
            do {
                event = try decode(RecordPayloadSource(recorded.payload, integralFloats: integralFloats))
            } catch {
                throw ReevaluationReplayResolutionError.eventDecode(
                    tickId: tickId, origin: origin, sequence: recorded.sequence, name: recorded.typeIdentifier, error: "\(error)"
                )
            }
            return ResolvedEvent(sequence: recorded.sequence, typeIdentifier: recorded.typeIdentifier, event: event, target: recorded.target)
        }
    }

    private static func decodeState(
        _ type: any StateFromSnapshotDecodable.Type,
        tickId: Int64,
        actualState: AnyCodable
    ) throws -> any StateNodeProtocol {
        guard let snapshot = decodeReplayState(StateSnapshot.self, from: actualState) else {
            throw ReevaluationReplayResolutionError.stateDecode(tickId: tickId, error: "the snapshot isn't a StateSnapshot")
        }
        do {
            return try type.init(fromBroadcastSnapshot: snapshot)
        } catch {
            throw ReevaluationReplayResolutionError.stateDecode(tickId: tickId, error: "\(error)")
        }
    }
}
