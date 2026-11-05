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

    /// Applies `patches` in order, mirroring the TypeScript client (`sdk/ts/src/core/view.ts`)
    /// where a correct diff can lead:
    /// a set below a missing parent creates it as an empty object (a per-player field's parent
    /// can be absent from the view until its first entry). Where only a wrong diff can lead, it
    /// throws instead of guessing: a set below a parent that is not an object, and a delete of a
    /// field (or below a parent) that is missing. Arrays are replaced whole (the diff never
    /// patches inside an array).
    ///
    /// Two deliberate differences from `view.ts`, both client path-parsing bugs (#121): this
    /// applier unescapes `~1`/`~0`, and it reads a component such as `items[0]` as a key, where
    /// the client reads it as an array element. A passing check through this applier therefore
    /// does not show that the client converges for keys containing `/`, `~` or `[n]`.
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
    ///
    /// Parsed over Unicode scalars, not `Character`s: a `/` or `~1` followed by a combining mark
    /// is one grapheme cluster, and splitting on characters would miss the delimiter.
    package static func keys(of path: String) throws -> [String] {
        let scalars = Array(path.unicodeScalars)
        guard scalars.count > 1, scalars[0] == "/" else {
            throw SnapshotPatchError.invalidPath(path)
        }
        var keys: [String] = []
        var current = String.UnicodeScalarView()
        var index = 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "/" {
                keys.append(String(current))
                current = String.UnicodeScalarView()
            } else if scalar == "~" {
                let next = index + 1
                guard next < scalars.count, scalars[next] == "0" || scalars[next] == "1" else {
                    throw SnapshotPatchError.invalidPath(path)
                }
                current.append(scalars[next] == "1" ? "/" : "~")
                index = next
            } else {
                current.append(scalar)
            }
            index += 1
        }
        keys.append(String(current))
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
