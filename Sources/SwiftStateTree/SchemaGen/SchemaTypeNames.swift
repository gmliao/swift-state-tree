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
        "\(name) names \(types.joined(separator: " and "))"
    }
}

/// A schema extraction found distinct types that share a definition name (#602).
public struct SchemaTypeNameCollisionError: Error, Sendable, Equatable, CustomStringConvertible {
    public let collisions: [SchemaTypeNameCollision]

    public var description: String {
        "schema definitions are keyed by a type's name, and these distinct types share one; "
            + "rename all but one of each: " + collisions.map(\.description).joined(separator: "; ")
    }
}

/// Records which type each definition name stands for during an extraction (#602).
///
/// The schema walk (`TypeToSchemaConverter`, `ActionEventExtractor`) notes every type it
/// defines, before it checks whether the name is already defined, so a second type with the
/// name is recorded even though the walk skips it. Bound by the entry points that use the
/// definitions: `SchemaExtractor.extract`, `SchemaGenCLI.generateSchema` (once for all its
/// lands, so a name two lands define differently is found too), `AtomicLayoutTable.build` and
/// the synced-state registration check. A direct call of the public converters without one
/// checks nothing, as before.
final class SchemaTypeNameRecorder: @unchecked Sendable {
    @TaskLocal static var current: SchemaTypeNameRecorder?

    private let lock = NSLock()
    /// For each definition name, the types noted under it, by identity, with their full names.
    private var types: [String: [ObjectIdentifier: String]] = [:]

    /// Notes that `name` defines `type`.
    func note(_ type: Any.Type, as name: String) {
        let id = ObjectIdentifier(type)
        lock.withLock {
            if types[name]?[id] == nil {
                types[name, default: [:]][id] = String(reflecting: type)
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

    /// Runs `body` with a recorder bound: the one already bound, which its binder checks, or a
    /// new one, checked when `body` returns.
    static func recording<T>(_ body: () throws -> T) throws -> T {
        if current != nil {
            return try body()
        }
        let recorder = SchemaTypeNameRecorder()
        let result = try $current.withValue(recorder) { try body() }
        try recorder.check()
        return result
    }
}
