// Tests/SwiftStateTreeTests/ResolverDeadlineSettledResultTests.swift
//
// A resolver group whose resolvers have all finished when the deadline passes isn't timed out,
// even if the task delivering its result hasn't run yet (#448). The test holds that task at
// `beforeResultDeliveryForTesting` and lets the timer read the running resolvers only once the
// hold is reached (`deadlinePassedForTesting`), so the order doesn't depend on timing: the
// deadline passes while every resolver has finished and the result is still undelivered.

import Foundation
import Testing
import Logging
@testable import SwiftStateTree

private func makeContexts(player: String) -> (ResolverContext, LandContext) {
    let landContext = LandContext(
        landID: "deadline-settled",
        playerID: PlayerID(player),
        clientID: ClientID("c-\(player)"),
        sessionID: SessionID("s-\(player)"),
        services: LandServices(),
        logger: Logger(label: "test"),
        deviceID: nil,
        metadata: [:],
        emitEventHandler: { _, _ in },
        requestSyncNowHandler: { },
        requestSyncBroadcastOnlyHandler: { }
    )
    let resolverContext = ResolverContext(landContext: landContext, currentState: DeadlineTestState())
    return (resolverContext, landContext)
}

@Suite("Resolver deadline: a finished group's result", .timeLimit(.minutes(1)))
struct ResolverDeadlineSettledResultTests {
    /// Runs `DeadlineJoinResolver` for `player` with a 1 ms deadline, the result's delivery held
    /// until the call returns, and the timer reading the running resolvers only after the
    /// delivery is held. Returns the call's result.
    private func runWithDeliveryHeld(player: String, metrics: ResolverDeadlineMetrics) async -> Result<LandContext, any Error> {
        let delivery = WatermarkGate()
        defer { delivery.release() }
        let (resolverContext, landContext) = makeContexts(player: player)
        let executor = ResolverExecutor.createExecutor(for: DeadlineJoinResolver.self)
        return await ResolverDeadline.$overrideForTesting.withValue(.milliseconds(1)) {
            await ResolverDeadline.$metricsForTesting.withValue(metrics) {
                await ResolverDeadline.$beforeResultDeliveryForTesting.withValue({ await delivery.enterAndWait() }) {
                    await ResolverDeadline.$deadlinePassedForTesting.withValue({ await delivery.waitUntilEntered() }) {
                        do {
                            return .success(try await ResolverExecutor.executeResolvers(
                                executors: [executor],
                                resolverContext: resolverContext,
                                landContext: landContext
                            ))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
            }
        }
    }

    @Test("A group that succeeded before the deadline returns its output, though its delivery is late; no timeout is counted")
    func succeededGroupWins() async throws {
        let metrics = ResolverDeadlineMetrics()
        let result = await runWithDeliveryHeld(player: "p-1", metrics: metrics)
        let context = try result.get()
        #expect(context.getResolverOutput(DeadlineResolverOutput.self, forPropertyName: "deadlineJoin")?.value == 0)
        #expect(metrics.snapshot == .init(timeouts: 0, abandoned: 0, onLeaveDropped: 0))
    }

    @Test("A group whose resolver failed before the deadline throws that error, though its delivery is late; no timeout is counted")
    func failedGroupWins() async throws {
        let metrics = ResolverDeadlineMetrics()
        let result = await runWithDeliveryHeld(player: "fail-1", metrics: metrics)
        guard case .failure(let error) = result else {
            Issue.record("Expected the resolver's error, got a result")
            return
        }
        guard case .resolverFailed(let name, let underlying)? = error as? ResolverExecutionError else {
            Issue.record("Expected resolverFailed, got \(error)")
            return
        }
        #expect(name == "DeadlineJoinResolver")
        #expect(underlying is ResolverError, "\(underlying)")
        #expect(metrics.snapshot == .init(timeouts: 0, abandoned: 0, onLeaveDropped: 0))
    }
}
