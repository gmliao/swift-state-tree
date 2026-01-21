import Foundation
import SwiftStateTree

public enum ReevaluationMonitor {
    public static func makeLand() -> LandDefinition<ReevaluationMonitorState> {
        Land(
            "reevaluation-monitor",
            using: ReevaluationMonitorState.self
        ) {
            AccessControl {
                AllowPublic(true) // Admin only (TODO: Restore auth)
                MaxPlayers(1)
            }

            Lifetime {
                Tick(every: .milliseconds(100)) { (state: inout ReevaluationMonitorState, ctx: LandContext) in
                    if let service = ctx.services.get(ReevaluationRunnerService.self) {
                        let status = service.getStatus()

                        // Sync status to state
                        state.status = status.phase.rawValue
                        state.currentTickId = status.currentTick
                        state.totalTicks = Int(status.totalTicks)
                        state.processedTicks = Int(status.currentTick) // Approximate
                        state.correctTicks = status.correctTicks
                        state.mismatchedTicks = status.mismatchedTicks
                        state.errorMessage = status.errorMessage
                        state.recordFilePath = status.recordFilePath

                        state.currentActualHash = status.currentActualHash
                        state.currentExpectedHash = status.currentExpectedHash
                        state.currentIsMatch = status.currentIsMatch

                        // Update paused state
                        state.isPaused = (status.phase == .paused)
                    }
                }
            }

            Rules {
                HandleAction(StartVerificationAction.self) { (state: inout ReevaluationMonitorState, action: StartVerificationAction, ctx: LandContext) in
                    guard let service = ctx.services.get(ReevaluationRunnerService.self) else {
                        state.errorMessage = "Service not available"
                        state.status = "failed"
                        return StartVerificationResponse()
                    }

                    state.status = "loading"
                    // Start verification (non-blocking now)
                    service.startVerification(landType: action.landType, recordFilePath: action.recordFilePath)

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
        }
    }
}
