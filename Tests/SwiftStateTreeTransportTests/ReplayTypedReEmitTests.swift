// The replay land re-emits typed (#521 PR 1b, #538). Its tick reads the frame the runner
// resolved and emits each event with `emitEvent`, so a recorded event in the record's tree form
// goes out as its payload type, with its recorded target, on every encoding. A record/code
// mismatch fails the replay run, not the replay land: the ticks before it stay queued and are
// shown, nothing after it is. A result the land can't show (no frame, another state type, no
// state) is refused before it is queued, or, for a land built with `makeLand` alone, fails the
// run when the land reads it.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
@testable import SwiftStateTreeReevaluationMonitor
import SwiftStateTreeMessagePack

/// A runner whose ticks `steps` build, in order; a step may throw, as `step()` does.
final class ScriptedReplayRunner: ReevaluationRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private let steps: [@Sendable () throws -> ReevaluationStepResult]
    var maxTickId: Int64 { Int64(steps.count - 1) }

    init(_ steps: [@Sendable () throws -> ReevaluationStepResult]) {
        self.steps = steps
    }

    convenience init(_ step: @escaping @Sendable () throws -> ReevaluationStepResult) {
        self.init([step])
    }

    func prepare() async throws {}
    func step() async throws -> ReevaluationStepResult? {
        let index: Int? = lock.withLock {
            guard next < steps.count else { return nil }
            defer { next += 1 }
            return next
        }
        guard let index else { return nil }
        return try steps[index]()
    }
}

struct ScriptedReplayFactory: ReevaluationTargetFactory {
    let runner: ScriptedReplayRunner
    func createRunner(landType: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        runner
    }
}

/// A projector that keeps no state: the copy it makes must keep every other field (M2).
struct EmptyReplayProjector: ReevaluationReplayProjecting {
    func project(_ result: ReevaluationStepResult) throws -> ProjectedReplayFrame {
        ProjectedReplayFrame(tickID: result.tickId, stateObject: [:])
    }
}

/// The base land of the replay: it registers `UntypedPayloadTypedEvent`.
private let replayBase = makeUntypedEmitLand("typed-replay", untyped: false)

private func replaySnapshot(round: Int = 1) -> AnyCodable {
    let snapshot = StateSnapshot(values: ["round": .int(round)])
    return AnyCodable(String(decoding: try! JSONEncoder().encode(snapshot), as: UTF8.self))
}

private let toAll = ReevaluationEventTargetRecord(kind: "all", ids: [])
/// A player who never joined: an event recorded to them reaches no session.
private let toAbsentPlayer = ReevaluationEventTargetRecord(kind: "player", ids: ["absent"])

/// A server event as a saved record's tree holds it.
private func recordedEvent(
    _ name: String, _ payload: some Encodable, sequence: Int64 = 1, tickId: Int64 = 0,
    target: ReevaluationEventTargetRecord = toAll
) throws -> ReevaluationRecordedServerEvent {
    ReevaluationRecordedServerEvent(
        kind: "serverEvent", sequence: sequence, tickId: tickId, typeIdentifier: name,
        payload: try CanonicalMessagePack.decode(AnyCodable.self, from: CanonicalMessagePack.encode(payload)),
        target: target
    )
}

private func typed(_ hp: Int, sequence: Int64 = 1, tickId: Int64 = 0, target: ReevaluationEventTargetRecord = toAll) throws -> ReevaluationRecordedServerEvent {
    try recordedEvent("UntypedPayloadTyped", UntypedPayloadTypedEvent(hp: hp), sequence: sequence, tickId: tickId, target: target)
}

/// One tick's result, resolved against the replay's base land as the stock runner does.
private func resolvedResult(
    tickId: Int64 = 0,
    recorded: [ReevaluationRecordedServerEvent] = [],
    projected: [ReevaluationRecordedServerEvent] = [],
    passMismatch: String? = nil,
    actualState: AnyCodable? = replaySnapshot()
) throws -> ReevaluationStepResult {
    let frame = try ReevaluationReplayFrame.resolve(
        tickId: tickId, recordedServerEvents: recorded, emittedServerEvents: projected, actualState: actualState, definition: replayBase
    )
    return ReevaluationStepResult(
        tickId: tickId, stateHash: "h", recordedHash: "h", isMatch: passMismatch == nil, actualState: actualState,
        emittedServerEvents: projected, recordedServerEvents: recorded,
        recordedPassMismatch: passMismatch, replayFrame: frame
    )
}

private func makeService(
    runner: ScriptedReplayRunner,
    expectState: Bool = true,
    projector: (any ReevaluationReplayProjecting)? = nil
) -> ReevaluationRunnerService {
    let service = ReevaluationRunnerService(factory: ScriptedReplayFactory(runner: runner), projectorResolver: { _ in projector })
    if expectState { service.expectReplayLandState(UntypedPayloadState.self) }
    return service
}

/// Runs `service`'s verification to its end (its results queued, or the run failed).
private func runToEnd(_ service: ReevaluationRunnerService) async {
    service.startVerification(landType: "typed-replay", recordFilePath: "unused")
    await service.verificationTaskForTesting()?.value
}

/// The replay land of `replayBase` under `policy`, fed by `service`, whose run has ended.
private func makeReplayLand(
    encoding: UntypedPayloadEncoding,
    service: ReevaluationRunnerService,
    policy: ReevaluationReplayEventPolicy = .projectedWithFallback
) async throws -> UntypedPayloadLand {
    var services = LandServices()
    services.register(service, as: ReevaluationRunnerService.self)
    services.register(ReevaluationReplayPolicyService(eventPolicy: policy), as: ReevaluationReplayPolicyService.self)
    let land = try await UntypedPayloadLand.make(
        GenericReplayLand<UntypedPayloadState>.makeLand(basedOn: replayBase), encoding: encoding, services: services)
    await runToEnd(service)
    await land.adapter.waitForOutboundIdleForTesting()
    return land
}

/// Whether `frames` carry `event`: its own frame on `json` and `opcode`, its body inside a
/// merged frame on `messagepack` (opcode 107).
private func carries(_ frames: ArraySlice<Data>, _ event: UntypedPayloadTypedEvent, encoding: UntypedPayloadEncoding) throws -> Bool {
    let encoder = encoding.config.makeMessageEncoder()
    let anyEvent = AnyServerEvent(event)
    if encoding == .messagepack, let mp = encoder as? MessagePackTransportMessageEncoder {
        let body = try pack(mp.encodeServerEventBody(anyEvent))
        return frames.contains { $0.range(of: body) != nil }
    }
    let frame = try encoder.encode(.event(event: .fromServer(event: anyEvent)))
    return frames.contains(frame)
}

/// How a later tick of the run fails.
enum ReplayRunFault: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// A recorded event whose name the land doesn't register.
    case unregistered
    /// A registered event whose payload doesn't decode into its type.
    case undecodable
    var testDescription: String { rawValue }

    func recorded() throws -> ReevaluationRecordedServerEvent {
        switch self {
        case .unregistered: return try recordedEvent("Recorded", ["hp": 3], sequence: 7, tickId: 1)
        case .undecodable: return try recordedEvent("UntypedPayloadTyped", ["hp": "three"], sequence: 7, tickId: 1)
        }
    }

    var expectedError: String {
        switch self {
        case .unregistered: return "replay tick 1: recorded server event 7 'Recorded' isn't registered"
        case .undecodable: return "replay tick 1: recorded server event 7 'UntypedPayloadTyped' doesn't decode"
        }
    }
}

@Suite("The replay land re-emits typed; a mismatch fails the run, not the land (#521 PR 1b, #538)", .serialized, .timeLimit(.minutes(1)))
struct ReplayTypedReEmitTests {
    @Test("The replay land registers its base land's server events (M5)")
    func registersTheBaseEvents() {
        let replay = GenericReplayLand<UntypedPayloadState>.makeLand(basedOn: replayBase)
        #expect(replay.serverEventRegistry.registered.map(\.eventName) == replayBase.serverEventRegistry.registered.map(\.eventName))
        #expect(replay.serverEventRegistry.registered.allSatisfy { $0.decodeServerEvent != nil })
    }

    @Test("A recorded event in the record's tree form is re-emitted typed, to its recorded target, and the land keeps running",
          arguments: UntypedPayloadEncoding.allCases)
    func reEmitsTyped(encoding: UntypedPayloadEncoding) async throws {
        let runner = ScriptedReplayRunner {
            try resolvedResult(recorded: [typed(3, sequence: 1), typed(4, sequence: 2, target: toAbsentPlayer)])
        }
        let service = makeService(runner: runner)
        let land = try await makeReplayLand(encoding: encoding, service: service)
        #expect(service.getStatus().phase == .completed, "\(encoding): \(service.getStatus().errorMessage)")
        let before = await land.transport.sends
        await land.tick()
        await land.adapter.waitForOutboundIdleForTesting()
        #expect(land.keeper.failure == nil, "\(encoding): \(String(describing: land.keeper.failure))")
        #expect(await land.keeper.currentState().round == 1, "\(encoding)")
        let sent = await land.transport.sent.dropFirst(before)
        #expect(try carries(sent, UntypedPayloadTypedEvent(hp: 3), encoding: encoding), "\(encoding): the event to all, typed")
        #expect(try !carries(sent, UntypedPayloadTypedEvent(hp: 4), encoding: encoding), "\(encoding): the event to an absent player reaches no one")
    }

    @Test("A later tick's record/code mismatch fails the run there: the earlier tick is shown, nothing after it, and the land keeps running (EV7)",
          arguments: UntypedPayloadEncoding.compressed, ReplayRunFault.allCases)
    func mismatchFailsTheRunAtItsTick(encoding: UntypedPayloadEncoding, fault: ReplayRunFault) async throws {
        for policy in [ReevaluationReplayEventPolicy.projectedWithFallback, .projectedOnly] {
            let runner = ScriptedReplayRunner([
                { try resolvedResult(tickId: 0, recorded: [typed(3)]) },
                { try resolvedResult(tickId: 1, recorded: [fault.recorded()], actualState: replaySnapshot(round: 2)) },
            ])
            let service = makeService(runner: runner)
            let land = try await makeReplayLand(encoding: encoding, service: service, policy: policy)
            let status = service.getStatus()
            #expect(status.phase == .failed, "\(encoding) \(policy)")
            #expect(status.errorMessage.hasPrefix(fault.expectedError), "\(encoding) \(policy): \(status.errorMessage)")
            // Tick 0 was queued before the failure and is shown.
            let beforeTick0 = await land.transport.sends
            await land.tick()
            await land.adapter.waitForOutboundIdleForTesting()
            #expect(await land.keeper.currentState().round == 1, "\(encoding) \(policy)")
            #expect(await land.transport.sends > beforeTick0, "\(encoding) \(policy): tick 0 is shown")
            // Tick 1 never queued: the next tick shows and sends nothing.
            let beforeTick1 = await land.transport.sends
            await land.tick()
            await land.adapter.waitForOutboundIdleForTesting()
            #expect(await land.keeper.currentState().round == 1, "\(encoding) \(policy): tick 1 isn't shown")
            #expect(await land.transport.sends == beforeTick1, "\(encoding) \(policy): nothing is sent after the failure")
            #expect(land.keeper.failure == nil, "\(encoding) \(policy): the replay land doesn't fail")
            #expect(service.consumeNextResult() == nil)
        }
    }

    @Test("A result without a frame is refused before it is queued: the run fails, 'result not resolved'")
    func unresolvedResultIsRefused() async throws {
        let runner = ScriptedReplayRunner {
            ReevaluationStepResult(tickId: 0, stateHash: "h", recordedHash: "h", isMatch: true, actualState: replaySnapshot())
        }
        let service = makeService(runner: runner)
        let land = try await makeReplayLand(encoding: .messagepack, service: service)
        #expect(service.getStatus().phase == .failed)
        #expect(service.getStatus().errorMessage == ReevaluationReplayResolutionError.unresolvedResult(tickId: 0).description)
        #expect(service.consumeNextResult() == nil)
        #expect(land.keeper.failure == nil)
    }

    @Test("A frame of another state type is refused before it is queued: the run fails, naming both types")
    func otherStateTypeIsRefused() async throws {
        let other = Land("other-replay", using: OtherReplayState.self) {
            Rules {}
            ServerEvents { Register(UntypedPayloadTypedEvent.self) }
        }
        let runner = ScriptedReplayRunner {
            let snapshot = AnyCodable(String(decoding: try JSONEncoder().encode(StateSnapshot(values: ["level": .int(2)])), as: UTF8.self))
            let frame = try ReevaluationReplayFrame.resolve(
                tickId: 0, recordedServerEvents: [], emittedServerEvents: [], actualState: snapshot, definition: other)
            return ReevaluationStepResult(tickId: 0, stateHash: "h", recordedHash: "h", isMatch: true, replayFrame: frame)
        }
        let service = makeService(runner: runner)
        _ = try await makeReplayLand(encoding: .messagepack, service: service)
        #expect(service.getStatus().phase == .failed)
        #expect(service.getStatus().errorMessage == ReevaluationReplayResolutionError.stateTypeMismatch(
            tickId: 0, runner: String(reflecting: OtherReplayState.self), replayLand: String(reflecting: UntypedPayloadState.self)
        ).description)
        #expect(service.consumeNextResult() == nil)
    }

    @Test("A frame without a state is refused before it is queued for a replay land: the run fails with the reason")
    func statelessFrameIsRefused() async throws {
        let runner = ScriptedReplayRunner { try resolvedResult(actualState: nil) }
        let service = makeService(runner: runner)
        _ = try await makeReplayLand(encoding: .messagepack, service: service)
        #expect(service.getStatus().phase == .failed)
        #expect(service.getStatus().errorMessage == ReevaluationReplayResolutionError.stateUnavailable(tickId: 0, reason: "no snapshot").description)
        #expect(service.consumeNextResult() == nil)
    }

    @Test("A land built with makeLand alone fails the run when it reads a result it can't show, instead of dropping it")
    func directMakeLandFailsTheRun() async throws {
        let runner = ScriptedReplayRunner([
            { ReevaluationStepResult(tickId: 0, stateHash: "h", recordedHash: "h", isMatch: true, actualState: replaySnapshot()) },
            { try resolvedResult(tickId: 1) },
        ])
        // No expectReplayLandState: the service queues both results, as for a monitor-only run.
        let service = makeService(runner: runner, expectState: false)
        let land = try await makeReplayLand(encoding: .opcode, service: service)
        #expect(service.getStatus().phase == .completed)
        let before = await land.transport.sends
        await land.tick()
        await land.adapter.waitForOutboundIdleForTesting()
        #expect(service.getStatus().phase == .failed)
        #expect(service.getStatus().errorMessage == ReevaluationReplayResolutionError.unresolvedResult(tickId: 0).description)
        #expect(service.consumeNextResult() == nil, "the failed run's later results are dropped")
        #expect(await land.transport.sends == before, "nothing is shown")
        #expect(await land.keeper.currentState().round == 0)
        #expect(land.keeper.failure == nil)
    }

    @Test("A result read from a run that a newer run replaced fails nothing: its ticket is stale")
    func staleTicketFailsNothing() async throws {
        let runner = ScriptedReplayRunner([
            { ReevaluationStepResult(tickId: 0, stateHash: "h", recordedHash: "h", isMatch: true, actualState: replaySnapshot()) },
        ])
        let service = makeService(runner: runner, expectState: false)
        await runToEnd(service)
        let (result, ticket) = try #require(service.consumeNextResultWithTicket())
        let refusal = try #require(ReevaluationReplayFrame.refusal(
            of: result, forStateType: ObjectIdentifier(UntypedPayloadState.self), named: "UntypedPayloadState"
        ))
        await runToEnd(service)     // a newer run, between the read and the refusal
        let before = service.getStatus()
        #expect(before.phase == .completed)
        #expect(!service.failRun(ticket: ticket, error: refusal), "the old run's ticket is stale")
        #expect(service.getStatus().phase == before.phase, "the newer run is untouched")
        #expect(service.getStatus().errorMessage == before.errorMessage)
    }

    @Test("A run that already failed keeps its first error when the land refuses one of its queued results")
    func firstFailureIsKept() async throws {
        struct RunnerFault: Error {}
        let runner = ScriptedReplayRunner([
            { ReevaluationStepResult(tickId: 0, stateHash: "h", recordedHash: "h", isMatch: true, actualState: replaySnapshot()) },
            { throw RunnerFault() },
        ])
        let service = makeService(runner: runner, expectState: false)
        let land = try await makeReplayLand(encoding: .opcode, service: service)
        #expect(service.getStatus().phase == .failed)
        let first = service.getStatus().errorMessage
        #expect(first == RunnerFault().localizedDescription)
        let ticket = service.generationForTesting()
        await land.tick()   // reads tick 0, which it can't show, and fails the run again
        await land.adapter.waitForOutboundIdleForTesting()
        #expect(service.generationForTesting() == ticket + 1, "the land's failRun took the current ticket")
        #expect(service.getStatus().phase == .failed)
        #expect(service.getStatus().errorMessage == first, "the runner's error stays")
        #expect(service.consumeNextResult() == nil)
    }

    @Test("Through processResult with a projector, a tick whose passes didn't match keeps its pass mismatch and frame, and shows only its replayed events (M2)")
    func projectorKeepsFieldsThroughProcessResult() async throws {
        let step: @Sendable () throws -> ReevaluationStepResult = {
            try resolvedResult(recorded: [typed(3)], projected: [typed(5, sequence: 2)], passMismatch: "passes differ")
        }
        let consumed = makeService(runner: ScriptedReplayRunner(step), projector: EmptyReplayProjector())
        await runToEnd(consumed)
        let result = try #require(consumed.consumeNextResult())
        #expect(result.recordedPassMismatch == "passes differ")
        #expect(result.replayFrame?.projectedEvents.count == 1)
        #expect(result.projectedFrame?.tickID == 0)

        let service = makeService(runner: ScriptedReplayRunner(step), projector: EmptyReplayProjector())
        let land = try await makeReplayLand(encoding: .opcode, service: service)
        let before = await land.transport.sends
        await land.tick()
        await land.adapter.waitForOutboundIdleForTesting()
        let sent = await land.transport.sent.dropFirst(before)
        #expect(try carries(sent, UntypedPayloadTypedEvent(hp: 5), encoding: .opcode), "the replayed event")
        #expect(try !carries(sent, UntypedPayloadTypedEvent(hp: 3), encoding: .opcode), "no fallback to the recorded event")
    }
}

@StateNodeBuilder
struct OtherReplayState: StateNodeProtocol, StateFromSnapshotDecodable {
    @Sync(.broadcast) var level: Int = 0
    init() {}
}
