import Foundation
import SwiftStateTree

/// The op of a row entry (`rowAddressing`): a row of a slot-addressed table is named by its
/// slot, not by its key.
public enum RowPatchOpcode: Int, Sendable {
    /// `[tableId, slot, 6, generation, parentSlot, key, value]`: a new row, whole.
    case create = 6
    /// `[tableId, slot, 7]`: the row and everything below it is removed.
    case delete = 7
    /// `[leafPathId, [slot, …], 8, [value, …]]`: one leaf set in those rows, slots ascending.
    case columnSet = 8
    /// `[leafPathId, [slot, …], 9]`: one leaf removed in those rows, slots ascending.
    case columnClear = 9
}

/// One row entry of an opcode frame. Indices are into the patches the plan was made from.
enum RowEntry {
    case create(table: UInt32, slot: Int32, generation: UInt32, key: String, index: Int)
    case delete(table: UInt32, slot: Int32, index: Int)
    /// `members` in ascending slot order.
    case columnSet(leaf: UInt32, members: [(slot: Int32, index: Int)])
    /// `members` in ascending slot order.
    case columnClear(leaf: UInt32, members: [(slot: Int32, index: Int)])
}

enum RowEntryPlan {
    /// Takes the patches that become row entries out of a frame's patches.
    ///
    /// A patch is a row entry when the diff that made it tagged it with its row
    /// (`PatchSplit.row`, from this hasher's trie) and the row's key is its only dynamic key:
    /// - at the row's own pattern, a set that carries a generation is a create and a delete is a
    ///   delete;
    /// - below it, a set is a column set and a delete a column clear.
    ///
    /// Every other patch stays in `rest`, in the order given: one with no tag, one below a value
    /// map or a nested node map of a row (two or more dynamic keys), and an `add`.
    ///
    /// `rows` are in the frame's order: per table in the order of `id` (the path id the frame
    /// writes), creates by slot, then columns by the leaf's `id` (a leaf's set before its
    /// clear) with slots ascending, then deletes by slot.
    static func plan(
        patches: [StatePatch],
        hasher: PathHasher,
        id: (UInt32) -> Int
    ) -> (rest: [StatePatch], rows: [RowEntry]) {
        struct Table {
            var creates: [(slot: Int32, generation: UInt32, key: String, index: Int)] = []
            var deletes: [(slot: Int32, index: Int)] = []
            /// By leaf hash.
            var sets: [UInt32: [(slot: Int32, index: Int)]] = [:]
            var clears: [UInt32: [(slot: Int32, index: Int)]] = [:]
        }
        var tables: [UInt32: Table] = [:]
        var rest: [StatePatch] = []
        var taken = false
        for (index, patch) in patches.enumerated() {
            guard let split = patch.split, split.belongs(to: hasher), let row = split.row,
                  split.dynamicKeys.count == 1
            else {
                if taken { rest.append(patch) }
                continue
            }
            let atRow = split.pathHash == row.table
            var isRowEntry = true
            switch (patch.operation, atRow, row.generation) {
            case (.set, true, let generation?):
                tables[row.table, default: Table()].creates.append((row.slot, generation, split.dynamicKeys[0], index))
            case (.delete, true, _):
                tables[row.table, default: Table()].deletes.append((row.slot, index))
            case (.set, false, _):
                tables[row.table, default: Table()].sets[split.pathHash, default: []].append((row.slot, index))
            case (.delete, false, _):
                tables[row.table, default: Table()].clears[split.pathHash, default: []].append((row.slot, index))
            default:
                isRowEntry = false
            }
            if isRowEntry {
                if !taken {
                    // The first row entry: everything before it stays.
                    taken = true
                    rest.reserveCapacity(patches.count)
                    rest.append(contentsOf: patches[..<index])
                }
            } else if taken {
                rest.append(patch)
            }
        }
        guard taken else { return (patches, []) }

        var rows: [RowEntry] = []
        for (table, content) in tables.sorted(by: { id($0.key) < id($1.key) }) {
            for create in content.creates.sorted(by: { $0.slot < $1.slot }) {
                rows.append(.create(table: table, slot: create.slot, generation: create.generation, key: create.key, index: create.index))
            }
            let leaves = Set(content.sets.keys).union(content.clears.keys).sorted { id($0) < id($1) }
            for leaf in leaves {
                if let members = content.sets[leaf] {
                    rows.append(.columnSet(leaf: leaf, members: members.sorted { $0.slot < $1.slot }))
                }
                if let members = content.clears[leaf] {
                    rows.append(.columnClear(leaf: leaf, members: members.sorted { $0.slot < $1.slot }))
                }
            }
            for delete in content.deletes.sorted(by: { $0.slot < $1.slot }) {
                rows.append(.delete(table: table, slot: delete.slot, index: delete.index))
            }
        }
        return (rest, rows)
    }
}
