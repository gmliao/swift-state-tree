// Tests/SwiftStateTreeTransportTests/ClientFrameFuzzTests.swift
//
// Decode or throw, never trap (#528). Every decoder a client's bytes reach is fed mutations of
// real client frames (`ClientFrameCorpus`), and must return or throw for each one. A trap, a
// crash or a stack overflow ends the test process; a hang fails the suite's time limit. The
// harness and its environment knobs are in `ClientFrameFuzzSupport.swift`.
//
// The targets call the server's own functions: the router's handshake and post-handshake
// decode (`LandRouter.decodeHandshakeFrame`, `decodePostHandshakeFrame`), the adapter's
// `MessageDecodingPipeline`, the sync-ack parser, the MessagePack unpacker and decoders, the
// payload decode the keeper and the client-event handlers run (`InboundPayloadDecoding`), and
// the join handler's checks on the fields a client builds.

import Foundation
import Logging
import Testing
@testable import SwiftStateTree
import SwiftStateTreeDeterministicMath
@testable import SwiftStateTreeMessagePack
@testable import SwiftStateTreeTransport

// MARK: - Fixture payload types (T5)

@Payload
struct FuzzLeavesAction: ActionPayload {
    typealias Response = PFResponse
    let bool: Bool
    let int: Int
    let int8: Int8
    let int16: Int16
    let int32: Int32
    let int64: Int64
    let uint: UInt
    let uint8: UInt8
    let uint16: UInt16
    let uint32: UInt32
    let uint64: UInt64
    let float: Float
    let double: Double
    let string: String
    let player: PlayerID
    let client: ClientID
    let session: SessionID
    let land: LandID
}

@Payload
struct FuzzMathAction: ActionPayload {
    typealias Response = PFResponse
    let angle: Angle
    let ivec2: IVec2
    let ivec3: IVec3
    let position: Position2
    let velocity: Velocity2
    let acceleration: Acceleration2
}

/// Optionals aren't allowed as payload fields; they appear inside a nested value.
struct FuzzOptionals: Codable, Sendable {
    let optional: Int?
    let optionalList: [String]?
}

indirect enum FuzzTree: Codable, Sendable {
    case leaf(Int)
    case node([FuzzTree])
}

@Payload
struct FuzzContainersEvent: ClientEventPayload {
    let ints: [Int]
    let byName: [String: Int]
    let byPlayer: [PlayerID: Int]
    let nested: PFNested
    let optionals: FuzzOptionals
    let any: AnyCodable
    let date: Date
    let data: Data
    let decimal: Decimal
    let uuid: UUID
    let kind: PFKind
    let tree: FuzzTree
}

/// The payload types T5 decodes each fuzzed action and client-event payload as.
enum FuzzPayloadTypes {
    static let actions: [any ActionPayload.Type] = [
        FuzzLeavesAction.self, FuzzMathAction.self, PFAction.self,
    ]
    static let clientEvents: [any ClientEventPayload.Type] = [
        FuzzContainersEvent.self, PFClientEvent.self, PFEmptyClientEvent.self,
    ]
}

// MARK: - Helpers

/// A log handler that discards everything at `.trace`, so the decoders' debug-only branches run
/// without writing output.
struct DiscardingLogHandler: LogHandler {
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(
        level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
        source: String, file: String, function: String, line: UInt
    ) {}
}

@StateNodeBuilder
struct FuzzState: StateNodeProtocol {
    @Sync(.broadcast) var value: Int = 0
}

typealias FuzzRouter = LandRouter<FuzzState>
typealias FuzzAdapter = TransportAdapter<FuzzState>

enum ClientFrameTargets {
    static let logger = Logger(label: "client-frame-fuzz", factory: { _ in DiscardingLogHandler() })
    static let sessionID = SessionID("fuzz-session")

    static func codec(_ encoding: FrameEncoding) -> any TransportCodec {
        switch encoding {
        case .json: TransportEncoding.json.makeCodec()
        case .opcodeJsonArray: TransportEncoding.opcodeJsonArray.makeCodec()
        case .messagepack: TransportEncoding.messagepack.makeCodec()
        }
    }

    static func pipeline(_ encoding: FrameEncoding, legacyJoin: Bool) -> MessageDecodingPipeline {
        MessageDecodingPipeline(
            codec: codec(encoding),
            opcodeDecoder: OpcodeTransportMessageDecoder(),
            enableLegacyJoin: legacyJoin
        )
    }

    /// T5 on a decoded message: an action's or a client event's payload decoded as every
    /// fixture type, the way the keeper and the client-event handlers decode it.
    static func decodePayloads(of message: TransportMessage) {
        let decoder = JSONDecoder()
        switch message.payload {
        case .action(let action):
            for type in FuzzPayloadTypes.actions {
                _ = try? InboundPayloadDecoding.decode(type, from: action.action.payload, decoder: decoder)
            }
            _ = try? InboundPayloadDecoding.decode(AnyCodable.self, from: action.action.payload, decoder: decoder)
        case .event(.fromClient(let event)):
            for type in FuzzPayloadTypes.clientEvents {
                _ = try? InboundPayloadDecoding.decode(type, from: event.payload, decoder: decoder)
            }
            _ = try? InboundPayloadDecoding.decode(AnyCodable.self, from: event.payload, decoder: decoder)
        default:
            break
        }
    }

    /// T6 on a decoded join: the router's checks on the fields a client builds, before any
    /// land is looked up.
    static func checkJoin(_ message: TransportMessage) {
        guard case .join(let join) = message.payload else { return }
        for authenticates in [false, true] {
            _ = FuzzAdapter.joinIdentityRejection(
                requestedPlayerID: join.playerID, authInfo: nil, authenticatesPlayers: authenticates
            )
        }
        _ = FuzzAdapter.joinIdentityRejection(
            requestedPlayerID: join.playerID,
            authInfo: AuthenticatedInfo(playerID: "token-player"),
            authenticatesPlayers: true
        )
        if let missing = FuzzAdapter.missingStateUpdateFeatures(
            required: StateUpdateFeature.supported, metadata: join.metadata
        ) {
            _ = FuzzAdapter.missingFeaturesMessage(missing)
        }
        if let instance = join.landInstanceId {
            _ = LandID(landType: join.landType, instanceId: instance).rawValue
        }
    }
}

// MARK: - Tests

@Suite("Client frame decoders: decode or throw (#528)", .timeLimit(.minutes(5)))
struct ClientFrameFuzzTests {
    static let encodings = FrameEncoding.allCases

    @Test("The corpus loads, and every frame decodes through its encoding's pipeline unmutated")
    func corpusDecodes() throws {
        #expect(ClientFrameCorpus.frames.count >= 60)
        for frame in ClientFrameCorpus.frames {
            let data = Data(frame.bytes)
            if frame.kind == "syncAck" {
                #expect(SyncAckFrame.parse(data) != nil, "\(frame.name) \(frame.encoding)")
                continue
            }
            do {
                let message = try ClientFrameTargets.pipeline(frame.encoding, legacyJoin: false).decode(data)
                #expect(message.kind.rawValue == (frame.kind == "clientEvent" ? "event" : frame.kind), "\(frame.name)")
            } catch {
                Issue.record("\(frame.name) \(frame.encoding): \(error)")
            }
        }
    }

    @Test("T1: the router's handshake decode (before join, JSON only)")
    func handshakeDecode() {
        let seeds = ClientFrameCorpus.frames.filter { $0.encoding != .messagepack }.map(\.bytes)
        let outcome = ClientFrameFuzzer.run(target: "T1-handshake", seeds: seeds) { data in
            if case .message(let message) = try FuzzRouter.decodeHandshakeFrame(
                data, sessionID: ClientFrameTargets.sessionID, logger: ClientFrameTargets.logger
            ) {
                ClientFrameTargets.checkJoin(message)
            }
        }
        #expect(outcome.decoded > 0 && outcome.threw > 0, "\(outcome)")
    }

    @Test("T2: the sync-ack parser", arguments: [FrameEncoding.opcodeJsonArray, .messagepack])
    func syncAckParse(encoding: FrameEncoding) {
        let seeds = ClientFrameCorpus.frames(encoding).map(\.bytes)
        ClientFrameFuzzer.run(target: "T2-sync-ack-\(encoding)", seeds: seeds) { data in
            _ = SyncAckFrame.parse(data)
        }
    }

    @Test("T3: the router's post-handshake decode", arguments: encodings)
    func postHandshakeDecode(encoding: FrameEncoding) {
        let codec = ClientFrameTargets.codec(encoding)
        let outcome = ClientFrameFuzzer.run(
            target: "T3-router-\(encoding)", seeds: ClientFrameCorpus.frames(encoding).map(\.bytes)
        ) { data in
            if case .message(let message) = try FuzzRouter.decodePostHandshakeFrame(
                data, codec: codec, sessionID: ClientFrameTargets.sessionID, logger: ClientFrameTargets.logger
            ) {
                ClientFrameTargets.decodePayloads(of: message)
            }
        }
        #expect(outcome.decoded > 0 && outcome.threw > 0, "\(outcome)")
    }

    @Test("T3: the adapter's decoding pipeline, legacy join off and on", arguments: encodings, [false, true])
    func adapterPipelineDecode(encoding: FrameEncoding, legacyJoin: Bool) {
        let pipeline = ClientFrameTargets.pipeline(encoding, legacyJoin: legacyJoin)
        let outcome = ClientFrameFuzzer.run(
            target: "T3-pipeline-\(encoding)-\(legacyJoin)", seeds: ClientFrameCorpus.frames(encoding).map(\.bytes)
        ) { data in
            let message = try pipeline.decode(data)
            ClientFrameTargets.decodePayloads(of: message)
            ClientFrameTargets.checkJoin(message)
        }
        #expect(outcome.decoded > 0 && outcome.threw > 0, "\(outcome)")
    }

    @Test("T4: the MessagePack unpacker and decoders")
    func messagePackDecoders() {
        let seeds = ClientFrameCorpus.frames(.messagepack).map(\.bytes)
        let serializer = MessagePackSerializer()
        let outcome = ClientFrameFuzzer.run(target: "T4-messagepack", seeds: seeds) { data in
            let value = try unpack(data)
            _ = try? MessagePackDirectDecoder().decodeTransportMessage(from: value)
            _ = try? serializer.decode(AnyCodable.self, from: data)
            _ = try serializer.decode(TransportMessage.self, from: data)
        }
        #expect(outcome.decoded > 0 && outcome.threw > 0, "\(outcome)")
    }

    @Test("T4: random bytes, not mutated from the corpus", arguments: encodings)
    func randomBytes(encoding: FrameEncoding) {
        let pipeline = ClientFrameTargets.pipeline(encoding, legacyJoin: false)
        var generator = FuzzGenerator.forTarget("T4-random-\(encoding)", seed: ClientFrameFuzzConfig.seed)
        for _ in 0..<ClientFrameFuzzConfig.iterations {
            let count = Int.random(in: 0...96, using: &generator)
            let data = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
            _ = try? pipeline.decode(data)
            _ = try? FuzzRouter.decodeHandshakeFrame(data, sessionID: ClientFrameTargets.sessionID, logger: ClientFrameTargets.logger)
            _ = SyncAckFrame.parse(data)
        }
    }
}
