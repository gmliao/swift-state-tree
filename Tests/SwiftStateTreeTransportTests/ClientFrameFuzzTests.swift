// Tests/SwiftStateTreeTransportTests/ClientFrameFuzzTests.swift
//
// Decode or throw, never trap (#528). Every decoder a client's bytes reach is fed mutations of
// real client frames (`ClientFrameCorpus`), and must return or throw for each one. A trap, a
// crash or a stack overflow ends the test process. A hang doesn't fail the suite's time limit:
// the decoders run synchronously and never check for cancellation, so a hang keeps the process
// running. Run a long run under an outer process timeout, e.g.
// `SST_FUZZ_ITERATIONS=1000000 timeout 3000 swift test --filter ClientFrameFuzzTests`; the
// last `[client-frame-fuzz]` line printed names the targets that finished. Every target prints
// its seed and outcome counts. Each target also requires that its entry points both decode and
// refuse some of their inputs, so a target that never reaches its decoder fails. The harness and
// its environment knobs are in `ClientFrameFuzzSupport.swift`.
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
@testable import SwiftStateTreeDeterministicMath
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

/// A valid value of each fixture type, encoded by the server's encoders as a client would send
/// it. Byte mutation can't invent a type's field names: without these seeds every decode into a
/// fixture type would stop at its first missing key.
enum T5Seeds {
    static let leaves = FuzzLeavesAction(
        bool: true, int: -42, int8: -8, int16: 1600, int32: -320_000, int64: 1 << 40,
        uint: 7, uint8: 200, uint16: 60_000, uint32: 4_000_000_000, uint64: 1 << 40,
        float: 1.5, double: -2.25, string: "h\u{E9}llo",
        player: PlayerID("p1"), client: ClientID("c1"), session: SessionID("s1"),
        land: LandID(landType: "t", instanceId: "i")
    )
    static let math = FuzzMathAction(
        angle: Angle(degrees: Float(90)),
        ivec2: IVec2(fixedPointX: 1500, fixedPointY: -2250),
        ivec3: IVec3(x: 1.5, y: -2, z: 3),
        position: Position2(v: IVec2(fixedPointX: 10, fixedPointY: 20)),
        velocity: Velocity2(v: IVec2(fixedPointX: -3, fixedPointY: 4)),
        acceleration: Acceleration2(v: IVec2(fixedPointX: 0, fixedPointY: -1))
    )
    static let containers = FuzzContainersEvent(
        ints: [1, -2, 3], byName: ["a": 1, "b": 2], byPlayer: [PlayerID("p1"): 5],
        nested: PFNested(a: 4, b: "x"), optionals: FuzzOptionals(optional: nil, optionalList: ["y"]),
        any: AnyCodable(["k": AnyCodable([AnyCodable(1), AnyCodable("v")])]),
        date: Date(timeIntervalSinceReferenceDate: 12), data: Data([1, 2, 3]),
        uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000528")!, kind: .second,
        tree: .node([.leaf(1), .node([.leaf(2)])])
    )

    static let pfClientEvent = PFClientEvent(
        player: PlayerID("p1"), to: Position2(v: IVec2(fixedPointX: 1500, fixedPointY: -2250)), step: 3
    )

    static var messages: [(name: String, kind: String, message: TransportMessage)] {
        // The payload as a client sends it: the value's JSON form, not the Swift value.
        func clientShaped<T: Encodable>(_ value: T) -> AnyCodable {
            (try? JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(value))) ?? AnyCodable(value)
        }
        func action<A: ActionPayload>(_ value: A) -> TransportMessage {
            .action(requestID: "t5", action: ActionEnvelope(typeIdentifier: String(describing: A.self), payload: clientShaped(value)))
        }
        func event<E: ClientEventPayload>(_ value: E) -> TransportMessage {
            .event(event: .fromClient(event: AnyClientEvent(type: String(describing: E.self), payload: clientShaped(value))))
        }
        return [
            ("t5/leaves", "action", action(leaves)),
            ("t5/math", "action", action(math)),
            ("t5/containers", "clientEvent", event(containers)),
            ("t5/pf-client-event", "clientEvent", event(pfClientEvent)),
        ]
    }

    /// Each message in all three encodings, written by the server's encoders with no event
    /// hashes (the event type as a string, as a client sends it) and plain payloads.
    static let frames: [CorpusFrame] = {
        let encoders: [(FrameEncoding, any TransportMessageEncoder)] = [
            (.json, JSONTransportMessageEncoder()),
            (.opcodeJsonArray, OpcodeTransportMessageEncoder(eventHashes: [:], clientEventHashes: [:], enablePayloadCompression: false)),
            (.messagepack, MessagePackTransportMessageEncoder(eventHashes: [:], clientEventHashes: [:], enablePayloadCompression: false)),
        ]
        return messages.flatMap { entry in
            encoders.compactMap { encoding, encoder -> CorpusFrame? in
                guard let data = try? encoder.encode(entry.message) else {
                    Issue.record("\(entry.name) doesn't encode as \(encoding)")
                    return nil
                }
                return CorpusFrame(name: entry.name, kind: entry.kind, encoding: encoding, bytes: Array(data))
            }
        }
    }()
}

/// How often each fixture type's decode succeeded and threw in one target (T5).
/// How one payload decode as a fixture type ended.
enum PayloadDecodeResult {
    case decoded
    /// A field the type needs is missing: the payload is another type's, or a key was mutated.
    case keyNotFound
    /// A field's value was refused (`typeMismatch`, `dataCorrupted`): a fuzzed value reached the
    /// field's decoder.
    case fieldRefused
    case otherError

    init(_ decode: () throws -> Void) {
        do {
            try decode()
            self = .decoded
        } catch DecodingError.keyNotFound {
            self = .keyNotFound
        } catch DecodingError.typeMismatch, DecodingError.dataCorrupted {
            self = .fieldRefused
        } catch {
            self = .otherError
        }
    }
}

struct PayloadCounts: CustomStringConvertible {
    var decoded = 0
    var keyNotFound = 0
    var fieldRefused = 0
    var otherError = 0

    var refused: Int { keyNotFound + fieldRefused + otherError }

    mutating func add(_ result: PayloadDecodeResult) {
        switch result {
        case .decoded: decoded += 1
        case .keyNotFound: keyNotFound += 1
        case .fieldRefused: fieldRefused += 1
        case .otherError: otherError += 1
        }
    }

    var description: String { "\(decoded)/\(keyNotFound)/\(fieldRefused)/\(otherError)" }
}

/// Payload decodes per fixture type, the seeds (replayed unmutated) and the mutations apart:
/// a seed shows that a type's decoder is reached, only a mutation that it is fuzzed.
struct PayloadOutcomes {
    var seeds: [String: PayloadCounts] = [:]
    var mutations: [String: PayloadCounts] = [:]
    /// Whether the input being decoded is a mutation; set by the target before each one.
    var mutated = false

    mutating func record(_ type: Any.Type, _ result: PayloadDecodeResult) {
        let name = String(describing: type)
        if mutated {
            mutations[name, default: PayloadCounts()].add(result)
        } else {
            seeds[name, default: PayloadCounts()].add(result)
        }
    }

    func all(_ name: String) -> PayloadCounts {
        let seed = seeds[name] ?? PayloadCounts()
        let mutation = mutations[name] ?? PayloadCounts()
        return PayloadCounts(
            decoded: seed.decoded + mutation.decoded, keyNotFound: seed.keyNotFound + mutation.keyNotFound,
            fieldRefused: seed.fieldRefused + mutation.fieldRefused, otherError: seed.otherError + mutation.otherError
        )
    }

    func printSummary(_ target: String) {
        func line(_ counts: [String: PayloadCounts]) -> String {
            counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
        print("[client-frame-fuzz] \(target) payloads decoded/keyNotFound/fieldRefused/other: seeds \(line(seeds)); mutations \(line(mutations))")
    }

    /// Every fixture type with fields was reached: seeds and mutations together, it decoded a
    /// payload and refused one. This doesn't show that a mutation reached a field
    /// (`expectFuzzedFields` does).
    func expectReached(_ target: String, sourceLocation: SourceLocation = #_sourceLocation) {
        printSummary(target)
        let types: [Any.Type] = FuzzPayloadTypes.actions + FuzzPayloadTypes.clientEvents
        // A field-less type decodes from any object: it has no refusal to see.
        for type in types where type != PFEmptyClientEvent.self {
            let name = String(describing: type)
            let counts = all(name)
            #expect(counts.decoded > 0 && counts.refused > 0, "\(target) \(name): \(counts)", sourceLocation: sourceLocation)
        }
    }

    /// Among the mutations alone, each of `types` decoded a payload and refused a field's value
    /// (`typeMismatch` or `dataCorrupted`, not a missing key): a fuzzed value reached a field
    /// decoder.
    func expectFuzzedFields(_ target: String, types: [Any.Type], sourceLocation: SourceLocation = #_sourceLocation) {
        printSummary(target)
        for type in types {
            let name = String(describing: type)
            let counts = mutations[name] ?? PayloadCounts()
            #expect(counts.decoded > 0 && counts.fieldRefused > 0, "\(target) \(name) mutations: \(counts)", sourceLocation: sourceLocation)
        }
    }
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
    /// fixture type from the decode source its frame's decoder built, the way the keeper decodes
    /// it at intake (#521): the whole-tree check, the typed decode, and the record's tree. A
    /// MessagePack frame's source decodes straight from its value; a JSON one with the round trip
    /// (`InboundPayloadDecoding`). Each type's outcome goes into `outcomes`. Returns whether the
    /// payload decoded as `AnyCodable`, or nil for a message without an action or client-event
    /// payload.
    @discardableResult
    static func decodePayloads(of message: TransportMessage, outcomes: inout PayloadOutcomes) -> Bool? {
        func attempt<T: Decodable>(_ type: T.Type, _ source: any PayloadDecodingSource) {
            outcomes.record(type, PayloadDecodeResult {
                try source.validateRecordable()
                _ = try source.decode(type)
                _ = try source.makeRecordPayload()
            })
        }
        let source: any PayloadDecodingSource
        switch message.payload {
        case .action(let action):
            source = action.action.source
            for type in FuzzPayloadTypes.actions { attempt(type, source) }
        case .event(.fromClient(let event)):
            source = event.source
            for type in FuzzPayloadTypes.clientEvents { attempt(type, source) }
        default:
            return nil
        }
        return (try? source.validateRecordable()).flatMap { (try? source.decode(AnyCodable.self)) } != nil
    }

    @discardableResult
    static func decodePayloads(of message: TransportMessage) -> Bool? {
        var outcomes = PayloadOutcomes()
        return decodePayloads(of: message, outcomes: &outcomes)
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
        if let missing = StateUpdateFeatureNegotiation.missingStateUpdateFeatures(
            required: StateUpdateFeature.supported, metadata: join.metadata
        ) {
            _ = StateUpdateFeatureNegotiation.missingFeaturesMessage(missing)
        }
        if let instance = join.landInstanceId {
            _ = LandID(landType: join.landType, instanceId: instance).rawValue
        }
    }
}

// MARK: - Tests

@Suite("Client frame decoders: decode or throw (#528)", .serialized, .timeLimit(.minutes(5)))
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

    @Test("The T5 seeds decode as their own fixture type in every encoding, unmutated", arguments: encodings)
    func t5SeedsDecode(encoding: FrameEncoding) throws {
        let expected = [
            "t5/leaves": "FuzzLeavesAction", "t5/math": "FuzzMathAction",
            "t5/containers": "FuzzContainersEvent", "t5/pf-client-event": "PFClientEvent",
        ]
        let seeds = T5Seeds.frames.filter { $0.encoding == encoding }
        #expect(seeds.count == expected.count)
        for frame in seeds {
            let message = try ClientFrameTargets.pipeline(encoding, legacyJoin: false).decode(Data(frame.bytes))
            var outcomes = PayloadOutcomes()
            ClientFrameTargets.decodePayloads(of: message, outcomes: &outcomes)
            let name = try #require(expected[frame.name])
            if outcomes.seeds[name]?.decoded != 1 {
                // Say why: the payload's own decode error.
                let source: (any PayloadDecodingSource)? = switch message.payload {
                case .action(let action): action.action.source
                case .event(.fromClient(let event)): event.source
                default: nil
                }
                let types: [any Decodable.Type] = [FuzzLeavesAction.self, FuzzMathAction.self, FuzzContainersEvent.self, PFClientEvent.self]
                let type = try #require(types.first { String(describing: $0) == name })
                do {
                    let source = try #require(source)
                    try source.validateRecordable()
                    _ = try source.decode(type)
                    Issue.record("\(frame.name) \(encoding): decodes alone but not in decodePayloads")
                } catch {
                    Issue.record("\(frame.name) \(encoding) as \(name): \(error)")
                }
            }
        }
    }

    @Test("T1: the router's handshake decode (before join, JSON only)")
    func handshakeDecode() async {
        let seeds = ClientFrameCorpus.frames.filter { $0.encoding != .messagepack }.map(\.bytes)
        var messages = 0
        let outcome = await ClientFrameFuzzer.run(target: "T1-handshake", seeds: seeds) { data in
            if case .message(let message) = try FuzzRouter.decodeHandshakeFrame(
                data, sessionID: ClientFrameTargets.sessionID, logger: ClientFrameTargets.logger
            ) {
                messages += 1
                ClientFrameTargets.checkJoin(message)
            }
        }
        // `.empty` and `.notJSON` return without throwing, so decoded messages are counted apart.
        #expect(messages > 0 && outcome.threw > 0, "\(outcome), messages \(messages)")
    }

    @Test("T2: the sync-ack parser", arguments: [FrameEncoding.opcodeJsonArray, .messagepack])
    func syncAckParse(encoding: FrameEncoding) async {
        let target = "T2-sync-ack-\(encoding)"
        let seeds = ClientFrameCorpus.frames(encoding).filter { $0.kind == "syncAck" }.map(\.bytes)
        var parsed = 0
        var refused = 0
        await ClientFrameFuzzer.run(target: target, seeds: seeds) { data in
            if SyncAckFrame.parse(data) != nil { parsed += 1 } else { refused += 1 }
        }
        print("[client-frame-fuzz] \(target) parsed=\(parsed) refused=\(refused)")
        #expect(parsed > 0 && refused > 0, "parsed \(parsed), refused \(refused)")
    }

    @Test("T3: the router's post-handshake decode", arguments: encodings)
    func postHandshakeDecode(encoding: FrameEncoding) async {
        let codec = ClientFrameTargets.codec(encoding)
        let target = "T3-router-\(encoding)"
        var payloads = PayloadOutcomes()
        let outcome = await ClientFrameFuzzer.run(target: target, seeds: ClientFrameCorpus.frames(encoding).map(\.bytes)) { data, mutated in
            payloads.mutated = mutated
            if case .message(let message) = try FuzzRouter.decodePostHandshakeFrame(
                data, codec: codec, sessionID: ClientFrameTargets.sessionID, logger: ClientFrameTargets.logger
            ) {
                ClientFrameTargets.decodePayloads(of: message, outcomes: &payloads)
            }
        }
        #expect(outcome.decoded > 0 && outcome.threw > 0, "\(outcome)")
        payloads.expectReached(target)
    }

    @Test("T3: the adapter's decoding pipeline, legacy join off and on", arguments: encodings, [false, true])
    func adapterPipelineDecode(encoding: FrameEncoding, legacyJoin: Bool) async {
        let pipeline = ClientFrameTargets.pipeline(encoding, legacyJoin: legacyJoin)
        let target = "T3-pipeline-\(encoding)-\(legacyJoin)"
        var payloads = PayloadOutcomes()
        let outcome = await ClientFrameFuzzer.run(target: target, seeds: ClientFrameCorpus.frames(encoding).map(\.bytes)) { data, mutated in
            payloads.mutated = mutated
            let message = try pipeline.decode(data)
            ClientFrameTargets.decodePayloads(of: message, outcomes: &payloads)
            ClientFrameTargets.checkJoin(message)
        }
        #expect(outcome.decoded > 0 && outcome.threw > 0, "\(outcome)")
        payloads.expectReached(target)
    }

    @Test("T5: mutations of the fixture payloads reach their field decoders", arguments: encodings)
    func fixturePayloadFields(encoding: FrameEncoding) async {
        let pipeline = ClientFrameTargets.pipeline(encoding, legacyJoin: false)
        let target = "T5-fields-\(encoding)"
        var payloads = PayloadOutcomes()
        // Mutated from the T5 seeds only: in the whole corpus a fixture type's seed is one frame
        // in about seventy, so few mutations of it reach its payload decode. At least 20,000
        // inputs: most mutations of a JSON-object frame break the frame (at 2,000, about 3%
        // decoded, and `FuzzMathAction` saw no field refusal). About a second in a debug build.
        let iterations = max(ClientFrameFuzzConfig.iterations, 20_000)
        let seeds = T5Seeds.frames.filter { $0.encoding == encoding }.map(\.bytes)
        let outcome = await ClientFrameFuzzer.run(target: target, seeds: seeds, iterations: iterations) { data, mutated in
            payloads.mutated = mutated
            ClientFrameTargets.decodePayloads(of: try pipeline.decode(data), outcomes: &payloads)
        }
        #expect(outcome.decoded > 0 && outcome.threw > 0, "\(outcome)")
        payloads.expectFuzzedFields(target, types: [FuzzLeavesAction.self, FuzzMathAction.self, FuzzContainersEvent.self, PFClientEvent.self])
    }

    @Test("T4: the MessagePack unpacker and decoders, each entry point counted")
    func messagePackDecoders() async {
        let seeds = ClientFrameCorpus.frames(.messagepack).map(\.bytes)
        let serializer = MessagePackSerializer()
        var direct = FuzzOutcome()
        var anyCodable = FuzzOutcome()
        var message = FuzzOutcome()
        func count(_ outcome: inout FuzzOutcome, _ body: () throws -> Void) {
            do {
                try body()
                outcome.decoded += 1
            } catch {
                outcome.threw += 1
            }
        }
        // The runner's outcome is the unpacker's: the decoders below run on what unpacks.
        let unpacked = await ClientFrameFuzzer.run(target: "T4-messagepack", seeds: seeds) { data in
            let value = try unpack(data)
            count(&direct) { _ = try MessagePackDirectDecoder().decodeTransportMessage(from: value) }
            count(&anyCodable) { _ = try serializer.decode(AnyCodable.self, from: data) }
            count(&message) { _ = try serializer.decode(TransportMessage.self, from: data) }
        }
        print("[client-frame-fuzz] T4-messagepack unpack=\(unpacked) direct=\(direct) anyCodable=\(anyCodable) message=\(message)")
        for (name, outcome) in [("unpack", unpacked), ("direct", direct), ("message", message), ("anyCodable", anyCodable)] {
            #expect(outcome.decoded > 0 && outcome.threw > 0, "\(name): \(outcome)")
        }
    }

    @Test("T4: random bytes, not mutated from the corpus", arguments: encodings)
    func randomBytes(encoding: FrameEncoding) async {
        let target = "T4-random-\(encoding)"
        let pipeline = ClientFrameTargets.pipeline(encoding, legacyJoin: false)
        var generator = FuzzGenerator.forTarget(target, seed: ClientFrameFuzzConfig.seed)
        var recorder = FuzzInputRecorder(target: target)
        var pipelineOutcome = FuzzOutcome()
        var handshake = FuzzOutcome()
        var syncAckRefused = 0
        print("[client-frame-fuzz] \(target) seed=\(ClientFrameFuzzConfig.seedText) iterations=\(ClientFrameFuzzConfig.iterations) started")
        for index in 0..<ClientFrameFuzzConfig.iterations {
            if index % ClientFrameFuzzer.inputsPerYield == 0 { await Task.yield() }
            let count = Int.random(in: 0...96, using: &generator)
            let data = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
            recorder?.record(data)
            if (try? pipeline.decode(data)) != nil {
                pipelineOutcome.decoded += 1
            } else {
                pipelineOutcome.threw += 1
            }
            let decoded = try? FuzzRouter.decodeHandshakeFrame(data, sessionID: ClientFrameTargets.sessionID, logger: ClientFrameTargets.logger)
            if case .message? = decoded {
                handshake.decoded += 1
            } else {
                handshake.threw += 1
            }
            if SyncAckFrame.parse(data) == nil { syncAckRefused += 1 }
        }
        print("[client-frame-fuzz] \(target) pipeline=\(pipelineOutcome) handshake=\(handshake) syncAckRefused=\(syncAckRefused)")
        // Random bytes are almost never a frame. This checks that each entry point ran and refused.
        #expect(pipelineOutcome.threw > 0 && handshake.threw > 0 && syncAckRefused > 0)
        #expect(pipelineOutcome.decoded + pipelineOutcome.threw == ClientFrameFuzzConfig.iterations)
    }
}
