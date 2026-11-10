// Examples/GameDemo/Sources/GameContent/Bound/HeroDefenseBound.swift
//
// Throwaway (step 1 of the flat-storage plan, never merged): Hero Defense's broadcast state in
// hand-written column tables, a dirty-row diff against last-sent buffers updated in place, and an
// encoder that writes today's opcode MessagePack entries (path index, slots, field merge,
// positional atomics) straight from the columns, in the canonical order. No SnapshotValue, no
// path string.
//
// The tables are fed after every tick with compare-on-assign (`mirror`): every row of the
// state is compared column by column, and a changed column is written and marked. The game logic
// keeps its native structs, so the tick pays the native writes and the compares; a land stored
// in the tables would pay the compares and column writes only. Tick time is an upper bound.

import Foundation
import SwiftStateTree
import SwiftStateTreeDeterministicMath
import SwiftStateTreeMessagePack
import SwiftStateTreeTransport

/// The wire ids of one row type: the path index of the row pattern (`monsters.*`) and of each
/// field (`monsters.*.health`), and each field's merge bit.
struct BoundRowIDs {
    let row: UInt64
    let fields: [UInt64]
    let bits: [Int]

    init(parent: String, fields names: [String], hashes: [String: UInt32], hasher: PathHasher) {
        func index(_ pattern: String) -> UInt64 {
            guard let hash = hashes[pattern], let index = hasher.pathIndex(of: hash) else {
                fatalError("bound: no path index for \(pattern)")
            }
            return UInt64(index)
        }
        row = index(parent)
        fields = names.map { index("\(parent).\($0)") }
        // Merge bit: rank among the parent's named children, by UTF-8 bytes.
        let prefix = parent + "."
        let named = hashes.keys.compactMap { pattern -> String? in
            guard pattern.hasPrefix(prefix) else { return nil }
            let rest = pattern.dropFirst(prefix.count)
            guard !rest.contains("."), rest != "*" else { return nil }
            return String(rest)
        }.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        bits = names.map { name in named.firstIndex(of: name)! }
    }
}

@inline(__always) func boundValue(_ p: Position2) -> MessagePackValue {
    .array([.int(Int64(p.v.x)), .int(Int64(p.v.y))])
}
@inline(__always) func boundValue(_ a: Angle) -> MessagePackValue {
    .array([.int(Int64(a.rawDegrees))])
}
@inline(__always) func boundValue(_ i: Int) -> MessagePackValue { .int(Int64(i)) }

/// Field patches of one row, given as (bit, field index, value) in ascending bit order, as the
/// entries today's encoder writes: one merged entry for two or more, a plain one for one.
@inline(__always)
func boundEmitFields(
    _ changed: inout [(bit: Int, field: Int, value: MessagePackValue)],
    ids: BoundRowIDs, keys: [String], into entries: inout [BoundEntry]
) {
    if changed.isEmpty { return }
    if changed.count == 1 {
        entries.append(BoundEntry(pathID: ids.fields[changed[0].field], keys: keys, tail: [.int(Int64(StatePatchOpcode.set.rawValue)), changed[0].value]))
    } else {
        changed.sort { $0.bit < $1.bit }
        var mask: UInt32 = 0
        var tail: [MessagePackValue] = [.int(Int64(MergedPatchOpcode.set.rawValue)), .nil]
        tail.reserveCapacity(changed.count + 2)
        for item in changed {
            mask |= UInt32(1) << UInt32(item.bit)
            tail.append(item.value)
        }
        tail[1] = .uint(UInt64(mask))
        entries.append(BoundEntry(pathID: ids.row, keys: keys, tail: tail))
    }
    changed.removeAll(keepingCapacity: true)
}

/// Row bookkeeping shared by the keyed tables: key → row, free rows, per-row marks.
struct BoundRows<Key: Hashable> {
    var rowOf: [Key: Int] = [:]
    var keyOf: [Key?] = []
    var keyString: [String] = []
    var alive: [Bool] = []
    var free: [Int] = []
    /// Changed-field mask per row since the last sync.
    var mask: [UInt64] = []
    var dirty: [Bool] = []
    var dirtyRows: [Int] = []
    /// Rows created since the last sync (sent whole).
    var created: [Bool] = []
    /// Rows removed since the last sync that the client has: their key strings.
    var removed: [String] = []
    var seen: [UInt32] = []
    var epoch: UInt32 = 0

    /// A new row for `key`; `grow` appends a slot to every column when the table grows.
    mutating func insert(_ key: Key, string: String, grow: () -> Void) -> Int {
        let row: Int
        if let reused = free.popLast() {
            row = reused
            keyOf[row] = key
            keyString[row] = string
            alive[row] = true
            mask[row] = 0
            created[row] = false
            seen[row] = 0
        } else {
            row = alive.count
            keyOf.append(key)
            keyString.append(string)
            alive.append(true)
            mask.append(0)
            dirty.append(false)
            created.append(false)
            seen.append(0)
            grow()
        }
        rowOf[key] = row
        return row
    }

    @inline(__always) mutating func mark(_ row: Int, _ bit: Int) {
        mask[row] |= UInt64(1) << UInt64(bit)
        if !dirty[row] {
            dirty[row] = true
            dirtyRows.append(row)
        }
    }

    mutating func markCreated(_ row: Int) {
        created[row] = true
        if !dirty[row] {
            dirty[row] = true
            dirtyRows.append(row)
        }
    }

    mutating func remove(_ row: Int) {
        guard let key = keyOf[row] else { return }
        rowOf[key] = nil
        alive[row] = false
        keyOf[row] = nil
        if created[row] {
            // Created and removed in one cycle: the client never had it.
            created[row] = false
        } else {
            removed.append(keyString[row])
        }
        mask[row] = 0
        free.append(row)
    }

    /// The rows with a patch this cycle, live and created ones, in key-string byte order.
    func patchRowsSorted() -> [Int] {
        dirtyRows.filter { alive[$0] }.sorted {
            keyString[$0].utf8.lexicographicallyPrecedes(keyString[$1].utf8)
        }
    }

    mutating func clearCycle() {
        for row in dirtyRows {
            dirty[row] = false
            mask[row] = 0
            created[row] = false
        }
        dirtyRows.removeAll(keepingCapacity: true)
        removed.removeAll(keepingCapacity: true)
    }
}

// MARK: - Tables

struct BoundMonsterTable {
    // Field order: by name (the merge bit order): health, id, maxHealth, position, rotation.
    static let names = ["health", "id", "maxHealth", "position", "rotation"]
    var rows = BoundRows<Int>()
    var health: [Int] = [], id: [Int] = [], maxHealth: [Int] = []
    var position: [Position2] = [], rotation: [Angle] = []
    var sentHealth: [Int] = [], sentID: [Int] = [], sentMaxHealth: [Int] = []
    var sentPosition: [Position2] = [], sentRotation: [Angle] = []

    mutating func assign(_ key: Int, _ m: MonsterState, seed: Bool) {
        if let row = rows.rowOf[key] {
            rows.seen[row] = rows.epoch
            if health[row] != m.health { health[row] = m.health; rows.mark(row, 0) }
            if id[row] != m.id { id[row] = m.id; rows.mark(row, 1) }
            if maxHealth[row] != m.maxHealth { maxHealth[row] = m.maxHealth; rows.mark(row, 2) }
            if position[row] != m.position { position[row] = m.position; rows.mark(row, 3) }
            if rotation[row] != m.rotation { rotation[row] = m.rotation; rows.mark(row, 4) }
            return
        }
        let row = rows.insert(key, string: String(key)) {
            health.append(0); id.append(0); maxHealth.append(0); position.append(Position2()); rotation.append(Angle())
            sentHealth.append(0); sentID.append(0); sentMaxHealth.append(0); sentPosition.append(Position2()); sentRotation.append(Angle())
        }
        rows.seen[row] = rows.epoch
        health[row] = m.health; id[row] = m.id; maxHealth[row] = m.maxHealth; position[row] = m.position; rotation[row] = m.rotation
        if seed {
            sentHealth[row] = m.health; sentID[row] = m.id; sentMaxHealth[row] = m.maxHealth; sentPosition[row] = m.position; sentRotation[row] = m.rotation
        } else {
            rows.markCreated(row)
        }
    }

    func rowObject(_ row: Int) -> MessagePackValue {
        .map([
            .string("health"): boundValue(health[row]), .string("id"): boundValue(id[row]),
            .string("maxHealth"): boundValue(maxHealth[row]), .string("position"): boundValue(position[row]),
            .string("rotation"): boundValue(rotation[row]),
        ])
    }

    /// The row's field patches against last-sent, which it then updates in place.
    mutating func diffRow(_ row: Int, ids: BoundRowIDs, into changed: inout [(bit: Int, field: Int, value: MessagePackValue)]) {
        let m = rows.mask[row]
        if m & 1 != 0, health[row] != sentHealth[row] { sentHealth[row] = health[row]; changed.append((ids.bits[0], 0, boundValue(health[row]))) }
        if m & 2 != 0, id[row] != sentID[row] { sentID[row] = id[row]; changed.append((ids.bits[1], 1, boundValue(id[row]))) }
        if m & 4 != 0, maxHealth[row] != sentMaxHealth[row] { sentMaxHealth[row] = maxHealth[row]; changed.append((ids.bits[2], 2, boundValue(maxHealth[row]))) }
        if m & 8 != 0, position[row] != sentPosition[row] { sentPosition[row] = position[row]; changed.append((ids.bits[3], 3, boundValue(position[row]))) }
        if m & 16 != 0, rotation[row] != sentRotation[row] { sentRotation[row] = rotation[row]; changed.append((ids.bits[4], 4, boundValue(rotation[row]))) }
    }

    mutating func sendWhole(_ row: Int) {
        sentHealth[row] = health[row]; sentID[row] = id[row]; sentMaxHealth[row] = maxHealth[row]
        sentPosition[row] = position[row]; sentRotation[row] = rotation[row]
    }
}

struct BoundPlayerTable {
    static let names = ["health", "maxHealth", "position", "resources", "rotation", "targetPosition", "weaponLevel"]
    var rows = BoundRows<PlayerID>()
    var health: [Int] = [], maxHealth: [Int] = [], position: [Position2] = [], resources: [Int] = []
    var rotation: [Angle] = [], targetPosition: [Position2?] = [], weaponLevel: [Int] = []
    var sHealth: [Int] = [], sMaxHealth: [Int] = [], sPosition: [Position2] = [], sResources: [Int] = []
    var sRotation: [Angle] = [], sTargetPosition: [Position2?] = [], sWeaponLevel: [Int] = []

    mutating func assign(_ key: PlayerID, _ p: PlayerState, seed: Bool) {
        if let row = rows.rowOf[key] {
            rows.seen[row] = rows.epoch
            if health[row] != p.health { health[row] = p.health; rows.mark(row, 0) }
            if maxHealth[row] != p.maxHealth { maxHealth[row] = p.maxHealth; rows.mark(row, 1) }
            if position[row] != p.position { position[row] = p.position; rows.mark(row, 2) }
            if resources[row] != p.resources { resources[row] = p.resources; rows.mark(row, 3) }
            if rotation[row] != p.rotation { rotation[row] = p.rotation; rows.mark(row, 4) }
            if targetPosition[row] != p.targetPosition { targetPosition[row] = p.targetPosition; rows.mark(row, 5) }
            if weaponLevel[row] != p.weaponLevel { weaponLevel[row] = p.weaponLevel; rows.mark(row, 6) }
            return
        }
        let row = rows.insert(key, string: key.rawValue) {
            health.append(0); maxHealth.append(0); position.append(Position2()); resources.append(0); rotation.append(Angle()); targetPosition.append(nil); weaponLevel.append(0)
            sHealth.append(0); sMaxHealth.append(0); sPosition.append(Position2()); sResources.append(0); sRotation.append(Angle()); sTargetPosition.append(nil); sWeaponLevel.append(0)
        }
        rows.seen[row] = rows.epoch
        health[row] = p.health; maxHealth[row] = p.maxHealth; position[row] = p.position; resources[row] = p.resources
        rotation[row] = p.rotation; targetPosition[row] = p.targetPosition; weaponLevel[row] = p.weaponLevel
        if seed { sendWhole(row) } else { rows.markCreated(row) }
    }

    mutating func sendWhole(_ row: Int) {
        sHealth[row] = health[row]; sMaxHealth[row] = maxHealth[row]; sPosition[row] = position[row]; sResources[row] = resources[row]
        sRotation[row] = rotation[row]; sTargetPosition[row] = targetPosition[row]; sWeaponLevel[row] = weaponLevel[row]
    }

    func rowObject(_ row: Int) -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [
            .string("health"): boundValue(health[row]), .string("maxHealth"): boundValue(maxHealth[row]),
            .string("position"): boundValue(position[row]), .string("resources"): boundValue(resources[row]),
            .string("rotation"): boundValue(rotation[row]), .string("weaponLevel"): boundValue(weaponLevel[row]),
        ]
        if let target = targetPosition[row] { map[.string("targetPosition")] = boundValue(target) }
        return .map(map)
    }

    /// Field patches; a target cleared to nil is a delete, which today's merge keeps plain and
    /// which closes the row's group (the fields after it start a new entry).
    mutating func diffRow(_ row: Int, ids: BoundRowIDs, keys: [String], into entries: inout [BoundEntry], changed: inout [(bit: Int, field: Int, value: MessagePackValue)]) {
        let m = rows.mask[row]
        if m & 1 != 0, health[row] != sHealth[row] { sHealth[row] = health[row]; changed.append((ids.bits[0], 0, boundValue(health[row]))) }
        if m & 2 != 0, maxHealth[row] != sMaxHealth[row] { sMaxHealth[row] = maxHealth[row]; changed.append((ids.bits[1], 1, boundValue(maxHealth[row]))) }
        if m & 4 != 0, position[row] != sPosition[row] { sPosition[row] = position[row]; changed.append((ids.bits[2], 2, boundValue(position[row]))) }
        if m & 8 != 0, resources[row] != sResources[row] { sResources[row] = resources[row]; changed.append((ids.bits[3], 3, boundValue(resources[row]))) }
        if m & 16 != 0, rotation[row] != sRotation[row] { sRotation[row] = rotation[row]; changed.append((ids.bits[4], 4, boundValue(rotation[row]))) }
        if m & 32 != 0, targetPosition[row] != sTargetPosition[row] {
            sTargetPosition[row] = targetPosition[row]
            if let target = targetPosition[row] {
                changed.append((ids.bits[5], 5, boundValue(target)))
            } else {
                boundEmitFields(&changed, ids: ids, keys: keys, into: &entries)
                entries.append(BoundEntry(pathID: ids.fields[5], keys: keys, tail: [.int(Int64(StatePatchOpcode.remove.rawValue))]))
            }
        }
        if m & 64 != 0, weaponLevel[row] != sWeaponLevel[row] { sWeaponLevel[row] = weaponLevel[row]; changed.append((ids.bits[6], 6, boundValue(weaponLevel[row]))) }
    }
}

struct BoundTurretTable {
    static let names = ["id", "level", "ownerID", "position", "rotation"]
    var rows = BoundRows<Int>()
    var id: [Int] = [], level: [Int] = [], ownerID: [PlayerID?] = [], position: [Position2] = [], rotation: [Angle] = []
    var sID: [Int] = [], sLevel: [Int] = [], sOwnerID: [PlayerID?] = [], sPosition: [Position2] = [], sRotation: [Angle] = []

    mutating func assign(_ key: Int, _ t: TurretState, seed: Bool) {
        if let row = rows.rowOf[key] {
            rows.seen[row] = rows.epoch
            if id[row] != t.id { id[row] = t.id; rows.mark(row, 0) }
            if level[row] != t.level { level[row] = t.level; rows.mark(row, 1) }
            if ownerID[row] != t.ownerID { ownerID[row] = t.ownerID; rows.mark(row, 2) }
            if position[row] != t.position { position[row] = t.position; rows.mark(row, 3) }
            if rotation[row] != t.rotation { rotation[row] = t.rotation; rows.mark(row, 4) }
            return
        }
        let row = rows.insert(key, string: String(key)) {
            id.append(0); level.append(0); ownerID.append(nil); position.append(Position2()); rotation.append(Angle())
            sID.append(0); sLevel.append(0); sOwnerID.append(nil); sPosition.append(Position2()); sRotation.append(Angle())
        }
        rows.seen[row] = rows.epoch
        id[row] = t.id; level[row] = t.level; ownerID[row] = t.ownerID; position[row] = t.position; rotation[row] = t.rotation
        if seed { sendWhole(row) } else { rows.markCreated(row) }
    }

    mutating func sendWhole(_ row: Int) {
        sID[row] = id[row]; sLevel[row] = level[row]; sOwnerID[row] = ownerID[row]; sPosition[row] = position[row]; sRotation[row] = rotation[row]
    }

    func rowObject(_ row: Int) -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [
            .string("id"): boundValue(id[row]), .string("level"): boundValue(level[row]),
            .string("position"): boundValue(position[row]), .string("rotation"): boundValue(rotation[row]),
        ]
        if let owner = ownerID[row] { map[.string("ownerID")] = .string(owner.rawValue) }
        return .map(map)
    }

    mutating func diffRow(_ row: Int, ids: BoundRowIDs, keys: [String], into entries: inout [BoundEntry], changed: inout [(bit: Int, field: Int, value: MessagePackValue)]) {
        let m = rows.mask[row]
        if m & 1 != 0, id[row] != sID[row] { sID[row] = id[row]; changed.append((ids.bits[0], 0, boundValue(id[row]))) }
        if m & 2 != 0, level[row] != sLevel[row] { sLevel[row] = level[row]; changed.append((ids.bits[1], 1, boundValue(level[row]))) }
        if m & 4 != 0, ownerID[row] != sOwnerID[row] {
            sOwnerID[row] = ownerID[row]
            if let owner = ownerID[row] {
                changed.append((ids.bits[2], 2, .string(owner.rawValue)))
            } else {
                boundEmitFields(&changed, ids: ids, keys: keys, into: &entries)
                entries.append(BoundEntry(pathID: ids.fields[2], keys: keys, tail: [.int(Int64(StatePatchOpcode.remove.rawValue))]))
            }
        }
        if m & 8 != 0, position[row] != sPosition[row] { sPosition[row] = position[row]; changed.append((ids.bits[3], 3, boundValue(position[row]))) }
        if m & 16 != 0, rotation[row] != sRotation[row] { sRotation[row] = rotation[row]; changed.append((ids.bits[4], 4, boundValue(rotation[row]))) }
    }
}

/// The root row (`score`) and the base row, held directly.
struct BoundSingles {
    static let baseNames = ["health", "maxHealth", "position", "radius"]
    var score = 0, sScore = 0, scoreDirty = false
    var bHealth = 0, bMaxHealth = 0, bPosition = Position2(), bRadius: Float = 0
    var sbHealth = 0, sbMaxHealth = 0, sbPosition = Position2(), sbRadius: Float = 0
    var baseMask: UInt8 = 0
}

// MARK: - The bound

public final class HeroDefenseBound: @unchecked Sendable {
    var monsters = BoundMonsterTable()
    var players = BoundPlayerTable()
    var turrets = BoundTurretTable()
    var singles = BoundSingles()
    let monsterIDs: BoundRowIDs
    let playerIDs: BoundRowIDs
    let turretIDs: BoundRowIDs
    let baseIDs: BoundRowIDs
    let scoreID: UInt64
    let monstersID: UInt64
    let playersID: UInt64
    let turretsID: UInt64
    private var changed: [(bit: Int, field: Int, value: MessagePackValue)] = []

    /// Per sync: dirty monster rows (with any patch) and live monster rows, for the idle check.
    public private(set) var dirtyMonsterRowsTotal = 0
    public private(set) var monsterRowsTotal = 0
    public private(set) var syncs = 0

    public init(pathHashes: [String: UInt32]) {
        let hasher = PathHasher(pathHashes: pathHashes)
        monsterIDs = BoundRowIDs(parent: "monsters.*", fields: BoundMonsterTable.names, hashes: pathHashes, hasher: hasher)
        playerIDs = BoundRowIDs(parent: "players.*", fields: BoundPlayerTable.names, hashes: pathHashes, hasher: hasher)
        turretIDs = BoundRowIDs(parent: "turrets.*", fields: BoundTurretTable.names, hashes: pathHashes, hasher: hasher)
        baseIDs = BoundRowIDs(parent: "base", fields: BoundSingles.baseNames, hashes: pathHashes, hasher: hasher)
        let rootIDs = BoundRowIDs(parent: "monsters", fields: [], hashes: pathHashes, hasher: hasher)
        monstersID = rootIDs.row
        playersID = BoundRowIDs(parent: "players", fields: [], hashes: pathHashes, hasher: hasher).row
        turretsID = BoundRowIDs(parent: "turrets", fields: [], hashes: pathHashes, hasher: hasher).row
        guard let hash = pathHashes["score"], let index = hasher.pathIndex(of: hash) else { fatalError("bound: score") }
        scoreID = UInt64(index)
    }

    /// The tables from `state`, as already sent: called once, when the bound takes over.
    public func seed(_ state: HeroDefenseState) {
        mirror(state, seed: true)
        clearCycle()
    }

    /// Compare-on-assign of every row of `state`, after a tick.
    public func mirror(_ state: HeroDefenseState) {
        let start = ContinuousClock.now
        mirror(state, seed: false)
        mirrorTime += start.duration(to: ContinuousClock.now)
        mirrors += 1
    }
    public private(set) var mirrorTime = Duration.zero
    public private(set) var mirrors = 0

    private func mirror(_ state: HeroDefenseState, seed: Bool) {
        monsters.rows.epoch &+= 1
        players.rows.epoch &+= 1
        turrets.rows.epoch &+= 1
        for (key, monster) in state.monsters { monsters.assign(key, monster, seed: seed) }
        for (key, player) in state.players { players.assign(key, player, seed: seed) }
        for (key, turret) in state.turrets { turrets.assign(key, turret, seed: seed) }
        if monsters.rows.rowOf.count != state.monsters.count {
            for row in monsters.rows.alive.indices where monsters.rows.alive[row] && monsters.rows.seen[row] != monsters.rows.epoch { monsters.rows.remove(row) }
        }
        if players.rows.rowOf.count != state.players.count {
            for row in players.rows.alive.indices where players.rows.alive[row] && players.rows.seen[row] != players.rows.epoch { players.rows.remove(row) }
        }
        if turrets.rows.rowOf.count != state.turrets.count {
            for row in turrets.rows.alive.indices where turrets.rows.alive[row] && turrets.rows.seen[row] != turrets.rows.epoch { turrets.rows.remove(row) }
        }
        if singles.score != state.score { singles.score = state.score; singles.scoreDirty = true }
        let base = state.base
        if singles.bHealth != base.health { singles.bHealth = base.health; singles.baseMask |= 1 }
        if singles.bMaxHealth != base.maxHealth { singles.bMaxHealth = base.maxHealth; singles.baseMask |= 2 }
        if singles.bPosition != base.position { singles.bPosition = base.position; singles.baseMask |= 4 }
        if singles.bRadius != base.radius { singles.bRadius = base.radius; singles.baseMask |= 8 }
        if seed {
            singles.sScore = singles.score
            singles.sbHealth = singles.bHealth; singles.sbMaxHealth = singles.bMaxHealth
            singles.sbPosition = singles.bPosition; singles.sbRadius = singles.bRadius
        }
    }

    private func clearCycle() {
        monsters.rows.clearCycle()
        players.rows.clearCycle()
        turrets.rows.clearCycle()
        singles.scoreDirty = false
        singles.baseMask = 0
    }

    /// The frame's entries in canonical order: root (score), then the tables base, monsters,
    /// players, turrets; rows by key bytes, a row's own patch before its fields. Last-sent
    /// buffers are updated in place and the cycle's marks cleared.
    public func entries() -> [BoundEntry] {
        var entries: [BoundEntry] = []
        // Table 0: the root's own field.
        if singles.scoreDirty, singles.score != singles.sScore {
            singles.sScore = singles.score
            entries.append(BoundEntry(pathID: scoreID, keys: [], tail: [.int(Int64(StatePatchOpcode.set.rawValue)), boundValue(singles.score)]))
        }
        // Table 1: base.
        if singles.baseMask != 0 {
            let m = singles.baseMask
            if m & 1 != 0, singles.bHealth != singles.sbHealth { singles.sbHealth = singles.bHealth; changed.append((baseIDs.bits[0], 0, boundValue(singles.bHealth))) }
            if m & 2 != 0, singles.bMaxHealth != singles.sbMaxHealth { singles.sbMaxHealth = singles.bMaxHealth; changed.append((baseIDs.bits[1], 1, boundValue(singles.bMaxHealth))) }
            if m & 4 != 0, singles.bPosition != singles.sbPosition { singles.sbPosition = singles.bPosition; changed.append((baseIDs.bits[2], 2, boundValue(singles.bPosition))) }
            if m & 8 != 0, singles.bRadius != singles.sbRadius { singles.sbRadius = singles.bRadius; changed.append((baseIDs.bits[3], 3, .double(Double(singles.bRadius)))) }
            boundEmitFields(&changed, ids: baseIDs, keys: [], into: &entries)
        }
        // Table 2: monsters.
        var dirtyMonsters = 0
        do {
            let removed = monsters.rows.removed
            let rows = monsters.rows.patchRowsSorted()
            var r = 0, d = 0
            let sortedRemoved = removed.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            while r < rows.count || d < sortedRemoved.count {
                let takeRemoved: Bool
                if r == rows.count { takeRemoved = true }
                else if d == sortedRemoved.count { takeRemoved = false }
                else { takeRemoved = sortedRemoved[d].utf8.lexicographicallyPrecedes(monsters.rows.keyString[rows[r]].utf8) }
                if takeRemoved {
                    entries.append(BoundEntry(pathID: monsterIDs.row, keys: [sortedRemoved[d]], tail: [.int(Int64(StatePatchOpcode.remove.rawValue))]))
                    d += 1
                    dirtyMonsters += 1
                    continue
                }
                let row = rows[r]
                r += 1
                let keys = [monsters.rows.keyString[row]]
                if monsters.rows.created[row] {
                    monsters.sendWhole(row)
                    entries.append(BoundEntry(pathID: monsterIDs.row, keys: keys, tail: [.int(Int64(StatePatchOpcode.set.rawValue)), monsters.rowObject(row)]))
                    dirtyMonsters += 1
                    continue
                }
                let before = entries.count
                monsters.diffRow(row, ids: monsterIDs, into: &changed)
                boundEmitFields(&changed, ids: monsterIDs, keys: keys, into: &entries)
                if entries.count != before { dirtyMonsters += 1 }
            }
        }
        // Table 3: players.
        do {
            let sortedRemoved = players.rows.removed.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for key in sortedRemoved {
                entries.append(BoundEntry(pathID: playerIDs.row, keys: [key], tail: [.int(Int64(StatePatchOpcode.remove.rawValue))]))
            }
            for row in players.rows.patchRowsSorted() {
                let keys = [players.rows.keyString[row]]
                if players.rows.created[row] {
                    players.sendWhole(row)
                    entries.append(BoundEntry(pathID: playerIDs.row, keys: keys, tail: [.int(Int64(StatePatchOpcode.set.rawValue)), players.rowObject(row)]))
                    continue
                }
                players.diffRow(row, ids: playerIDs, keys: keys, into: &entries, changed: &changed)
                boundEmitFields(&changed, ids: playerIDs, keys: keys, into: &entries)
            }
        }
        // Table 4: turrets.
        do {
            let sortedRemoved = turrets.rows.removed.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for key in sortedRemoved {
                entries.append(BoundEntry(pathID: turretIDs.row, keys: [key], tail: [.int(Int64(StatePatchOpcode.remove.rawValue))]))
            }
            for row in turrets.rows.patchRowsSorted() {
                let keys = [turrets.rows.keyString[row]]
                if turrets.rows.created[row] {
                    turrets.sendWhole(row)
                    entries.append(BoundEntry(pathID: turretIDs.row, keys: keys, tail: [.int(Int64(StatePatchOpcode.set.rawValue)), turrets.rowObject(row)]))
                    continue
                }
                turrets.diffRow(row, ids: turretIDs, keys: keys, into: &entries, changed: &changed)
                boundEmitFields(&changed, ids: turretIDs, keys: keys, into: &entries)
            }
        }
        syncs += 1
        dirtyMonsterRowsTotal += dirtyMonsters
        monsterRowsTotal += monsters.rows.rowOf.count
        clearCycle()
        return entries
    }
}
