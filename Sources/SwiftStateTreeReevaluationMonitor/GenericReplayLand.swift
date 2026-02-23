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

                    guard let result = runnerService.consumeNextResult() else {
                        return
                    }

                    guard let snapshot = decodeReplayState(StateSnapshot.self, from: result.actualState) else {
                        return
                    }

                    guard let decoded = try? State(fromBroadcastSnapshot: snapshot) else {
                        return
                    }

                    state = decoded
                    ctx.requestSyncBroadcastOnly()
                }
            }
        }
    }
}
