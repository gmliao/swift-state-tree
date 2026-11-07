import Foundation
import Testing
import SwiftStateTree
@testable import GameContent

@Suite("Resolver test land (#65)")
struct ResolverTestLandTests {
    @Test("Settings come from the environment, clamped, with defaults")
    func settingsFromEnvironment() {
        #expect(SimulatedServiceSettings.fromEnvironment([:]) == SimulatedServiceSettings())
        let settings = SimulatedServiceSettings.fromEnvironment([
            ResolverTestEnvKeys.delayMs: "350",
            ResolverTestEnvKeys.delayJitterMs: "20",
            ResolverTestEnvKeys.failureRate: "1.5",
            ResolverTestEnvKeys.deadlineMs: "-4",
            ResolverTestEnvKeys.seed: "9",
        ])
        #expect(settings == SimulatedServiceSettings(delayMs: 350, delayJitterMs: 20, failureRate: 1, deadlineMs: 0, seed: 9))
        #expect(SimulatedServiceSettings.fromEnvironment([ResolverTestEnvKeys.ignoreCancellation: "true"]).ignoresCancellation)
        #expect(!SimulatedServiceSettings.fromEnvironment([:]).ignoresCancellation)
    }

    @Test("A cancelled call stops; with ignoresCancellation it runs to its end and returns")
    func cancellation() async throws {
        func cancelledCall(ignoring: Bool) async -> Result<String, any Error> {
            let service = SimulatedExternalService(settings: SimulatedServiceSettings(delayMs: 50, deadlineMs: 1000, ignoresCancellation: ignoring))
            let plan = await service.plan(delayMs: nil, fail: false, deadlineMs: nil)
            // Cancelled before it runs: the cooperative sleep throws at once.
            let task = Task { try await service.call(plan) }
            task.cancel()
            return await task.result
        }
        let cooperative = await cancelledCall(ignoring: false)
        #expect(throws: CancellationError.self) { try cooperative.get() }
        let start = ContinuousClock.now
        let ignoring = await cancelledCall(ignoring: true)
        #expect(try ignoring.get() == "call-0")
        // It ran to its planned end, not just past the cancellation.
        #expect(ContinuousClock.now - start >= .milliseconds(50))
    }

    /// The load client classifies a failed action by its error message, so the server's strings
    /// are pinned in the fixture both sides read.
    @Test("Failed actions' error messages are the ones the load client classifies")
    func failureMessages() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ws-loadtest/tests/fixtures/resolver-failure-messages.json")
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixtureURL))
        let keeper = LandKeeper<ResolverTestState>(
            definition: ResolverTest.makeLand(),
            initialState: ResolverTestState(),
            services: ResolverTest.makeServices(settings: SimulatedServiceSettings(delayMs: 0, deadlineMs: 1000)),
            autoStartLoops: false
        )
        let player = PlayerID("p1"), client = ClientID("c1"), session = SessionID("s1")
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        func message(_ action: CallServiceAction) async -> String? {
            let envelope = ActionEnvelope(typeIdentifier: String(describing: CallServiceAction.self), payload: AnyCodable(action))
            do {
                _ = try await keeper.handleActionEnvelope(envelope, playerID: player, clientID: client, sessionID: session)
                return nil
            } catch {
                // What the adapter sends as the ACTION_HANDLER_ERROR message.
                return "\(error)"
            }
        }
        #expect(await message(CallServiceAction(tag: "f", outcome: CallServiceOutcome.fail)) == fixture["failed"])
        #expect(await message(CallServiceAction(tag: "d", delayMs: 5, deadlineMs: 0, outcome: CallServiceOutcome.succeed)) == fixture["serviceDeadline"])
        let timedOut = ResolverExecutionError.timedOut(names: [String(describing: ServiceCallResolver.self)], after: .milliseconds(1000))
        #expect("\(timedOut)" == fixture["timedOut"])
    }

    @Test("Call plans are deterministic in the seed and the call order")
    func plansAreDeterministic() async {
        let settings = SimulatedServiceSettings(delayMs: 100, delayJitterMs: 50, failureRate: 0.3, deadlineMs: 1000, seed: 7)
        func plans(_ settings: SimulatedServiceSettings) async -> [SimulatedCallPlan] {
            let service = SimulatedExternalService(settings: settings)
            var out: [SimulatedCallPlan] = []
            for _ in 0..<200 { out.append(await service.plan(delayMs: nil, fail: nil, deadlineMs: nil)) }
            return out
        }
        let first = await plans(settings)
        #expect(await plans(settings) == first)
        var other = settings
        other.seed = 8
        #expect(await plans(other) != first)
        #expect(first.map(\.callIndex) == Array(0..<200))
        #expect(first.allSatisfy { (100...150).contains($0.delayMs) && $0.deadlineMs == 1000 })
        let failures = first.filter(\.fails).count
        #expect((30...90).contains(failures), "about 30% of 200 calls fail, got \(failures)")
    }

    @Test("Rates 0 and 1 never and always fail; the action's fields override the settings")
    func ratesAndOverrides() async {
        let never = SimulatedExternalService(settings: SimulatedServiceSettings(failureRate: 0))
        let always = SimulatedExternalService(settings: SimulatedServiceSettings(failureRate: 1))
        for _ in 0..<50 {
            #expect(await never.plan(delayMs: nil, fail: nil, deadlineMs: nil).fails == false)
            #expect(await always.plan(delayMs: nil, fail: nil, deadlineMs: nil).fails == true)
        }
        #expect(await always.plan(delayMs: nil, fail: false, deadlineMs: nil).fails == false)
        let plan = await never.plan(delayMs: 700, fail: true, deadlineMs: 300)
        #expect(plan.delayMs == 700 && plan.deadlineMs == 300 && plan.fails && plan.timesOut)
    }

    @Test("A call past its deadline throws the deadline error, a failing call the service error")
    func callOutcomes() async throws {
        let service = SimulatedExternalService(settings: SimulatedServiceSettings(delayMs: 0, deadlineMs: 1000))
        #expect(try await service.call(await service.plan(delayMs: 0, fail: false, deadlineMs: nil)) == "call-0")
        let late = await service.plan(delayMs: 5, fail: false, deadlineMs: 0)
        await #expect(throws: ResolverDeadlineExceeded(callIndex: 1, deadlineMs: 0)) { try await service.call(late) }
        let failing = await service.plan(delayMs: 0, fail: true, deadlineMs: nil)
        await #expect(throws: SimulatedServiceFailure(callIndex: 2)) { try await service.call(failing) }
        #expect(await service.inFlight == 0)
    }

    @Test("Payload sentinels map to overrides")
    func payloadOverrides() {
        #expect(CallServiceAction(tag: "t").overrides == (nil, nil, nil))
        let o = CallServiceAction(tag: "t", delayMs: 0, deadlineMs: 300, outcome: CallServiceOutcome.fail).overrides
        #expect(o.delayMs == 0 && o.deadlineMs == 300 && o.fail == true)
        #expect(CallServiceAction(tag: "t", outcome: CallServiceOutcome.succeed).overrides.fail == false)
    }

    @Test("A failed or timed-out action leaves the state unchanged; a successful one is applied")
    func actionOutcomes() async throws {
        let keeper = LandKeeper<ResolverTestState>(
            definition: ResolverTest.makeLand(),
            initialState: ResolverTestState(),
            services: ResolverTest.makeServices(settings: SimulatedServiceSettings(delayMs: 0, deadlineMs: 1000)),
            autoStartLoops: false
        )
        let player = PlayerID("p1")
        let client = ClientID("c1")
        let session = SessionID("s1")
        try await keeper.join(playerID: player, clientID: client, sessionID: session)

        func send(_ action: CallServiceAction) async throws -> AnyCodable {
            let envelope = ActionEnvelope(typeIdentifier: String(describing: CallServiceAction.self), payload: AnyCodable(action))
            return try await keeper.handleActionEnvelope(envelope, playerID: player, clientID: client, sessionID: session)
        }

        let failing = CallServiceAction(tag: "fail", outcome: CallServiceOutcome.fail)
        await #expect(throws: (any Error).self) { _ = try await send(failing) }
        let late = CallServiceAction(tag: "late", delayMs: 5, deadlineMs: 0, outcome: CallServiceOutcome.succeed)
        await #expect(throws: (any Error).self) { _ = try await send(late) }
        await keeper.stepTickOnce()
        var state = await keeper.currentState()
        #expect(state.applied == 0 && state.lastTag == "" && state.lastResult == "")

        // The action is applied in a turn; step ticks until it is.
        let pending = Task { try await send(CallServiceAction(tag: "ok", outcome: CallServiceOutcome.succeed)) }
        for _ in 0..<200 where await keeper.currentState().applied == 0 {
            await keeper.stepTickOnce()
            await Task.yield()
        }
        _ = try await pending.value
        state = await keeper.currentState()
        #expect(state.applied == 1)
        #expect(state.lastTag == "ok")
        #expect(state.lastResult == "call-2")
    }
}
