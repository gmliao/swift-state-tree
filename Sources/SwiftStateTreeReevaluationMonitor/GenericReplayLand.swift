// GenericReplayLand.swift
// Generic replay land that broadcasts recorded game state to connected clients.
// Runs in .live mode — no changes to LandKeeper required.

import Foundation
import SwiftStateTree

/// A factory for creating replay LandDefinitions.
///
/// Each tick, GenericReplayLand:
/// 1. Consumes the next result from ReevaluationRunnerService
/// 2. Decodes the StateSnapshot from actualState JSON via decodeReplayState
/// 3. Initialises a new State via init(fromBroadcastSnapshot:) (sets all dirty flags)
/// 4. Broadcasts the state diff to all connected clients
///
/// Runs in .live mode — no changes to LandKeeper are required.
public enum GenericReplayLand<State: StateFromSnapshotDecodable> {

    /// Creates a replay LandDefinition based on an existing land definition.
    ///
    /// The replay land uses the same `id`, access-control settings and tick interval
    /// as the base definition.
    ///
    /// Inject a `ReevaluationRunnerService` into the replay land's services before
    /// starting it. The service must already have a verification run in progress so
    /// that results appear in the queue each tick.
    public static func makeLand(
        basedOn definition: LandDefinition<State>
    ) -> LandDefinition<State> {
        let config = definition.config
        let tickInterval = definition.lifetimeHandlers.tickInterval ?? .milliseconds(50)

        return Land(
            definition.id,
            using: State.self
        ) {
            AccessControl { acl in
                acl.allowPublic = config.allowPublic
                if let maxPlayers = config.maxPlayers {
                    acl.maxPlayers = maxPlayers
                }
            }

            Lifetime {
                Tick(every: tickInterval) { (state: inout State, ctx: LandContext) in
                    guard let runnerService = ctx.services.get(ReevaluationRunnerService.self) else {
                        return
                    }

                    let debugEnabled = EnvHelpers.getEnvBool(
                        key: "GENERIC_REPLAY_DEBUG",
                        defaultValue: false
                    )

                    // Fallback bootstrap: if replay runner was not started by server wiring,
                    // derive record path from replay landID and start verification here.
                    let status = runnerService.getStatus()
                    if status.phase == .idle,
                       let recordFilePath = decodeReplayRecordPath(from: ctx.landID) {
                        runnerService.startVerification(
                            landType: definition.id,
                            recordFilePath: recordFilePath
                        )
                        if debugEnabled {
                            ctx.logger.info("Generic replay runner started from replay landID", metadata: [
                                "landID": .string(ctx.landID),
                                "recordFilePath": .string(recordFilePath),
                            ])
                        }
                    }

                    guard let result = runnerService.consumeNextResult() else {
                        if debugEnabled {
                            let phase = runnerService.getStatus().phase.rawValue
                            ctx.logger.debug("Generic replay result queue empty", metadata: [
                                "landID": .string(ctx.landID),
                                "phase": .string(phase),
                            ])
                        }
                        return
                    }

                    guard let snapshot = decodeReplayState(StateSnapshot.self, from: result.actualState) else {
                        if debugEnabled {
                            ctx.logger.warning("Generic replay failed to decode StateSnapshot from actualState", metadata: [
                                "tickId": .stringConvertible(result.tickId),
                                "stateHash": .string(result.stateHash),
                            ])
                        }
                        return
                    }

                    guard let decoded = try? State(fromBroadcastSnapshot: snapshot) else {
                        if debugEnabled {
                            ctx.logger.warning("Generic replay failed to decode State from broadcast snapshot", metadata: [
                                "tickId": .stringConvertible(result.tickId),
                                "stateHash": .string(result.stateHash),
                            ])
                        }
                        return
                    }

                    state = decoded
                    ctx.requestSyncBroadcastOnly()

                    // Emit server events for this tick (projectedOnly vs projectedWithFallback).
                    let policy = ctx.services.get(ReevaluationReplayPolicyService.self)?.eventPolicy ?? .projectedOnly
                    let eventsToSend: [ReevaluationRecordedServerEvent]
                    switch policy {
                    case .projectedOnly:
                        eventsToSend = result.emittedServerEvents
                    case .projectedWithFallback:
                        eventsToSend = result.emittedServerEvents.isEmpty ? result.recordedServerEvents : result.emittedServerEvents
                    }
                    for recorded in eventsToSend {
                        let anyEvent = AnyServerEvent(type: recorded.typeIdentifier, payload: recorded.payload)
                        let target = recorded.target.toEventTarget()
                        ctx.emitAnyServerEvent(anyEvent, to: target)
                    }
                }
            }
        }
    }

    private static func decodeReplayRecordPath(from landIDString: String) -> String? {
        let landID = LandID(landIDString)
        let parts = landID.instanceId.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }

        let token = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = token.count % 4
        let padded = remainder > 0 ? token + String(repeating: "=", count: 4 - remainder) : token
        guard let data = Data(base64Encoded: padded),
              let recordPath = String(data: data, encoding: .utf8),
              !recordPath.isEmpty else {
            return nil
        }
        return recordPath
    }
}
