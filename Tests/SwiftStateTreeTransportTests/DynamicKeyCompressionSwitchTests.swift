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

    @Test("Opcode MessagePack: off sends full key strings, with the same structure as opcode JSON off")
    func opcodeMessagePackOff() throws {
        let messagePack = OpcodeMessagePackStateUpdateEncoder(
            pathHasher: PathHasher(pathHashes: pathHashes),
            dynamicKeyCompression: false
        )
        let json = OpcodeJSONStateUpdateEncoder(
            pathHasher: PathHasher(pathHashes: pathHashes),
            dynamicKeyCompression: false
        )
        for update in [firstSync, diff] {
            let packed = try unpack(try messagePack.encode(update: update, landID: "land", playerID: player))
            guard case .array(let elements) = packed else {
                Issue.record("expected a MessagePack array")
                return
            }
            let keys = elements.dropFirst().compactMap { element -> MessagePackValue? in
                guard case .array(let patch) = element else { return nil }
                return patch[1]
            }
            for key in keys {
                switch key {
                case .string, .nil: break
                case .array(let parts):
                    #expect(parts.allSatisfy { if case .string = $0 { return true } else { return false } }, "\(parts)")
                default:
                    Issue.record("compression off sent a slot: \(key)")
                }
            }
            let jsonPayload = try #require(
                try JSONSerialization.jsonObject(with: json.encode(update: update, landID: "land", playerID: player)) as? [Any]
            )
            #expect(keys.count == dynamicKeyElements(jsonPayload).count)
        }
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
        #expect(!TransportEncodingConfig.dynamicKeyCompressionFromEnvironment(environment: ["DYNAMIC_KEY_COMPRESSION": "false"]))
        #expect(TransportEncodingConfig.dynamicKeyCompressionFromEnvironment(environment: ["DYNAMIC_KEY_COMPRESSION": "true"]))
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
