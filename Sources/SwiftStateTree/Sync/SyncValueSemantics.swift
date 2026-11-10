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
/// copies and compares) through optionals, dictionary keys and values, array and set elements
/// and nested state nodes. At each level the type itself must not be a class. Plain structs
/// (`SnapshotValueConvertible` ones included: a conformer's storage is state too), tuples, enum
/// payloads and existential fields are looked into through the values of a default instance
/// (`rootType.init()`), so a class inside them is found when the default instance holds one.
/// Not seen here: a class only in an enum case the default instance doesn't take, or only in a
/// collection that is empty by default. `SnapshotValue` refuses those when it converts them.
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
                let pair = sample.flatMap { Mirror(reflecting: $0).children.first?.value }.map { Array(Mirror(reflecting: $0).children) }
                if let key = SchemaHelper.dictionaryKeyType(from: type) {
                    visitValue(key, sample: pair?.first?.value, path: "\(path)[key]")
                }
                visitValue(value, sample: pair?.dropFirst().first?.value, path: "\(path)[*]")
            } else if let element = SchemaHelper.arrayElementType(from: type) ?? SyncSetHelper.elementType(of: type) {
                let first = sample.flatMap { Mirror(reflecting: $0).children.first?.value }
                visitValue(element, sample: first, path: "\(path)[*]")
            } else if let sample {
                // An existential (`Any`, `any P`) holding a class, or a value to look into.
                let mirror = Mirror(reflecting: sample)
                switch mirror.displayStyle {
                case .class?:
                    violations.append(.init(path: path, typeName: String(describing: Swift.type(of: sample))))
                case .struct?, .tuple?, .enum?:
                    // A struct's stored properties, a tuple's elements (`.0`), or the payload of
                    // the enum case the sample takes (labelled with the case's name).
                    for (index, child) in mirror.children.enumerated() {
                        var label = child.label ?? "\(index)"
                        if label.hasPrefix(".") { label.removeFirst() }
                        visitValue(Swift.type(of: child.value), sample: child.value, path: "\(path).\(label)")
                    }
                default:
                    break
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

/// Unwraps `Set<T>` to `T` at the type level.
protocol SyncSetTypeProtocol {
    static var syncSetElementType: Any.Type { get }
}

extension Set: SyncSetTypeProtocol {
    static var syncSetElementType: Any.Type { Element.self }
}

enum SyncSetHelper {
    static func elementType(of type: Any.Type) -> Any.Type? {
        (type as? any SyncSetTypeProtocol.Type)?.syncSetElementType
    }
}
