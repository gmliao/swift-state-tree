// EXPERIMENT ONLY (not for merge): two wire changes for the opcode encoders, measured by
// EncodingBenchmark, each behind its own env flag. The format is frozen; nothing reads these
// frames except the verifier below.
//
//   SST_EXP_PATH_INDEX=1  the path id is the rank of the pattern's hash among the land's sorted
//                         schema path hashes, not the 32-bit hash.
//   SST_EXP_PATCH_MERGE=1 patches in one frame to named leaves of the same parent node, with the
//                         same dynamic keys and the same op, are sent as one entry
//                         `[parentId, keys, op, fieldMask, v1, v2, ...]`. The mask bit of a field
//                         is its rank among the parent's named children, sorted by name. Not
//                         merged: deletes, root-level fields,
//                         paths without a schema pattern, patterns with a pattern below them
//                         (object-level sets; an atomic value, in the atomic layout table, is a
//                         leaf), and groups of one.
//   SST_EXP_VERIFY=1      after every frame, expand it back to plain entries and check they are
//                         the unflagged encoder's entries (path hash, keys, op, wire value), as a
//                         set: a frame's patches have distinct paths.

import Foundation
import SwiftStateTree
import SwiftStateTreeMessagePack

package enum ExperimentalPathWire {
    package static let index: Bool = EnvHelpers.getEnvBool(key: "SST_EXP_PATH_INDEX", defaultValue: false)
    package static let merge: Bool = EnvHelpers.getEnvBool(key: "SST_EXP_PATCH_MERGE", defaultValue: false)
    package static let verify: Bool = EnvHelpers.getEnvBool(key: "SST_EXP_VERIFY", defaultValue: false)
    package static var active: Bool { index || merge || verify }

    // MARK: Layout derived from the schema's path hashes

    package final class Layout: @unchecked Sendable {
        let sortedHashes: [UInt32]
        let rank: [UInt32: Int]
        let patternOfHash: [UInt32: String]
        let hashOfPattern: [String: UInt32]
        /// Named children of a parent pattern, sorted by name.
        let children: [String: [String]]
        /// Patterns with a longer pattern below them (not leaves).
        let inner: Set<String>

        init(_ hasher: PathHasher) {
            hashOfPattern = hasher.patternHashes
            sortedHashes = Array(Set(hashOfPattern.values)).sorted()
            rank = Dictionary(uniqueKeysWithValues: sortedHashes.enumerated().map { ($1, $0) })
            patternOfHash = Dictionary(hashOfPattern.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            var children: [String: Set<String>] = [:]
            var inner: Set<String> = []
            for pattern in hashOfPattern.keys {
                guard let dot = pattern.lastIndex(of: ".") else { continue }
                inner.insert(String(pattern[..<dot]))
                let name = String(pattern[pattern.index(after: dot)...])
                guard name != "*" else { continue }
                children[String(pattern[..<dot]), default: []].insert(name)
            }
            self.children = children.mapValues { $0.sorted() }
            self.inner = inner
        }

        /// The path id on the wire.
        func id(_ hash: UInt32) -> UInt64 {
            if ExperimentalPathWire.index, let r = rank[hash] { return UInt64(r) }
            return UInt64(hash)
        }

        /// The hash for a wire id (verifier).
        func hash(ofId id: UInt64) -> UInt32 {
            ExperimentalPathWire.index ? sortedHashes[Int(id)] : UInt32(id)
        }
    }

    private static let layouts = LayoutCache()

    private final class LayoutCache: @unchecked Sendable {
        private var byPatterns: [Int: Layout] = [:]
        private let lock = NSLock()
        func layout(for hasher: PathHasher) -> Layout {
            let key = hasher.patternHashes.count ^ hasher.patternHashes.values.reduce(0) { $0 &+ Int($1) }
            lock.lock(); defer { lock.unlock() }
            if let layout = byPatterns[key] { return layout }
            let layout = Layout(hasher)
            byPatterns[key] = layout
            return layout
        }
    }

    package static func layout(for hasher: PathHasher) -> Layout {
        _ = reportAtExit
        return layouts.layout(for: hasher)
    }

    /// Prints the counters once, at process exit: `EXP_PATH_WIRE {json}`.
    private static let reportAtExit: Void = {
        atexit {
            let s = ExperimentalPathWire.stats
            let line = "EXP_PATH_WIRE {\"index\":\(ExperimentalPathWire.index),\"merge\":\(ExperimentalPathWire.merge),\"verify\":\(ExperimentalPathWire.verify),\"frames\":\(s.frames),\"patches\":\(s.patches),\"entries\":\(s.entries),\"mergedGroups\":\(s.mergedGroups),\"mergedMembers\":\(s.mergedMembers),\"idBytes\":\(s.idBytes),\"verifiedFrames\":\(s.verifiedFrames)}\n"
            FileHandle.standardError.write(Data(line.utf8))
            if ExperimentalPathWire.dumpPatterns {
                for (row, n) in s.patterns.sorted(by: { $0.value > $1.value }) {
                    FileHandle.standardError.write(Data("EXP_PATTERN \(n) \(row)\n".utf8))
                }
                for (k, n) in s.perFrame.sorted(by: { $0.key < $1.key }) {
                    FileHandle.standardError.write(Data("EXP_PER_FRAME \(k) \(n)\n".utf8))
                }
            }
        }
    }()

    // MARK: Plan

    package enum Item {
        case plain(StatePatch)
        /// `members` in mask order.
        case merged(parentHash: UInt32, keys: [String], op: StatePatchOpcode, mask: UInt64, members: [StatePatch])
    }

    package static func plan(_ patches: [StatePatch], hasher: PathHasher, layout: Layout, atomic: AtomicLayoutTable?) -> [Item] {
        guard merge else { return patches.map { .plain($0) } }
        struct GroupKey: Hashable { let parent: UInt32; let keys: [String]; let op: UInt8 }
        var groups: [GroupKey: [(bit: Int, patch: StatePatch)]] = [:]
        var order: [Either] = []
        enum Either { case plain(StatePatch); case group(GroupKey) }
        for patch in patches {
            let op: StatePatchOpcode
            switch patch.operation {
            case .set: op = .set
            case .add: op = .add
            case .delete: order.append(.plain(patch)); continue
            }
            let (hash, keys) = hasher.split(patch.path)
            // A leaf is a pattern with nothing below it in the schema; an atomic value (Position2,
            // Angle) is one, though its logical value is an object.
            guard let pattern = layout.patternOfHash[hash],
                  !layout.inner.contains(pattern) || atomic?.patterns[pattern] != nil,
                  let dot = pattern.lastIndex(of: ".") else {
                order.append(.plain(patch)); continue
            }
            let name = String(pattern[pattern.index(after: dot)...])
            let parent = String(pattern[..<dot])
            guard name != "*", let parentHash = layout.hashOfPattern[parent],
                  let bit = layout.children[parent]?.firstIndex(of: name) else {
                order.append(.plain(patch)); continue
            }
            let key = GroupKey(parent: parentHash, keys: keys, op: UInt8(op.rawValue))
            if groups[key] == nil { order.append(.group(key)) }
            groups[key, default: []].append((bit, patch))
        }
        return order.flatMap { entry -> [Item] in
            switch entry {
            case .plain(let patch):
                return [.plain(patch)]
            case .group(let key):
                let members = groups[key]!
                if members.count < 2 { return [.plain(members[0].patch)] }
                let sorted = members.sorted { $0.bit < $1.bit }
                let mask = sorted.reduce(UInt64(0)) { $0 | (UInt64(1) << UInt64($1.bit)) }
                return [.merged(
                    parentHash: key.parent, keys: key.keys, op: StatePatchOpcode(rawValue: Int(key.op))!,
                    mask: mask, members: sorted.map(\.patch)
                )]
            }
        }
    }

    // MARK: Stats

    package struct Stats: Sendable {
        package var frames = 0
        package var patches = 0
        package var entries = 0
        package var mergedGroups = 0
        package var mergedMembers = 0
        package var idBytes = 0
        package var verifiedFrames = 0
        /// `pattern op kind` → count, with SST_EXP_PATTERNS=1.
        package var patterns: [String: Int] = [:]
        /// patches per frame → frames.
        package var perFrame: [Int: Int] = [:]
    }

    package static let dumpPatterns: Bool = EnvHelpers.getEnvBool(key: "SST_EXP_PATTERNS", defaultValue: false)

    package static func recordPatterns(_ patches: [StatePatch], layout: Layout, hasher: PathHasher) {
        guard dumpPatterns else { return }
        let rows = patches.map { patch -> String in
            let pattern = layout.patternOfHash[hasher.split(patch.path).pathHash] ?? "?\(patch.path)"
            switch patch.operation {
            case .set(let v): return "\(pattern) set \(kind(v))"
            case .add(let v): return "\(pattern) add \(kind(v))"
            case .delete: return "\(pattern) delete"
            }
        }
        record { s in
            for row in rows { s.patterns[row, default: 0] += 1 }
            s.perFrame[patches.count, default: 0] += 1
        }
    }

    private static func kind(_ v: SnapshotValue) -> String {
        switch v {
        case .object: return "object"
        case .array: return "array"
        case .null: return "null"
        default: return "scalar"
        }
    }

    private final class StatsBox: @unchecked Sendable {
        var stats = Stats()
        let lock = NSLock()
    }

    private static let statsBox = StatsBox()

    package static func record(_ update: (inout Stats) -> Void) {
        statsBox.lock.lock(); defer { statsBox.lock.unlock() }
        update(&statsBox.stats)
    }

    package static var stats: Stats {
        statsBox.lock.lock(); defer { statsBox.lock.unlock() }
        return statsBox.stats
    }

    package static func recordPlan(_ items: [Item], patchCount: Int, idBytes: Int) {
        record { s in
            s.frames += 1
            s.patches += patchCount
            s.entries += items.count
            s.idBytes += idBytes
            for case .merged(_, _, _, _, let members) in items {
                s.mergedGroups += 1
                s.mergedMembers += members.count
            }
        }
    }

    /// Bytes of an unsigned id: MessagePack (positive fixint, uint8/16/32) or JSON digits.
    package static func idSize(_ id: UInt64, json: Bool) -> Int {
        if json { return String(id).utf8.count }
        switch id {
        case 0..<128: return 1
        case 128..<256: return 2
        case 256..<65536: return 3
        case 65536..<4_294_967_296: return 5
        default: return 9
        }
    }

    // MARK: Verifier

    /// Slot → key for one key scope, mirrored from the flagged frames.
    package final class SlotMirror: @unchecked Sendable {
        private var tables: [String: [Int: String]] = [:]
        private let lock = NSLock()
        func resolve(_ raw: Any?, scope: String, reset: Bool) throws -> [String] {
            lock.lock(); defer { lock.unlock() }
            if reset { tables[scope] = [:] }
            var table = tables[scope] ?? [:]
            defer { tables[scope] = table }
            func one(_ raw: Any) throws -> String {
                if let key = raw as? String { return key }
                if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    guard let key = table[number.intValue] else { throw Mismatch("slot \(number) used before definition") }
                    return key
                }
                if let pair = raw as? [Any], pair.count == 2, let slot = pair[0] as? NSNumber, let key = pair[1] as? String {
                    table[slot.intValue] = key
                    return key
                }
                throw Mismatch("bad key \(raw)")
            }
            guard let raw, !(raw is NSNull) else { return [] }
            if let array = raw as? [Any] {
                // [slot, "key"] is one key definition; otherwise a list of keys.
                if array.count == 2, array[0] is NSNumber, array[1] is String { return [try one(array)] }
                return try array.map(one)
            }
            return [try one(raw)]
        }
    }

    package struct Mismatch: Error, CustomStringConvertible {
        package let description: String
        init(_ description: String) { self.description = description }
    }

    static func canonical(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// `frame` is `[opcode, entry, ...]` as plain values; `reference` the unflagged entries
    /// `(hash, keys, op, canonical value or nil)`.
    package static func verify(
        frame: [Any], reference: [(UInt32, [String], Int, String?)], layout: Layout,
        mirror: SlotMirror, scope: String, reset: Bool
    ) throws {
        var expanded: [String] = []
        var first = true
        for case let entry as [Any] in frame.dropFirst() {
            let isMerged = entry.count >= 6
            guard let rawId = entry[0] as? NSNumber, let op = entry[2] as? NSNumber else { throw Mismatch("bad entry \(entry)") }
            let keys = try mirror.resolve(entry[1], scope: scope, reset: reset && first)
            first = false
            let hash = layout.hash(ofId: rawId.uint64Value)
            if !isMerged {
                let value = entry.count > 3 ? canonical(entry[3]) : "-"
                expanded.append("\(hash)|\(keys)|\(op)|\(value)")
                continue
            }
            guard let parent = layout.patternOfHash[hash], let names = layout.children[parent],
                  let mask = (entry[3] as? NSNumber)?.uint64Value else { throw Mismatch("bad merged entry \(entry)") }
            var valueIndex = 4
            for (bit, name) in names.enumerated() where mask & (UInt64(1) << UInt64(bit)) != 0 {
                guard let child = layout.hashOfPattern["\(parent).\(name)"], valueIndex < entry.count else {
                    throw Mismatch("mask \(mask) beyond \(parent)'s fields")
                }
                expanded.append("\(child)|\(keys)|\(op)|\(canonical(entry[valueIndex]))")
                valueIndex += 1
            }
            guard valueIndex == entry.count else { throw Mismatch("merged entry has \(entry.count - valueIndex) extra values") }
        }
        let expected = reference.map { "\($0.0)|\($0.1)|\($0.2)|\($0.3 ?? "-")" }
        guard expanded.sorted() == expected.sorted() else {
            throw Mismatch("frame differs:\n  expanded \(expanded.sorted())\n  expected \(expected.sorted())")
        }
        record { $0.verifiedFrames += 1 }
    }

    /// A MessagePack value as plain Foundation values (verifier).
    package static func plain(_ value: MessagePackValue) -> Any {
        switch value {
        case .nil: return NSNull()
        case .bool(let b): return b
        case .int(let i): return NSNumber(value: i)
        case .uint(let u): return NSNumber(value: u)
        case .float(let f): return NSNumber(value: Double(f))
        case .double(let d): return NSNumber(value: d)
        case .string(let s): return s
        case .binary(let d): return d.base64EncodedString()
        case .array(let a): return a.map(plain)
        case .map(let m):
            var out: [String: Any] = [:]
            for (k, v) in m { if case .string(let key) = k { out[key] = plain(v) } else { out["\(k)"] = plain(v) } }
            return out
        case .extended(let t, let d): return "ext\(t):\(d.base64EncodedString())"
        }
    }
}
