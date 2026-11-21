// An untyped payload (a dictionary, an array, a primitive) on a compressed message encoding
// (#544). The positional encoders write only payload types; any other value used to reach a
// `fatalError` and end the process. It now throws `UntypedPayloadError`: an event that throws it is
// lost and the land that emitted it ends with `.eventEncode` (#535 row 17); an action response
// that throws it ends its land with `.responseEncode`. Never the process. The replay land
// re-emits typed since #521 PR 1b (#538); its tests are `ReplayTypedReEmitTests`.
//
// The exit tests are the regression on the process: a trap ends the child, so each fails on a
// build that still traps. The other tests give the details in process.

import Foundation
import Testing
import SwiftStateTreeTestSupport
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

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
    private(set) var sent: [Data] = []
    var sends: Int { sent.count }
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) { sent.append(message) }
    func closeSession(_ sessionID: SessionID, with close: SessionClose, generation: UInt64?) async {
        closes.append(close.code)
    }
}

/// One land on its own keeper and adapter, with one joined session.
struct UntypedPayloadLand {
    let keeper: LandKeeper<UntypedPayloadState>
    let adapter: TransportAdapter<UntypedPayloadState>
    let transport: UntypedPayloadTransport
    let encoding: UntypedPayloadEncoding
    static let session = SessionID("s1")
    static let player = PlayerID("p1")

    static func make(
        _ definition: LandDefinition<UntypedPayloadState>,
        encoding: UntypedPayloadEncoding,
        services: LandServices = LandServices(),
        waitsByEvent: Bool = false
    ) async throws -> UntypedPayloadLand {
        let transport = UntypedPayloadTransport()
        let keeper = LandKeeper<UntypedPayloadState>(
            definition: definition, initialState: UntypedPayloadState(), services: services)
        let adapter = TransportAdapter<UntypedPayloadState>(
            keeper: keeper, transport: transport, landID: definition.id, encodingConfig: encoding.config)
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        let client = ClientID("c1")
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(
            adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: player, waitsByEvent: waitsByEvent)
        return UntypedPayloadLand(keeper: keeper, adapter: adapter, transport: transport, encoding: encoding)
    }

    /// Sends one `UntypedResponseAction` from the session, as a client frame; returns once the
    /// adapter has handled it (answered it or ended the land).
    func sendAction(requestID: String) async throws {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: UntypedResponseAction.self),
            payload: AnyCodable(UntypedResponseAction(tag: requestID))
        )
        let frame = try encoding.config.makeCodec().encode(TransportMessage.action(requestID: requestID, action: envelope))
        await adapter.onMessage(frame, from: Self.session)
    }

    /// One tick, and with legacy sync the next one too: legacy sync submits its failure, which
    /// the keeper applies in its next turn.
    func tick() async {
        await keeper.stepTickOnce()
    }
}

/// A land whose tick emits a dictionary payload untyped (the package test hook; land code has no
/// untyped emit since #521 PR 1b) to `target`, when
/// `untyped` is set (a typed event otherwise), and syncs.
func makeUntypedEmitLand(_ id: String, untyped: Bool, target: SwiftStateTree.EventTarget = .all) -> LandDefinition<UntypedPayloadState> {
    Land(id, using: UntypedPayloadState.self) {
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout UntypedPayloadState, ctx: LandContext) in
                state.round += 1
                if untyped {
                    ctx.emitAnyServerEventForTesting(AnyServerEvent(type: "Untyped", payload: UntypedPayloadKind.dictionary.payload), to: target)
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

@Payload
struct UntypedResponseAction: ActionPayload {
    typealias Response = UntypedResponseReply
    let tag: String
}

@Payload
struct UntypedResponseReply: ResponsePayload {
    let count: Int
}

/// A tickless land whose action handler answers with a dictionary, not its declared response type.
/// Every public way to declare a handler returns the action's `Response` (#561, #586), so only the
/// package-level type-erased init can build one.
func makeUntypedResponseLand() -> LandDefinition<UntypedPayloadState> {
    let untyped = AnyActionHandler<UntypedPayloadState>(
        type: UntypedResponseAction.self,
        responseType: UntypedResponseReply.self,
        invoke: { state, _, _ in
            state.round += 1
            return AnyCodable(["hp": 3] as [String: Int])
        },
        resolverExecutors: []
    )
    return Land("untyped-response", using: UntypedPayloadState.self) {
        ServerEvents { Register(UntypedPayloadTypedEvent.self) }
        Rules { untyped }
    }
}

/// Runs `fail`, which makes an action's answer fail to encode, with the failure held between
/// the adapter and the keeper (`.answerFailureSubmit`). In that window the land hasn't failed
/// yet, but the adapter has closed its output gate in the failing segment, so an event sent then
/// doesn't go out. Then the keeper applies the failure.
func expectGateClosedBeforeTheFailureTurn(
    _ land: UntypedPayloadLand,
    _ label: String,
    fail: @escaping @Sendable () async throws -> Void
) async throws {
    let submit = TestGate()
    await land.adapter.installHolds(HoldRegistry.at(.answerFailureSubmit) { await submit.arrive() })
    let sentBefore = await land.transport.sends
    let failing = Task { try await fail() }
    #expect(await submit.waitForArrivals(1), "\(label): the failure is held before the keeper")
    #expect(land.keeper.failure == nil, "\(label): the keeper hasn't applied the failure yet")
    #expect(land.adapter.outputGate.isClosed, "\(label): the gate closed in the failing segment")
    await land.adapter.sendEventToTransport(AnyServerEvent(UntypedPayloadTypedEvent(hp: 1)), to: .all)
    await land.adapter.waitForOutboundIdleForTesting()
    // On messagepack, events merge: the event only queues a body, which this window doesn't
    // flush, so a send count can't show it there. The isClosed check above pins the close on
    // every encoding.
    if land.encoding != .messagepack {
        #expect(await land.transport.sends == sentBefore, "\(label): an event sent in that window doesn't go out")
    }
    submit.open()
    try await failing.value
    await land.adapter.installHolds(nil)
    try #require(await land.keeper.waitForFailureForTesting(), "\(label): the land failed")
    await land.keeper.waitUntilDrained()
    #expect(land.keeper.failure?.kind == .responseEncode, "\(label)")
}

// MARK: - Tests

@Suite("An untyped event payload on a compressed encoding ends the land, not the process (#544)", .serialized, .timeLimit(.minutes(1)))
struct UntypedEventPayloadTests {
    // Exit codes of the children: 0 pass; 10 + n the n-th case encoded; 30 + n it threw another error;
    // 50 + n the land didn't end with .eventEncode (.responseEncode for the response test).

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

    @Test("the process survives an action response that isn't a payload type on each compressed encoding (exit test)")
    func untypedResponseDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            var n = 0
            for encoding in UntypedPayloadEncoding.compressed {
                n += 1
                guard let land = try? await UntypedPayloadLand.make(makeUntypedResponseLand(), encoding: encoding),
                      (try? await land.sendAction(requestID: "r1")) != nil
                else { exit(Int32(30 + n)) }
                guard await land.keeper.waitForFailureForTesting(), land.keeper.failure?.kind == .responseEncode
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

    @Test("a live land's untyped emit, to everyone or to one player, ends that land with .eventEncode and 4016, sending nothing in the failing tick; a second land in the process keeps syncing; on JSON nothing ends (#544)",
          arguments: UntypedPayloadEncoding.allCases, [false, true])
    func liveEmitEndsTheLand(encoding: UntypedPayloadEncoding, targeted: Bool) async throws {
        let target: SwiftStateTree.EventTarget = targeted ? .player(UntypedPayloadLand.player) : .all
        let failing = try await UntypedPayloadLand.make(makeUntypedEmitLand("untyped-live", untyped: true, target: target), encoding: encoding)
        let healthy = try await UntypedPayloadLand.make(makeUntypedEmitLand("typed-live", untyped: false), encoding: encoding)
        await failing.adapter.waitForOutboundIdleForTesting()
        let sentBefore = await failing.transport.sends
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
        await failing.adapter.waitForOutboundIdleForTesting()
        #expect(await failing.transport.sends == sentBefore, "\(encoding) targeted \(targeted): the failing tick sends nothing")

        let before = await healthy.transport.sends
        await healthy.tick()
        await healthy.adapter.waitForOutboundIdleForTesting()
        #expect(healthy.keeper.failure == nil, "\(encoding): the other land is unaffected")
        #expect(await healthy.transport.sends > before, "\(encoding): the other land still sends")
        #expect(await healthy.transport.closes.isEmpty, "\(encoding)")
    }

    @Test("an action response that isn't a payload type ends the land with .responseEncode and 4016, and its client gets no answer; on JSON it is sent",
          arguments: UntypedPayloadEncoding.allCases)
    func untypedResponseEndsTheLand(encoding: UntypedPayloadEncoding) async throws {
        let land = try await UntypedPayloadLand.make(makeUntypedResponseLand(), encoding: encoding)
        await land.adapter.waitForOutboundIdleForTesting()
        let sentBefore = await land.transport.sends
        try await land.sendAction(requestID: "r1")
        await land.adapter.waitForOutboundIdleForTesting()
        if encoding == .json {
            #expect(land.keeper.failure == nil, "JSON writes a dictionary response")
            let answers = await land.transport.sent.dropFirst(sentBefore).filter { String(decoding: $0, as: UTF8.self).contains("r1") }
            #expect(answers.count == 1, "the response reached the client")
            return
        }
        try #require(await land.keeper.waitForFailureForTesting(), "\(encoding): the land failed")
        await land.keeper.waitUntilDrained()
        #expect(land.keeper.failure?.kind == .responseEncode, "\(encoding)")
        #expect(land.keeper.failure?.position.stage == .actionResponse, "\(encoding)")
        #expect(land.keeper.failure?.detail.contains("UntypedResponseAction") == true, "\(encoding): \(String(describing: land.keeper.failure))")
        #expect(land.keeper.failure?.detail.contains("UntypedPayloadError") == true || land.keeper.failure?.detail.contains("isn't a payload type") == true,
                "\(encoding): \(String(describing: land.keeper.failure))")
        #expect(land.adapter.outputGate.isClosed, "\(encoding)")
        #expect(await land.transport.sends == sentBefore, "\(encoding): no answer and no frame after the failure")
        #expect(await land.transport.closes == [SessionClose.Code.landFailed], "\(encoding)")
    }

    @Test("an action response that doesn't encode closes the output gate before the keeper's failure turn",
          arguments: UntypedPayloadEncoding.compressed)
    func untypedResponseClosesTheGateFirst(encoding: UntypedPayloadEncoding) async throws {
        let land = try await UntypedPayloadLand.make(makeUntypedResponseLand(), encoding: encoding)
        await land.adapter.waitForOutboundIdleForTesting()
        try await expectGateClosedBeforeTheFailureTurn(land, "\(encoding)") {
            try await land.sendAction(requestID: "r1")
        }
    }
}
