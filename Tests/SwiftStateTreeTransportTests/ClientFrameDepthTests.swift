// Tests/SwiftStateTreeTransportTests/ClientFrameDepthTests.swift
//
// Deep nesting (#362) and decode amplification (#528) on the client-frame decode chain.
//
// - Depth: an action, a client event and a join, each with its payload nested `depth` levels,
//   go through the router's and the adapter's decode and then the payload decode, on a task of
//   the cooperative pool. The parsers' limits bound the depth: JSON parsing throws past 512
//   levels, the MessagePack unpacker past `messagePackMaxNestingDepth`. Every depth up to the
//   limit must decode or throw; a stack overflow ends the process.
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

enum ClientFrameChain {
    /// Every decode a frame of `encoding` reaches, ending in the payload decode and the join
    /// checks. Each step may throw; none may trap.
    static func run(_ data: Data, encoding: FrameEncoding) {
        let logger = ClientFrameTargets.logger
        let session = ClientFrameTargets.sessionID
        var messages: [TransportMessage] = []
        if encoding != .messagepack,
           case .message(let message)? = try? FuzzRouter.decodeHandshakeFrame(data, sessionID: session, logger: logger) {
            messages.append(message)
        }
        if case .message(let message)? = try? FuzzRouter.decodePostHandshakeFrame(
            data, codec: ClientFrameTargets.codec(encoding), sessionID: session, logger: logger
        ) {
            messages.append(message)
        }
        for legacyJoin in [false, true] {
            if let message = try? ClientFrameTargets.pipeline(encoding, legacyJoin: legacyJoin).decode(data) {
                messages.append(message)
            }
        }
        for message in messages {
            ClientFrameTargets.decodePayloads(of: message)
            ClientFrameTargets.checkJoin(message)
        }
    }
}

@Suite("Client frame decoders: deep nesting and amplification (#362, #528)", .timeLimit(.minutes(5)))
struct ClientFrameDepthTests {
    static let jsonLimit = 512

    static func depths(upTo limit: Int) -> [Int] {
        if let text = ProcessInfo.processInfo.environment[ClientFrameDepthEnvKeys.depth], let depth = Int(text) {
            return [depth]
        }
        return [8, 32, 64, 128, 256, limit - 1, limit, limit + 1]
    }

    @Test("Nesting up to the JSON parsers' limit decodes or throws, on the cooperative pool",
          arguments: [FrameEncoding.json, .opcodeJsonArray], ["action", "clientEvent", "join"])
    func jsonDepth(encoding: FrameEncoding, kind: String) async {
        for depth in Self.depths(upTo: Self.jsonLimit) {
            for objects in [false, true] {
                let data = encoding == .json
                    ? DeepFrames.json(kind, depth: depth, objects: objects)
                    : DeepFrames.opcodeJSON(kind, depth: depth, objects: objects)
                await Task.detached { ClientFrameChain.run(data, encoding: encoding) }.value
            }
        }
    }

    @Test("Nesting up to the MessagePack unpacker's limit decodes or throws, on the cooperative pool",
          arguments: ["action", "clientEvent", "join"])
    func messagePackDepth(kind: String) async throws {
        for depth in Self.depths(upTo: messagePackMaxNestingDepth) {
            let data = DeepFrames.messagePack(kind, depth: depth)
            await Task.detached { ClientFrameChain.run(data, encoding: .messagepack) }.value
        }
        // The fixture is what it claims: one level past the limit is refused by the unpacker.
        #expect(throws: (any Error).self) {
            try unpack(DeepFrames.messagePack(kind, depth: messagePackMaxNestingDepth + 2))
        }
    }

    @Test("The JSON fixtures are as deep as they claim: the parser accepts the limit and refuses one past it")
    func jsonFixtureDepth() {
        for kind in ["action", "clientEvent", "join"] {
            #expect((try? JSONSerialization.jsonObject(with: DeepFrames.json(kind, depth: Self.jsonLimit, objects: false))) != nil, "\(kind)")
            #expect((try? JSONSerialization.jsonObject(with: DeepFrames.json(kind, depth: Self.jsonLimit + 1, objects: false))) == nil, "\(kind)")
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
