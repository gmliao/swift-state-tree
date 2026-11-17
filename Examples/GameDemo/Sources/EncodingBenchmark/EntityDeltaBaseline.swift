// Examples/GameDemo/Sources/EncodingBenchmark/EntityDeltaBaseline.swift
//
// `--baseline entity-delta`: a Quake 3–style entity-delta snapshot protocol over the same
// per-player projections SST syncs (Notes/plans/2026-11-07-entity-delta-baseline.md).
// Each player's projection is split into entities (a root plus one per child of a keyed
// collection); each frame carries new field definitions, removed slots, created slots and,
// per changed entity, a changed-field bitmask and the changed values. Over a reliable,
// ordered transport the client's acknowledged baseline is the previous frame, so every frame
// is a delta against the previous one sent to that client.
//
// The client decoder is a separate TypeScript implementation
// (ws-loadtest/src/entity-delta.ts); `verify-views` checks it against the projections.
//
// Frame layout (all counts and slots are varints):
//   newFieldCount, { entityType: u8, path: string }*
//   removedCount, { slot }*
//   createdCount, { slot, entityType: u8, key: string }*
//   changedCount, { slot, mask: varint, value* (in field order) }*
// Values (byte-aligned writer): one tag byte, then the payload.

import Foundation
import GameContent
import LoadTestPacing
@_spi(Testing) import SwiftStateTree

// MARK: - Model

/// One leaf of an entity: a scalar at a path, or a marker for an empty container.
enum EntityDeltaLeaf: Hashable {
    case absent
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case emptyObject
    case emptyArray
}

/// An entity: type 0 is the root, type `i + 1` a child of `EntityDeltaModel.collections[i]`.
struct EntityDeltaKey: Hashable, Comparable {
    let type: UInt8
    let key: String

    static func < (lhs: EntityDeltaKey, rhs: EntityDeltaKey) -> Bool {
        lhs.type != rhs.type ? lhs.type < rhs.type : Array(lhs.key.utf8).lexicographicallyPrecedes(Array(rhs.key.utf8))
    }
}

enum EntityDeltaModel {
    /// Top-level keyed collections whose children are entities (hero-defense).
    static let collections = ["players", "monsters", "turrets"]
    static let root = EntityDeltaKey(type: 0, key: "")

    /// A projection as entities, each a map from leaf path to value. A collection present in
    /// the projection marks the root with `#<name>` (so an empty collection survives).
    static func entities(of projection: [String: SnapshotValue]) -> [EntityDeltaKey: [String: EntityDeltaLeaf]] {
        var result: [EntityDeltaKey: [String: EntityDeltaLeaf]] = [:]
        var rootLeaves: [String: EntityDeltaLeaf] = [:]
        for (name, value) in projection {
            if let index = collections.firstIndex(of: name), case let .object(children) = value {
                rootLeaves["#\(name)"] = .bool(true)
                for (key, child) in children {
                    var leaves: [String: EntityDeltaLeaf] = [:]
                    flatten(child, prefix: "", into: &leaves)
                    result[EntityDeltaKey(type: UInt8(index + 1), key: key)] = leaves
                }
            } else {
                flatten(value, prefix: name, into: &rootLeaves)
            }
        }
        result[Self.root] = rootLeaves
        return result
    }

    private static func flatten(_ value: SnapshotValue, prefix: String, into out: inout [String: EntityDeltaLeaf]) {
        switch value {
        case .null: out[prefix] = .null
        case let .bool(v): out[prefix] = .bool(v)
        case let .int(v): out[prefix] = .int(v)
        case let .double(v): out[prefix] = .double(v)
        case let .string(v): out[prefix] = .string(v)
        case let .object(o):
            if o.isEmpty { out[prefix] = .emptyObject }
            for (k, v) in o { flatten(v, prefix: prefix.isEmpty ? k : "\(prefix).\(k)", into: &out) }
        case let .array(a):
            // Hero-defense syncs no arrays; an array would need element paths and a length.
            guard a.isEmpty else { fatalError("entity-delta: arrays aren't supported (at \(prefix))") }
            out[prefix] = .emptyArray
        }
    }
}

// MARK: - Value coding

/// Writes a frame. The byte-aligned writer is the measured one; a bit-packed writer can
/// replace it behind this interface without touching the entity, slot or mask logic.
protocol EntityDeltaValueWriter {
    init()
    var bytes: [UInt8] { get }
    mutating func byte(_ value: UInt8)
    mutating func varint(_ value: UInt64)
    mutating func string(_ value: String)
    mutating func leaf(_ value: EntityDeltaLeaf)
    mutating func append(_ other: Self)
}

/// Tags: 0 absent, 1 null, 2 false, 3 true, 4 int (zigzag varint), 5 float32 (little endian),
/// 6 string, 7 empty object, 8 empty array, 9 float64 (little endian).
struct ByteAlignedEntityDeltaWriter: EntityDeltaValueWriter {
    private(set) var bytes: [UInt8] = []

    init() {}

    mutating func byte(_ value: UInt8) { bytes.append(value) }

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func string(_ value: String) {
        let utf8 = Array(value.utf8)
        varint(UInt64(utf8.count))
        bytes += utf8
    }

    mutating func leaf(_ value: EntityDeltaLeaf) {
        switch value {
        case .absent: bytes.append(0)
        case .null: bytes.append(1)
        case let .bool(v): bytes.append(v ? 3 : 2)
        case let .int(v):
            bytes.append(4)
            varint(EntityDeltaBits.zigzag(v))
        case let .double(v):
            if let f = Float(exactly: v) {
                bytes.append(5)
                withUnsafeBytes(of: f.bitPattern.littleEndian) { bytes += $0 }
            } else {
                bytes.append(9)
                withUnsafeBytes(of: v.bitPattern.littleEndian) { bytes += $0 }
            }
        case let .string(v):
            bytes.append(6)
            string(v)
        case .emptyObject: bytes.append(7)
        case .emptyArray: bytes.append(8)
        }
    }

    mutating func append(_ other: ByteAlignedEntityDeltaWriter) { bytes += other.bytes }
}

enum EntityDeltaBits {
    static func zigzag(_ v: Int) -> UInt64 { UInt64(bitPattern: Int64((v << 1) ^ (v >> 63))) }

    /// Bits for an unsigned value (at least 1).
    static func width(_ v: UInt64) -> Int { max(1, 64 - v.leadingZeroBitCount) }
}

// MARK: - Bit-packing bound

/// The fixed-width bit-packing bound (plan § Value coding): per field, the width covering
/// every value it took; per frame, the changed values at their fields' widths, a one-bit-per-
/// field mask per changed entity, slots at the run's highest slot width, and everything that
/// isn't a number (counts, definitions, keys, strings) at its byte-aligned size. Widths are
/// only known at the end, so the frames' contributions are kept as counts.
struct EntityDeltaBitpackBound {
    struct FieldID: Hashable { let type: UInt8; let index: Int }

    /// Per field: the widest integer seen, and whether it ever held a non-integer (one more
    /// bit to tell the kinds apart; a string's bytes are counted where it occurs).
    private var fieldWidth: [FieldID: Int] = [:]
    private var fieldMixed: Set<FieldID> = []
    private var maxSlot = 0

    /// Counted inside the measured window only.
    private var valueCounts: [FieldID: Int] = [:]
    private var slotRefs = 0
    private var fixedBits = 0

    mutating func observe(field: FieldID, leaf: EntityDeltaLeaf, measured: Bool) {
        switch leaf {
        case let .int(v):
            fieldWidth[field] = max(fieldWidth[field] ?? 1, EntityDeltaBits.width(EntityDeltaBits.zigzag(v)))
        case let .double(v):
            fieldWidth[field] = max(fieldWidth[field] ?? 1, Float(exactly: v) != nil ? 32 : 64)
        case let .string(s):
            fieldMixed.insert(field)
            if measured {
                var w = ByteAlignedEntityDeltaWriter()
                w.string(s)
                fixedBits += 8 * w.bytes.count
            }
        case .absent, .null, .bool, .emptyObject, .emptyArray:
            fieldMixed.insert(field)
        }
        if measured { valueCounts[field, default: 0] += 1 }
    }

    mutating func observe(slot: Int, measured: Bool) {
        maxSlot = max(maxSlot, slot)
        if measured { slotRefs += 1 }
    }

    /// A changed entity's mask: one bit per field in its type's table.
    mutating func observeMask(fields: Int, measured: Bool) {
        if measured { fixedBits += fields }
    }

    /// Byte-aligned parts (counts, definitions, keys) of a measured frame.
    mutating func observeFixed(bytes: Int, measured: Bool) {
        if measured { fixedBits += 8 * bytes }
    }

    /// Bytes in the measured window.
    var totalBytes: Int {
        var bits = fixedBits + slotRefs * EntityDeltaBits.width(UInt64(maxSlot))
        for (field, count) in valueCounts {
            bits += count * ((fieldWidth[field] ?? 1) + (fieldMixed.contains(field) ? 1 : 0))
        }
        return (bits + 7) / 8
    }
}

// MARK: - Encoder

/// One client's encoder: field tables per entity type, the slot map and the last values sent.
struct EntityDeltaEncoder {
    private(set) var fields: [UInt8: [String]] = [:]
    private var fieldIndex: [UInt8: [String: Int]] = [:]
    private(set) var slotOf: [EntityDeltaKey: Int] = [:]
    private var freeSlots: [Int] = []
    private var nextSlot = 0
    private(set) var values: [Int: [EntityDeltaLeaf]] = [:]

    /// Encodes `entities` against the previous frame and makes it the new baseline.
    /// `bound` (optional) collects the bit-packing bound; `measured` marks the window.
    mutating func encode<W: EntityDeltaValueWriter>(
        _ entities: [EntityDeltaKey: [String: EntityDeltaLeaf]],
        writer _: W.Type,
        bound: inout EntityDeltaBitpackBound?,
        measured: Bool
    ) -> [UInt8] {
        var w = W()
        var fixed = 0  // byte-aligned bytes for the bound: counts, definitions, keys

        // 1. New field definitions, in canonical order.
        var newFields: [(UInt8, String)] = []
        for key in entities.keys.sorted() {
            guard let leaves = entities[key] else { continue }
            for path in leaves.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
                where fieldIndex[key.type]?[path] == nil
            {
                fieldIndex[key.type, default: [:]][path] = fields[key.type, default: []].count
                fields[key.type, default: []].append(path)
                newFields.append((key.type, path))
            }
        }
        var definitions = W()
        definitions.varint(UInt64(newFields.count))
        for (type, path) in newFields {
            definitions.byte(type)
            definitions.string(path)
        }
        fixed += definitions.bytes.count
        w.append(definitions)

        // 2. Removed entities, by slot (before creations, so a freed slot can be reused).
        let removed = slotOf.keys.filter { entities[$0] == nil }.sorted { slotOf[$0]! < slotOf[$1]! }
        var counts = W()
        counts.varint(UInt64(removed.count))
        fixed += counts.bytes.count
        w.append(counts)
        for key in removed {
            let slot = slotOf.removeValue(forKey: key)!
            values[slot] = nil
            freeSlots.append(slot)
            w.varint(UInt64(slot))
            bound?.observe(slot: slot, measured: measured)
        }

        // 3. Created entities: slot, type, key (lowest free slot first).
        let created = entities.keys.filter { slotOf[$0] == nil }.sorted()
        counts = W()
        counts.varint(UInt64(created.count))
        fixed += counts.bytes.count
        w.append(counts)
        freeSlots.sort(by: >)
        for key in created {
            let slot: Int
            if let free = freeSlots.popLast() {
                slot = free
            } else {
                slot = nextSlot
                nextSlot += 1
            }
            slotOf[key] = slot
            values[slot] = []
            w.varint(UInt64(slot))
            bound?.observe(slot: slot, measured: measured)
            var keyBytes = W()
            keyBytes.byte(key.type)
            keyBytes.string(key.key)
            fixed += keyBytes.bytes.count
            w.append(keyBytes)
        }

        // 4. Changed entities, by slot: slot, mask, changed values in field order.
        var changes = W()
        var changedCount = 0
        for (key, leaves) in entities.sorted(by: { slotOf[$0.key]! < slotOf[$1.key]! }) {
            let slot = slotOf[key]!
            let table = fields[key.type] ?? []
            var old = values[slot] ?? []
            if old.count < table.count { old += Array(repeating: .absent, count: table.count - old.count) }
            var mask: UInt64 = 0
            var changed: [(Int, EntityDeltaLeaf)] = []
            for (i, path) in table.enumerated() {
                let new = leaves[path] ?? .absent
                if new != old[i] {
                    precondition(i < 64, "entity-delta: more than 64 fields in entity type \(key.type)")
                    mask |= 1 << UInt64(i)
                    changed.append((i, new))
                    old[i] = new
                }
            }
            values[slot] = old
            guard mask != 0 else { continue }
            changedCount += 1
            changes.varint(UInt64(slot))
            changes.varint(mask)
            bound?.observe(slot: slot, measured: measured)
            bound?.observeMask(fields: table.count, measured: measured)
            for (i, leaf) in changed {
                changes.leaf(leaf)
                bound?.observe(field: .init(type: key.type, index: i), leaf: leaf, measured: measured)
            }
        }
        counts = W()
        counts.varint(UInt64(changedCount))
        fixed += counts.bytes.count
        w.append(counts)
        w.append(changes)
        bound?.observeFixed(bytes: fixed, measured: measured)
        return w.bytes
    }

    /// Encoder-state size by the plan's counting rule: per field-table entry its path's UTF-8
    /// bytes plus 8, per slot entry its key's UTF-8 bytes plus 16, per stored value 9 bytes.
    var stateBytes: Int {
        var total = 0
        for (_, table) in fields { for path in table { total += path.utf8.count + 8 } }
        for (key, _) in slotOf { total += key.key.utf8.count + 16 }
        for (_, row) in values { total += 9 * row.count }
        return total
    }
}

// MARK: - Per-room encoding: per client, and shared per (encoder state, projection)

/// The clients of one room. `perClient` encodes every client's frame with its own encoder, as
/// Quake 3 does. `shared` keeps one encoder per group of clients whose encoder state is the
/// same (same history) and whose projection is the same this sync; a group splits when its
/// members' projections differ. Both give every client the same bytes.
struct EntityDeltaRoom {
    private(set) var perClient: [EntityDeltaEncoder]
    private var groups: [(members: [Int], encoder: EntityDeltaEncoder)]
    var bound: EntityDeltaBitpackBound? = EntityDeltaBitpackBound()

    init(clients: Int) {
        perClient = Array(repeating: EntityDeltaEncoder(), count: clients)
        groups = [(Array(0 ..< clients), EntityDeltaEncoder())]
    }

    /// Per-client encode: one frame per client.
    mutating func encodePerClient(_ entities: [[EntityDeltaKey: [String: EntityDeltaLeaf]]], measured: Bool) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        frames.reserveCapacity(entities.count)
        for client in entities.indices {
            // The bound counts every client's frame, the same frames `bytes_per_sync` counts.
            frames.append(perClient[client].encode(entities[client], writer: ByteAlignedEntityDeltaWriter.self, bound: &bound, measured: measured))
        }
        return frames
    }

    /// Shared encode: one frame per group, reused for its members.
    mutating func encodeShared(_ entities: [[EntityDeltaKey: [String: EntityDeltaLeaf]]]) -> [[UInt8]] {
        var frames = Array(repeating: [UInt8](), count: entities.count)
        var next: [(members: [Int], encoder: EntityDeltaEncoder)] = []
        var noBound: EntityDeltaBitpackBound? = nil
        // Pop the groups so each encoder is uniquely owned and mutates in place; only a group
        // that splits pays for copying its state.
        var pending = groups
        groups = []
        while var group = pending.popLast() {
            var parts: [(entities: [EntityDeltaKey: [String: EntityDeltaLeaf]], members: [Int])] = []
            for member in group.members {
                if let i = parts.firstIndex(where: { $0.entities == entities[member] }) {
                    parts[i].members.append(member)
                } else {
                    parts.append((entities[member], [member]))
                }
            }
            // Parts after the first continue from a copy of the group's state.
            let copies = Array(repeating: group.encoder, count: parts.count - 1)
            for (index, part) in parts.enumerated() {
                var encoder = index == 0 ? group.encoder : copies[index - 1]
                if index == 0 { group.encoder = EntityDeltaEncoder() }  // release the group's reference
                let frame = encoder.encode(part.entities, writer: ByteAlignedEntityDeltaWriter.self, bound: &noBound, measured: false)
                for member in part.members { frames[member] = frame }
                next.append((part.members, encoder))
            }
        }
        groups = next
        return frames
    }

    var stateBytes: Int { perClient.reduce(0) { $0 + $1.stateBytes } }
}

// MARK: - Run-level counters

/// Totals over a cell's rooms, for the result JSON.
struct EntityDeltaTotals {
    var firstSyncBytes = 0
    var measuredBytes = 0
    var projectDuration = Duration.zero
    var encodeDuration = Duration.zero
    var encodeSharedDuration = Duration.zero
    /// Frames where the shared encode's bytes differ from the per-client encode's (must be 0).
    var sharedMismatches = 0

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}

// MARK: - Run driver

enum EntityDeltaRun {
    /// Set by `main` before any run when `--baseline entity-delta` is given.
    nonisolated(unsafe) static var enabled = false
    static let formatName = "entity-delta"
}

/// B2 over a hero-defense multi-room run: one `EntityDeltaRoom` per room. The SST adapter keeps
/// running; this times only its own spans (projection, per-client encode, shared encode).
final class EntityDeltaCell: @unchecked Sendable {
    private var rooms: [EntityDeltaRoom]
    private let players: [[PlayerID]]
    private let sessions: [[SessionID]]
    private let engine = SyncEngine(for: HeroDefenseState.self)
    private(set) var totals = EntityDeltaTotals()
    private let rssBefore = ProcessUsage.currentResidentBytes()

    init(roomCount: Int, playersPerRoom: Int) {
        rooms = Array(repeating: EntityDeltaRoom(clients: playersPerRoom), count: roomCount)
        players = (0 ..< roomCount).map { r in (0 ..< playersPerRoom).map { PlayerID("room\(r)-player-\($0)") } }
        sessions = (0 ..< roomCount).map { r in (0 ..< playersPerRoom).map { SessionID(fixed: "room\(r)-session-\($0)") } }
    }

    /// Encodes every room's frames for this sync. `measured` is false for the first frame
    /// (outside the window). Returns the frames of the first `captureRooms` rooms, as captured
    /// frames addressed to each session.
    func sync(_ contexts: [HeroDefenseRoomContext], measured: Bool, captureRooms: Int) async -> [[CapturedFrame]] {
        var captured: [[CapturedFrame]] = []
        for (index, context) in contexts.enumerated() {
            let state = await context.keeper.currentState()
            let projectStart = ContinuousClock.now
            let entities = players[index].map { player -> [EntityDeltaKey: [String: EntityDeltaLeaf]] in
                do {
                    return EntityDeltaModel.entities(of: try engine.snapshot(for: player, from: state, mode: .all).values)
                } catch {
                    fatalError("entity-delta: projection failed: \(error)")
                }
            }
            let encodeStart = ContinuousClock.now
            let frames = rooms[index].encodePerClient(entities, measured: measured)
            let sharedStart = ContinuousClock.now
            let shared = rooms[index].encodeShared(entities)
            let end = ContinuousClock.now
            if shared != frames { totals.sharedMismatches += 1 }
            let bytes = frames.reduce(0) { $0 + $1.count }
            if measured {
                totals.projectDuration += projectStart.duration(to: encodeStart)
                totals.encodeDuration += encodeStart.duration(to: sharedStart)
                totals.encodeSharedDuration += sharedStart.duration(to: end)
                totals.measuredBytes += bytes
            } else {
                totals.firstSyncBytes += bytes
            }
            if index < captureRooms {
                captured.append(zip(sessions[index], frames).map { CapturedFrame(target: "s:\($0.rawValue)", data: Data($1)) })
            }
        }
        return captured
    }

    /// The result JSON's `entityDelta` object. Exits when the shared encode ever differed.
    func report(iterations: Int) -> [String: Any] {
        if totals.sharedMismatches > 0 {
            try? FileHandle.standardError.write(contentsOf: Data("error: entity-delta shared encode differed from the per-client encode in \(totals.sharedMismatches) room syncs\n".utf8))
            exit(1)
        }
        let roomSyncs = Double(max(1, iterations * rooms.count))
        let us = { (d: Duration) in EntityDeltaTotals.ms(d) * 1000 / roomSyncs }
        let bound = rooms.reduce(0) { $0 + ($1.bound?.totalBytes ?? 0) }
        var report: [String: Any] = [
            "format": EntityDeltaRun.formatName,
            "valueWriter": "byte-aligned",
            "totalBytes": totals.measuredBytes,
            "bytesPerSync": iterations > 0 ? Double(totals.measuredBytes) / Double(iterations) : 0,
            "firstSyncBytes": totals.firstSyncBytes,
            "bytesPerSyncBitpackedBound": iterations > 0 ? Double(bound) / Double(iterations) : 0,
            "projectUsPerRoomSync": us(totals.projectDuration),
            "encodeOnlyUsPerRoomSync": us(totals.encodeDuration),
            "encodeUsPerRoomSync": us(totals.projectDuration + totals.encodeDuration),
            "encodeSharedOnlyUsPerRoomSync": us(totals.encodeSharedDuration),
            "encodeSharedUsPerRoomSync": us(totals.projectDuration + totals.encodeSharedDuration),
            "encoderStateBytes": rooms.reduce(0) { $0 + $1.stateBytes },
        ]
        if let before = rssBefore, let after = ProcessUsage.currentResidentBytes() {
            report["rssDeltaMiB"] = (Double(after) - Double(before)) / 1_048_576
        }
        return report
    }
}
