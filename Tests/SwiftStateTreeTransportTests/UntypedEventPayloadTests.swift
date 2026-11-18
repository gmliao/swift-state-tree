// An untyped event payload (a dictionary, an array, a primitive) on a compressed message encoding
// (#544, #538). The positional encoders write only payload types; any other value used to reach a
// `fatalError` and end the process. It now throws `UntypedPayloadError`, so the event is lost and
// the land that emitted it ends with `.eventEncode` (#535 row 17), never the process.
//
// The exit tests are the regression on the process: a trap ends the child, so each fails on a
// build that still traps. The other tests give the details in process.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
@testable import SwiftStateTreeReevaluationMonitor

// MARK: - Fixtures

/// The compressed message encodings, and JSON as the control: JSON writes any value.
enum UntypedPayloadEncoding: String, CaseIterable, Sendable, CustomStringConvertible {
    case messagepack
    case opcode
    case json

    var description: String { rawValue }
    static let compressed: [UntypedPayloadEncoding] = [.messagepack, .opcode]

    var config: TransportEncodingConfig {
        switch self {
        case .messagepack: return .messagepack
        case .opcode: return .opcode
        case .json: return .json
        }
    }
}

/// The values that aren't payload types: a dictionary (what a record's JSON decodes to), an
/// array and a primitive.
enum UntypedPayloadKind: String, CaseIterable, Sendable, CustomStringConvertible {
    case dictionary
    case array
    case primitive

    var description: String { rawValue }

    var payload: AnyCodable {
        switch self {
        case .dictionary: return AnyCodable(["hp": 3] as [String: Int])
        case .array: return AnyCodable([1, 2] as [Int])
        case .primitive: return AnyCodable(7)
        }
    }
}

@Payload
struct UntypedPayloadTypedEvent: ServerEventPayload {
    let hp: Int
}

/// Encodes one server event with `encoding`'s message encoder, as the adapter does.
func encodeUntypedPayloadEvent(_ payload: AnyCodable, encoding: UntypedPayloadEncoding) throws -> Data {
    let encoder = encoding.config.makeMessageEncoder()
    let event = AnyServerEvent(type: "Untyped", payload: payload)
    return try encoder.encode(.event(event: .fromServer(event: event)))
}

@StateNodeBuilder
struct UntypedPayloadState: StateNodeProtocol, StateFromSnapshotDecodable {
    @Sync(.broadcast) var round: Int = 0
    init() {}
}

actor UntypedPayloadTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var closes: [UInt16] = []
    private(set) var sends = 0
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) { sends += 1 }
    func closeSession(_ sessionID: SessionID, with close: SessionClose, generation: UInt64?) async {
        closes.append(close.code)
    }
}

/// One land on its own keeper and adapter, with one joined session.
struct UntypedPayloadLand {
    let keeper: LandKeeper<UntypedPayloadState>
    let adapter: TransportAdapter<UntypedPayloadState>
    let transport: UntypedPayloadTransport

    static func make(
        _ definition: LandDefinition<UntypedPayloadState>,
        encoding: UntypedPayloadEncoding,
        services: LandServices = LandServices()
    ) async throws -> UntypedPayloadLand {
        let transport = UntypedPayloadTransport()
        let keeper = LandKeeper<UntypedPayloadState>(
            definition: definition, initialState: UntypedPayloadState(), services: services)
        let adapter = TransportAdapter<UntypedPayloadState>(
            keeper: keeper, transport: transport, landID: definition.id, encodingConfig: encoding.config)
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        let session = SessionID("s1"), client = ClientID("c1")
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: PlayerID("p1"))
        return UntypedPayloadLand(keeper: keeper, adapter: adapter, transport: transport)
    }

    /// One tick, and with legacy sync the next one too: legacy sync submits its failure, which
    /// the keeper applies in its next turn.
    func tick() async {
        await keeper.stepTickOnce()
        if !InTurnSync.isEnabled() { await keeper.stepTickOnce() }
    }
}

/// A land whose tick emits `payload` untyped (`emitAnyServerEvent`), when `untyped` is set, and
/// syncs.
func makeUntypedEmitLand(_ id: String, untyped: Bool) -> LandDefinition<UntypedPayloadState> {
    Land(id, using: UntypedPayloadState.self) {
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout UntypedPayloadState, ctx: LandContext) in
                state.round += 1
                if untyped {
                    ctx.emitAnyServerEvent(AnyServerEvent(type: "Untyped", payload: UntypedPayloadKind.dictionary.payload), to: .all)
                } else {
                    ctx.emitEvent(UntypedPayloadTypedEvent(hp: state.round), to: .all)
                }
                ctx.requestSyncNow()
            }
        }
        ServerEvents {
            Register(UntypedPayloadTypedEvent.self)
        }
    }
}

/// A record runner with one tick: no event replayed, one recorded with a dictionary payload, as a
/// record's JSON decodes it. The service queues a step's result before it asks for the next
/// step, so the second `step()` call (`queued`) says the result is in the queue.
final class UntypedRecordRunner: ReevaluationRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stepped = false
    let queued: AsyncStream<Void>
    private let queuedContinuation: AsyncStream<Void>.Continuation
    var maxTickId: Int64 { 0 }

    init() {
        (queued, queuedContinuation) = AsyncStream.makeStream()
    }

    func prepare() async throws {}
    func step() async throws -> ReevaluationStepResult? {
        let first = lock.withLock {
            defer { stepped = true }
            return !stepped
        }
        guard first else {
            queuedContinuation.yield()
            queuedContinuation.finish()
            return nil
        }
        let snapshot = StateSnapshot(values: ["round": .int(1)])
        let recorded = ReevaluationRecordedServerEvent(
            kind: "serverEvent", sequence: 1, tickId: 0, typeIdentifier: "Recorded",
            payload: try JSONDecoder().decode(AnyCodable.self, from: Data(#"{"hp":3}"#.utf8)),
            target: ReevaluationEventTargetRecord(kind: "all", ids: [])
        )
        return ReevaluationStepResult(
            tickId: 0, stateHash: "h", recordedHash: "h", isMatch: true,
            actualState: AnyCodable(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)),
            emittedServerEvents: [], recordedServerEvents: [recorded]
        )
    }
}

struct UntypedRecordFactory: ReevaluationTargetFactory {
    let runner = UntypedRecordRunner()
    func createRunner(landType: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        runner
    }
}

/// The replay land of `makeUntypedEmitLand`, with the fallback event policy and a run whose one
/// tick has its result queued.
func makeUntypedReplayLand(encoding: UntypedPayloadEncoding) async throws -> UntypedPayloadLand {
    let factory = UntypedRecordFactory()
    let runner = ReevaluationRunnerService(factory: factory, projectorResolver: { _ in nil })
    var services = LandServices()
    services.register(runner, as: ReevaluationRunnerService.self)
    services.register(ReevaluationReplayPolicyService(eventPolicy: .projectedWithFallback), as: ReevaluationReplayPolicyService.self)
    let base = makeUntypedEmitLand("untyped-replay", untyped: false)
    let land = try await UntypedPayloadLand.make(
        GenericReplayLand<UntypedPayloadState>.makeLand(basedOn: base), encoding: encoding, services: services)
    runner.startVerification(landType: "untyped-replay", recordFilePath: "unused")
    for await _ in factory.runner.queued { break }
    return land
}

// MARK: - Tests

@Suite("An untyped event payload on a compressed encoding ends the land, not the process (#544, #538)", .serialized, .timeLimit(.minutes(1)))
struct UntypedEventPayloadTests {
    // Exit codes of the children: 0 pass; 10 + n the n-th case encoded; 30 + n it threw another error;
    // 50 + n the land didn't end with .eventEncode.

    @Test("the process survives encoding an untyped payload on each compressed encoding (exit test)")
    func encodeDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            var n = 0
            for encoding in UntypedPayloadEncoding.compressed {
                for kind in UntypedPayloadKind.allCases {
                    n += 1
                    do {
                        _ = try encodeUntypedPayloadEvent(kind.payload, encoding: encoding)
                        exit(Int32(10 + n))
                    } catch is UntypedPayloadError {
                    } catch {
                        exit(Int32(30 + n))
                    }
                }
            }
            exit(0)
        }
    }

    @Test("the process survives a live land's untyped emit on each compressed encoding (exit test, #544)")
    func liveEmitDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            var n = 0
            for encoding in UntypedPayloadEncoding.compressed {
                n += 1
                guard let land = try? await UntypedPayloadLand.make(makeUntypedEmitLand("untyped-live", untyped: true), encoding: encoding)
                else { exit(Int32(30 + n)) }
                await land.tick()
                guard await land.keeper.waitForFailureForTesting(), land.keeper.failure?.kind == .eventEncode
                else { exit(Int32(50 + n)) }
            }
            exit(0)
        }
    }

    @Test("the process survives the replay land re-emitting a recorded dictionary on each compressed encoding (exit test, #538)")
    func replayReEmitDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            var n = 0
            for encoding in UntypedPayloadEncoding.compressed {
                n += 1
                guard let land = try? await makeUntypedReplayLand(encoding: encoding) else { exit(Int32(30 + n)) }
                await land.tick()
                guard await land.keeper.waitForFailureForTesting(), land.keeper.failure?.kind == .eventEncode
                else { exit(Int32(50 + n)) }
            }
            exit(0)
        }
    }

    @Test("a compressed encoder throws UntypedPayloadError naming the value's type; a typed payload encodes, and JSON writes any value",
          arguments: UntypedPayloadEncoding.allCases, UntypedPayloadKind.allCases)
    func encoderThrows(encoding: UntypedPayloadEncoding, kind: UntypedPayloadKind) throws {
        if encoding == .json {
            #expect(throws: Never.self, "\(encoding) \(kind)") { try encodeUntypedPayloadEvent(kind.payload, encoding: encoding) }
            return
        }
        let error = #expect(throws: UntypedPayloadError.self, "\(encoding) \(kind)") {
            try encodeUntypedPayloadEvent(kind.payload, encoding: encoding)
        }
        #expect(error?.typeName == String(describing: type(of: kind.payload.base)), "\(encoding) \(kind)")
        #expect(throws: Never.self, "\(encoding): a typed payload") {
            try encodeUntypedPayloadEvent(AnyCodable(UntypedPayloadTypedEvent(hp: 1)), encoding: encoding)
        }
    }

    @Test("a live land's untyped emit ends that land with .eventEncode and 4016; a second land in the process keeps syncing; on JSON nothing ends (#544)",
          arguments: UntypedPayloadEncoding.allCases)
    func liveEmitEndsTheLand(encoding: UntypedPayloadEncoding) async throws {
        let failing = try await UntypedPayloadLand.make(makeUntypedEmitLand("untyped-live", untyped: true), encoding: encoding)
        let healthy = try await UntypedPayloadLand.make(makeUntypedEmitLand("typed-live", untyped: false), encoding: encoding)
        await failing.tick()
        if encoding == .json {
            await failing.adapter.waitForOutboundIdleForTesting()
            #expect(failing.keeper.failure == nil, "JSON writes a dictionary payload")
            return
        }
        try #require(await failing.keeper.waitForFailureForTesting(), "\(encoding): the land failed")
        await failing.keeper.waitUntilDrained()
        #expect(failing.keeper.failure?.kind == .eventEncode, "\(encoding)")
        #expect(failing.keeper.failure?.detail.contains("Untyped") == true, "\(encoding): \(String(describing: failing.keeper.failure))")
        #expect(await failing.transport.closes == [SessionClose.Code.landFailed], "\(encoding)")

        let before = await healthy.transport.sends
        await healthy.tick()
        await healthy.adapter.waitForOutboundIdleForTesting()
        #expect(healthy.keeper.failure == nil, "\(encoding): the other land is unaffected")
        #expect(await healthy.transport.sends > before, "\(encoding): the other land still sends")
        #expect(await healthy.transport.closes.isEmpty, "\(encoding)")
    }

    @Test("the replay land's re-emit of a recorded dictionary under .projectedWithFallback ends the replay land with .eventEncode and 4016 (#538)",
          arguments: UntypedPayloadEncoding.compressed)
    func replayReEmitEndsTheReplayLand(encoding: UntypedPayloadEncoding) async throws {
        let land = try await makeUntypedReplayLand(encoding: encoding)
        await land.tick()
        try #require(await land.keeper.waitForFailureForTesting(), "\(encoding): the replay land failed")
        await land.keeper.waitUntilDrained()
        #expect(land.keeper.failure?.kind == .eventEncode, "\(encoding)")
        #expect(land.keeper.failure?.detail.contains("Recorded") == true, "\(encoding): \(String(describing: land.keeper.failure))")
        #expect(await land.transport.closes == [SessionClose.Code.landFailed], "\(encoding)")
    }
}
