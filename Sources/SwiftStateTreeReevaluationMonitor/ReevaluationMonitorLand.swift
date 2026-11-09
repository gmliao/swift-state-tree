import Foundation
import SwiftStateTree

public enum ReevaluationMonitor {
    /// The reevaluation monitor land: it shows one verification run of the record its ticket
    /// binds (#366).
    ///
    /// The run is work outside the land's turns, done by `ReevaluationRunnerService`, which is
    /// shared mutable state outside the land's state: the one exception, in this land, to keeping
    /// all state in the land. Turns only request a run (`requestVerification`, synchronous, taking
    /// the run's ticket) and read the service's phase; the tick is the only reader of the run's
    /// status and results, which a run writes only while its ticket is current. The tick's read
    /// is an exception to "apply depends only on inputs" (the land isn't recorded, so replay
    /// doesn't need it); #387 replaces it with server-originated turn inputs.
    public static func makeLand() -> LandDefinition<ReevaluationMonitorState> {
        Land(
            "reevaluation-monitor",
            using: ReevaluationMonitorState.self
        ) {
            AccessControl {
                // Public join; the land is created only from a ticket the admin monitor start
                // signed (#366), and its ID is that ticket.
                AllowPublic(true)
                MaxPlayers(1)
            }

            Lifetime {
                Tick(every: .milliseconds(100)) { (state: inout ReevaluationMonitorState, ctx: LandContext) in
                    guard let service = ctx.services.get(ReevaluationRunnerService.self) else { return }

                    // Sync status to state
                    let status = service.getStatus()

                    state.status = status.phase.rawValue
                    state.currentTickId = status.currentTick
                    state.totalTicks = Int(status.totalTicks)
                    state.processedTicks = Int(status.currentTick) + 1
                    state.correctTicks = status.correctTicks
                    state.mismatchedTicks = status.mismatchedTicks
                    state.errorMessage = status.errorMessage
                    state.recordFilePath = status.recordFilePath

                    state.currentActualHash = status.currentActualHash
                    state.currentExpectedHash = status.currentExpectedHash
                    state.currentIsMatch = status.currentIsMatch
                    state.isPaused = (status.phase == .paused)

                    // Consume results and emit events
                    let newResults = service.consumeResults()
                    for result in newResults {
                        let event = TickSummaryEvent(
                            tickId: result.tickId,
                            isMatch: result.isMatch,
                            expectedHash: result.recordedHash ?? "?",
                            actualHash: result.stateHash
                        )
                        ctx.emitEvent(event, to: .all)

                        if let actualState = result.actualState {
                            let processedEvent = TickProcessedEvent(
                                tickId: result.tickId,
                                expectedState: actualState,
                                actualState: actualState,
                                isMatch: result.isMatch,
                                expectedHash: result.recordedHash ?? "?",
                                actualHash: result.stateHash
                            )
                            ctx.emitEvent(processedEvent, to: .all)
                        }
                    }
                }
            }

            Rules {
                // The run is requested in the first join's turn, not when the land is created:
                // the tick emits each result to the players present, so a run started before
                // anyone joined would send its first ticks to nobody. Later joins find it under
                // way (or finished) and see its totals in the state. The turn only requests the
                // run (synchronously, taking its ticket); the service's driver, started outside
                // any turn, does the work, and the tick reads the current run's results back.
                OnJoin { (state: inout ReevaluationMonitorState, ctx: LandContext) in
                    guard let service = ctx.services.get(ReevaluationRunnerService.self),
                          let run = ctx.services.get(ReevaluationMonitorRun.self),
                          service.getStatus().phase == .idle
                    else { return }
                    state.status = "loading"
                    service.requestVerification(landType: run.landType, recordFilePath: run.recordFilePath)
                }
                // The first join's turn requests the run (above). This only restarts a finished
                // run, with the ticket's record; the action's fields are ignored.
                HandleAction(StartVerificationAction.self) { (state: inout ReevaluationMonitorState, _: StartVerificationAction, ctx: LandContext) in
                    guard let service = ctx.services.get(ReevaluationRunnerService.self),
                          let run = ctx.services.get(ReevaluationMonitorRun.self) else {
                        state.errorMessage = "Service not available"
                        state.status = "failed"
                        return StartVerificationResponse()
                    }
                    switch service.getStatus().phase {
                    case .completed, .failed:
                        state.status = "loading"
                        // A request, as on the first join: the driver runs it outside the turn.
                        service.requestVerification(landType: run.landType, recordFilePath: run.recordFilePath)
                    case .idle, .loading, .verifying, .paused:
                        break
                    }
                    return StartVerificationResponse()
                }

                HandleAction(PauseVerificationAction.self) { (state: inout ReevaluationMonitorState, _: PauseVerificationAction, ctx: LandContext) in
                    ctx.services.get(ReevaluationRunnerService.self)?.pause()
                    state.isPaused = true
                    state.status = "paused"
                    return PauseVerificationResponse()
                }

                HandleAction(ResumeVerificationAction.self) { (state: inout ReevaluationMonitorState, _: ResumeVerificationAction, ctx: LandContext) in
                    ctx.services.get(ReevaluationRunnerService.self)?.resume()
                    state.isPaused = false
                    state.status = "verifying"
                    return ResumeVerificationResponse()
                }
            }

            ServerEvents {
                Register(TickSummaryEvent.self)
                Register(TickProcessedEvent.self)
                Register(VerificationProgressEvent.self)
                Register(VerificationCompleteEvent.self)
                Register(VerificationFailedEvent.self)
            }
        }
    }
}
