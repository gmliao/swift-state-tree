import Foundation
import SwiftStateTree

/// The op of a merged entry (`[parentId, dynamicKey, op, fieldMask, v1, v2, …]`).
public enum MergedPatchOpcode: Int, Sendable {
    /// Each field is set (as `StatePatchOpcode.set`).
    case set = 4
    /// Each field is added (as `StatePatchOpcode.add`).
    case add = 5
}

/// One entry of an opcode frame: a patch on its own, or patches merged under their parent.
enum FieldMergeEntry {
    case plain(Int)
    /// `members` are patch indices with their bits, in ascending bit order.
    case merged(parentHash: UInt32, dynamicKeys: [String], op: MergedPatchOpcode, members: [(bit: Int, index: Int)])

    /// The mask of a merged entry's members.
    static func mask(_ members: [(bit: Int, index: Int)]) -> UInt32 {
        members.reduce(0) { $0 | (UInt32(1) << UInt32($1.bit)) }
    }
}

enum FieldMergePlan {
    /// The frame's entries. Patches that set (or add) mergeable fields of one parent with the
    /// same dynamic keys and op share an entry, at the position of the first of them; a group of
    /// one stays plain. Deletes, object-level sets and paths outside the schema stay plain.
    ///
    /// Merging moves later members forward, past the patches between them. That is safe only
    /// past a patch that touches none of the group's fields, so a patch at, above or below the
    /// group's parent path (other than a member) closes the group, and later fields of that
    /// parent start a new one: a delete of the entity, or a set of the whole entity, between two
    /// field sets keeps them on either side of it.
    static func entries(
        patches: [StatePatch],
        splits: [(pathHash: UInt32, dynamicKeys: [String], inSchema: Bool)],
        table: FieldMergeTable?
    ) -> [FieldMergeEntry] {
        guard let table, patches.count > 1 else { return patches.indices.map { .plain($0) } }
        struct GroupKey: Hashable {
            let parentHash: UInt32
            let dynamicKeys: [String]
            let op: Int
        }
        final class Group {
            let key: GroupKey
            let parentPath: Substring
            var members: [(bit: Int, index: Int)] = []
            var open = true
            init(key: GroupKey, parentPath: Substring) {
                self.key = key
                self.parentPath = parentPath
            }
        }
        var order: [Either] = []
        enum Either { case plain(Int), group(Group) }
        var openByKey: [GroupKey: Group] = [:]
        var openByParentPath: [Substring: [Group]] = [:]

        func close(_ group: Group) {
            group.open = false
            openByKey[group.key] = nil
            openByParentPath[group.parentPath]?.removeAll { $0 === group }
        }
        /// Closes the open groups whose parent path is `path` or one of its ancestors, except
        /// `keep`; with `ancestorOfParents`, also those below `path`.
        func closeOverlapping(_ path: String, keep: Group?, ancestorOfParents: Bool) {
            if openByParentPath.isEmpty { return }
            var end = path.endIndex
            while true {
                let prefix = path[path.startIndex ..< end]
                if let groups = openByParentPath[prefix] {
                    for group in groups where group !== keep { close(group) }
                }
                guard let slash = path[path.startIndex ..< end].lastIndex(of: "/") else { break }
                end = slash
            }
            if ancestorOfParents {
                for group in openByKey.values where group !== keep {
                    let parent = group.parentPath
                    if parent.count > path.count, parent.hasPrefix(path), parent[parent.index(parent.startIndex, offsetBy: path.count)] == "/" {
                        close(group)
                    }
                }
            }
        }

        for (index, patch) in patches.enumerated() {
            let op: MergedPatchOpcode?
            switch patch.operation {
            case .set: op = .set
            case .add: op = .add
            case .delete: op = nil
            }
            guard let op, let field = table.field(ofHash: splits[index].pathHash),
                  let slash = patch.path.lastIndex(of: "/") else {
                closeOverlapping(patch.path, keep: nil, ancestorOfParents: true)
                order.append(.plain(index))
                continue
            }
            let key = GroupKey(parentHash: field.parentHash, dynamicKeys: splits[index].dynamicKeys, op: op.rawValue)
            var group = openByKey[key]
            // The same field twice (not expected in a frame): the later one starts a new group.
            if let existing = group, existing.members.contains(where: { $0.bit == field.bit }) {
                close(existing)
                group = nil
            }
            // A field patch can be the parent of another group (an atomic value's leaves).
            closeOverlapping(patch.path, keep: group, ancestorOfParents: field.hasPatternsBelow)
            if group == nil || group?.open == false {
                let created = Group(key: key, parentPath: patch.path[patch.path.startIndex ..< slash])
                openByKey[key] = created
                openByParentPath[created.parentPath, default: []].append(created)
                order.append(.group(created))
                group = created
            }
            group!.members.append((field.bit, index))
        }
        return order.map { item in
            switch item {
            case .plain(let index):
                return .plain(index)
            case .group(let group):
                if group.members.count == 1 { return .plain(group.members[0].index) }
                return .merged(
                    parentHash: group.key.parentHash,
                    dynamicKeys: group.key.dynamicKeys,
                    op: MergedPatchOpcode(rawValue: group.key.op)!,
                    members: group.members.sorted { $0.bit < $1.bit }
                )
            }
        }
    }
}
