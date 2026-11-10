// Tests/SwiftStateTreeTransportTests/RowEntryTests.swift
//
// Row entries (`RowPatchOpcode`, ops 6 to 9): the opcode encoders write a patch the typed diff
// tagged with its row as a create, a delete, a column set or a column clear, and the Swift
// decoder reads them back as the patches today's entries carry. Nothing in a server turns this
// on yet: the encoders are switched here with `withRowAddressing()`.
//
// The golden frames are in `Fixtures/RowAddressing/row-addressing-frames.json`.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeMessagePack

enum RowEntryFixtureEnvKeys {
    /// Set to `1` to rewrite the fixture instead of checking it.
    static let regenerate = "SST_REGENERATE_ROW_ADDRESSING_FRAMES"
}

/// A value that isn't `Equatable`: its field takes the fallback diff. Its object has no `n` at
/// 0, so the leaf `blob.n` can be removed: the one way a leaf inside a row is deleted (an
/// optional going nil is a set of null).
struct RowEntryBlob: Sendable, SnapshotValueConvertible {
    var n: Int = 0

    func toSnapshotValue() throws -> SnapshotValue {
        .object(n == 0 ? [:] : ["n": .int(n)])
    }
}

@StateNodeBuilder
struct RowEntryPart: StateNodeProtocol {
    @Sync(.broadcast) var v: Int = 0

    public init() {}
}

/// A row with every shape section 3 of the plan lists.
@StateNodeBuilder
struct RowEntryUnit: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.broadcast) var note: String? = nil
    @Sync(.broadcast) var tags: [String] = []
    @Sync(.broadcast) var core: RowEntryPart = RowEntryPart()
    @Sync(.broadcast) var bag: [String: Int] = [:]
    @Sync(.broadcast) var parts: [String: RowEntryPart] = [:]
    @Sync(.broadcast) var blob: RowEntryBlob = RowEntryBlob()

    public init() {}
}

@StateNodeBuilder
struct RowEntryState: StateNodeProtocol {
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var units: [String: RowEntryUnit] = [:]
    @Sync(.broadcast) var scores: [String: Int] = [:]

    public init() {}
}

private let rowEntryPatterns = [
    "round", "scores", "scores.*", "units", "units.*", "units.*.hp", "units.*.note", "units.*.tags",
    "units.*.core", "units.*.core.v", "units.*.bag", "units.*.bag.*", "units.*.parts", "units.*.parts.*",
    "units.*.parts.*.v", "units.*.blob", "units.*.blob.n",
]
private let rowEntryHashes = Dictionary(uniqueKeysWithValues: rowEntryPatterns.map { ($0, DeterministicHash.fnv1a32($0)) })

/// One step of the script: a change to the state, sent as one frame.
private struct RowEntryStep {
    let name: String
    let change: @Sendable (inout RowEntryState) -> Void
}

private let rowEntrySteps: [RowEntryStep] = [
    RowEntryStep(name: "three rows created, one with an empty key") { state in
        state.round = 1
        for key in ["b", "", "a/b"] {
            state.units[key] = RowEntryUnit()
        }
        state.units["b"]?.hp = 2
    },
    RowEntryStep(name: "one leaf in two rows, a root value and a value map entry") { state in
        state.round = 2
        state.scores["p"] = 5
        state.units["b"]?.hp = 3
        state.units["a/b"]?.hp = 4
    },
    RowEntryStep(name: "an optional set, a nested node's field, an array and a fallback field") { state in
        state.units["b"]?.note = "n"
        state.units[""]?.note = "m"
        state.units["b"]?.core.v = 7
        state.units["b"]?.tags = ["x", "y"]
        state.units["a/b"]?.blob.n = 9
    },
    RowEntryStep(name: "a column clear next to a column set of the same leaf") { state in
        state.units["a/b"]?.blob.n = 0
        state.units["b"]?.blob.n = 4
    },
    RowEntryStep(name: "a value map and a nested node map inside a row keep today's entries") { state in
        state.units["b"]?.bag["k"] = 1
        state.units["b"]?.parts["p"] = RowEntryPart()
        state.units["b"]?.hp = 5
        // An optional going nil is a set of null, as today: a column set, not a clear.
        state.units["b"]?.note = nil
    },
    RowEntryStep(name: "a delete, a create that does not take its slot, and a column") { state in
        state.units[""] = nil
        state.units["c"] = RowEntryUnit()
        state.units["b"]?.hp = 6
    },
    RowEntryStep(name: "the freed slot taken again, with the next generation") { state in
        state.units["d"] = RowEntryUnit()
        state.units["d"]?.hp = 1
    },
    RowEntryStep(name: "every row deleted") { state in
        state.units = [:]
    },
]

/// The script's frames: the typed diff's patches for each step, with their row tags.
private struct RowEntryScript {
    let hasher = PathHasher(pathHashes: rowEntryHashes)
    let frames: [(name: String, patches: [StatePatch], slots: [String: SyncRowSlotForTesting])]

    init() {
        let tables = SyncTableBroadcastDiff<RowEntryState>(pathCursor: hasher.rootCursor)
        var drops = ExtractionDrops()
        var state = RowEntryState()
        // Seeded empty: every row then arrives as a create.
        tables.seed(state, drops: &drops)
        var frames: [(String, [StatePatch], [String: SyncRowSlotForTesting])] = []
        for step in rowEntrySteps {
            step.change(&state)
            let result = tables.diff(state, fields: nil, drops: &drops)
            tables.apply(result.staged)
            frames.append((step.name, result.patches, tables.rowSlotsForTesting("units") ?? [:]))
        }
        precondition(drops.count == 0)
        self.frames = frames
    }

    func jsonEncoder(rows: Bool) -> OpcodeJSONStateUpdateEncoder {
        OpcodeJSONStateUpdateEncoder(pathHasher: hasher, pathIndex: true, fieldMerge: FieldMergeTable(pathHashes: rowEntryHashes))
            .withRowAddressing(rows)
    }

    func messagePackEncoder(rows: Bool) -> OpcodeMessagePackStateUpdateEncoder {
        OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher, pathIndex: true, fieldMerge: FieldMergeTable(pathHashes: rowEntryHashes))
            .withRowAddressing(rows)
    }

    func decoder() -> OpcodeJSONStateUpdateDecoder {
        OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: true)
    }
}

private let player = PlayerID("p1")

private func byPath(_ patches: [StatePatch]) -> [StatePatch] {
    patches.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
}

private func patches(_ decoded: DecodedStateUpdate?) -> [StatePatch] {
    switch decoded?.update {
    case .diff(let patches), .firstSync(let patches): return patches
    default: return []
    }
}

/// The entries of a JSON frame after its opcode, as (op, second element).
private func entries(_ frame: Data) throws -> [(id: Int, second: Any, op: Int, entry: [Any])] {
    let array = try #require(try JSONSerialization.jsonObject(with: frame) as? [Any])
    return try array.dropFirst().map { raw in
        let entry = try #require(raw as? [Any])
        return (try #require(entry[0] as? Int), entry[1], try #require(entry[2] as? Int), entry)
    }
}

@Suite("Row entries: the encoders and the Swift decoder")
struct RowEntryTests {
    @Test("Each frame decodes to the patches of the same frame without row entries, in both formats, and the row tables are the server's")
    func decodesToTheSamePatches() throws {
        let script = RowEntryScript()
        let jsonOn = script.jsonEncoder(rows: true), jsonOff = script.jsonEncoder(rows: false)
        let packOn = script.messagePackEncoder(rows: true), packOff = script.messagePackEncoder(rows: false)
        let decoders = (jsonOn: script.decoder(), jsonOff: script.decoder(), packOn: script.decoder(), packOff: script.decoder())
        var rowOps = Set<Int>()
        for frame in script.frames {
            let update = StateUpdate.diff(frame.patches)
            let on = try jsonOn.encode(update: update, landID: "rows", playerID: player)
            let off = try jsonOff.encode(update: update, landID: "rows", playerID: player)
            let expected = byPath(patches(try decoders.jsonOff.decodeFrame(off, format: .json)))
            #expect(byPath(patches(try decoders.jsonOn.decodeFrame(on, format: .json))) == expected, "\(frame.name): JSON")
            rowOps.formUnion(try entries(on).map(\.op).filter { $0 >= 6 })

            let packedOn = try packOn.encode(update: update, landID: "rows", playerID: player)
            let packedOff = try packOff.encode(update: update, landID: "rows", playerID: player)
            let expectedPacked = byPath(patches(try decoders.packOff.decodeFrame(packedOff, format: .messagePack)))
            #expect(byPath(patches(try decoders.packOn.decodeFrame(packedOn, format: .messagePack))) == expectedPacked, "\(frame.name): MessagePack")
            #expect(expectedPacked == expected, "\(frame.name): the two formats carry the same patches")

            // Slot, key and generation, as the server's table holds them.
            for decoder in [decoders.jsonOn, decoders.packOn] {
                let bound = decoder.boundRows(ofPattern: "units.*")
                var server: [Int: String] = [:]
                var generations: [Int: UInt32] = [:]
                for (key, row) in frame.slots {
                    server[Int(row.slot)] = SyncEngine.escapedPathComponent(key)
                    generations[Int(row.slot)] = row.generation
                }
                #expect(bound.mapValues(\.key) == server, "\(frame.name)")
                #expect(bound.mapValues(\.generation) == generations, "\(frame.name)")
            }
            #expect(decoders.jsonOff.boundRows(ofPattern: "units.*").isEmpty)
        }
        #expect(rowOps == [6, 7, 8, 9], "the script has every row entry")
    }

    @Test("A frame's order: today's entries, then per table creates by slot, columns by leaf then slot, deletes by slot")
    func entryOrderAndForms() throws {
        let script = RowEntryScript()
        let encoder = script.jsonEncoder(rows: true)
        var frames: [String: [(id: Int, second: Any, op: Int, entry: [Any])]] = [:]
        for frame in script.frames {
            frames[frame.name] = try entries(try encoder.encode(update: .diff(frame.patches), landID: "rows", playerID: player))
        }
        func index(_ pattern: String) throws -> Int {
            let hash = try #require(rowEntryHashes[pattern])
            return try #require(script.hasher.pathIndex(of: hash))
        }
        let table = try index("units.*")

        // Creates: slots 0, 1, 2 in the keys' byte order ("" < "a~1b" < "b"), whole rows.
        let created = try #require(frames["three rows created, one with an empty key"])
        #expect(created.map(\.op) == [1, 6, 6, 6], "the root value first")
        #expect(created.dropFirst().map(\.id) == [table, table, table])
        #expect(created.dropFirst().map { $0.second as? Int } == [0, 1, 2])
        #expect(created.dropFirst().map { $0.entry[5] as? String } == ["", "a~1b", "b"])
        for create in created.dropFirst() {
            #expect(create.entry.count == 7)
            #expect(create.entry[3] as? Int == 0, "generation")
            #expect(create.entry[4] is NSNull, "no parent slot")
            #expect(create.entry[6] is [String: Any], "the whole row")
        }

        // One column for the leaf, slots ascending, after today's entries.
        let column = try #require(frames["one leaf in two rows, a root value and a value map entry"])
        #expect(column.map(\.op) == [1, 1, 8])
        let hp = try #require(column.last)
        #expect(hp.id == (try index("units.*.hp")))
        #expect(hp.second as? [Int] == [1, 2])
        #expect(hp.entry[3] as? [Int] == [4, 3], "values in slot order")

        // A leaf's set comes before its clear.
        let cleared = try #require(frames["a column clear next to a column set of the same leaf"])
        #expect(cleared.map(\.op) == [8, 9])
        #expect(cleared.map(\.id) == [try index("units.*.blob.n"), try index("units.*.blob.n")])
        #expect(cleared[0].second as? [Int] == [2] && cleared[1].second as? [Int] == [1])
        #expect(cleared[1].entry.count == 3)

        // Columns in the order of their path ids; a fallback field, an array and a nested
        // node's field are columns.
        let mixed = try #require(frames["an optional set, a nested node's field, an array and a fallback field"])
        #expect(mixed.allSatisfy { $0.op == 8 })
        #expect(mixed.map(\.id) == mixed.map(\.id).sorted())
        #expect(Set(mixed.map(\.id)) == Set(try ["units.*.note", "units.*.core.v", "units.*.tags", "units.*.blob.n"].map(index)))

        // Two dynamic keys: today's entries, before the row's column.
        let nested = try #require(frames["a value map and a nested node map inside a row keep today's entries"])
        let columns = nested.filter { $0.op >= 6 }
        #expect(columns.map(\.op) == [8, 8])
        #expect(nested.prefix(nested.count - 2).allSatisfy { $0.op < 6 } && nested.count >= 4)
        let note = try #require(columns.first { $0.id == (try? index("units.*.note")) })
        #expect((note.entry[3] as? [Any])?.first is NSNull, "nil is a set of null")

        // Creates, columns, deletes; the create is past the end, not in the deleted row's slot.
        let replaced = try #require(frames["a delete, a create that does not take its slot, and a column"])
        #expect(replaced.map(\.op) == [6, 8, 7])
        #expect(replaced[0].second as? Int == 3)
        #expect(replaced[2].second as? Int == 0 && replaced[2].entry.count == 3)

        // The freed slot again: generation 1.
        let reused = try #require(frames["the freed slot taken again, with the next generation"])
        #expect(reused.map(\.op) == [6])
        #expect(reused[0].second as? Int == 0 && reused[0].entry[3] as? Int == 1)

        let emptied = try #require(frames["every row deleted"])
        #expect(emptied.map(\.op) == [7, 7, 7, 7])
        #expect(emptied.map { $0.second as? Int } == [0, 1, 2, 3])
    }

    @Test("Without row addressing, and for patches without a row tag, the frames are today's bytes")
    func offAndUntaggedAreUnchanged() throws {
        let script = RowEntryScript()
        for frame in script.frames {
            let update = StateUpdate.diff(frame.patches)
            // The tags alone change nothing.
            let untagged = StateUpdate.diff(frame.patches.map { StatePatch(path: $0.path, operation: $0.operation) })
            #expect(
                try script.jsonEncoder(rows: false).encode(update: update, landID: "rows", playerID: player)
                    == script.jsonEncoder(rows: false).encode(update: untagged, landID: "rows", playerID: player),
                "\(frame.name)"
            )
            // With the switch on, a patch without a tag is today's entry.
            #expect(
                try script.jsonEncoder(rows: true).encode(update: untagged, landID: "rows", playerID: player)
                    == script.jsonEncoder(rows: false).encode(update: untagged, landID: "rows", playerID: player),
                "\(frame.name)"
            )
            #expect(
                try script.messagePackEncoder(rows: true).encode(update: untagged, landID: "rows", playerID: player)
                    == script.messagePackEncoder(rows: false).encode(update: untagged, landID: "rows", playerID: player),
                "\(frame.name)"
            )
        }
    }

    @Test("A tag from another hasher's trie is not taken")
    func foreignTag() throws {
        let script = RowEntryScript()
        let other = PathHasher(pathHashes: rowEntryHashes)
        let frame = script.frames[1]
        let encoder = OpcodeJSONStateUpdateEncoder(pathHasher: other, pathIndex: true).withRowAddressing()
        let ops = try entries(try encoder.encode(update: .diff(frame.patches), landID: "rows", playerID: player)).map(\.op)
        #expect(ops.allSatisfy { $0 < 6 })
    }

    @Test("The decoder is strict about slots and generations")
    func strictRules() throws {
        let hasher = PathHasher(pathHashes: rowEntryHashes)
        func index(_ pattern: String) -> Int { hasher.pathIndex(of: rowEntryHashes[pattern]!)! }
        let table = index("units.*"), hp = index("units.*.hp")
        func frame(_ entries: String...) -> Data { Data("[2,\(entries.joined(separator: ","))]".utf8) }
        func create(_ slot: Int, generation: Int, key: String = "k") -> String {
            "[\(table),\(slot),6,\(generation),null,\"\(key)\",{\"hp\":1}]"
        }
        func fails(_ data: Data, after setup: [Data] = [], _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: true)
            for data in setup {
                #expect(throws: Never.self, sourceLocation: sourceLocation) { _ = try decoder.decodeFrame(data, format: .json) }
            }
            do {
                _ = try decoder.decodeFrame(data, format: .json)
                Issue.record("accepted: \(message)", sourceLocation: sourceLocation)
            } catch StateUpdateDecodingError.invalidPayload(let text) {
                #expect(text.contains(message), "\(text)", sourceLocation: sourceLocation)
            } catch {
                Issue.record("\(error)", sourceLocation: sourceLocation)
            }
        }
        let bound = frame(create(0, generation: 0))
        fails(frame("[\(hp),[0],8,[1]]"), "unbound slot")
        fails(frame("[\(hp),[0],9]"), "unbound slot")
        fails(frame("[\(table),0,7]"), "unbound slot")
        fails(frame(create(0, generation: 1)), after: [bound], "bound slot")
        // Deleted, then created again: the generation must go up.
        let deleted = frame("[\(table),0,7]")
        fails(frame(create(0, generation: 0)), after: [bound, deleted], "generation 0 after 0")
        fails(frame("[\(hp),[1,0],8,[1,2]]"), after: [bound, frame(create(1, generation: 0, key: "j"))], "not ascending")
        fails(frame("[\(hp),[0],8,[1,2]]"), after: [bound], "1 slots for 2 values")
        fails(frame("[\(hp),0,6,0,null,\"k\",1]"), "without a slot")
        fails(frame("[\(table),[0],8,[1]]"), after: [bound], "Invalid column set")
        fails(frame("[\(index("units.*.bag.*")),[0],8,[1]]"), after: [bound], "not a row or a leaf")
        fails(frame("[\(table),0,7,1]"), after: [bound], "must not include a value")

        // Numbers that are not a slot, a generation or an op are refused, not rounded: a
        // fraction, a negative number, a boolean, a number past the range.
        for slot in ["0.5", "-1", "true", "2147483648", "\"0\"", "[0]", "0.0000000000000000001"] {
            fails(frame("[\(table),\(slot),7]"), after: [bound], "without a slot")
            fails(frame("[\(table),\(slot),6,0,null,\"k\",{\"hp\":1}]"), "without a slot")
        }
        for slots in ["[0.5]", "[-1]", "[true]", "[0,1.5]"] {
            fails(frame("[\(hp),\(slots),8,[1]]"), after: [bound], "not ascending integers")
            fails(frame("[\(hp),\(slots),9]"), after: [bound], "not ascending integers")
        }
        for generation in ["0.5", "-1", "true", "4294967296", "1.0000000000000000001"] {
            fails(frame("[\(table),0,6,\(generation),null,\"k\",{\"hp\":1}]"), "Invalid row create")
        }
        // A fractional op is no row op: the entry is read as today's, and refused there.
        for op in ["7.5", "6.5", "7.0000000000000000001"] {
            let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: true)
            _ = try decoder.decodeFrame(bound, format: .json)
            #expect(throws: (any Error).self) { _ = try decoder.decodeFrame(frame("[\(table),0,\(op)]"), format: .json) }
            #expect(decoder.boundRows(ofPattern: "units.*").keys.sorted() == [0], "op \(op) left the row bound")
        }
        // The same checks hold behind the MessagePack front.
        func packedFails(_ slot: MessagePackValue, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: true)
            _ = try decoder.decodeFrame(
                try pack(.array([.int(2), .array([.int(Int64(table)), .int(0), .int(6), .int(0), .nil, .string("k"), .map([.string("hp"): .int(1)])])])),
                format: .messagePack
            )
            do {
                _ = try decoder.decodeFrame(try pack(.array([.int(2), .array([.int(Int64(table)), slot, .int(7)])])), format: .messagePack)
                Issue.record("accepted: \(slot)", sourceLocation: sourceLocation)
            } catch StateUpdateDecodingError.invalidPayload(let text) {
                #expect(text.contains(message), "\(text)", sourceLocation: sourceLocation)
            }
            #expect(decoder.boundRows(ofPattern: "units.*").keys.sorted() == [0], sourceLocation: sourceLocation)
        }
        try packedFails(.double(0.5), "without a slot")
        try packedFails(.float(0.5), "without a slot")
        try packedFails(.int(-1), "without a slot")
        try packedFails(.bool(false), "without a slot")
        // A fractional generation or op behind the same front.
        let packedDecoder = OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: true)
        func packedEntry(generation: MessagePackValue, op: MessagePackValue) throws -> Data {
            try pack(.array([.int(2), .array([.int(Int64(table)), .int(0), op, generation, .nil, .string("k"), .map([.string("hp"): .int(1)])])]))
        }
        #expect(throws: (any Error).self) {
            _ = try packedDecoder.decodeFrame(try packedEntry(generation: .double(0.5), op: .int(6)), format: .messagePack)
        }
        #expect(throws: (any Error).self) {
            _ = try packedDecoder.decodeFrame(try packedEntry(generation: .int(0), op: .double(6.5)), format: .messagePack)
        }
        #expect(packedDecoder.boundRows(ofPattern: "units.*").isEmpty)

        // Accepted: a higher generation after a delete, and a slot never seen with any generation.
        let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: true)
        _ = try decoder.decodeFrame(bound, format: .json)
        _ = try decoder.decodeFrame(deleted, format: .json)
        _ = try decoder.decodeFrame(frame(create(0, generation: 1), create(5, generation: 9, key: "late")), format: .json)
        #expect(decoder.boundRows(ofPattern: "units.*").mapValues(\.generation) == [0: 1, 5: 9])
    }

    @Test("A resync clears the rows; a firstSync keeps them and starts the scope's key table again")
    func resyncAndKeyScopes() throws {
        let hasher = PathHasher(pathHashes: rowEntryHashes)
        func index(_ pattern: String) -> Int { hasher.pathIndex(of: rowEntryHashes[pattern]!)! }
        let table = index("units.*"), hp = index("units.*.hp"), score = index("scores.*")
        let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: true, syncSequence: true)
        func decode(_ text: String) throws -> [StatePatch] {
            patches(try decoder.decodeFrame(Data(text.utf8), format: .json))
        }
        _ = try decode("[2,1,[\(table),0,6,0,null,\"k\",{\"hp\":1}],[\(score),[0,\"p\"],1,5]]")
        #expect(try decode("[2,2,[\(score),0,1,6]]").map(\.path) == ["/scores/p"])

        // A firstSync that carries a diff (a key-scope reset): keys start again, rows stay.
        #expect(try decode("[1,3,[\(hp),[0],8,[2]]]").map(\.path) == ["/units/k/hp"])
        #expect(throws: StateUpdateDecodingError.self) { _ = try decode("[2,4,[\(score),0,1,7]]") }

        // A resync: the rows are gone until its creates.
        _ = try decode("[3,5,[\(table),0,6,0,null,\"again\",{\"hp\":1}]]")
        #expect(decoder.boundRows(ofPattern: "units.*").mapValues(\.key) == [0: "again"])
        _ = try decode("[3,6]")
        #expect(decoder.boundRows(ofPattern: "units.*").isEmpty)
        #expect(throws: StateUpdateDecodingError.self) { _ = try decode("[2,7,[\(hp),[0],8,[2]]]") }
    }

    @Test("The MessagePack front: a merged frame's state update is in the broadcast scope, a state frame in the per-player one, other frames are skipped")
    func messagePackFront() throws {
        let hasher = PathHasher(pathHashes: rowEntryHashes)
        let encoder = OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher, pathIndex: true)
        let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: true)
        func set(_ path: String, _ value: Int) -> StatePatch { StatePatch(path: path, operation: .set(.int(value))) }
        func state(_ patches: [StatePatch], scope: StateUpdateKeyScope) throws -> [MessagePackValue] {
            try encoder.encodeToMessagePackArray(update: .diff(patches), landID: "rows", playerID: player, playerSlot: nil, scope: scope)
        }
        func merged(_ patches: [StatePatch]) throws -> Data {
            try pack(.array([.int(MessageKindOpcode.stateUpdateWithEvents), .array(try state(patches, scope: .broadcast)), .array([])]))
        }
        // Slot 0 is "b" in the broadcast scope and "p" in the per-player one.
        #expect(patches(try decoder.decodeFrame(try merged([set("/scores/b", 1)]), format: .messagePack)).map(\.path) == ["/scores/b"])
        let own = try pack(.array(try state([set("/scores/p", 2)], scope: .perPlayer)))
        #expect(patches(try decoder.decodeFrame(own, format: .messagePack)).map(\.path) == ["/scores/p"])
        // Each by its slot alone now.
        #expect(patches(try decoder.decodeFrame(try merged([set("/scores/b", 3)]), format: .messagePack)).map(\.path) == ["/scores/b"])
        let ownAgain = try pack(.array(try state([set("/scores/p", 4)], scope: .perPlayer)))
        let decoded = try decoder.decodeFrame(ownAgain, format: .messagePack)
        #expect(patches(decoded) == [set("/scores/p", 4)])

        // An event frame is not a state update.
        let event = try pack(.array([.int(103), .string("x")]))
        #expect(try decoder.decodeFrame(event, format: .messagePack) == nil)
    }
}

@Suite("Row entries: the golden frames")
struct RowEntryFixtureTests {
    static let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/RowAddressing/row-addressing-frames.json").path

    /// The script's frames as one stream per format: a decoder reads them in order, since the
    /// row tables and the key tables carry over. `plain` frames are the same patches without row
    /// entries, from encoders of their own.
    static func fixture() throws -> Data {
        let script = RowEntryScript()
        let jsonOn = script.jsonEncoder(rows: true), jsonOff = script.jsonEncoder(rows: false)
        let packOn = script.messagePackEncoder(rows: true), packOff = script.messagePackEncoder(rows: false)
        var frames: [[String: AnyCodable]] = []
        for frame in script.frames {
            let update = StateUpdate.diff(frame.patches)
            func text(_ encoder: OpcodeJSONStateUpdateEncoder) throws -> AnyCodable {
                AnyCodable(String(decoding: try encoder.encode(update: update, landID: "rows", playerID: player), as: UTF8.self))
            }
            func base64(_ encoder: OpcodeMessagePackStateUpdateEncoder) throws -> AnyCodable {
                AnyCodable(try encoder.encode(update: update, landID: "rows", playerID: player).base64EncodedString())
            }
            let slots = frame.slots.map { key, row in
                AnyCodable(["key": AnyCodable(key), "slot": AnyCodable(Int(row.slot)), "generation": AnyCodable(Int(row.generation))])
            }
            frames.append([
                "name": AnyCodable(frame.name),
                "jsonFrame": try text(jsonOn),
                "messagePackFrame": try base64(packOn),
                "plainJsonFrame": try text(jsonOff),
                "plainMessagePackFrame": try base64(packOff),
                // The table after the frame, by slot.
                "rows": AnyCodable(slots.sorted { lhs, rhs in
                    let l = (lhs.base as? [String: AnyCodable])?["slot"]?.base as? Int ?? 0
                    let r = (rhs.base as? [String: AnyCodable])?["slot"]?.base as? Int ?? 0
                    return l < r
                }),
            ])
        }
        let document: [String: AnyCodable] = [
            "pathHashes": AnyCodable(rowEntryHashes.mapValues { AnyCodable(Int($0)) }),
            "table": AnyCodable("units.*"),
            "frames": AnyCodable(frames.map { AnyCodable($0) }),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document) + Data("\n".utf8)
    }

    @Test("The fixture is current")
    func fixtureIsCurrent() throws {
        let data = try Self.fixture()
        if EnvHelpers.getEnvBool(key: RowEntryFixtureEnvKeys.regenerate, defaultValue: false) {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: Self.fixturePath).deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: Self.fixturePath))
            return
        }
        let committed = try Data(contentsOf: URL(fileURLWithPath: Self.fixturePath))
        #expect(data == committed, "regenerate with \(RowEntryFixtureEnvKeys.regenerate)=1")
    }

    @Test("The committed frames decode, in order, to the plain frames' patches and to the listed rows")
    func committedFramesDecode() throws {
        let committed = try Data(contentsOf: URL(fileURLWithPath: Self.fixturePath))
        let document = try #require(try JSONSerialization.jsonObject(with: committed) as? [String: Any])
        let frames = try #require(document["frames"] as? [[String: Any]])
        let hasher = PathHasher(pathHashes: rowEntryHashes)
        let decoders = (0..<4).map { _ in OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: true) }
        for frame in frames {
            let name = frame["name"] as? String ?? ""
            func text(_ key: String) throws -> Data { Data(try #require(frame[key] as? String).utf8) }
            func packed(_ key: String) throws -> Data {
                let text = try #require(frame[key] as? String)
                return try #require(Data(base64Encoded: text))
            }
            let plain = byPath(patches(try decoders[0].decodeFrame(try text("plainJsonFrame"), format: .json)))
            #expect(byPath(patches(try decoders[1].decodeFrame(try text("jsonFrame"), format: .json))) == plain, "\(name)")
            #expect(byPath(patches(try decoders[2].decodeFrame(try packed("messagePackFrame"), format: .messagePack))) == plain, "\(name)")
            #expect(byPath(patches(try decoders[3].decodeFrame(try packed("plainMessagePackFrame"), format: .messagePack))) == plain, "\(name)")
            let rows = try #require(frame["rows"] as? [[String: Any]])
            var expected: [Int: String] = [:]
            for row in rows {
                expected[try #require(row["slot"] as? Int)] = SyncEngine.escapedPathComponent(try #require(row["key"] as? String))
            }
            #expect(decoders[1].boundRows(ofPattern: "units.*").mapValues(\.key) == expected, "\(name)")
            #expect(decoders[2].boundRows(ofPattern: "units.*").mapValues(\.key) == expected, "\(name)")
        }
    }
}

// MARK: - Bytes

/// A row shaped like the game cells' monsters: a few integers and a float.
@StateNodeBuilder
struct RowEntryMonster: StateNodeProtocol {
    @Sync(.broadcast) var id: Int = 0
    @Sync(.broadcast) var health: Int = 100
    @Sync(.broadcast) var x: Int = 0
    @Sync(.broadcast) var y: Int = 0
    @Sync(.broadcast) var rotation: Int = 0
    @Sync(.broadcast) var progress: Float = 0

    public init() {}
}

@StateNodeBuilder
struct RowEntryArena: StateNodeProtocol {
    @Sync(.broadcast) var monsters: [Int: RowEntryMonster] = [:]

    public init() {}
}

private let arenaPatterns = [
    "monsters", "monsters.*", "monsters.*.id", "monsters.*.health", "monsters.*.x", "monsters.*.y",
    "monsters.*.rotation", "monsters.*.progress",
]
private let arenaHashes = Dictionary(uniqueKeysWithValues: arenaPatterns.map { ($0, DeterministicHash.fnv1a32($0)) })

/// Bytes per sync of row entries against field merge, on synthetic tables shaped like the game
/// cells. The numbers go into the PR; the test only pins that the report runs and that both
/// forms carry the same patches.
@Suite("Row entries: bytes against field merge")
struct RowEntryByteReportTests {
    struct Shape: Sendable, CustomStringConvertible {
        let name: String
        let rows: Int
        /// Of 100 rows, how many move (x, y, rotation, progress) in a sync.
        let movingPercent: Int
        /// Rows that lose health in a sync.
        let hits: Int
        /// A row is replaced (one deleted, one created) every this many syncs; 0 for never.
        let replaceEvery: Int
        var description: String { name }
    }

    static let shapes = [
        Shape(name: "100 rows, all moving, 2 replaced per sync", rows: 100, movingPercent: 100, hits: 5, replaceEvery: 1),
        Shape(name: "20 rows, all moving, few replaced", rows: 20, movingPercent: 100, hits: 5, replaceEvery: 4),
        Shape(name: "500 rows, 1 in 40 moving", rows: 500, movingPercent: 3, hits: 2, replaceEvery: 2),
        Shape(name: "100 rows, one field of 3 rows", rows: 100, movingPercent: 0, hits: 3, replaceEvery: 0),
    ]

    @Test("The report", arguments: shapes)
    func report(shape: Shape) throws {
        let hasher = PathHasher(pathHashes: arenaHashes)
        let tables = SyncTableBroadcastDiff<RowEntryArena>(pathCursor: hasher.rootCursor)
        var drops = ExtractionDrops()
        var state = RowEntryArena()
        tables.seed(state, drops: &drops)
        var random: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Int((random >> 33) % UInt64(bound))
        }
        var nextID = 0
        func spawn() {
            var monster = RowEntryMonster()
            monster.id = nextID
            monster.x = next(64000)
            monster.y = next(36000)
            state.monsters[nextID] = monster
            nextID += 1
        }
        for _ in 0..<shape.rows { spawn() }

        func encoders(rows: Bool) -> (json: OpcodeJSONStateUpdateEncoder, pack: OpcodeMessagePackStateUpdateEncoder) {
            let merge = FieldMergeTable(pathHashes: arenaHashes)
            return (
                OpcodeJSONStateUpdateEncoder(pathHasher: hasher, pathIndex: true, fieldMerge: merge).withRowAddressing(rows),
                OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher, pathIndex: true, fieldMerge: merge).withRowAddressing(rows)
            )
        }
        let on = encoders(rows: true), off = encoders(rows: false)
        let decoderOn = OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: true)
        let decoderOff = OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: true)
        var bytes = (jsonOn: 0, jsonOff: 0, packOn: 0, packOff: 0)
        let syncs = 200
        for sync in 0...syncs {
            if sync > 0 {
                for key in state.monsters.keys.sorted() where next(100) < shape.movingPercent {
                    state.monsters[key]?.x += next(200) - 100
                    state.monsters[key]?.y += next(200) - 100
                    state.monsters[key]?.rotation = next(6283)
                    state.monsters[key]?.progress += 0.0125
                }
                let keys = state.monsters.keys.sorted()
                for _ in 0..<shape.hits {
                    state.monsters[keys[next(keys.count)]]?.health -= 1 + next(20)
                }
                if shape.replaceEvery > 0, sync % shape.replaceEvery == 0 {
                    for _ in 0..<(shape.replaceEvery == 1 ? 2 : 1) {
                        state.monsters[keys[next(keys.count)]] = nil
                        spawn()
                    }
                }
            }
            let result = tables.diff(state, fields: nil, drops: &drops)
            tables.apply(result.staged)
            let update = StateUpdate.diff(result.patches)
            let jsonOn = try on.json.encode(update: update, landID: "arena", playerID: player)
            let jsonOff = try off.json.encode(update: update, landID: "arena", playerID: player)
            let packOn = try on.pack.encode(update: update, landID: "arena", playerID: player)
            let packOff = try off.pack.encode(update: update, landID: "arena", playerID: player)
            #expect(
                byPath(patches(try decoderOn.decodeFrame(packOn, format: .messagePack)))
                    == byPath(patches(try decoderOff.decodeFrame(packOff, format: .messagePack))),
                "sync \(sync)"
            )
            // The first sync creates every row; the report is the steady state.
            guard sync > 0 else { continue }
            bytes.jsonOn += jsonOn.count
            bytes.jsonOff += jsonOff.count
            bytes.packOn += packOn.count
            bytes.packOff += packOff.count
        }
        #expect(drops.count == 0)
        func percent(_ on: Int, _ off: Int) -> String {
            String(format: "%+.1f %%", 100 * (Double(on) / Double(off) - 1))
        }
        print(
            "ROW-ENTRY-BYTES \(shape.name): messagepack \(bytes.packOff / syncs) -> \(bytes.packOn / syncs) bytes/sync (\(percent(bytes.packOn, bytes.packOff)));"
                + " opcode json \(bytes.jsonOff / syncs) -> \(bytes.jsonOn / syncs) (\(percent(bytes.jsonOn, bytes.jsonOff)))"
        )
    }
}

// MARK: - Bytes on a captured run

enum RowEntryCaptureEnvKeys {
    /// A room file written by the game benchmark's `--capture-views` (`room-0.ndjson`).
    static let capture = "SST_ROW_ENTRY_CAPTURE"
}

/// Replays a captured run's broadcast frames as row entries and reports the bytes against the
/// frames as they were sent (field merge). The capture holds today's entries, so the slots are
/// assigned here, by the tables' own rule (`SyncSlottedTable`), from the decoded patches.
///
/// Without `SST_ROW_ENTRY_CAPTURE` the test does nothing: the capture is megabytes and is made
/// when the report is wanted, not checked in.
@Suite("Row entries: bytes on a captured run")
struct RowEntryCaptureReportTests {
    @Test("The report")
    func report() throws {
        guard let path = EnvHelpers.getEnvStringOptional(key: RowEntryCaptureEnvKeys.capture), !path.isEmpty else { return }
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        let header = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let features = header["stateUpdateFeatures"] as? [String] ?? []
        #expect(header["stateUpdate"] as? String == StateUpdateEncoding.opcodeMessagePack.rawValue)
        let schema = try JSONDecoder().decode(
            ProtocolSchema.self, from: JSONSerialization.data(withJSONObject: try #require(header["schema"]))
        )
        let pathHashes = try #require(schema.lands.values.compactMap({ $0.pathHashes }).first)
        let hasher = PathHasher(pathHashes: pathHashes)
        let pathIndex = features.contains(StateUpdateFeature.pathIndex)
        // A root field whose rows have fields of their own is a table.
        let tableFields = Set(pathHashes.keys.compactMap { pattern -> String? in
            let parts = pattern.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 3 && parts[1] == "*" && parts[2] != "*" ? String(parts[0]) : nil
        })

        // Atomic patterns are not in the capture, so this table merges what field merge merges
        // without them; the report says how far its frames are from the captured ones.
        let merge = features.contains(StateUpdateFeature.fieldMerge) ? FieldMergeTable(pathHashes: pathHashes) : nil
        let on = OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher, pathIndex: pathIndex, fieldMerge: merge).withRowAddressing()
        let off = OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher, pathIndex: pathIndex, fieldMerge: merge)
        let broadcast = OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: pathIndex)
        let own = OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: pathIndex)
        let check = OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: pathIndex)

        var tables: [String: SyncSlottedTable<String, Bool>] = [:]
        var seeded = false
        var bytes = (captured: 0, off: 0, on: 0)
        var frames = 0, rowPatches = 0, otherPatches = 0, unknownRows = 0
        func components(_ path: String) -> [String] {
            path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        }
        for line in lines.dropFirst() {
            let checkpoint = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            // The merged frame goes to every session with the same bytes: one per checkpoint.
            var tookBroadcast = false
            for frame in checkpoint["frames"] as? [[String: Any]] ?? [] {
                let data = try #require(Data(base64Encoded: frame["data"] as? String ?? ""))
                guard case .array(let merged) = try unpack(data), let kind = merged.first else { continue }
                guard kind == .int(MessageKindOpcode.stateUpdateWithEvents) || kind == .uint(UInt64(MessageKindOpcode.stateUpdateWithEvents)) else {
                    // The first full view seeds the tables, as the server's own seed numbers them.
                    guard !seeded, case .firstSync(let view)? = try own.decodeFrame(data, format: .messagePack)?.update else { continue }
                    for patch in view {
                        let parts = components(patch.path)
                        guard parts.count == 1, tableFields.contains(parts[0]), case .set(.object(let rows)) = patch.operation else { continue }
                        var keys: [String: Bool] = [:]
                        for key in rows.keys { keys[SyncEngine.escapedPathComponent(key)] = true }
                        tables[parts[0]] = SyncSlottedTable(seeding: keys, keyString: { $0 })
                    }
                    seeded = true
                    continue
                }
                guard seeded, !tookBroadcast, merged.count > 1 else { continue }
                tookBroadcast = true
                guard let decoded = try broadcast.decodeFrame(data, format: .messagePack) else { continue }
                guard case .diff(let sent) = decoded.update, !sent.isEmpty else { continue }

                // Tag the patches as the typed diff does.
                var plans: [String: SyncRowPlan<String, Bool>] = [:]
                var created: [String: [(key: String, index: Int)]] = [:]
                var tagged = sent
                for (index, patch) in sent.enumerated() {
                    let parts = components(patch.path)
                    guard parts.count >= 2, tableFields.contains(parts[0]) else {
                        otherPatches += 1
                        continue
                    }
                    let table = tables[parts[0], default: SyncSlottedTable()]
                    let rowCursor = hasher.rootCursor.descending(parts[0])?.descending(parts[1])
                    guard let slot = table.index[parts[1]] else {
                        if parts.count == 2, case .set = patch.operation {
                            created[parts[0], default: []].append((parts[1], index))
                        } else {
                            unknownRows += 1
                        }
                        continue
                    }
                    rowPatches += 1
                    let split = rowCursor?.asRow(slot).split(of: patch.path, under: "/\(parts[0])/\(parts[1])")
                    if parts.count == 2 {
                        guard case .delete = patch.operation else { continue }
                        plans[parts[0], default: SyncRowPlan()].deletes.append(slot)
                    }
                    tagged[index] = StatePatch(path: patch.path, operation: patch.operation, split: split)
                }
                for (field, rows) in created {
                    let table = tables[field, default: SyncSlottedTable()]
                    let ordered = rows.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
                    let slots = table.plannedSlots(creating: ordered.count)
                    plans[field, default: SyncRowPlan()].plannedCreates = ordered.count
                    for (row, slot) in zip(ordered, slots) {
                        rowPatches += 1
                        plans[field, default: SyncRowPlan()].creates.append((slot, row.key, true))
                        let split = hasher.rootCursor.descending(field)?.descending(row.key)?.split?
                            .asRow(slot, generation: table.plannedGeneration(of: slot))
                        tagged[row.index] = StatePatch(path: sent[row.index].path, operation: sent[row.index].operation, split: split)
                    }
                }
                for (field, plan) in plans {
                    tables[field, default: SyncSlottedTable()].commit(plan)
                }

                let encodedOn = try on.encode(update: .diff(tagged), landID: "capture", playerID: player, playerSlot: nil, scope: .broadcast)
                let encodedOff = try off.encode(update: .diff(sent), landID: "capture", playerID: player, playerSlot: nil, scope: .broadcast)
                #expect(
                    byPath(patches(try check.decodeFrame(encodedOn, format: .messagePack, scope: .broadcast))) == byPath(sent),
                    "sync \(checkpoint["sync"] ?? "")"
                )
                bytes.captured += try pack(merged[1]).count
                bytes.off += encodedOff.count
                bytes.on += encodedOn.count
                frames += 1
            }
        }
        try #require(frames > 0, "no broadcast frame in the capture")
        func percent(_ value: Int, _ base: Int) -> String {
            String(format: "%+.2f %%", 100 * (Double(value) / Double(base) - 1))
        }
        let cell = (header["cell"] as? [String: Any]).map { cell in
            cell.filter { $0.value is Int || $0.value is String }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        } ?? ""
        print(
            "ROW-ENTRY-CAPTURE \(cell): \(frames) broadcast frames; bytes/frame as sent \(bytes.captured / frames),"
                + " re-encoded without row entries \(bytes.off / frames) (\(percent(bytes.off, bytes.captured)) vs sent),"
                + " with row entries \(bytes.on / frames) (\(percent(bytes.on, bytes.captured)) vs sent, \(percent(bytes.on, bytes.off)) vs re-encoded);"
                + " patches in rows \(rowPatches), other \(otherPatches), in rows not seen \(unknownRows)"
        )
    }
}
