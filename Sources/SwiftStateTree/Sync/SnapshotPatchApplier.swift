// Sources/SwiftStateTree/Sync/SnapshotPatchApplier.swift
//
// Applies state patches to a client view, as a client would. It parses JSON Pointer paths
// itself and shares no helper with the diff (`SyncEngine`), so a bug in the diff's path
// building cannot cancel out here: the sync-output replay check uses it as an oracle.

import Foundation

/// Why a patch could not be applied.
package enum SnapshotPatchError: Error, Equatable, Sendable {
    /// The path is not a JSON Pointer to a field (empty, or not starting with `/`).
    case invalidPath(String)
    /// A component on the way to the target exists but is not an object.
    case nonObjectParent(String)
    /// A component on the way to a deleted field is missing.
    case missingParent(String)
    /// A delete for a field that does not exist.
    case missingTarget(String)
}

/// A client's view of one sync scope: the top-level fields and everything below them.
package struct SnapshotClientView: Equatable, Sendable {
    package private(set) var fields: [String: SnapshotValue]

    package init(fields: [String: SnapshotValue] = [:]) {
        self.fields = fields
    }

    /// Applies `patches` in order, as the TypeScript client does where a correct diff can lead:
    /// a set below a missing parent creates it as an empty object (a per-player field's parent
    /// can be absent from the view until its first entry). Where only a wrong diff can lead, it
    /// throws instead of guessing: a set below a parent that is not an object, and a delete of a
    /// field (or below a parent) that is missing. Arrays are replaced whole (the diff never
    /// patches inside an array).
    package mutating func apply(_ patches: [StatePatch]) throws {
        for patch in patches {
            try apply(patch)
        }
    }

    package mutating func apply(_ patch: StatePatch) throws {
        let keys = try Self.keys(of: patch.path)
        switch patch.operation {
        case .set(let value), .add(let value):
            fields = try Self.setting(value, at: keys[...], in: fields, path: patch.path)
        case .delete:
            fields = try Self.deleting(at: keys[...], in: fields, path: patch.path)
        }
    }

    /// The unescaped keys of a JSON Pointer (RFC 6901): `~1` is `/`, then `~0` is `~`.
    package static func keys(of path: String) throws -> [String] {
        guard path.hasPrefix("/"), path.count > 1 else {
            throw SnapshotPatchError.invalidPath(path)
        }
        var keys: [String] = []
        var current = ""
        var index = path.index(after: path.startIndex)
        while index < path.endIndex {
            let character = path[index]
            if character == "/" {
                keys.append(current)
                current = ""
            } else if character == "~" {
                let next = path.index(after: index)
                guard next < path.endIndex, path[next] == "0" || path[next] == "1" else {
                    throw SnapshotPatchError.invalidPath(path)
                }
                current.append(path[next] == "1" ? "/" : "~")
                index = next
            } else {
                current.append(character)
            }
            index = path.index(after: index)
        }
        keys.append(current)
        return keys
    }

    private static func setting(
        _ value: SnapshotValue,
        at keys: ArraySlice<String>,
        in object: [String: SnapshotValue],
        path: String
    ) throws -> [String: SnapshotValue] {
        var object = object
        let key = keys[keys.startIndex]
        if keys.count == 1 {
            object[key] = value
            return object
        }
        let child: [String: SnapshotValue]
        switch object[key] {
        case nil:
            child = [:]
        case .object(let existing)?:
            child = existing
        case .some:
            throw SnapshotPatchError.nonObjectParent(path)
        }
        object[key] = .object(try setting(value, at: keys.dropFirst(), in: child, path: path))
        return object
    }

    private static func deleting(
        at keys: ArraySlice<String>,
        in object: [String: SnapshotValue],
        path: String
    ) throws -> [String: SnapshotValue] {
        var object = object
        let key = keys[keys.startIndex]
        if keys.count == 1 {
            guard object.removeValue(forKey: key) != nil else {
                throw SnapshotPatchError.missingTarget(path)
            }
            return object
        }
        guard let parent = object[key] else {
            throw SnapshotPatchError.missingParent(path)
        }
        guard case .object(let child) = parent else {
            throw SnapshotPatchError.nonObjectParent(path)
        }
        object[key] = .object(try deleting(at: keys.dropFirst(), in: child, path: path))
        return object
    }
}
