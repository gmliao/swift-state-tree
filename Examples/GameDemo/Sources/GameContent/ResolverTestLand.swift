// Examples/GameDemo/Sources/GameContent/ResolverTestLand.swift
//
// A test land for action resolvers that are slow, fail or time out (#65). `CallServiceAction`
// declares a resolver that calls a simulated external service. The service waits a configured
// delay, fails at a configured rate, and the resolver gives up at a deadline. The land ticks at a
// fixed rate, so a check can see that ticks keep coming while resolvers are pending, and that a
// failed or timed-out action leaves the state unchanged.

import Foundation
import SwiftStateTree

// MARK: - Layout

public enum ResolverTestConfig {
    public static let landType = "resolver-test"
    public static let tickIntervalMs: Int64 = 50
    public static let maxPlayers = 16
}

/// Environment keys for the simulated service, read once when the server builds a land's services.
public enum ResolverTestEnvKeys {
    /// Base delay of each call, ms. Default 200.
    public static let delayMs = "RESOLVER_TEST_DELAY_MS"
    /// Extra delay drawn per call in `0...jitter`, ms (deterministic from the seed). Default 0.
    public static let delayJitterMs = "RESOLVER_TEST_DELAY_JITTER_MS"
    /// Share of calls that fail, `0...1` (deterministic from the seed). Default 0.
    public static let failureRate = "RESOLVER_TEST_FAILURE_RATE"
    /// The resolver's deadline, ms: a call that would take longer throws at the deadline. Default 1000.
    public static let deadlineMs = "RESOLVER_TEST_DEADLINE_MS"
    /// Seed of the per-call draws. Default 1.
    public static let seed = "RESOLVER_TEST_SEED"
    /// `true`: a call waits its whole delay even when its task is cancelled, as a client library
    /// with its own blocking timeout does. The framework's resolver deadline then gives up on the
    /// call while it keeps running (an abandoned resolver). Default false: a cancelled call stops.
    public static let ignoreCancellation = "RESOLVER_TEST_IGNORE_CANCELLATION"
    /// Share of joins whose OnJoin resolver fails, `0...1` (deterministic from the seed and the
    /// land's join count). The client gets `JOIN_DENIED` with the check's error,
    /// `Resolver 'JoinCheckResolver' failed: SimulatedMembershipFailure(kind: join, index: n)`. Default 0.
    public static let joinFailureRate = "RESOLVER_TEST_JOIN_FAILURE_RATE"
    /// Share of leaves whose OnLeave resolver fails, `0...1`: the leave's handler doesn't run
    /// (the framework's `onLeaveDropped`); the player is removed anyway. Default 0.
    public static let leaveFailureRate = "RESOLVER_TEST_LEAVE_FAILURE_RATE"
}

// MARK: - Simulated service

/// How the simulated service behaves. Each field can be overridden per call by the action.
public struct SimulatedServiceSettings: Sendable, Equatable {
    public var delayMs: Int
    public var delayJitterMs: Int
    public var failureRate: Double
    public var deadlineMs: Int
    public var seed: UInt64
    /// `RESOLVER_TEST_IGNORE_CANCELLATION`; for the whole service, not per call.
    public var ignoresCancellation: Bool
    /// `RESOLVER_TEST_JOIN_FAILURE_RATE` and `_LEAVE_FAILURE_RATE`.
    public var joinFailureRate: Double
    public var leaveFailureRate: Double

    public init(delayMs: Int = 200, delayJitterMs: Int = 0, failureRate: Double = 0, deadlineMs: Int = 1000, seed: UInt64 = 1, ignoresCancellation: Bool = false, joinFailureRate: Double = 0, leaveFailureRate: Double = 0) {
        self.delayMs = max(0, delayMs)
        self.delayJitterMs = max(0, delayJitterMs)
        self.failureRate = min(1, max(0, failureRate))
        self.deadlineMs = max(0, deadlineMs)
        self.seed = seed
        self.ignoresCancellation = ignoresCancellation
        self.joinFailureRate = min(1, max(0, joinFailureRate))
        self.leaveFailureRate = min(1, max(0, leaveFailureRate))
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> SimulatedServiceSettings {
        SimulatedServiceSettings(
            delayMs: EnvHelpers.getEnvInt(key: ResolverTestEnvKeys.delayMs, defaultValue: 200, environment: environment),
            delayJitterMs: EnvHelpers.getEnvInt(key: ResolverTestEnvKeys.delayJitterMs, defaultValue: 0, environment: environment),
            failureRate: EnvHelpers.getEnvDouble(key: ResolverTestEnvKeys.failureRate, defaultValue: 0, min: 0, max: 1, environment: environment),
            deadlineMs: EnvHelpers.getEnvInt(key: ResolverTestEnvKeys.deadlineMs, defaultValue: 1000, environment: environment),
            seed: UInt64(max(0, EnvHelpers.getEnvInt(key: ResolverTestEnvKeys.seed, defaultValue: 1, environment: environment))),
            ignoresCancellation: EnvHelpers.getEnvBool(key: ResolverTestEnvKeys.ignoreCancellation, defaultValue: false, environment: environment),
            joinFailureRate: EnvHelpers.getEnvDouble(key: ResolverTestEnvKeys.joinFailureRate, defaultValue: 0, min: 0, max: 1, environment: environment),
            leaveFailureRate: EnvHelpers.getEnvDouble(key: ResolverTestEnvKeys.leaveFailureRate, defaultValue: 0, min: 0, max: 1, environment: environment)
        )
    }
}

/// What one call will do, decided when it starts.
public struct SimulatedCallPlan: Sendable, Equatable {
    public let callIndex: Int
    public let delayMs: Int
    public let deadlineMs: Int
    public let fails: Bool

    /// The call runs past its deadline: the resolver throws at the deadline.
    public var timesOut: Bool { delayMs > deadlineMs }
}

public struct SimulatedServiceFailure: Error, Sendable, Equatable {
    public let callIndex: Int
}

public struct ResolverDeadlineExceeded: Error, Sendable, Equatable {
    public let callIndex: Int
    public let deadlineMs: Int
}

/// A join or leave the service's draw failed (`RESOLVER_TEST_JOIN_FAILURE_RATE`, `_LEAVE_FAILURE_RATE`).
/// Its description is what a failed join's `JOIN_DENIED` message carries, pinned in the load
/// client's fixture, so it doesn't depend on how Swift prints a module-qualified enum.
public struct SimulatedMembershipFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public let kind: MembershipCheckKind
    public let index: Int

    public var description: String { "SimulatedMembershipFailure(kind: \(kind.rawValue), index: \(index))" }
}

public enum MembershipCheckKind: String, Sendable, Equatable, Codable {
    case join, leave
}

/// An external service stand-in. One instance per land; its call counter drives the seeded draws,
/// so a run with the same seed and the same call order fails the same calls.
public actor SimulatedExternalService {
    public let settings: SimulatedServiceSettings
    private var calls = 0
    private var joinChecks = 0
    private var leaveChecks = 0
    /// Calls started and not finished (diagnostics).
    public private(set) var inFlight = 0

    public init(settings: SimulatedServiceSettings) {
        self.settings = settings
    }

    /// The next join or leave check: the n-th one of its kind fails by `seed`, `n` and the rate.
    /// Its own counter, so membership checks don't shift the action calls' draws.
    public func checkMembership(_ kind: MembershipCheckKind) throws -> Int {
        let index: Int
        let rate: Double
        switch kind {
        case .join:
            index = joinChecks
            joinChecks += 1
            rate = settings.joinFailureRate
        case .leave:
            index = leaveChecks
            leaveChecks += 1
            rate = settings.leaveFailureRate
        }
        let draw = Self.mix(settings.seed, UInt64(index), salt: kind == .join ? 3 : 4)
        if Double(draw >> 11) / Double(1 << 53) < rate {
            throw SimulatedMembershipFailure(kind: kind, index: index)
        }
        return index
    }

    /// Plans the next call: the n-th call's jitter and failure come from `seed` and `n`.
    public func plan(delayMs: Int?, fail: Bool?, deadlineMs: Int?) -> SimulatedCallPlan {
        let index = calls
        calls += 1
        let jitterDraw = Self.mix(settings.seed, UInt64(index), salt: 1)
        let failureDraw = Self.mix(settings.seed, UInt64(index), salt: 2)
        let jitter = settings.delayJitterMs > 0 ? Int(jitterDraw % UInt64(settings.delayJitterMs + 1)) : 0
        let failsByRate = Double(failureDraw >> 11) / Double(1 << 53) < settings.failureRate
        return SimulatedCallPlan(
            callIndex: index,
            delayMs: max(0, delayMs ?? settings.delayMs + jitter),
            deadlineMs: max(0, deadlineMs ?? settings.deadlineMs),
            fails: fail ?? failsByRate
        )
    }

    /// Runs a planned call: waits its delay (or only up to the deadline), then fails or returns.
    public func call(_ plan: SimulatedCallPlan) async throws -> String {
        inFlight += 1
        defer { inFlight -= 1 }
        let wait = Duration.milliseconds(Int64(min(plan.delayMs, plan.deadlineMs)))
        if settings.ignoresCancellation {
            // A detached task doesn't inherit the caller's cancellation, and awaiting its value
            // isn't interrupted by it: the call runs to its end.
            try await Task.detached { try await safeTaskSleep(for: wait) }.value
        } else {
            try await safeTaskSleep(for: wait)
        }
        if plan.timesOut {
            throw ResolverDeadlineExceeded(callIndex: plan.callIndex, deadlineMs: plan.deadlineMs)
        }
        if plan.fails {
            throw SimulatedServiceFailure(callIndex: plan.callIndex)
        }
        return "call-\(plan.callIndex)"
    }

    /// SplitMix64 of the seed, the call index and a salt.
    static func mix(_ seed: UInt64, _ index: UInt64, salt: UInt64) -> UInt64 {
        var z = seed &+ index &* 0x9E37_79B9_7F4A_7C15 &+ salt &* 0xD1B5_4A32_D192_ED03
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - State

@StateNodeBuilder
public struct ResolverTestState: StateNodeProtocol, StateFromSnapshotDecodable {
    /// Actions whose resolver succeeded and whose handler ran.
    @Sync(.broadcast)
    public var applied: Int = 0

    /// The last applied action's tag and its service result.
    @Sync(.broadcast)
    public var lastTag: String = ""

    @Sync(.broadcast)
    public var lastResult: String = ""

    /// Joins and leaves whose resolver succeeded and whose handler ran. A failed join never
    /// joined; a failed leave's player is removed without its handler.
    @Sync(.broadcast)
    public var joins: Int = 0

    @Sync(.broadcast)
    public var leaves: Int = 0

    /// Ticks between the last applied action's resolver start and its handler: about the
    /// service delay over the tick interval when the keeper keeps ticking while it waits.
    @Sync(.broadcast)
    public var lastTickAdvance: Int64 = 0

    @Sync(.broadcast)
    public var tickCount: Int64 = 0

    public init() {}
}

// MARK: - Action

/// Calls the simulated service through `ServiceCallResolver`. A negative `delayMs` or
/// `deadlineMs` uses the server's setting (`ResolverTestEnvKeys`). `outcome` is `"rate"` (fail
/// at the server's failure rate), `"fail"` or `"succeed"`.
@Payload
public struct CallServiceAction: ActionPayload {
    public typealias Response = CallServiceResponse
    public let tag: String
    public let delayMs: Int
    public let deadlineMs: Int
    public let outcome: String

    public init(tag: String, delayMs: Int = -1, deadlineMs: Int = -1, outcome: String = CallServiceOutcome.byRate) {
        self.tag = tag
        self.delayMs = delayMs
        self.deadlineMs = deadlineMs
        self.outcome = outcome
    }
}

/// `CallServiceAction.outcome` values.
public enum CallServiceOutcome {
    public static let byRate = "rate"
    public static let fail = "fail"
    public static let succeed = "succeed"
    public static let all = [byRate, fail, succeed]
}

extension CallServiceAction {
    /// The per-call overrides, `nil` where the server's setting applies.
    var overrides: (delayMs: Int?, fail: Bool?, deadlineMs: Int?) {
        let fail: Bool? = switch outcome {
        case CallServiceOutcome.fail: true
        case CallServiceOutcome.succeed: false
        default: nil
        }
        return (delayMs >= 0 ? delayMs : nil, fail, deadlineMs >= 0 ? deadlineMs : nil)
    }
}

@Payload
public struct CallServiceResponse: ResponsePayload {
    public let applied: Int
    public let tickAdvance: Int64

    public init(applied: Int, tickAdvance: Int64) {
        self.applied = applied
        self.tickAdvance = tickAdvance
    }
}

// MARK: - Resolver

public struct ServiceCall: ResolverOutput {
    public let tag: String
    public let callIndex: Int
    public let result: String
    /// `tickCount` when the resolver started.
    public let startTick: Int64

    public init(tag: String, callIndex: Int, result: String, startTick: Int64) {
        self.tag = tag
        self.callIndex = callIndex
        self.result = result
        self.startTick = startTick
    }
}

/// The output of a join or leave check: its index among the land's checks of that kind.
public struct MembershipCheck: ResolverOutput {
    public let index: Int

    public init(index: Int) {
        self.index = index
    }
}

/// OnJoin's check: fails at `RESOLVER_TEST_JOIN_FAILURE_RATE`, so the join fails.
public struct JoinCheckResolver: ContextResolver {
    public typealias Output = MembershipCheck

    public static func resolve(ctx: ResolverContext) async throws -> MembershipCheck {
        guard let service = ctx.services.get(SimulatedExternalService.self) else {
            throw ResolverError.custom("SimulatedExternalService is not registered")
        }
        return MembershipCheck(index: try await service.checkMembership(.join))
    }
}

/// OnLeave's check: fails at `RESOLVER_TEST_LEAVE_FAILURE_RATE`, so the leave is dropped.
public struct LeaveCheckResolver: ContextResolver {
    public typealias Output = MembershipCheck

    public static func resolve(ctx: ResolverContext) async throws -> MembershipCheck {
        guard let service = ctx.services.get(SimulatedExternalService.self) else {
            throw ResolverError.custom("SimulatedExternalService is not registered")
        }
        return MembershipCheck(index: try await service.checkMembership(.leave))
    }
}

/// Calls `SimulatedExternalService` for a `CallServiceAction`. Its output is recorded, so replay
/// does not call the service; a failed or timed-out call throws, and the action is never applied.
public struct ServiceCallResolver: ContextResolver {
    public typealias Output = ServiceCall

    public static func resolve(ctx: ResolverContext) async throws -> ServiceCall {
        guard let action = ctx.actionPayload as? CallServiceAction else {
            throw ResolverError.missingParameter("CallServiceAction")
        }
        guard let service = ctx.services.get(SimulatedExternalService.self) else {
            throw ResolverError.custom("SimulatedExternalService is not registered")
        }
        let startTick = (ctx.currentState as? ResolverTestState)?.tickCount ?? 0
        let overrides = action.overrides
        guard CallServiceOutcome.all.contains(action.outcome) else {
            throw ResolverError.custom("unknown outcome \(action.outcome)")
        }
        let plan = await service.plan(delayMs: overrides.delayMs, fail: overrides.fail, deadlineMs: overrides.deadlineMs)
        let result = try await service.call(plan)
        return ServiceCall(tag: action.tag, callIndex: plan.callIndex, result: result, startTick: startTick)
    }
}

// MARK: - Land

public enum ResolverTest {
    public static func makeLand() -> LandDefinition<ResolverTestState> {
        Land(ResolverTestConfig.landType, using: ResolverTestState.self) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(ResolverTestConfig.maxPlayers)
            }

            Rules {
                OnJoin(resolvers: JoinCheckResolver.self) { (state: inout ResolverTestState, _: LandContext) in
                    state.joins += 1
                }

                OnLeave(resolvers: LeaveCheckResolver.self) { (state: inout ResolverTestState, _: LandContext) in
                    state.leaves += 1
                }

                HandleAction(CallServiceAction.self, resolvers: ServiceCallResolver.self) {
                    (state: inout ResolverTestState, _: CallServiceAction, ctx: LandContext) in
                    guard let call = ctx.serviceCall as ServiceCall? else {
                        throw ResolverError.custom("ServiceCallResolver output missing")
                    }
                    state.applied += 1
                    state.lastTag = call.tag
                    state.lastResult = call.result
                    state.lastTickAdvance = state.tickCount - call.startTick
                    return CallServiceResponse(applied: state.applied, tickAdvance: state.lastTickAdvance)
                }
            }

            Lifetime {
                Tick(every: .milliseconds(ResolverTestConfig.tickIntervalMs)) { (state: inout ResolverTestState, ctx: LandContext) in
                    // Server-side tick timing (`TickProbe`); no probe in re-evaluation.
                    ctx.services.get(TickProbe.self)?.noteTickStart()
                    state.tickCount = ctx.tickId ?? state.tickCount + 1
                }
            }
        }
    }

    /// The services a live resolver-test land needs: its own simulated service, and with a
    /// recorder its own tick probe. Called once per land.
    public static func makeServices(settings: SimulatedServiceSettings = .fromEnvironment(), tickRecorder: TickProbeRecorder? = nil) -> LandServices {
        var services = LandServices()
        services.register(SimulatedExternalService(settings: settings), as: SimulatedExternalService.self)
        if let tickRecorder {
            services.register(TickProbe(recorder: tickRecorder), as: TickProbe.self)
        }
        return services
    }
}
