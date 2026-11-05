// Tests/SwiftStateTreeTransportTests/DynamicKeyCompressionSwitchTests.swift
//
// Dynamic-key compression (`[slot, "key"]` on first use, then `slot`) is switchable on its own,
// independently of path hashing (#59).

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack
@testable import SwiftStateTreeTransport

private let pathHashes: [String: UInt32] = [
    "players.*": 300,
    "players.*.score": 301,
    "rooms.*.seats.*": 302
]

private let firstSync: StateUpdate = .firstSync([
    // No 0, 1 or Bool values: the JSON test decoder reads a nested 1 back as `true`.
    StatePatch(path: "/players/alice", operation: .set(.object(["score": .int(5)]))),
    StatePatch(path: "/players/bob/score", operation: .set(.int(2))),
    StatePatch(path: "/rooms/r1/seats/alice", operation: .add(.string("seated")))
])

/// Repeats every key, so with compression the second use is a bare slot.
private let diff: StateUpdate = .diff([
    StatePatch(path: "/players/alice/score", operation: .set(.int(3))),
    StatePatch(path: "/players/bob", operation: .delete),
    StatePatch(path: "/rooms/r1/seats/alice", operation: .delete),
    StatePatch(path: "/players/carol/score", operation: .set(.int(4)))
])

private let player = PlayerID("p1")

/// The dynamic-key element of every patch in an opcode array payload (`[opcode, patch...]`).
private func dynamicKeyElements(_ payload: [Any]) -> [Any] {
    payload.dropFirst().compactMap { ($0 as? [Any]).map { $0[1] } }
}

/// Whether a dynamic-key element uses a slot (a number, or a `[slot, "key"]` definition).
private func usesSlot(_ element: Any) -> Bool {
    if element is NSNumber { return true }
    guard let array = element as? [Any] else { return false }
    if array.count == 2, array[0] is NSNumber, array[1] is String { return true }
    return array.contains(where: usesSlot)
}

private func roundTripJSON(compress: Bool) throws -> (updates: [StateUpdate], keyElements: [[Any]]) {
    let encoder = OpcodeJSONStateUpdateEncoder(
        pathHasher: PathHasher(pathHashes: pathHashes),
        dynamicKeyCompression: compress
    )
    let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: PathHasher(pathHashes: pathHashes))
    var updates: [StateUpdate] = []
    var keyElements: [[Any]] = []
    for update in [firstSync, diff] {
        let data = try encoder.encode(update: update, landID: "land", playerID: player)
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
        keyElements.append(dynamicKeyElements(payload))
        updates.append(try decoder.decode(data: data).update)
    }
    return (updates, keyElements)
}

@Suite("Dynamic-key compression switch")
struct DynamicKeyCompressionSwitchTests {
    @Test("Opcode JSON: on and off decode to the same updates; off sends full key strings only")
    func opcodeJSONRoundTrip() throws {
        let on = try roundTripJSON(compress: true)
        let off = try roundTripJSON(compress: false)
        #expect(on.updates == [firstSync, diff])
        #expect(off.updates == [firstSync, diff])
        #expect(on.keyElements.joined().contains(where: usesSlot), "compression on uses slots")
        #expect(!off.keyElements.joined().contains(where: usesSlot), "compression off sends key strings")
        // The multi-key path keeps its keys in order.
        #expect(off.keyElements[0][2] as? [String] == ["r1", "alice"])
    }

    @Test("Opcode MessagePack: off sends the same patches as opcode JSON off, full keys in order")
    func opcodeMessagePackOff() throws {
        let messagePack = OpcodeMessagePackStateUpdateEncoder(
            pathHasher: PathHasher(pathHashes: pathHashes),
            dynamicKeyCompression: false
        )
        let json = OpcodeJSONStateUpdateEncoder(
            pathHasher: PathHasher(pathHashes: pathHashes),
            dynamicKeyCompression: false
        )
        let expectedKeys: [[MessagePackValue]] = [
            [.string("alice"), .string("bob"), .array([.string("r1"), .string("alice")])],
            [.string("alice"), .string("bob"), .array([.string("r1"), .string("alice")]), .string("carol")]
        ]
        for (update, keys) in zip([firstSync, diff], expectedKeys) {
            let packed = try unpack(try messagePack.encode(update: update, landID: "land", playerID: player))
            guard case .array(let elements) = packed else {
                Issue.record("expected a MessagePack array")
                return
            }
            let packedKeys = elements.dropFirst().compactMap { element -> MessagePackValue? in
                guard case .array(let patch) = element else { return nil }
                return patch[1]
            }
            #expect(packedKeys == keys)
            // Path hashes, keys, opcodes and values all match opcode JSON off, element by element.
            let jsonPayload = try #require(
                try JSONSerialization.jsonObject(with: json.encode(update: update, landID: "land", playerID: player)) as? [Any]
            )
            #expect((packed.toAny() as? NSArray)?.isEqual(to: jsonPayload) == true, "\(packed)")
        }
    }

    @Test("Golden bytes, compression on: unchanged from the encoders before the switch")
    func goldenOn() throws {
        // The default initializers, as before the switch: these pins also pass on the parent commit.
        let json = OpcodeJSONStateUpdateEncoder(pathHasher: PathHasher(pathHashes: pathHashes))
        let messagePack = OpcodeMessagePackStateUpdateEncoder(pathHasher: PathHasher(pathHashes: pathHashes))
        let jsonText = try goldenJSON(json)
        let hex = try goldenHex(messagePack)
        #expect(jsonText == goldenOnJSON)
        #expect(hex == goldenOnHex)
    }

    @Test("Golden bytes, compression off: full keys every time")
    func goldenOff() throws {
        let json = OpcodeJSONStateUpdateEncoder(pathHasher: PathHasher(pathHashes: pathHashes), dynamicKeyCompression: false)
        let messagePack = OpcodeMessagePackStateUpdateEncoder(
            pathHasher: PathHasher(pathHashes: pathHashes),
            dynamicKeyCompression: false
        )
        let jsonText = try goldenJSON(json)
        let hex = try goldenHex(messagePack)
        #expect(jsonText == goldenOffJSON)
        #expect(hex == goldenOffHex)
    }

    @Test("Compression on stays the default, in the encoders and in TransportEncodingConfig")
    func defaultIsOn() throws {
        #expect(TransportEncodingConfig.messagepack.dynamicKeyCompression)
        #expect(TransportEncodingConfig(message: .opcodeJsonArray, stateUpdate: .opcodeJsonArray).dynamicKeyCompression)
        let defaultEncoder = OpcodeJSONStateUpdateEncoder(pathHasher: PathHasher(pathHashes: pathHashes))
        let data = try defaultEncoder.encode(update: diff, landID: "land", playerID: player)
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
        #expect(dynamicKeyElements(payload).contains(where: usesSlot))
    }

    @Test("DYNAMIC_KEY_COMPRESSION turns it off; unset keeps it on")
    func environmentKey() {
        #expect(TransportEncodingConfig.dynamicKeyCompressionFromEnvironment(environment: [:]))
        #expect(!TransportEncodingConfig.dynamicKeyCompressionFromEnvironment(environment: [TransportEncodingConfig.dynamicKeyCompressionEnvironmentKey: "false"]))
        #expect(TransportEncodingConfig.dynamicKeyCompressionFromEnvironment(environment: [TransportEncodingConfig.dynamicKeyCompressionEnvironmentKey: "true"]))
        #expect(!TransportEncodingConfig.messagepack.withDynamicKeyCompression(false).dynamicKeyCompression)
        #expect(TransportEncodingConfig.messagepack.withDynamicKeyCompression(false).stateUpdate == .opcodeMessagePack)
    }

    @Test("TransportEncodingConfig passes the switch to the state-update encoder it makes")
    func configPassesSwitch() throws {
        for stateUpdate in [StateUpdateEncoding.opcodeJsonArray, .opcodeMessagePack] {
            let config = TransportEncodingConfig(
                message: .opcodeJsonArray,
                stateUpdate: stateUpdate,
                dynamicKeyCompression: false
            )
            let encoder = config.makeStateUpdateEncoder(pathHashes: pathHashes)
            let data = try encoder.encode(update: diff, landID: "land", playerID: player)
            let payload: [Any]
            if stateUpdate == .opcodeMessagePack {
                // Same array structure: compare through JSON-like values.
                payload = try #require(try unpack(data).toAny() as? [Any])
            } else {
                payload = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
            }
            #expect(!dynamicKeyElements(payload).contains(where: usesSlot), "\(stateUpdate)")
        }
    }
}

/// firstSync then diff from one encoder, as opcode JSON text.
private func goldenJSON(_ encoder: StateUpdateEncoder) throws -> [String] {
    try [firstSync, diff].map { String(decoding: try encoder.encode(update: $0, landID: "land", playerID: player), as: UTF8.self) }
}

/// firstSync then diff from one encoder, as lowercase hex.
private func goldenHex(_ encoder: StateUpdateEncoder) throws -> [String] {
    try [firstSync, diff].map { try encoder.encode(update: $0, landID: "land", playerID: player).map { String(format: "%02x", $0) }.joined() }
}

/// Slots on first use (`[slot,"key"]`), bare slots after; also what the parent commit produced.
private let goldenOnJSON: [String] = [
    #"[1,[300,[0,"alice"],1,{"score":5}],[301,[1,"bob"],1,2],[302,[[2,"r1"],[0,"alice"]],3,"seated"]]"#,
    #"[2,[301,0,1,3],[300,1,2],[302,[2,0],2],[301,[3,"carol"],1,4]]"#,
]
private let goldenOnHex: [String] = [
    "940194cd012c9200a5616c6963650181a573636f72650594cd012d9201a3626f62010294cd012e929202a272319200a5616c69636503a6736561746564",
    "950294cd012d00010393cd012c010293cd012e9202000294cd012d9203a56361726f6c0104",
]
/// Full keys in every patch; the multi-key path as `["r1","alice"]`.
private let goldenOffJSON: [String] = [
    #"[1,[300,"alice",1,{"score":5}],[301,"bob",1,2],[302,["r1","alice"],3,"seated"]]"#,
    #"[2,[301,"alice",1,3],[300,"bob",2],[302,["r1","alice"],2],[301,"carol",1,4]]"#,
]
private let goldenOffHex: [String] = [
    "940194cd012ca5616c6963650181a573636f72650594cd012da3626f62010294cd012e92a27231a5616c69636503a6736561746564",
    "950294cd012da5616c696365010393cd012ca3626f620293cd012e92a27231a5616c6963650294cd012da56361726f6c0104",
]

private extension MessagePackValue {
    /// JSON-like Foundation values (numbers as `NSNumber`), for comparing array structures.
    func toAny() -> Any {
        switch self {
        case .nil: return NSNull()
        case .bool(let b): return NSNumber(value: b)
        case .int(let i): return NSNumber(value: i)
        case .uint(let u): return NSNumber(value: u)
        case .float(let f): return NSNumber(value: f)
        case .double(let d): return NSNumber(value: d)
        case .string(let s): return s
        case .binary(let b): return b
        case .array(let a): return a.map { $0.toAny() }
        case .map(let m): return Dictionary(uniqueKeysWithValues: m.map { (String(describing: $0.key.toAny()), $0.value.toAny()) })
        case .extended(_, let d): return d
        }
    }
}
