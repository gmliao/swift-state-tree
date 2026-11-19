// GenericReplayLand.swift
// Generic replay land that broadcasts recorded game state to connected clients.
// Runs in .live mode — no changes to LandKeeper required.

import Foundation
import SwiftStateTree

/// The events the replay land sends for a tick. A tick whose recorded passes didn't match
/// (#325) replayed none of its inputs, so it never falls back to the recorded events: that
/// would show a failed replay as a correct one.
func selectReplayEventsToEmit<Event>(
    policy: ReevaluationReplayEventPolicy,
    emittedServerEvents: [Event],
    recordedServerEvents: [Event],
    recordedPassMismatch: String? = nil
) -> [Event] {
    if recordedPassMismatch != nil { return emittedServerEvents }
    switch policy {
    case .projectedOnly:
        return emittedServerEvents
    case .projectedWithFallback:
        return emittedServerEvents.isEmpty ? recordedServerEvents : emittedServerEvents
    }
}

/// A factory for creating replay LandDefinitions.
///
/// Each tick, GenericReplayLand:
/// 1. Consumes the next result from ReevaluationRunnerService
/// 2. Takes its resolved frame (`ReevaluationReplayFrame`): the state built back from the
///    runner's snapshot, and the tick's server events decoded into their registered types. The
///    runner resolved it in `step()`, so a record/code mismatch failed the run there (#521 PR 1b).
/// 3. Sets the state (all dirty flags set), requests a broadcast sync, and emits the events the
///    policy picks, typed (`emitEvent`), each with its recorded target.
///
/// Runs in .live mode — no changes to LandKeeper are required.
public enum GenericReplayLand<State: StateFromSnapshotDecodable> {

    /// Creates a replay LandDefinition based on an existing land definition.
    ///
    /// The replay land uses the same `id`, access-control settings and tick interval
    /// as the base definition, and registers the same server events (#521 PR 1b, M5).
    ///
    /// Inject a `ReevaluationRunnerService` into the replay land's services before
    /// starting it. The service must already have a verification run in progress so
    /// that results appear in the queue each tick. `registerWithGenericReplay` does both, and
    /// starts the run only for a land whose ID is a replay ticket the admin replay start issued;
    /// the land never starts a run from its own ID.
    public static func makeLand(
        basedOn definition: LandDefinition<State>
    ) -> LandDefinition<State> {
        let config = definition.config
        let tickInterval = definition.lifetimeHandlers.tickInterval ?? .milliseconds(50)

        let replayLand = Land(
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

                    // The runner is started by the server wiring when the land is created
                    // (`registerWithGenericReplay`), which verifies the land's replay ticket
                    // first. The land never starts one from its own ID (#366).
                    let debugEnabled = EnvHelpers.getEnvBool(
                        key: "GENERIC_REPLAY_DEBUG",
                        defaultValue: false
                    )

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

                    // The service queues only results resolved for this land's state type
                    // (`expectReplayLandState`), so the frame and its state are always there.
                    guard let frame = result.replayFrame, let decoded = frame.state as? State else {
                        ctx.logger.error("Generic replay result without a frame of this land's state type", metadata: [
                            "tickId": .stringConvertible(result.tickId),
                        ])
                        return
                    }

                    state = decoded
                    ctx.requestSyncBroadcastOnly()

                    // Emit server events for this tick (projectedOnly vs projectedWithFallback).
                    let policy = ctx.services.get(ReevaluationReplayPolicyService.self)?.eventPolicy ?? .projectedOnly
                    let eventsToSend = selectReplayEventsToEmit(
                        policy: policy,
                        emittedServerEvents: frame.projectedEvents,
                        recordedServerEvents: frame.recordedEvents,
                        recordedPassMismatch: result.recordedPassMismatch
                    )
                    if let reason = result.recordedPassMismatch {
                        ctx.logger.error("Replay: the record's passes don't match the tick's inputs", metadata: [
                            "tickId": .stringConvertible(result.tickId),
                            "reason": .string(reason),
                        ])
                    }
                    for resolved in eventsToSend {
                        ctx.emitEvent(resolved.event, to: resolved.target.toEventTarget())
                    }
                }
            }
        }
        return replayLand.replacingServerEventRegistry(definition.serverEventRegistry)
    }
}
