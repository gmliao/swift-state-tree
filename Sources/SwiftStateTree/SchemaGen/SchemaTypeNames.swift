// Sources/SwiftStateTree/SchemaGen/SchemaTypeNames.swift
//
// Schema definitions are keyed by a type's short name; two distinct types with one name are
// refused (#602).

import Foundation

/// Two or more distinct types that a schema would define under one name (#602).
///
/// The schema keys each definition by the type's short name (`String(describing:)`, so `A.Item`
/// and `B.Item` are both `Item`) and refers to it as `#/defs/<name>`. A second type with the
/// name would be skipped as already defined, or would replace the first one's definition, and
/// every `$ref` would point at one of them.
public struct SchemaTypeNameCollision: Sendable, Equatable, CustomStringConvertible {
    /// The definition name the types share.
    public let name: String
    /// Each type's full name (`String(reflecting:)`), sorted.
    public let types: [String]

    public var description: String {
        if name == SchemaTypeNameCollision.reservedDiffName {
            let users = types.filter { $0 != SchemaTypeNameCollision.reservedDiffOwner }
            return "\(name) is reserved for the schema's diff placeholder; give "
                + users.joined(separator: " and ") + " another name"
        }
        return "\(name) names \(types.joined(separator: " and ")); rename all but one"
    }

    /// The schema's diff placeholder definition: its name and the type that stands for it.
    static let reservedDiffName = "StateDiff"
    static let reservedDiffOwner = "the schema's diff placeholder"
}

/// A schema extraction found distinct types that share a definition name (#602).
public struct SchemaTypeNameCollisionError: Error, Sendable, Equatable, CustomStringConvertible {
    public let collisions: [SchemaTypeNameCollision]

    public var description: String {
        "schema definitions are keyed by a type's name, and these distinct types share one: "
            + collisions.map(\.description).joined(separator: "; ")
    }
}

/// Records which type each definition name stands for during an extraction (#602).
///
/// The schema walk (`TypeToSchemaConverter`, `ActionEventExtractor`) notes every type it
/// defines, before it checks whether the name is already defined, so a second type with the
/// name is recorded even though the walk skips it. Bound by the entry points that use the
/// definitions:
/// - `SchemaExtractor.extract`, for one land's walk;
/// - `SchemaGenCLI.generateSchema`, around all its lands, so a name two lands define with
///   different types is found too;
/// - the replay fingerprint, around the land's extraction and its server inputs' walk, which
///   adds definitions to the land's;
/// - `AtomicLayoutTable.build` and the synced-state registration check.
///
/// A direct call of the public converters without one checks nothing, as before.
final class SchemaTypeNameRecorder: @unchecked Sendable {
    @TaskLocal static var current: SchemaTypeNameRecorder?

    private let lock = NSLock()
    /// For each definition name, the types noted under it, by identity, with their full names.
    private var types: [String: [ObjectIdentifier: String]] = [:]

    /// Notes that `name` defines `type`, shown as `displayName` (its full name by default).
    func note(_ type: Any.Type, as name: String, displayName: String? = nil) {
        let id = ObjectIdentifier(type)
        lock.withLock {
            if types[name]?[id] == nil {
                types[name, default: [:]][id] = displayName ?? String(reflecting: type)
            }
        }
    }

    /// Adds `other`'s notes to this record.
    func absorb(_ other: SchemaTypeNameRecorder) {
        let notes = other.lock.withLock { other.types }
        lock.withLock {
            for (name, types) in notes {
                self.types[name, default: [:]].merge(types) { first, _ in first }
            }
        }
    }

    /// Every name noted for more than one type, sorted by name.
    var collisions: [SchemaTypeNameCollision] {
        lock.withLock {
            types.filter { $0.value.count > 1 }
                .map { SchemaTypeNameCollision(name: $0.key, types: $0.value.values.sorted()) }
                .sorted { $0.name < $1.name }
        }
    }

    /// Throws the collisions, if any.
    func check() throws {
        let found = collisions
        if !found.isEmpty {
            throw SchemaTypeNameCollisionError(collisions: found)
        }
    }

    /// Runs `body` with a new recorder bound and checks it when `body` returns, so a collision
    /// in `body`'s own walk is thrown there, before anything is built from its definitions.
    /// Under an enclosing `recording`, its notes are then added to the enclosing record, which
    /// checks the union: names that only collide across the parts (two lands, a land and its
    /// server inputs).
    static func recording<T>(_ body: () throws -> T) throws -> T {
        let enclosing = current
        let recorder = SchemaTypeNameRecorder()
        let result = try $current.withValue(recorder) { try body() }
        try recorder.check()
        enclosing?.absorb(recorder)
        return result
    }
}
