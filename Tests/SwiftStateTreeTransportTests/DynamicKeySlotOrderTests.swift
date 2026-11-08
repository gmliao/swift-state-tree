// Tests/SwiftStateTreeTransportTests/DynamicKeySlotOrderTests.swift
//
// Dynamic-key slots don't depend on the order a frame's patches come in (#292): the diff's patch
// order follows dictionary iteration, which Swift seeds per process, so two keys first seen in one
// frame used to get each other's slots in another run.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack
@testable import SwiftStateTreeTransport

private let pathHashes: [String: UInt32] = [
    "players.*.score": 401,
    "rooms.*.seats.*": 402,
]

private let player = PlayerID("p1")

/// `/players/<key>/score` set to `value`.
private func score(_ key: String, _ value: Int) -> StatePatch {
    StatePatch(path: "/players/\(key)/score", operation: .set(.int(value)))
}

/// Every `[slot, "key"]` definition in a decoded opcode payload, in order, as key → slot.
private func definitions(_ element: Any, into result: inout [(String, Int)]) {
    guard let array = element as? [Any] else { return }
    if array.count == 2, let slot = (array[0] as? NSNumber)?.intValue, let key = array[1] as? String {
        result.append((key, slot))
        return
    }
    for item in array { definitions(item, into: &result) }
}

private func definedSlots(_ payload: [Any]) -> [String: Int] {
    var pairs: [(String, Int)] = []
    for entry in payload.dropFirst() {
        guard let patch = entry as? [Any], patch.count > 1 else { continue }
        definitions(patch[1], into: &pairs)
    }
    return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
}

/// Internal: the parameterized tests take it as an argument.
enum DynamicKeySlotFormat: CaseIterable, Sendable {
    case json, messagePack

    func encoder() -> any StateUpdateEncoder {
        switch self {
        case .json: return OpcodeJSONStateUpdateEncoder(pathHasher: PathHasher(pathHashes: pathHashes))
        case .messagePack: return OpcodeMessagePackStateUpdateEncoder(pathHasher: PathHasher(pathHashes: pathHashes))
        }
    }

    /// The payload as Foundation values (`[opcode, patch...]`).
    func payload(_ data: Data) throws -> [Any] {
        switch self {
        case .json: return try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
        case .messagePack: return try #require(try unpack(data).slotOrderFoundationValue() as? [Any])
        }
    }
}

@Suite("Dynamic-key slots are independent of patch order")
struct DynamicKeySlotOrderTests {
    @Test("Keys first seen in one frame get their slots in byte order, whatever the patch order", arguments: DynamicKeySlotFormat.allCases)
    func slotsFollowKeyOrder(format: DynamicKeySlotFormat) throws {
        let frames: [[StatePatch]] = [
            [score("zed", 2), score("amy", 3), StatePatch(path: "/rooms/r9/seats/bea", operation: .set(.string("x")))],
            [score("amy", 4), score("cat", 5), score("bob", 6)],
        ]
        var slotsByOrder: [[String: Int]] = []
        var sizesByOrder: [[Int]] = []
        for reversed in [false, true] {
            let encoder = format.encoder()
            var slots: [String: Int] = [:]
            var sizes: [Int] = []
            for frame in frames {
                let patches = reversed ? Array(frame.reversed()) : frame
                let data = try encoder.encode(update: .diff(patches), landID: "land", playerID: player)
                sizes.append(data.count)
                slots.merge(definedSlots(try format.payload(data)), uniquingKeysWith: { first, _ in first })
            }
            slotsByOrder.append(slots)
            sizesByOrder.append(sizes)
        }
        // Frame 1's new keys amy, bea, r9, zed (byte order); frame 2's bob, cat. Every new key is
        // still defined on its first use.
        let expected = ["amy": 0, "bea": 1, "r9": 2, "zed": 3, "bob": 4, "cat": 5]
        #expect(slotsByOrder[0] == expected)
        #expect(slotsByOrder[1] == expected)
        #expect(sizesByOrder[0] == sizesByOrder[1])
    }

    @Test("A frame still decodes to its patches with order-independent slots", arguments: DynamicKeySlotFormat.allCases)
    func roundTrip(format: DynamicKeySlotFormat) throws {
        let encoder = format.encoder()
        let hasher = PathHasher(pathHashes: pathHashes)
        let frames: [StateUpdate] = [
            .diff([score("zed", 2), score("amy", 3)]),
            .diff([score("amy", 4), score("zed", 5), score("bob", 6)]),
        ]
        // One decoder across the frames, as a client keeps its slot table. MessagePack payloads go
        // through their JSON form: the decoder reads the same array either way.
        let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: hasher)
        var decoded: [StateUpdate] = []
        for frame in frames {
            let data = try encoder.encode(update: frame, landID: "land", playerID: player)
            let json = try JSONSerialization.data(withJSONObject: try format.payload(data))
            decoded.append(try decoder.decode(data: json).update)
        }
        #expect(decoded == frames)
    }

    @Test("Two new keys at the 127/128 slot boundary: the same MessagePack size in either patch order")
    func sizeAtFixintBoundary() throws {
        // 127 keys take slots 0...126, then "a" and "b" are new in one frame. A later frame uses
        // "b" three times: slot 127 is a 1-byte fixint and 128 a 2-byte uint8, so with first-use
        // slots the two patch orders differed by 3 bytes there.
        let filler = (0 ..< 127).map { score(String(format: "k%03d", $0), 7) }
        let later: [StatePatch] = [
            score("b", 8),
            StatePatch(path: "/rooms/b/seats/b", operation: .set(.string("x"))),
        ]
        var sizes: [[Int]] = []
        for reversed in [false, true] {
            let encoder = DynamicKeySlotFormat.messagePack.encoder()
            let newKeys = [score("a", 2), score("b", 3)]
            var run: [Int] = []
            for frame in [filler, reversed ? Array(newKeys.reversed()) : newKeys, later] {
                run.append(try encoder.encode(update: .diff(frame), landID: "land", playerID: player).count)
            }
            sizes.append(run)
        }
        #expect(sizes[0] == sizes[1], "\(sizes)")
    }
}

private extension MessagePackValue {
    /// JSON-like Foundation values (numbers as `NSNumber`), the shape `JSONSerialization` gives.
    func slotOrderFoundationValue() -> Any {
        switch self {
        case .nil: return NSNull()
        case .bool(let b): return NSNumber(value: b)
        case .int(let i): return NSNumber(value: i)
        case .uint(let u): return NSNumber(value: u)
        case .float(let f): return NSNumber(value: f)
        case .double(let d): return NSNumber(value: d)
        case .string(let s): return s
        case .binary(let b): return b
        case .array(let a): return a.map { $0.slotOrderFoundationValue() }
        case .map(let m):
            return Dictionary(
                m.map { (String(describing: $0.key.slotOrderFoundationValue()), $0.value.slotOrderFoundationValue()) },
                uniquingKeysWith: { first, _ in first }
            )
        case .extended(_, let d): return d
        }
    }
}
