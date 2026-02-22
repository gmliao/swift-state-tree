import Foundation
import SwiftStateTree

// MARK: - ReplayTickEvent

/// Generic replay tick result event emitted by GenericReplayLand on each processed tick.
/// Replaces game-specific tick events (e.g. HeroDefenseReplayTickEvent).
@Payload
public struct ReplayTickEvent: ServerEventPayload {
    public let tickId: Int64
    public let isMatch: Bool
    public let expectedHash: String
    public let actualHash: String

    public init(tickId: Int64, isMatch: Bool, expectedHash: String, actualHash: String) {
        self.tickId = tickId
        self.isMatch = isMatch
        self.expectedHash = expectedHash
        self.actualHash = actualHash
    }
}

// MARK: - Internal state decode helpers

/// Type-erased protocol allowing `StandardReplayLifetime` to call `decodeReplayState`
/// on State types that also conform to `Decodable`, without constraining the generic
/// parameter of `StandardReplayLifetime` itself.
private protocol _DecodableStateDecoder {
    static func _decodeFromActualState(_ actualState: AnyCodable?) -> Self?
}

extension _DecodableStateDecoder where Self: Decodable {
    static func _decodeFromActualState(_ actualState: AnyCodable?) -> Self? {
        decodeReplayState(Self.self, from: actualState)
    }
}

/// Attempts to decode a `State` from `result.actualState` when `State` is `Decodable`.
///
/// Returns `nil` when `State` does not conform to `Decodable` or when decoding fails.
/// Used by `StandardReplayLifetime` which cannot constrain `State: Decodable`.
private func decodeReplayStateIfDecodable<State: StateNodeProtocol>(
    _ type: State.Type,
    from actualState: AnyCodable?
) -> State? {
    guard let decoderType = State.self as? any _DecodableStateDecoder.Type else { return nil }
    return decoderType._decodeFromActualState(actualState) as? State
}

/// Decodes a State from `result.actualState`.
///
/// `actualState?.base` is a JSON string. It may be a flat JSON object or wrapped in
/// `{"values": {...}}` (SwiftStateTree serialization artifact). Both formats are tried.
func decodeReplayState<State: Decodable>(_ type: State.Type, from actualState: AnyCodable?) -> State? {
    guard let jsonText = actualState?.base as? String,
          let data = jsonText.data(using: .utf8)
    else { return nil }

    // Try direct decode first (flat format)
    if let decoded = try? JSONDecoder().decode(type, from: data) {
        return decoded
    }

    // Try "values" wrapper format: {"values": {...}}
    guard let rawJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let valuesRaw = rawJSON["values"],
          JSONSerialization.isValidJSONObject(valuesRaw),
          let valuesData = try? JSONSerialization.data(withJSONObject: valuesRaw),
          let decoded = try? JSONDecoder().decode(type, from: valuesData)
    else { return nil }

    return decoded
}

// MARK: - StandardReplayLifetime

/// Generic replay tick loop for any State conforming to StateNodeProtocol.
///
/// On each 50 ms tick:
/// 1. Reads `ReevaluationRunnerService` from `ctx.services`.
/// 2. When the service phase is `.idle`, decodes the record path from `ctx.landID` via
///    `ReevaluationReplaySessionDescriptor.decode` and calls `service.startVerification`.
/// 3. When a result is available via `service.consumeNextResult()`:
///    - Decodes the actual state (only when `State: Decodable`; otherwise logs a warning).
///    - Forwards all recorded server events via `ctx.emitAnyServerEvent`.
///    - Emits a `ReplayTickEvent` with hash comparison metadata.
///
/// For use with concrete State types that are also `Decodable`, state decode is
/// attempted automatically. When `State` does not conform to `Decodable` the tick
/// loop still runs but the projected state is not applied.
public func StandardReplayLifetime<State: StateNodeProtocol>(
    landType: String
) -> LifetimeNode<State> {
    let captureLandType = landType
    return Lifetime {
        Tick(every: .milliseconds(50)) { (state: inout State, ctx: LandContext) in
            guard let service = ctx.services.get(ReevaluationRunnerService.self) else {
                return
            }

            let status = service.getStatus()

            if status.phase == .idle {
                let instanceId = LandID(ctx.landID).instanceId
                let recordsDir = ReevaluationEnvConfig.fromEnvironment().recordsDir
                guard let descriptor = ReevaluationReplaySessionDescriptor.decode(
                    instanceId: instanceId,
                    landType: captureLandType,
                    recordsDir: recordsDir
                ) else {
                    service.startVerification(
                        landType: captureLandType,
                        recordFilePath: "__invalid_replay_record_path__"
                    )
                    return
                }
                service.startVerification(
                    landType: captureLandType,
                    recordFilePath: descriptor.recordFilePath
                )
                return
            }

            guard let result = service.consumeNextResult() else { return }

            if let decoded = decodeReplayStateIfDecodable(State.self, from: result.actualState) {
                state = decoded
                ctx.requestSyncBroadcastOnly()
            }

            for event in result.emittedServerEvents {
                ctx.emitAnyServerEvent(
                    AnyServerEvent(type: event.typeIdentifier, payload: event.payload),
                    to: .all
                )
            }

            ctx.emitEvent(
                ReplayTickEvent(
                    tickId: result.tickId,
                    isMatch: result.isMatch,
                    expectedHash: result.recordedHash ?? "?",
                    actualHash: result.stateHash
                ),
                to: .all
            )
        }
    }
}

// MARK: - StandardReplayServerEvents

/// Returns a `ServerEventsNode` that registers `ReplayTickEvent`.
///
/// Use this alongside `StandardReplayLifetime` when composing a custom replay land
/// that needs to emit `ReplayTickEvent` to connected clients.
public func StandardReplayServerEvents() -> ServerEventsNode {
    ServerEvents {
        Register(ReplayTickEvent.self)
    }
}

// MARK: - GenericReplayLand

/// Zero-config generic replay land for any State conforming to StateNodeProtocol & Decodable.
///
/// Replaces hand-written game-specific replay lands (e.g. HeroDefenseReplayLand).
/// - Starts reevaluation verification automatically on first tick.
/// - Decodes projected state from `result.actualState` using JSONDecoder.
/// - Forwards ALL recorded server events without filtering.
/// - Emits ReplayTickEvent after each result.
///
/// For custom actions (fast-forward, reset, etc.), use
/// `StandardReplayLifetime` and `StandardReplayServerEvents` instead.
public enum GenericReplayLand {
    /// Creates a generic replay LandDefinition.
    ///
    /// - Parameters:
    ///   - landType: The BASE land type (e.g. "hero-defense"), NOT the replay land type.
    ///     The returned definition's ID will be "\(landType)-replay".
    ///   - stateType: The State type. Must conform to `StateNodeProtocol`. For actual state
    ///     decoding in Task 3, the state must also be `Decodable`.
    public static func makeLand<State: StateNodeProtocol>(
        landType: String,
        stateType: State.Type
    ) -> LandDefinition<State> {
        Land("\(landType)-replay", using: stateType) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(64)
            }

            StandardReplayLifetime(landType: landType) as LifetimeNode<State>

            ServerEvents {
                Register(ReplayTickEvent.self)
            }
        }
    }
}
