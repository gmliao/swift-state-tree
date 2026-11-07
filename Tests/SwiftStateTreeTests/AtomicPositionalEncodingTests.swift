// Tests/SwiftStateTreeTests/AtomicPositionalEncodingTests.swift
//
// Atomic values on the wire (atomic values PR 2): the opcode encoders send a value at an atomic
// path as the array of its leaves, nested values too; the logical form stays keyed.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack
@testable import SwiftStateTreeTransport
import SwiftStateTreeDeterministicMath

private let table = AtomicLayoutTable.forState(AtomicLayoutState.self)

/// int32-sized coordinates (70.0 → 70000), so MessagePack sizes are exact: 5 B per leaf.
private let position = Position2(v: IVec2(x: 70, y: -80))
private let rotation = Angle(degrees: 90.5)

private func snapshot(_ value: some SnapshotValueConvertible) throws -> SnapshotValue {
    try value.toSnapshotValue()
}

private func unitValue() throws -> SnapshotValue {
    .object(["position": try snapshot(position), "rotation": try snapshot(rotation), "hp": .int(7)])
}

private let pathHashes: [String: UInt32] = [
    "units": 400, "units.*": 401, "units.*.position": 402, "units.*.rotation": 403, "units.*.hp": 404,
    "target": 405, "plain": 406, "plain.*": 407, "marker": 408, "velocity": 409,
]

/// One update with every case: a value at an atomic path, an optional (value and null), a unit
/// added with atomic fields inside, a whole map, an undeclared `{x, y}` and a nested atomic type.
private func patches() throws -> [StatePatch] {
    [
        StatePatch(path: "/units/3/position", operation: .set(try snapshot(position))),
        StatePatch(path: "/units/3/rotation", operation: .set(try snapshot(rotation))),
        StatePatch(path: "/target", operation: .set(try snapshot(position))),
        StatePatch(path: "/target", operation: .set(.null)),
        StatePatch(path: "/units/4", operation: .add(try unitValue())),
        StatePatch(path: "/units", operation: .set(.object(["5": try unitValue(), "6": try unitValue()]))),
        StatePatch(path: "/plain/a", operation: .set(.object(["x": .int(70000), "y": .int(-80000)]))),
        StatePatch(path: "/marker", operation: .set(try snapshot(Marker(origin: IVec2(x: 70, y: 80), radius: 90000, label: "m")))),
        StatePatch(path: "/units/3", operation: .delete),
    ]
}

private let player = PlayerID("p1")

private func toAny(_ value: MessagePackValue) -> Any {
    switch value {
    case .nil: return NSNull()
    case .bool(let b): return NSNumber(value: b)
    case .int(let i): return NSNumber(value: i)
    case .uint(let u): return NSNumber(value: u)
    case .float(let f): return NSNumber(value: f)
    case .double(let d): return NSNumber(value: d)
    case .string(let s): return s
    case .binary(let b): return b
    case .array(let a): return a.map(toAny)
    case .map(let m):
        var result: [String: Any] = [:]
        for (k, v) in m { if case .string(let key) = k { result[key] = toAny(v) } }
        return result
    case .extended: return NSNull()
    }
}

/// Decodes either opcode encoding with the Swift decoder (MessagePack through its JSON-like values).
private func decode(_ data: Data, messagePack: Bool, hashed: Bool) throws -> [StatePatch] {
    let decoder = OpcodeJSONStateUpdateDecoder(
        pathHasher: hashed ? PathHasher(pathHashes: pathHashes) : nil, atomicLayout: table
    )
    let json = messagePack
        ? try JSONSerialization.data(withJSONObject: toAny(try unpack(data)))
        : data
    switch try decoder.decode(data: json).update {
    case .diff(let patches), .firstSync(let patches): return patches
    case .noChange: return []
    }
}

private func encoders(hashed: Bool) -> [(name: String, messagePack: Bool, encoder: any StateUpdateEncoder)] {
    let hasher = hashed ? PathHasher(pathHashes: pathHashes) : nil
    return [
        ("opcodeJSON", false, OpcodeJSONStateUpdateEncoder(pathHasher: hasher, atomicLayout: table)),
        ("messagePack", true, OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher, atomicLayout: table)),
    ]
}

@Suite("Atomic values: positional encoding")
struct AtomicPositionalEncodingTests {
    @Test("A value at an atomic path is the array of its leaves, in leaf order")
    func atomicPathIsPositional() throws {
        #expect(try table.positional(try snapshot(position), atPath: "/units/3/position") == .array([.int(70000), .int(-80000)]))
        #expect(try table.positional(try snapshot(rotation), atPath: "/units/3/rotation") == .array([.int(90500)]))
        #expect(try table.positional(.null, atPath: "/target") == .null)
        // A nested atomic type contributes its leaves in declaration order.
        let marker = try snapshot(Marker(origin: IVec2(x: 70, y: 80), radius: 90000, label: "m"))
        #expect(try table.positional(marker, atPath: "/marker") == .array([.int(70000), .int(80000), .int(90000), .string("m")]))
        // Not declared atomic: keyed, whatever its shape.
        let plain = SnapshotValue.object(["x": .int(70000), "y": .int(-80000)])
        #expect(try table.positional(plain, atPath: "/plain/a") == plain)
    }

    @Test("Atomic values inside an added unit and a whole map are positional too")
    func nestedValuesArePositional() throws {
        let expectedUnit = SnapshotValue.object([
            "position": .array([.int(70000), .int(-80000)]), "rotation": .array([.int(90500)]), "hp": .int(7),
        ])
        #expect(try table.positional(try unitValue(), atPath: "/units/4") == expectedUnit)
        #expect(try table.positional(.object(["5": try unitValue()]), atPath: "/units") == .object(["5": expectedUnit]))
    }

    @Test("An object at an atomic path without exactly its declared leaves is not encodable")
    func wrongKeysThrow() throws {
        for bad: SnapshotValue in [
            .object(["v": .object(["x": .int(7)])]),
            .object(["v": .object(["x": .int(7), "y": .int(8), "z": .int(9)])]),
            .object(["v": .object(["x": .int(7), "why": .int(8)])]),
            .object(["v": .object(["x": .int(7), "y": .array([])])]),
            .int(7),
        ] {
            #expect(throws: AtomicPositionalFormError.self) { try table.positional(bad, atPath: "/target") }
        }
    }

    @Test("keyed(_:atPath:) inverts positional, accepts keyed values, rejects a wrong length")
    func keyedInvertsPositional() throws {
        for patch in try patches() {
            guard let value = patch.operation.value else { continue }
            let wire = try table.positional(value, atPath: patch.path)
            #expect(try table.keyed(wire, atPath: patch.path) == value, "\(patch.path)")
            #expect(try table.keyed(value, atPath: patch.path) == value, "keyed in: \(patch.path)")
        }
        #expect(throws: AtomicPositionalFormError.self) { try table.keyed(.array([.int(7)]), atPath: "/target") }
        #expect(throws: AtomicPositionalFormError.self) {
            try table.keyed(.array([.int(7), .array([])]), atPath: "/target")
        }
    }

    @Test("Both opcode encodings, with and without path hashes, round trip through the Swift decoder")
    func encodersRoundTrip() throws {
        let original = try patches()
        for hashed in [false, true] {
            for (name, messagePack, encoder) in encoders(hashed: hashed) {
                for update in [StateUpdate.diff(original), .firstSync(original)] {
                    let data = try encoder.encode(update: update, landID: "land", playerID: player)
                    #expect(try decode(data, messagePack: messagePack, hashed: hashed) == original, "\(name) hashed=\(hashed)")
                }
            }
        }
    }

    @Test("A Position2 patch value is 11 B and an Angle 6 B in MessagePack")
    func messagePackSizes() throws {
        let encoder = OpcodeMessagePackStateUpdateEncoder(pathHasher: PathHasher(pathHashes: pathHashes), atomicLayout: table)
        let keyed = OpcodeMessagePackStateUpdateEncoder(pathHasher: PathHasher(pathHashes: pathHashes))
        func size(_ path: String, _ value: SnapshotValue, _ encoder: OpcodeMessagePackStateUpdateEncoder) throws -> Int {
            let payload = try encoder.encodeToMessagePackArray(
                update: .diff([StatePatch(path: path, operation: .set(value))]),
                landID: "land", playerID: player, playerSlot: nil, scope: .perPlayer
            )
            guard case .array(let patch) = payload[1], let last = patch.last else { return -1 }
            return try pack(last).count
        }
        #expect(try size("/units/3/position", try snapshot(position), encoder) == 11)
        #expect(try size("/units/3/rotation", try snapshot(rotation), encoder) == 6)
        #expect(try size("/units/3/position", try snapshot(position), keyed) == 18, "keyed, as before")
        #expect(try size("/units/3/rotation", try snapshot(rotation), keyed) == 14, "keyed, as before")
    }

    @Test("A patch value that isn't encodable fails the encode instead of being sent")
    func unencodablePatchThrows() throws {
        let bad = [StatePatch(path: "/target", operation: .set(.object(["v": .object(["x": .int(7)])])))]
        for hashed in [false, true] {
            for (name, _, encoder) in encoders(hashed: hashed) {
                #expect(throws: AtomicPositionalFormError.self, "\(name)") {
                    try encoder.encode(update: .diff(bad), landID: "land", playerID: player)
                }
            }
        }
    }

    @Test("The keyed switch and an encoder without a table send keyed values")
    func keyedSwitch() throws {
        let value = try snapshot(position)
        let update = StateUpdate.diff([StatePatch(path: "/target", operation: .set(value))])
        for stateUpdate in [StateUpdateEncoding.opcodeJsonArray, .opcodeMessagePack] {
            let keyedConfig = TransportEncodingConfig(message: .opcodeJsonArray, stateUpdate: stateUpdate, atomicValues: .keyed)
            let positionalConfig = keyedConfig.withAtomicValues(.positional)
            #expect(positionalConfig.atomicValues == .positional)
            let keyedEncoder = keyedConfig.makeStateUpdateEncoder(warnIfMissingPathHashes: false, atomicLayout: table)
            let positionalEncoder = positionalConfig.makeStateUpdateEncoder(warnIfMissingPathHashes: false, atomicLayout: table)
            let messagePack = stateUpdate == .opcodeMessagePack
            let plainDecoder = OpcodeJSONStateUpdateDecoder()
            func wireValue(_ data: Data) throws -> SnapshotValue? {
                let json = messagePack ? try JSONSerialization.data(withJSONObject: toAny(try unpack(data))) : data
                guard case .diff(let patches) = try plainDecoder.decode(data: json).update else { return nil }
                return patches.first?.operation.value
            }
            #expect(try wireValue(keyedEncoder.encode(update: update, landID: "land", playerID: player)) == value)
            #expect(try wireValue(positionalEncoder.encode(update: update, landID: "land", playerID: player))
                == .array([.int(70000), .int(-80000)]))
        }
        #expect(TransportEncodingConfig().atomicValues == .positional, "positional by default")
    }
}

private extension PatchOperation {
    var value: SnapshotValue? {
        switch self {
        case .set(let value), .add(let value): return value
        case .delete: return nil
        }
    }
}
