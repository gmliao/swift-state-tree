import Foundation

/// A value at an atomic path that can't be written (or read) in the positional form.
public struct AtomicPositionalFormError: Error, Equatable, CustomStringConvertible {
    /// The patch path the value was written for, e.g. `/players/p1/position`.
    public let path: String
    public let reason: String

    public var description: String { "atomic value at \(path): \(reason)" }
}

/// The positional wire form of atomic values (`AtomicSnapshotValue`).
///
/// The opcode encoders send a value at an atomic path as the array of its leaves, in the type's
/// `atomicLeafPaths` order (`Position2` → `[x, y]`, `Angle` → `[d]`), and recurse into objects
/// and arrays, so an atomic value nested in a patch value (a player added with a position, a
/// firstSync snapshot) is positional too. Everything else stays as it is. The logical form
/// (`SnapshotValue`, `StatePatch`, every state and sync-output hash) stays keyed: this is only a
/// wire transform, and `keyed(_:atPath:)` is its inverse for decoders.
extension AtomicLayoutTable {
    /// The table position of a patch path (`/players/p1/position`), or `nil` when no atomic
    /// value is at or below it.
    package func node(atPath path: String) -> Node? {
        guard var node = root else { return nil }
        // Empty components are keys too (`/m/` is the entry under `""`).
        for component in PathHasher.components(of: path) {
            guard let next = node.child(component) else { return nil }
            node = next
        }
        return node
    }

    /// `value`, written at `path`, with every atomic value in it as the array of its leaves.
    /// Throws when a value at an atomic path doesn't have exactly the declared leaves (a value
    /// built by hand, a custom `toSnapshotValue`), so it is reported, never sent half-converted.
    package func positional(_ value: SnapshotValue, atPath path: String) throws -> SnapshotValue {
        try positional(value, at: node(atPath: path), path: path)
    }

    /// `positional(_:atPath:)` with the path's table position already known (`node(atPath:)`,
    /// or `AtomicPatternIndex`); `path` is only for the errors and the nested values' paths.
    package func positional(_ value: SnapshotValue, at node: Node?, path: String) throws -> SnapshotValue {
        guard let node else { return value }
        return try Self.positional(value, at: node, path: path)
    }

    /// The keyed form of `value`, received at `path` in either form: a positional array at an
    /// atomic path is rebuilt from the leaf paths; a keyed object is accepted as it is (a
    /// `.keyed` server). Throws on an array of the wrong length or with a non-scalar leaf.
    package func keyed(_ value: SnapshotValue, atPath path: String) throws -> SnapshotValue {
        guard let node = node(atPath: path) else { return value }
        return try Self.keyed(value, at: node, path: path)
    }

    // MARK: - Encode

    private static func positional(_ value: SnapshotValue, at node: Node, path: String) throws -> SnapshotValue {
        if let leafPaths = node.leafPaths {
            switch value {
            case .null:
                return .null
            case .object(let object):
                return .array(try leaves(of: object, in: leafPaths, path: path))
            default:
                throw AtomicPositionalFormError(path: path, reason: "expected an object, got \(kind(value))")
            }
        }
        switch value {
        case .object(let object):
            var result = object
            for (key, child) in object {
                if let childNode = node.child(key) {
                    result[key] = try positional(child, at: childNode, path: path + "/" + key)
                }
            }
            return .object(result)
        case .array(let elements):
            guard let elementNode = node.wildcard else { return value }
            var result = elements
            for index in elements.indices {
                result[index] = try positional(elements[index], at: elementNode, path: path + "/\(index)")
            }
            return .array(result)
        default:
            return value
        }
    }

    /// The leaves of `object` in `leafPaths` order; its leaf set must be exactly `leafPaths`.
    private static func leaves(
        of object: [String: SnapshotValue], in leafPaths: [[String]], path: String
    ) throws -> [SnapshotValue] {
        var found = 0
        countLeaves(.object(object), into: &found)
        guard found == leafPaths.count else {
            throw AtomicPositionalFormError(
                path: path, reason: "has \(found) leaves, its type declares \(leafPaths.count)"
            )
        }
        var result: [SnapshotValue] = []
        result.reserveCapacity(leafPaths.count)
        for leafPath in leafPaths {
            var current = SnapshotValue.object(object)
            for key in leafPath {
                guard case .object(let fields) = current, let next = fields[key] else {
                    throw AtomicPositionalFormError(
                        path: path, reason: "no leaf \(leafPath.joined(separator: "."))"
                    )
                }
                current = next
            }
            guard isScalar(current) else {
                throw AtomicPositionalFormError(
                    path: path, reason: "leaf \(leafPath.joined(separator: ".")) is \(kind(current))"
                )
            }
            result.append(current)
        }
        return result
    }

    private static func countLeaves(_ value: SnapshotValue, into count: inout Int) {
        if case .object(let fields) = value, !fields.isEmpty {
            for child in fields.values {
                countLeaves(child, into: &count)
            }
        } else {
            count += 1
        }
    }

    // MARK: - Decode

    private static func keyed(_ value: SnapshotValue, at node: Node, path: String) throws -> SnapshotValue {
        if let leafPaths = node.leafPaths {
            switch value {
            case .null, .object:
                return value
            case .array(let leaves):
                guard leaves.count == leafPaths.count else {
                    throw AtomicPositionalFormError(
                        path: path, reason: "has \(leaves.count) leaves, its type declares \(leafPaths.count)"
                    )
                }
                var object: [String: SnapshotValue] = [:]
                for (leaf, leafPath) in zip(leaves, leafPaths) {
                    guard isScalar(leaf) else {
                        throw AtomicPositionalFormError(
                            path: path, reason: "leaf \(leafPath.joined(separator: ".")) is \(kind(leaf))"
                        )
                    }
                    insert(leaf, at: leafPath[...], into: &object)
                }
                return .object(object)
            default:
                throw AtomicPositionalFormError(path: path, reason: "expected an array, got \(kind(value))")
            }
        }
        switch value {
        case .object(let object):
            var result = object
            for (key, child) in object {
                if let childNode = node.child(key) {
                    result[key] = try keyed(child, at: childNode, path: path + "/" + key)
                }
            }
            return .object(result)
        case .array(let elements):
            guard let elementNode = node.wildcard else { return value }
            var result = elements
            for index in elements.indices {
                result[index] = try keyed(elements[index], at: elementNode, path: path + "/\(index)")
            }
            return .array(result)
        default:
            return value
        }
    }

    private static func insert(_ leaf: SnapshotValue, at path: ArraySlice<String>, into object: inout [String: SnapshotValue]) {
        guard let key = path.first else { return }
        if path.count == 1 {
            object[key] = leaf
            return
        }
        var child: [String: SnapshotValue] = [:]
        if case .object(let existing)? = object[key] {
            child = existing
        }
        insert(leaf, at: path.dropFirst(), into: &child)
        object[key] = .object(child)
    }

    private static func isScalar(_ value: SnapshotValue) -> Bool {
        switch value {
        case .bool, .int, .double, .string: return true
        case .null, .array, .object: return false
        }
    }

    private static func kind(_ value: SnapshotValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "a bool"
        case .int: return "an int"
        case .double: return "a double"
        case .string: return "a string"
        case .array: return "an array"
        case .object: return "an object"
        }
    }
}
