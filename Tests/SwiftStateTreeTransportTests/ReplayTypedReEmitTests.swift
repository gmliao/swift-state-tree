// The replay land re-emits typed (#521 PR 1b, #538). Its tick reads the frame the runner
// resolved and emits each event with `emitEvent`, so a recorded event in the record's tree form
// goes out as its payload type on every encoding. A record/code mismatch fails the replay run,
// not the replay land; a result without a resolved frame of the land's state type is refused
// before it is queued.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
@testable import SwiftStateTreeReevaluationMonitor

/// A runner with one tick, whose result `makeResult` builds; it may throw, as a step does.
final class ScriptedReplayRunner: ReevaluationRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stepped = false
    private let makeResult: @Sendable () throws -> ReevaluationStepResult
    var maxTickId: Int64 { 0 }

    init(_ makeResult: @escaping @Sendable () throws -> ReevaluationStepResult) {
        self.makeResult = makeResult
    }

    func prepare() async throws {}
    func step() async throws -> ReevaluationStepResult? {
        let first = lock.withLock {
            defer { stepped = true }
            return !stepped
        }
        return first ? try makeResult() : nil
    }
}

struct ScriptedReplayFactory: ReevaluationTargetFactory {
    let runner: ScriptedReplayRunner
    func createRunner(landType: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        runner
    }
}

/// The base land of the replay: it registers `UntypedPayloadTypedEvent`.
private let replayBase = makeUntypedEmitLand("typed-replay", untyped: false)

private func replaySnapshot() -> AnyCodable {
    let snapshot = StateSnapshot(values: ["round": .int(1)])
    return AnyCodable(String(decoding: try! JSONEncoder().encode(snapshot), as: UTF8.self))
}

/// A recorded event as a saved record's tree holds it.
private func recordedEvent(_ name: String, _ payload: some Encodable) throws -> ReevaluationRecordedServerEvent {
    ReevaluationRecordedServerEvent(
        kind: "serverEvent", sequence: 1, tickId: 0, typeIdentifier: name,
        payload: try CanonicalMessagePack.decode(AnyCodable.self, from: CanonicalMessagePack.encode(payload)),
        target: ReevaluationEventTargetRecord(kind: "all", ids: [])
    )
}

/// One tick's result, resolved against the replay's base land as the stock runner does.
private func resolvedResult(recorded: [ReevaluationRecordedServerEvent]) throws -> ReevaluationStepResult {
    let frame = try ReevaluationReplayFrame.resolve(
        tickId: 0, recordedServerEvents: recorded, emittedServerEvents: [], actualState: replaySnapshot(), definition: replayBase
    )
    return ReevaluationStepResult(
        tickId: 0, stateHash: "h", recordedHash: "h", isMatch: true, actualState: replaySnapshot(),
        recordedServerEvents: recorded, replayFrame: frame
    )
}

/// The replay land of `replayBase` with the fallback policy, fed by `runner`, whose run has
/// ended (its result queued, or the run failed).
private func makeReplayLand(
    encoding: UntypedPayloadEncoding,
    runner: ScriptedReplayRunner
) async throws -> (land: UntypedPayloadLand, service: ReevaluationRunnerService) {
    let service = ReevaluationRunnerService(factory: ScriptedReplayFactory(runner: runner), projectorResolver: { _ in nil })
    service.expectReplayLandState(UntypedPayloadState.self)
    var services = LandServices()
    services.register(service, as: ReevaluationRunnerService.self)
    services.register(ReevaluationReplayPolicyService(eventPolicy: .projectedWithFallback), as: ReevaluationReplayPolicyService.self)
    let land = try await UntypedPayloadLand.make(
        GenericReplayLand<UntypedPayloadState>.makeLand(basedOn: replayBase), encoding: encoding, services: services)
    service.startVerification(landType: "typed-replay", recordFilePath: "unused")
    await service.verificationTaskForTesting()?.value
    return (land, service)
}

@Suite("The replay land re-emits typed; a mismatch fails the run, not the land (#521 PR 1b, #538)", .serialized, .timeLimit(.minutes(1)))
struct ReplayTypedReEmitTests {
    @Test("The replay land registers its base land's server events (M5)")
    func registersTheBaseEvents() {
        let replay = GenericReplayLand<UntypedPayloadState>.makeLand(basedOn: replayBase)
        #expect(replay.serverEventRegistry.registered.map(\.eventName) == replayBase.serverEventRegistry.registered.map(\.eventName))
        #expect(replay.serverEventRegistry.registered.allSatisfy { $0.decodeServerEvent != nil })
    }

    @Test("A recorded event in the record's tree form is re-emitted typed under .projectedWithFallback, and the land keeps running",
          arguments: UntypedPayloadEncoding.allCases)
    func reEmitsTyped(encoding: UntypedPayloadEncoding) async throws {
        let runner = ScriptedReplayRunner {
            try resolvedResult(recorded: [recordedEvent("UntypedPayloadTyped", UntypedPayloadTypedEvent(hp: 3))])
        }
        let (land, service) = try await makeReplayLand(encoding: encoding, runner: runner)
        #expect(service.getStatus().phase == .completed, "\(encoding): \(service.getStatus().errorMessage)")
        await land.adapter.waitForOutboundIdleForTesting()
        let before = await land.transport.sends
        await land.tick()
        await land.adapter.waitForOutboundIdleForTesting()
        #expect(land.keeper.failure == nil, "\(encoding): \(String(describing: land.keeper.failure))")
        #expect(await land.transport.sends > before, "\(encoding): the tick sent its state and event")
        #expect(await land.keeper.currentState().round == 1, "\(encoding)")
        let typed = try encoding.config.makeMessageEncoder().encode(
            .event(event: .fromServer(event: AnyServerEvent(UntypedPayloadTypedEvent(hp: 3)))))
        if encoding != .messagepack {
            // Not merged into a state frame: the event's own frame, byte for byte.
            #expect(await land.transport.sent.dropFirst(before).contains(typed), "\(encoding): the typed frame was sent")
        }
    }

    @Test("A recorded event the land doesn't register fails the run with its tick and name; the replay land shows nothing and keeps running (EV7)",
          arguments: UntypedPayloadEncoding.compressed)
    func unregisteredEventFailsTheRun(encoding: UntypedPayloadEncoding) async throws {
        let runner = ScriptedReplayRunner { try resolvedResult(recorded: [recordedEvent("Recorded", ["hp": 3])]) }
        let (land, service) = try await makeReplayLand(encoding: encoding, runner: runner)
        #expect(service.getStatus().phase == .failed)
        #expect(service.getStatus().errorMessage.contains("'Recorded' isn't registered"), "\(service.getStatus().errorMessage)")
        await land.tick()
        await land.adapter.waitForOutboundIdleForTesting()
        #expect(land.keeper.failure == nil, "\(encoding): the replay land doesn't fail")
        #expect(await land.keeper.currentState().round == 0, "\(encoding): nothing was queued")
    }

    @Test("A result without a frame is refused before it is queued: the run fails, 'result not resolved'")
    func unresolvedResultIsRefused() async throws {
        let runner = ScriptedReplayRunner {
            ReevaluationStepResult(tickId: 0, stateHash: "h", recordedHash: "h", isMatch: true, actualState: replaySnapshot())
        }
        let (land, service) = try await makeReplayLand(encoding: .messagepack, runner: runner)
        #expect(service.getStatus().phase == .failed)
        #expect(service.getStatus().errorMessage.contains("result not resolved"), "\(service.getStatus().errorMessage)")
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
        let (_, service) = try await makeReplayLand(encoding: .messagepack, runner: runner)
        #expect(service.getStatus().phase == .failed)
        let message = service.getStatus().errorMessage
        #expect(message.contains("OtherReplayState") && message.contains("UntypedPayloadState"), "\(message)")
    }
}

@StateNodeBuilder
struct OtherReplayState: StateNodeProtocol, StateFromSnapshotDecodable {
    @Sync(.broadcast) var level: Int = 0
    init() {}
}
