// Tests/SwiftStateTreeTransportTests/ClientFrameDepthTests.swift
//
// Deep nesting (#362) and decode amplification (#528) on the client-frame decode chain.
//
// - Depth: an action, a client event and a join, each with its payload nested `depth` levels,
//   go through the router's and the adapter's decode and then the payload decode, on a task of
//   the cooperative pool. One limit bounds the depth in every encoding
//   (`PayloadNesting.clientFrameMaxDepth`, 32): JSON is refused past it before it is parsed,
//   MessagePack by its unpacker, given the same limit. Foundation's own JSON limit (512) isn't the
//   bound: on Darwin's 524 KiB pool stacks the payload's re-encode overflows there (#362). Up to
//   the limit every decoder must produce the message and its payload stage must succeed, so the
//   recursive stages after the parse ran at that depth. Past it, up to and beyond Foundation's
//   limit, every decoder must refuse with the nesting error. A stack overflow ends the process.
//   `SST_FUZZ_DEPTH=<n>` runs one depth only, to find a limit (one process per depth).
// - Amplification: a frame of one-byte elements (empty maps), decoded, holds no more elements
//   than the frame has bytes. `SST_FUZZ_AMPLIFICATION_BYTES=<n>` sets the frame size (default
//   64 KiB, to keep the JSON-object case near a second in a debug build; the inbound limit
//   `maxFrameSize` is 16 MiB) and prints the count and the time.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack
@testable import SwiftStateTreeTransport

enum ClientFrameDepthEnvKeys {
    static let depth = "SST_FUZZ_DEPTH"
    static let amplificationBytes = "SST_FUZZ_AMPLIFICATION_BYTES"
}

/// Frames whose payload is nested `depth` levels deep, counted from the frame's outermost
/// container, so `depth` is what the parser sees.
enum DeepFrames {
    /// `[[[...]]]` holding `[]` at the bottom: `levels` arrays.
    private static func jsonArrays(_ levels: Int) -> String {
        String(repeating: "[", count: levels) + String(repeating: "]", count: levels)
    }

    /// `{"a":{"a":...{}}}`: `levels` objects.
    private static func jsonObjects(_ levels: Int) -> String {
        String(repeating: "{\"a\":", count: max(0, levels - 1)) + "{}" + String(repeating: "}", count: max(0, levels - 1))
    }

    static func json(_ kind: String, depth: Int, objects: Bool) -> Data {
        let inner = { (levels: Int) in objects ? jsonObjects(levels) : jsonArrays(levels) }
        switch kind {
        case "action":  // {"kind","payload":{..., "payload": <inner>}}: 2 levels around it
            return Data(#"{"kind":"action","payload":{"requestID":"r","typeIdentifier":"X","payload":\#(inner(depth - 2))}}"#.utf8)
        case "clientEvent":  // {"payload":{"fromClient":{"payload": <inner>}}}: 3 levels
            return Data(#"{"kind":"event","payload":{"fromClient":{"type":"E","payload":\#(inner(depth - 3))}}}"#.utf8)
        default:  // join metadata {"k": <inner>}: 4 levels
            return Data(#"{"kind":"join","payload":{"join":{"requestID":"j","landType":"t","metadata":{"k":\#(inner(depth - 4))}}}}"#.utf8)
        }
    }

    static func opcodeJSON(_ kind: String, depth: Int, objects: Bool) -> Data {
        let levels = depth - 1  // inside the opcode array
        let inner = objects ? jsonObjects(levels) : jsonArrays(levels)
        switch kind {
        case "action": return Data(#"[101,"r","X",\#(inner)]"#.utf8)
        case "clientEvent": return Data(#"[103,0,"E",\#(inner)]"#.utf8)
        default: return Data(#"[104,"j","t",null,null,null,{"k":\#(objects ? jsonObjects(levels - 1) : jsonArrays(levels - 1))}]"#.utf8)
        }
    }

    /// MessagePack opcode arrays with `depth - 1` fixarray(1) levels inside, `[]` at the bottom.
    static func messagePack(_ kind: String, depth: Int) -> Data {
        let levels = max(0, depth - 1)
        let nest: [UInt8] = [UInt8](repeating: 0x91, count: max(0, levels - 1)) + [0x90]
        let str = { (s: String) -> [UInt8] in [0xA0 | UInt8(s.utf8.count)] + Array(s.utf8) }
        switch kind {
        case "action":
            var bytes: [UInt8] = [0x94, 0x65]
            bytes += str("r")
            bytes += str("X")
            bytes += nest
            return Data(bytes)
        case "clientEvent":
            var bytes: [UInt8] = [0x94, 0x67, 0x00]
            bytes += str("E")
            bytes += nest
            return Data(bytes)
        default:
            let metadataNest: [UInt8] = [UInt8](repeating: 0x91, count: max(0, levels - 2)) + [0x90]
            var bytes: [UInt8] = [0x97, 0x68]
            bytes += str("j")
            bytes += str("t")
            bytes += [0xC0, 0xC0, 0xC0, 0x81]
            bytes += str("k")
            bytes += metadataNest
            return Data(bytes)
        }
    }
}

/// What one frame did in each stage of the chain: the frame decoders by name, then for each
/// decoded message its payload stage (`<decoder>/payload`: the action's or client event's
/// payload through `InboundPayloadDecoding`, or the join's metadata and the join checks).
struct ChainReport: CustomStringConvertible {
    var succeeded: [String] = []
    /// The stage's error, or why it produced no message.
    var refused: [String: String] = [:]

    var description: String { "succeeded \(succeeded), refused \(refused)" }
}

enum ClientFrameChain {
    /// The frame decoders a frame of `encoding` reaches.
    static func decoders(_ encoding: FrameEncoding) -> [String] {
        (encoding == .messagepack ? [] : ["handshake"]) + ["router", "pipeline", "pipeline-legacy-join"]
    }

    /// Every decode a frame of `encoding` reaches, ending in the payload decode and the join
    /// checks. Each step may throw; none may trap. It yields between stages: a deep frame's
    /// stage takes long in a debug build, and the cases run in parallel on the cooperative pool.
    static func run(_ data: Data, encoding: FrameEncoding) async -> ChainReport {
        let logger = ClientFrameTargets.logger
        let session = ClientFrameTargets.sessionID
        var report = ChainReport()
        func stage(_ name: String, _ decode: () throws -> TransportMessage?) {
            do {
                guard let message = try decode() else {
                    report.refused[name] = "no message"
                    return
                }
                report.succeeded.append(name)
                payloadStage("\(name)/payload", message)
            } catch {
                report.refused[name] = String(describing: error)
            }
        }
        func payloadStage(_ name: String, _ message: TransportMessage) {
            if case .join(let join) = message.payload {
                ClientFrameTargets.checkJoin(message)
                if join.metadata?["k"] != nil { report.succeeded.append(name) } else { report.refused[name] = "no metadata" }
                return
            }
            if ClientFrameTargets.decodePayloads(of: message) == true {
                report.succeeded.append(name)
            } else {
                report.refused[name] = "payload didn't decode"
            }
        }
        if encoding != .messagepack {
            await Task.yield()
            stage("handshake") {
                guard case .message(let message) = try FuzzRouter.decodeHandshakeFrame(data, sessionID: session, logger: logger) else { return nil }
                return message
            }
        }
        await Task.yield()
        stage("router") {
            guard case .message(let message) = try FuzzRouter.decodePostHandshakeFrame(
                data, codec: ClientFrameTargets.codec(encoding), sessionID: session, logger: logger
            ) else { return nil }
            return message
        }
        await Task.yield()
        stage("pipeline") { try ClientFrameTargets.pipeline(encoding, legacyJoin: false).decode(data) }
        await Task.yield()
        stage("pipeline-legacy-join") { try ClientFrameTargets.pipeline(encoding, legacyJoin: true).decode(data) }
        return report
    }

    /// At or under the parsers' limit: every decoder produced a message and its payload stage
    /// succeeded, so the recursive stages after the parse ran at this depth.
    static func expectReachedPayload(
        _ report: ChainReport, encoding: FrameEncoding, _ context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let expected = decoders(encoding).flatMap { [$0, "\($0)/payload"] }
        #expect(report.succeeded == expected, "\(context): \(report)", sourceLocation: sourceLocation)
    }

    /// Past the limit: every decoder refused the frame, each with the parser's own nesting
    /// error, not some other failure.
    static func expectNestingRefusal(
        _ report: ChainReport, encoding: FrameEncoding, _ context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(report.succeeded.isEmpty, "\(context): \(report)", sourceLocation: sourceLocation)
        // The same refusal in every encoding: JSON's before it is parsed (`PayloadNesting`),
        // MessagePack's from its unpacker.
        let marker = "Nesting deeper than \(PayloadNesting.clientFrameMaxDepth)"
        for name in decoders(encoding) {
            let error = report.refused[name] ?? "none"
            #expect(error.contains(marker), "\(context) \(name): \(error)", sourceLocation: sourceLocation)
        }
    }
}

@Suite("Client frame decoders: deep nesting and amplification (#362, #528)", .serialized, .timeLimit(.minutes(5)))
struct ClientFrameDepthTests {
    /// The nesting limit of every client frame (#362).
    static let limit = PayloadNesting.clientFrameMaxDepth
    /// The deepest frame the depth tests send: Linux Foundation's JSON parser limit. Every
    /// platform's parser reads a frame this deep (`jsonFixtureDepth`), and the depth tests refuse
    /// frames up to and past it.
    static let foundationJSONLimit = 512

    /// Runs `body` on a thread of its own with an 8 MiB stack and waits for it. Foundation's own
    /// parse of a 512-level frame recurses about 940 frames deep on Darwin, which overflows a
    /// cooperative-pool thread's 524 KiB stack and would kill the test bundle.
    static func onLargeStack(_ body: @escaping @Sendable () -> Bool) -> Bool {
        final class Box: @unchecked Sendable {
            var value = false
            let done = DispatchSemaphore(value: 0)
        }
        let box = Box()
        let thread = Thread {
            box.value = body()
            box.done.signal()
        }
        thread.stackSize = 8 << 20
        thread.start()
        box.done.wait()
        return box.value
    }

    /// The depths a test runs: around the limit, then deeper ones, up to and past Foundation's
    /// JSON limit, which must be refused, not overflow.
    static func depths(upTo limit: Int) -> [Int] {
        if let text = ProcessInfo.processInfo.environment[ClientFrameDepthEnvKeys.depth], let depth = Int(text) {
            return [depth]
        }
        return Array(Set([8, 32, limit - 1, limit, limit + 1, 128, 256, foundationJSONLimit, foundationJSONLimit + 1])).sorted()
    }

    /// Checks the chain's report at `depth`: up to `limit` every stage through the payload
    /// succeeded, past it every decoder refused with the parser's nesting error.
    static func check(_ report: ChainReport, encoding: FrameEncoding, depth: Int, limit: Int, _ context: String) {
        if depth <= limit {
            ClientFrameChain.expectReachedPayload(report, encoding: encoding, context)
        } else {
            ClientFrameChain.expectNestingRefusal(report, encoding: encoding, context)
        }
    }

    @Test("JSON nested up to the limit reaches the payload decode, on the cooperative pool; deeper, up to and past Foundation's limit, is refused",
          arguments: [FrameEncoding.json, .opcodeJsonArray], ["action", "clientEvent", "join"])
    func jsonDepth(encoding: FrameEncoding, kind: String) async {
        for depth in Self.depths(upTo: Self.limit) {
            for objects in [false, true] {
                let data = encoding == .json
                    ? DeepFrames.json(kind, depth: depth, objects: objects)
                    : DeepFrames.opcodeJSON(kind, depth: depth, objects: objects)
                let report = await Task.detached { await ClientFrameChain.run(data, encoding: encoding) }.value
                Self.check(report, encoding: encoding, depth: depth, limit: Self.limit,
                           "\(encoding) \(kind) depth \(depth) \(objects ? "objects" : "arrays")")
            }
        }
    }

    @Test("Leading whitespace or a UTF-8 BOM doesn't skip the check: at the limit the payload is reached, past it every parsing decoder refuses",
          arguments: [FrameEncoding.json, .opcodeJsonArray], ["action", "clientEvent", "join"])
    func prefixedJSON(encoding: FrameEncoding, kind: String) async {
        for prefix in [" ", "\n\t ", "\u{FEFF}", "\u{FEFF} "] {
            for depth in [Self.limit, Self.limit + 1, Self.foundationJSONLimit] {
                let frame = encoding == .json
                    ? DeepFrames.json(kind, depth: depth, objects: true)
                    : DeepFrames.opcodeJSON(kind, depth: depth, objects: true)
                let data = Data(prefix.utf8) + frame
                let report = await Task.detached { await ClientFrameChain.run(data, encoding: encoding) }.value
                let context = "\(encoding) \(kind) depth \(depth) prefix \(Array(prefix.utf8))"
                // The handshake reads only a frame that starts with `[` or `{`; this one it
                // refuses unparsed.
                #expect(report.refused["handshake"] == "no message", "\(context): \(report)")
                let parsing = ["router", "pipeline", "pipeline-legacy-join"]
                if depth <= Self.limit {
                    #expect(report.succeeded == parsing.flatMap { [$0, "\($0)/payload"] }, "\(context): \(report)")
                } else {
                    #expect(report.succeeded.isEmpty, "\(context): \(report)")
                    for name in parsing {
                        let error = report.refused[name] ?? "none"
                        #expect(error.contains("Nesting deeper than \(Self.limit)"), "\(context) \(name): \(error)")
                    }
                }
            }
        }
    }

    @Test("UTF-16 JSON is refused by every decoder, whether or not Foundation would read it",
          arguments: [FrameEncoding.json, .opcodeJsonArray], [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf16])
    func utf16Refused(encoding: FrameEncoding, textEncoding: String.Encoding) async throws {
        // An escaped quote inside a string, then nesting past the limit: a byte-wise escape
        // count would end the string early and miss the brackets after it.
        let utf8 = encoding == .json
            ? DeepFrames.json("action", depth: Self.foundationJSONLimit, objects: false)
            : DeepFrames.opcodeJSON("action", depth: Self.foundationJSONLimit, objects: false)
        let text = try #require(String(data: utf8, encoding: .utf8))
            .replacingOccurrences(of: "\"r\"", with: "\"r\\\"q\"")
        let data = try #require(text.data(using: textEncoding))
        let report = await Task.detached { await ClientFrameChain.run(data, encoding: encoding) }.value
        let context = "\(encoding) \(textEncoding)"
        #expect(report.succeeded.isEmpty, "\(context): \(report)")
        for name in ["router", "pipeline", "pipeline-legacy-join"] {
            let error = report.refused[name] ?? "none"
            #expect(error.contains("Not UTF-8 JSON"), "\(context) \(name): \(error)")
        }
    }

    @Test("MessagePack nested up to the limit reaches the payload decode, on the cooperative pool; deeper is refused",
          arguments: ["action", "clientEvent", "join"])
    func messagePackDepth(kind: String) async throws {
        for depth in Self.depths(upTo: Self.limit) {
            let data = DeepFrames.messagePack(kind, depth: depth)
            let report = await Task.detached { await ClientFrameChain.run(data, encoding: .messagepack) }.value
            Self.check(report, encoding: .messagepack, depth: depth, limit: Self.limit,
                       "messagepack \(kind) depth \(depth)")
        }
    }

    @Test("Client frames nest at most 32 deep in every encoding; frames the server builds, 64, the unpacker's default")
    func limits() {
        #expect(PayloadNesting.clientFrameMaxDepth == 32)
        #expect(PayloadNesting.serverFrameMaxDepth == 64)
        #expect(PayloadNesting.clientFrameMaxDepth < PayloadNesting.serverFrameMaxDepth)
        #expect(messagePackMaxNestingDepth == PayloadNesting.serverFrameMaxDepth)
    }

    @Test("The MessagePack unpacker refuses a container count above the bytes left with its own error, before reserving")
    func messagePackCountGuard() {
        // An array claiming 2 elements, then a map claiming 2 entries, with 1 byte (nil) left. Without the
        // guard the unpacker would reserve, read one element and fail at the end of the data
        // with a different error.
        for frame in [Data([0xDC, 0x00, 0x02, 0xC0]), Data([0xDE, 0x00, 0x02, 0xC0])] {
            do {
                _ = try unpack(frame)
                Issue.record("\(Array(frame)) unpacked")
            } catch MessagePackError.invalidData(let message) {
                // A map's count is its keys and values: 2 entries are 4 elements.
                let elements = frame[0] == 0xDC ? 2 : 4
                #expect(message == "Container count \(elements) exceeds the 1 bytes left", "\(Array(frame))")
            } catch {
                Issue.record("\(Array(frame)): \(error)")
            }
        }
    }

    @Test("The JSON fixtures are well-formed at the deepest depth sent, and the check counts them as nested as they claim")
    func jsonFixtureDepth() {
        // Every JSON frame the depth tests use, nested in arrays and in objects. Foundation must
        // parse the deepest one, so a refusal in the depth tests is the check's, not malformed
        // JSON. Where Foundation's own limit sits is its business, and it differs: Linux refuses
        // 513 levels, Darwin accepts them. So only the parse at 512 is asserted, on a thread with
        // a large stack (`onLargeStack`); the check's refusal past 32 runs here, on the pool.
        for encoding in [FrameEncoding.json, .opcodeJsonArray] {
            for kind in ["action", "clientEvent", "join"] {
                for objects in [false, true] {
                    func frame(_ depth: Int) -> Data {
                        encoding == .json
                            ? DeepFrames.json(kind, depth: depth, objects: objects)
                            : DeepFrames.opcodeJSON(kind, depth: depth, objects: objects)
                    }
                    let context = "\(encoding) \(kind) \(objects ? "objects" : "arrays")"
                    // The pre-parse check counts as the parser does: it takes the limit and
                    // refuses one past it.
                    #expect((try? PayloadNesting.checkJSON(frame(Self.limit))) != nil, "\(context)")
                    #expect(throws: PayloadNesting.TooDeep.self, "\(context)") { try PayloadNesting.checkJSON(frame(Self.limit + 1)) }
                    let deepest = frame(Self.foundationJSONLimit)
                    let parsed = Self.onLargeStack { (try? JSONSerialization.jsonObject(with: deepest)) != nil }
                    #expect(parsed, "\(context)")
                }
            }
        }
    }

    /// Counts the containers and leaves in a decoded `AnyCodable` value.
    static func elementCount(_ value: Any) -> Int {
        switch value {
        case let array as [Any]: return 1 + array.reduce(0) { $0 + elementCount($1) }
        case let map as [String: Any]: return 1 + map.values.reduce(0) { $0 + elementCount($1) }
        case let codable as AnyCodable: return elementCount(codable.base)
        default: return 1
        }
    }

    @Test("A frame of one-byte elements decodes to no more elements than it has bytes", arguments: FrameEncoding.allCases)
    func amplification(encoding: FrameEncoding) throws {
        let size = ProcessInfo.processInfo.environment[ClientFrameDepthEnvKeys.amplificationBytes].flatMap(Int.init) ?? (1 << 16)
        let data: Data
        switch encoding {
        case .json, .opcodeJsonArray:
            // [101,"r","X",[{},{},...]]: three bytes per element.
            let count = max(1, (size - 16) / 3)
            let body = Array(repeating: "{}", count: count).joined(separator: ",")
            data = Data((encoding == .json
                ? #"{"kind":"action","payload":{"requestID":"r","typeIdentifier":"X","payload":[\#(body)]}}"#
                : #"[101,"r","X",[\#(body)]]"#).utf8)
        case .messagepack:
            // [101,"r","X",array32 of fixmap(0)]: one byte per element.
            let count = max(1, size - 16)
            var bytes: [UInt8] = [0x94, 0x65, 0xA1, 0x72, 0xA1, 0x58, 0xDD]
            bytes += withUnsafeBytes(of: UInt32(count).bigEndian, Array.init)
            bytes += [UInt8](repeating: 0x80, count: count)
            data = Data(bytes)
        }
        let start = ContinuousClock.now
        let message = try ClientFrameTargets.pipeline(encoding, legacyJoin: false).decode(data)
        guard case .action(let action) = message.payload else {
            Issue.record("not an action")
            return
        }
        let elements = Self.elementCount(action.action.payload)
        let elapsed = ContinuousClock.now - start
        print("[client-frame-amplification] \(encoding) bytes=\(data.count) elements=\(elements) decode=\(elapsed)")
        #expect(elements <= data.count)
    }
}
