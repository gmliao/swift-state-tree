// Tests/SwiftStateTreeTransportTests/FieldMergeTests.swift
//
// Same-parent field merge (`TransportEncodingConfig.fieldMerge`): patches in one frame that set
// (or add) fields of one parent with the same dynamic keys go out as one merged entry,
// `[parentId, dynamicKey, op 4|5, fieldMask, v1, v2, …]`, and decode back to the same patches.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeMessagePack

@Suite("Field merge")
struct FieldMergeTests {
    static let landType = "field-merge"

    /// Hand-written schema patterns: `monsters.*` has the fields `hp`, `name`, `pos` (atomic,
    /// with leaves below) and `tags` (a map, so not a leaf); `wide` has eight fields; `big` has
    /// 33, one more than a mask holds.
    static let patterns: [String] = {
        var patterns = [
            "round", "monsters", "monsters.*", "monsters.*.hp", "monsters.*.name",
            "monsters.*.pos", "monsters.*.pos.v", "monsters.*.pos.v.x", "monsters.*.pos.v.y",
            "monsters.*.tags", "monsters.*.tags.*", "wide", "big",
        ]
        patterns += (0 ..< 8).map { "wide.f\($0)" }
        patterns += (0 ..< 33).map { String(format: "big.c%02d", $0) }
        return patterns
    }()
    static let pathHashes = Dictionary(uniqueKeysWithValues: patterns.map { ($0, DeterministicHash.fnv1a32($0)) })
    static let atomicPatterns: Set<String> = ["monsters.*.pos"]
    static let table = FieldMergeTable(pathHashes: pathHashes, atomicPatterns: atomicPatterns)
    static let hasher = PathHasher(pathHashes: pathHashes)

    static func hash(_ pattern: String) -> UInt32 { pathHashes[pattern]! }

    // MARK: Table

    @Test("A field's bit is its rank among the parent's named children; only leaves and atomic values merge")
    func table() {
        let monster = Self.hash("monsters.*")
        #expect(Self.table.field(ofHash: Self.hash("monsters.*.hp")) == .init(parentHash: monster, bit: 0))
        #expect(Self.table.field(ofHash: Self.hash("monsters.*.name")) == .init(parentHash: monster, bit: 1))
        #expect(Self.table.field(ofHash: Self.hash("monsters.*.pos")) == .init(parentHash: monster, bit: 2, hasPatternsBelow: true))
        #expect(Self.table.field(ofHash: Self.hash("monsters.*.tags")) == nil, "a map is not a leaf")
        #expect(Self.table.childHash(parent: monster, bit: 3) == Self.hash("monsters.*.tags"), "but it has a bit")
        #expect(Self.table.field(ofHash: Self.hash("monsters.*")) == nil, "the last component is *")
        #expect(Self.table.field(ofHash: Self.hash("round")) == nil, "a root field has no parent")
        // Byte order: "c10" sorts after "c09".
        let big = Self.hash("big")
        #expect(Self.table.field(ofHash: Self.hash("big.c31")) == .init(parentHash: big, bit: 31))
        #expect(Self.table.field(ofHash: Self.hash("big.c32")) == nil, "rank 32 is past the mask")
        #expect(Self.table.childHash(parent: big, bit: 32) == nil)
        // Without the atomic pattern, `pos` has patterns below it and is not a leaf.
        let plain = FieldMergeTable(pathHashes: Self.pathHashes)
        #expect(plain.field(ofHash: Self.hash("monsters.*.pos")) == nil)
    }

    // MARK: Encoding

    static let pos: SnapshotValue = .object(["v": .object(["x": .int(1), "y": .int(2)])])

    /// The frame's patches and what the merge makes of them.
    static let patches = [
        StatePatch(path: "/round", operation: .set(.int(1))),            // root: plain
        StatePatch(path: "/monsters/a/hp", operation: .set(.int(5))),    // merged with /monsters/a/pos
        StatePatch(path: "/monsters/b/hp", operation: .set(.int(6))),    // a group of one: plain
        StatePatch(path: "/monsters/a/pos", operation: .set(pos)),
        StatePatch(path: "/monsters/a/name", operation: .add(.string("x"))), // add: its own group, of one
        StatePatch(path: "/monsters/a/tags", operation: .set(.object([:]))), // not a leaf: plain
        StatePatch(path: "/monsters/c/name", operation: .delete),        // delete: plain
    ]
    /// The decoded order: a merged entry takes its first member's place, fields in bit order.
    static let decodedOrder = [0, 1, 3, 2, 4, 5, 6]

    static func encoders(pathIndex: Bool, merge: Bool = true) -> (OpcodeJSONStateUpdateEncoder, OpcodeMessagePackStateUpdateEncoder) {
        let table = merge ? Self.table : nil
        return (
            OpcodeJSONStateUpdateEncoder(pathHasher: hasher, pathIndex: pathIndex, fieldMerge: table),
            OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher, pathIndex: pathIndex, fieldMerge: table)
        )
    }

    static func jsonFrame(_ data: Data) throws -> [Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
    }

    static func packedFrame(_ data: Data) throws -> [MessagePackValue] {
        guard case .array(let frame) = try unpack(data) else {
            Issue.record("MessagePack frame is not an array")
            return []
        }
        return frame
    }

    static func int(_ value: MessagePackValue?) -> Int? {
        switch value {
        case .int(let v): Int(v)
        case .uint(let v): Int(v)
        default: nil
        }
    }

    @Test("Both encoders merge the fields of one parent; the decoder expands them to the same patches", arguments: [false, true])
    func roundTrip(pathIndex: Bool) throws {
        let (json, messagePack) = Self.encoders(pathIndex: pathIndex)
        let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: Self.hasher, pathIndex: pathIndex)
        let jsonData = try json.encode(update: .diff(Self.patches), landID: Self.landType, playerID: PlayerID("p1"))
        let frame = try Self.jsonFrame(jsonData)
        #expect(frame.count == 1 + 6, "seven patches, one merged pair")
        let merged = try #require(frame[2] as? [Any])
        let parentID = pathIndex ? Self.hasher.pathIndex(of: Self.hash("monsters.*"))! : Int(Self.hash("monsters.*"))
        #expect(merged[0] as? Int == parentID)
        #expect(merged[2] as? Int == MergedPatchOpcode.set.rawValue)
        #expect(merged[3] as? Int == 0b101, "hp (bit 0) and pos (bit 2)")
        #expect(merged.count == 6)

        let packed = try Self.packedFrame(try messagePack.encode(update: .diff(Self.patches), landID: Self.landType, playerID: PlayerID("p1")))
        #expect(packed.count == frame.count)
        guard case .array(let packedMerged) = packed[2] else {
            Issue.record("MessagePack merged entry is not an array")
            return
        }
        #expect(Self.int(packedMerged[0]) == parentID)
        #expect(Self.int(packedMerged[2]) == MergedPatchOpcode.set.rawValue)
        #expect(Self.int(packedMerged[3]) == 0b101)

        guard case .diff(let decoded) = try decoder.decode(data: jsonData).update else {
            Issue.record("not a diff")
            return
        }
        #expect(decoded == Self.decodedOrder.map { Self.patches[$0] })
    }

    @Test("With the merge off, every patch is its own entry, as before")
    func off() throws {
        let (json, _) = Self.encoders(pathIndex: false, merge: false)
        let frame = try Self.jsonFrame(try json.encode(update: .diff(Self.patches), landID: Self.landType, playerID: PlayerID("p1")))
        #expect(frame.count == 1 + Self.patches.count)
    }

    @Test("A patch at, above or below the parent between two fields keeps them apart")
    func overlapClosesTheGroup() throws {
        let (json, _) = Self.encoders(pathIndex: true)
        let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: Self.hasher, pathIndex: true)
        let cases: [[StatePatch]] = [
            // The entity is deleted between two of its fields.
            [StatePatch(path: "/monsters/a/hp", operation: .set(.int(1))),
             StatePatch(path: "/monsters/a", operation: .delete),
             StatePatch(path: "/monsters/a/name", operation: .set(.string("n")))],
            // The whole entity is set between two of its fields.
            [StatePatch(path: "/monsters/a/hp", operation: .set(.int(1))),
             StatePatch(path: "/monsters/a", operation: .set(.object([:]))),
             StatePatch(path: "/monsters/a/name", operation: .set(.string("n")))],
            // The map holding it is replaced.
            [StatePatch(path: "/monsters/a/hp", operation: .set(.int(1))),
             StatePatch(path: "/monsters", operation: .set(.object([:]))),
             StatePatch(path: "/monsters/a/name", operation: .set(.string("n")))],
            // A field of the parent is deleted.
            [StatePatch(path: "/monsters/a/hp", operation: .set(.int(1))),
             StatePatch(path: "/monsters/a/tags", operation: .delete),
             StatePatch(path: "/monsters/a/name", operation: .set(.string("n")))],
        ]
        for patches in cases {
            let data = try json.encode(update: .diff(patches), landID: Self.landType, playerID: PlayerID("p1"))
            #expect(try Self.jsonFrame(data).count == 1 + 3, "\(patches[1].path): no merge across it")
            guard case .diff(let decoded) = try decoder.decode(data: data).update else {
                Issue.record("not a diff")
                continue
            }
            #expect(decoded == patches)
        }
        // An unrelated entity between them doesn't keep them apart.
        let apart = [
            StatePatch(path: "/monsters/a/hp", operation: .set(.int(1))),
            StatePatch(path: "/monsters/b", operation: .delete),
            StatePatch(path: "/monsters/a/name", operation: .set(.string("n"))),
        ]
        #expect(try Self.jsonFrame(try json.encode(update: .diff(apart), landID: Self.landType, playerID: PlayerID("p1"))).count == 1 + 2)
    }

    @Test("Without the order rule (measurement only), the plan merges across the patch in between")
    func withoutOrderRule() {
        let patches = [
            StatePatch(path: "/monsters/a/hp", operation: .set(.int(1))),
            StatePatch(path: "/monsters/a", operation: .delete),
            StatePatch(path: "/monsters/a/name", operation: .set(.string("n"))),
        ]
        let splits = patches.map { Self.hasher.splitReportingMatch($0.path) }
        func shape(_ entries: [FieldMergeEntry]) -> [String] {
            entries.map { entry in
                switch entry {
                case .plain(let index): return "plain \(index)"
                case .merged(_, _, _, let members): return "merged \(members.map(\.index))"
                }
            }
        }
        #expect(shape(FieldMergePlan.entries(patches: patches, splits: splits, table: Self.table)) == ["plain 0", "plain 1", "plain 2"])
        #expect(shape(FieldMergePlan.entries(patches: patches, splits: splits, table: Self.table, orderRule: false)) == ["merged [0, 2]", "plain 1"])
    }

    @Test("Two fields that reach the schema only by a fallback hash stay plain, so the encoder refuses each")
    func fallbackFieldsDontMerge() throws {
        // `/a/x/b` and `/a/x/d` follow the literal `a.x` (from `a.x.c`), find no `b` or `d` there
        // and fall back to `a.*.b` / `a.*.d`, schema patterns they didn't match.
        let patterns = ["a", "a.*", "a.*.b", "a.*.d", "a.x", "a.x.c"]
        let pathHashes = Dictionary(uniqueKeysWithValues: patterns.map { ($0, DeterministicHash.fnv1a32($0)) })
        let hasher = PathHasher(pathHashes: pathHashes)
        let table = FieldMergeTable(pathHashes: pathHashes, atomicPatterns: [])
        let patches = [
            StatePatch(path: "/a/x/b", operation: .set(.int(1))),
            StatePatch(path: "/a/x/d", operation: .set(.int(2))),
        ]
        let splits = patches.map { hasher.splitReportingMatch($0.path) }
        #expect(splits.allSatisfy { !$0.inSchema })
        let entries = FieldMergePlan.entries(patches: patches, splits: splits, table: table)
        #expect(entries.allSatisfy { if case .plain = $0 { true } else { false } })
        let encoders: [any StateUpdateEncoder] = [
            OpcodeJSONStateUpdateEncoder(pathHasher: hasher, pathIndex: true, fieldMerge: table),
            OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher, pathIndex: true, fieldMerge: table),
        ]
        for encoder in encoders {
            #expect(throws: StateUpdateEncodingError.pathNotInSchema("/a/x/b")) {
                try encoder.encode(update: .diff(patches), landID: Self.landType, playerID: PlayerID("p1"))
            }
        }
        // In the schema (`/a/y/...`), the same two fields merge.
        let inSchema = [StatePatch(path: "/a/y/b", operation: .set(.int(1))), StatePatch(path: "/a/y/d", operation: .set(.int(2)))]
        let merged = FieldMergePlan.entries(patches: inSchema, splits: inSchema.map { hasher.splitReportingMatch($0.path) }, table: table)
        #expect(merged.count == 1)
    }

    @Test("Many entities in one frame: each delete closes only its own entity's groups")
    func manyEntitiesKeepTheirGroups() {
        // Entity i: hp, then a delete of entity i-1's map entry (`/monsters/<i-1>` is another
        // entity), then name. Every entity still merges hp and name.
        var patches: [StatePatch] = []
        for i in 0 ..< 200 {
            patches.append(StatePatch(path: "/monsters/m\(i)/hp", operation: .set(.int(i))))
            patches.append(StatePatch(path: "/monsters/x\(i)", operation: .delete))
            patches.append(StatePatch(path: "/monsters/m\(i)/name", operation: .set(.string("n"))))
        }
        let splits = patches.map { Self.hasher.splitReportingMatch($0.path) }
        let entries = FieldMergePlan.entries(patches: patches, splits: splits, table: Self.table)
        let merged = entries.filter { if case .merged = $0 { true } else { false } }.count
        #expect(merged == 200 && entries.count == 400)
    }

    static func shape(_ entries: [FieldMergeEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .plain(let index): return "plain \(index)"
            case .merged(let parent, let keys, let op, let members): return "merged \(parent) \(keys) \(op) \(members.map(\.index))"
            }
        }
    }

    @Test("Recipients that share a broadcast prefix share its plan, and each still gets its own fields and values")
    func sharedPlanPerRecipient() throws {
        func set(_ path: String, _ value: Int) -> StatePatch { StatePatch(path: path, operation: .set(.int(value))) }
        let broadcast = [set("/monsters/a/hp", 1), set("/monsters/b/hp", 2), set("/round", 3), set("/monsters/c/hp", 4)]
        // Each recipient's frame: the broadcast (a per-player patch at the same path replaces its
        // entry) and then its own patches, as the adapter combines them.
        var mine = broadcast
        mine[1] = set("/monsters/b/hp", 20)
        var deleted = broadcast
        deleted[1] = StatePatch(path: "/monsters/b/hp", operation: .delete)
        let frames: [[StatePatch]] = [
            broadcast + [StatePatch(path: "/monsters/a/name", operation: .set(.string("p1")))],
            broadcast + [StatePatch(path: "/monsters/b/name", operation: .set(.string("p2")))],
            broadcast + [StatePatch(path: "/monsters/a/name", operation: .set(.string("p3"))), set("/monsters/c/hp", 5)],
            mine + [StatePatch(path: "/monsters/b/name", operation: .set(.string("p4")))],
            deleted + [StatePatch(path: "/monsters/b/name", operation: .set(.string("p5")))],
            broadcast + [StatePatch(path: "/monsters/a", operation: .delete), StatePatch(path: "/monsters/a/name", operation: .set(.string("p6")))],
            broadcast,
        ]
        let cache = FieldMergePlanCache()
        for (n, frame) in frames.enumerated() {
            let splits = frame.map { Self.hasher.splitReportingMatch($0.path) }
            let full = FieldMergePlan.entries(patches: frame, splits: splits, table: Self.table)
            let shared = FieldMergePlan.splitsAndEntries(patches: frame, hasher: Self.hasher, table: Self.table, cache: cache)
            #expect(Self.shape(shared.entries) == Self.shape(full), "frame \(n)")
            #expect(shared.splits.map(\.pathHash) == splits.map(\.pathHash), "frame \(n)")
        }
        // Frame 1 keeps a checkpoint at the broadcast's end; frames 2 and 3 resume from it (3 has its
        // own value at a shared path). Frame 4's delete at a shared path ends the shared prefix.
        #expect(cache.resumes == 2)

        // End to end: each recipient decodes its own frame from an encoder that shares plans.
        for pathIndex in [false, true] {
            let (json, messagePack) = Self.encoders(pathIndex: pathIndex)
            let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: Self.hasher, pathIndex: pathIndex)
            for (n, frame) in frames.enumerated() {
                let player = PlayerID("p\(n)")
                let (freshJSON, freshPack) = Self.encoders(pathIndex: pathIndex)
                guard case .diff(let decoded) = try decoder.decode(data: try json.encode(update: .diff(frame), landID: Self.landType, playerID: player)).update,
                      case .diff(let expected) = try decoder.decode(data: try freshJSON.encode(update: .diff(frame), landID: Self.landType, playerID: player)).update else {
                    Issue.record("not a diff")
                    return
                }
                #expect(decoded == expected, "frame \(n)")
                #expect(decoded.count == frame.count && frame.allSatisfy(decoded.contains), "frame \(n): every patch, with this recipient's values")
                #expect(try messagePack.encode(update: .diff(frame), landID: Self.landType, playerID: player)
                    == freshPack.encode(update: .diff(frame), landID: Self.landType, playerID: player), "frame \(n)")
            }
            #expect(json.fieldMergePlanCache.resumes > 0 && messagePack.fieldMergePlanCache.resumes > 0)
        }
    }

    @Test("A shared plan equals the full plan over frames that share prefixes of any length")
    func sharedPlanMatchesFullPlan() {
        // A small pool of paths: fields of a few entities, the entities themselves, a top-level field.
        let entities = ["a", "b", "c"]
        var pool: [StatePatch] = [StatePatch(path: "/round", operation: .set(.int(0)))]
        for e in entities {
            pool.append(StatePatch(path: "/monsters/\(e)/hp", operation: .set(.int(1))))
            pool.append(StatePatch(path: "/monsters/\(e)/name", operation: .set(.string(e))))
            pool.append(StatePatch(path: "/monsters/\(e)/hp", operation: .delete))
            pool.append(StatePatch(path: "/monsters/\(e)", operation: .delete))
            pool.append(StatePatch(path: "/monsters/\(e)", operation: .set(.object([:]))))
            pool.append(StatePatch(path: "/monsters/\(e)/tags/t", operation: .add(.int(2))))
        }
        var seed: UInt64 = 0x5eed
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let cache = FieldMergePlanCache()
        var previous: [StatePatch] = []
        for n in 0 ..< 600 {
            // Keep a prefix of the previous frame (often the whole "broadcast"), then new patches.
            var frame = Array(previous.prefix(next(previous.count + 1)))
            for _ in 0 ..< next(12) { frame.append(pool[next(pool.count)]) }
            if n % 7 == 0 { frame = (0 ..< next(20)).map { _ in pool[next(pool.count)] } }
            let splits = frame.map { Self.hasher.splitReportingMatch($0.path) }
            let full = FieldMergePlan.entries(patches: frame, splits: splits, table: Self.table)
            let shared = FieldMergePlan.splitsAndEntries(patches: frame, hasher: Self.hasher, table: Self.table, cache: cache)
            #expect(Self.shape(shared.entries) == Self.shape(full), "frame \(n)")
            previous = frame
        }
        #expect(cache.resumes > 100)
    }

    @Test("A mask with bits 0–6 is a 1-byte fixint in MessagePack; bit 7 takes a uint8")
    func maskWidth() throws {
        let (_, messagePack) = Self.encoders(pathIndex: true)
        func bytes(_ fields: [Int]) throws -> Int {
            let patches = fields.map { StatePatch(path: "/wide/f\($0)", operation: .set(.int(1))) }
            return try messagePack.encode(update: .diff(patches), landID: Self.landType, playerID: PlayerID("p1")).count
        }
        // Masks 0b0110_0000 (96) and 0b1100_0000 (192): the same frame but for the mask's width.
        #expect(try bytes([6, 7]) == bytes([5, 6]) + 1)
    }

    @Test("Ranks 30 and 31 merge; rank 32 is sent plain")
    func widestMask() throws {
        let (json, _) = Self.encoders(pathIndex: true)
        let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: Self.hasher, pathIndex: true)
        let patches = [30, 31, 32].map { StatePatch(path: String(format: "/big/c%02d", $0), operation: .set(.int($0))) }
        let data = try json.encode(update: .diff(patches), landID: Self.landType, playerID: PlayerID("p1"))
        let frame = try Self.jsonFrame(data)
        #expect(frame.count == 1 + 2)
        let merged = try #require(frame[1] as? [Any])
        #expect((merged[3] as? NSNumber)?.uint32Value == UInt32(3) << 30)
        let plain = try #require(frame[2] as? [Any])
        #expect(plain[2] as? Int == StatePatchOpcode.set.rawValue)
        guard case .diff(let decoded) = try decoder.decode(data: data).update else {
            Issue.record("not a diff")
            return
        }
        #expect(decoded == patches)
    }

    @Test("Dynamic keys of a merged entry use the same slots as plain entries")
    func dynamicKeys() throws {
        let (json, _) = Self.encoders(pathIndex: true)
        let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: Self.hasher, pathIndex: true)
        // The key is defined in the first frame and reused in the second, merged or not.
        for update in [StateUpdate.firstSync(Self.patches), .diff(Self.patches)] {
            let data = try json.encode(update: update, landID: Self.landType, playerID: PlayerID("p1"))
            let decoded: [StatePatch]
            switch try decoder.decode(data: data).update {
            case .firstSync(let patches), .diff(let patches): decoded = patches
            case .noChange: decoded = []
            }
            #expect(decoded == Self.decodedOrder.map { Self.patches[$0] })
        }
    }

    @Test("The decoder rejects a mask that doesn't match the values or names no field")
    func badMergedEntries() throws {
        let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: Self.hasher)
        let parent = Self.hash("monsters.*")
        for (entry, message) in [
            ("[\(parent),\"k\",4,5,1]", "mask 5 for 1 values"),
            ("[\(parent),\"k\",4,0]", "mask 0 for 0 values"),
            ("[\(parent),\"k\",4,256,1]", "Unknown merged field: bit 8"),
        ] {
            #expect(throws: StateUpdateDecodingError.self, "\(message)") {
                try decoder.decode(data: Data("[2,\(entry)]".utf8))
            }
        }
    }

    // MARK: Config

    @Test("The config's features: fieldMerge (on by default) with an opcode state-update encoding")
    func configFeatures() {
        #expect(TransportEncodingConfig.messagepack.fieldMerge)
        #expect(TransportEncodingConfig.messagepack.stateUpdateFeatures == ["fieldMerge"])
        #expect(TransportEncodingConfig.messagepack.withPathIndex(true).stateUpdateFeatures == ["pathIndex", "fieldMerge"])
        #expect(TransportEncodingConfig.messagepack.withFieldMerge(false).stateUpdateFeatures == [])
        #expect(TransportEncodingConfig.json.stateUpdateFeatures == [])
        #expect(TransportEncodingConfig.messagepack.effective(pathHashes: nil).stateUpdateFeatures == [])
        #expect(TransportEncodingConfig.fieldMergeFromEnvironment(environment: [:]))
        #expect(!TransportEncodingConfig.fieldMergeFromEnvironment(environment: ["FIELD_MERGE": "false"]))
    }
}
