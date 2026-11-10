// Sources/SwiftStateTree/Sync/SyncValueSemantics.swift
//
// Synced state is made of value types (#464).

import Foundation

/// The value-semantics rule for synced state (#464): no `@Sync` field holds a class, at any
/// depth.
///
/// Everything that compares, copies or diffs state relies on it:
/// - the typed tables' per-row `==` diff;
/// - the debug check of a throwing handler's writes (#87), which compares a copy taken before
///   the handler;
/// - a rollback of a throwing input.
///
/// A write through a shared object escapes all three.
///
/// The check walks every synced field's type (`.serverOnly` too: it is state the land keeps,
/// copies and compares) through optionals, dictionary values, array elements and nested state
/// nodes. At each level the type itself must not be a class. Plain structs are looked into
/// through the values of a default instance (`rootType.init()`), as `SyncPolicyNesting` does,
/// so a class held inside a struct, or an `Any` field holding a class, is found when the default
/// instance has one. A class that only appears at runtime is refused by `SnapshotValue` when it
/// is converted.
///
/// `@Internal` fields are not synced and not checked: they may hold a class (a cache, a
/// service handle). They are also outside the #87 checks.
///
/// `LandTypeRegistry.init`, `NIOLandHost.register` and `SchemaExtractor.extract` run this
/// check, next to `SyncPolicyNesting.validate`. It is `package`, not public: users meet the
/// rule through those entry points and `SyncValueSemanticsError`, not by calling it.
package enum SyncValueSemantics {
    /// Throws `SyncValueSemanticsError` naming every synced field, at any depth, whose type is
    /// a class or whose default value holds one.
    package static func validate(_ rootType: any StateNodeProtocol.Type) throws {
        var walker = Walker()
        walker.visitNode(rootType, sample: rootType.init(), path: String(describing: rootType))
        if !walker.violations.isEmpty {
            throw SyncValueSemanticsError(violations: walker.violations)
        }
    }

    private struct Walker {
        var violations: [SyncValueSemanticsError.Violation] = []
        /// State node types on the current path, so a recursive type ends.
        private var onPath: Set<ObjectIdentifier> = []

        mutating func visitNode(_ type: any StateNodeProtocol.Type, sample: Any?, path: String) {
            let id = ObjectIdentifier(type)
            guard !onPath.contains(id) else { return }
            onPath.insert(id)
            defer { onPath.remove(id) }
            let fieldSamples = sample.map(SyncPolicyNesting.syncFieldValues(of:)) ?? [:]
            for field in type.getFieldMetadata() where field.policy != nil {
                let fieldSample = fieldSamples[field.name]
                let fieldType = field.type == Any.self ? fieldSample.map { Swift.type(of: $0) } ?? field.type : field.type
                visitValue(fieldType, sample: fieldSample, path: "\(path).\(field.name)")
            }
        }

        mutating func visitValue(_ type: Any.Type, sample: Any?, path: String) {
            if type is AnyObject.Type {
                violations.append(.init(path: path, typeName: String(describing: type)))
                return
            }
            if let node = type as? any StateNodeProtocol.Type {
                visitNode(node, sample: sample ?? node.init(), path: path)
            } else if let wrapped = NestingOptionalHelper.wrappedType(of: type) {
                let inner = sample.flatMap { Mirror(reflecting: $0).children.first?.value }
                visitValue(wrapped, sample: inner, path: path)
            } else if let value = SchemaHelper.dictionaryValueType(from: type) {
                let first = sample.flatMap { Mirror(reflecting: $0).children.first?.value }
                    .flatMap { Mirror(reflecting: $0).children.dropFirst().first?.value }
                visitValue(value, sample: first, path: "\(path)[*]")
            } else if let element = SchemaHelper.arrayElementType(from: type) {
                let first = sample.flatMap { Mirror(reflecting: $0).children.first?.value }
                visitValue(element, sample: first, path: "\(path)[*]")
            } else if let sample {
                // An existential (`Any`, `any P`) holding a class, or a plain struct to look into.
                let mirror = Mirror(reflecting: sample)
                if mirror.displayStyle == .class {
                    violations.append(.init(path: path, typeName: String(describing: Swift.type(of: sample))))
                    return
                }
                guard mirror.displayStyle == .struct,
                      !(sample is any SnapshotValueConvertible), !(sample is any FullSnapshotValueConvertible)
                else { return }
                for child in mirror.children {
                    guard let label = child.label else { continue }
                    visitValue(Swift.type(of: child.value), sample: child.value, path: "\(path).\(label)")
                }
            }
        }
    }
}

/// Synced fields that hold a class (#464).
public struct SyncValueSemanticsError: Error, CustomStringConvertible, Equatable {
    public struct Violation: Sendable, Equatable {
        /// The field, from the root type: `Root.items[*].owner` (`[*]` is any key or element).
        public let path: String
        /// The class's name.
        public let typeName: String
    }

    public let violations: [Violation]

    public var description: String {
        let lines = violations.map { "- \($0.path): \($0.typeName) is a class; synced state must be value types" }
        return """
        Synced state must be made of value types (#464): a write through a shared object would \
        escape the diff, the throwing-input check and rollback.
        \(lines.joined(separator: "\n"))
        Make the type a struct (or an enum), or keep a reference the land doesn't sync in an \
        @Internal field.
        """
    }
}
