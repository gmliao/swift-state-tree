// Sources/SwiftStateTree/Sync/SyncPolicyNesting.swift
//
// Which @Sync policies may be nested under which (#179).

import Foundation

/// The nesting rule for `@Sync` policies (#179).
///
/// A field whose value depends on the player (`.perPlayer`, `.perPlayerSlice`, the deprecated
/// `.custom`) must not have a `.broadcast` ancestor. A broadcast field is encoded once, from the
/// view without a player, and sent to everyone, so a per-player field below it can't reach its
/// player in diffs. The check looks through containers: dictionaries, arrays, optionals and
/// deeper nesting of state nodes.
///
/// Every other combination is allowed. A child sees what its parent's filter left, with its own
/// policy then applied on top:
/// - under `.broadcast`: `.broadcast` children are sent to everyone, `.serverOnly` ones never, and
///   `.masked` ones to everyone with the mask applied;
/// - under a per-player parent: every child policy applies, for the player the parent let through;
/// - under `.masked`: the mask runs on the node's server value first, then the children's policies;
/// - under `.serverOnly`: nothing below is ever sent.
///
/// `LandTypeRegistry.init` (so every host that serves a land), `NIOLandHost.register`,
/// `SchemaExtractor.extract` and `SchemaGenCLI.generateSchema`/`generate` run this check.
public enum SyncPolicyNesting {
    /// Throws `SyncPolicyNestingError` listing every per-player field with a broadcast ancestor
    /// in `rootType`, at any depth.
    ///
    /// Plain structs and classes (not state nodes) are looked into through the values of a
    /// default instance (`rootType.init()`), as the encoder walks them; one inside an empty
    /// collection can't be seen here, and the encoder refuses it instead
    /// (`playerDependentNodeInPlainValue`). A field with an unrecognized policy counts as both
    /// player-dependent and broadcast, so it is rejected under a broadcast field and its
    /// children are checked as if it were one.
    public static func validate(_ rootType: any StateNodeProtocol.Type) throws {
        var walker = Walker()
        walker.visitNode(rootType, sample: rootType.init(), path: String(describing: rootType), broadcastAncestor: nil)
        if !walker.violations.isEmpty {
            throw SyncPolicyNestingError(violations: walker.violations)
        }
    }

    /// Whether `type` has a player-dependent field at any depth (not below a server-only one):
    /// its view without a player leaves something out that some player would see. Cached.
    static func hasPlayerDependentFields(_ type: any StateNodeProtocol.Type) -> Bool {
        let id = ObjectIdentifier(type)
        if let cached = playerDependentCache.withLock({ $0[id] }) { return cached }
        var walker = Walker()
        walker.visitNode(type, sample: nil, path: "", broadcastAncestor: "")
        let result = !walker.violations.isEmpty
        playerDependentCache.withLock { $0[id] = result }
        return result
    }

    private static let playerDependentCache = NestingLock<[ObjectIdentifier: Bool]>([:])

    private struct Walker {
        var violations: [SyncPolicyNestingError.Violation] = []
        /// Types on the current path, each with whether it was entered under a broadcast
        /// ancestor: a recursive type is walked once per path in each of the two states, so a
        /// broadcast field of a recursive type still has its own children checked.
        private var onPath: Set<PathKey> = []

        private struct PathKey: Hashable {
            let type: ObjectIdentifier
            let underBroadcast: Bool
        }

        mutating func visitNode(_ type: any StateNodeProtocol.Type, sample: Any?, path: String, broadcastAncestor: String?) {
            let key = PathKey(type: ObjectIdentifier(type), underBroadcast: broadcastAncestor != nil)
            guard !onPath.contains(key) else { return }
            onPath.insert(key)
            defer { onPath.remove(key) }

            // The instance's field values, to look into plain structs and classes.
            let fieldSamples = sample.map(Self.syncFieldValues(of:)) ?? [:]
            for field in type.getFieldMetadata() {
                guard let policy = field.policy else { continue }
                let fieldPath = "\(path).\(field.name)"
                if let ancestor = broadcastAncestor, policy.dependsOnPlayer {
                    violations.append(.init(path: fieldPath, policy: policy, broadcastAncestor: ancestor))
                }
                // A server-only subtree is never sent, so nothing below it can be under-sent.
                guard policy != .serverOnly else { continue }
                let ancestor = broadcastAncestor ?? (policy.mayBeBroadcast ? fieldPath : nil)
                let fieldSample = fieldSamples[field.name]
                // A field declared without a type has `Any` metadata: its value's type stands in.
                let fieldType = field.type == Any.self ? fieldSample.map { Swift.type(of: $0) } ?? field.type : field.type
                visitValue(fieldType, sample: fieldSample, path: fieldPath, broadcastAncestor: ancestor)
            }
        }

        mutating func visitValue(_ type: Any.Type, sample: Any?, path: String, broadcastAncestor: String?) {
            if let node = type as? any StateNodeProtocol.Type {
                visitNode(node, sample: sample ?? node.init(), path: path, broadcastAncestor: broadcastAncestor)
            } else if let wrapped = NestingOptionalHelper.wrappedType(of: type) {
                let inner = sample.flatMap { Mirror(reflecting: $0).children.first?.value }
                visitValue(wrapped, sample: inner, path: path, broadcastAncestor: broadcastAncestor)
            } else if let value = SchemaHelper.dictionaryValueType(from: type) {
                let first = sample.flatMap { Mirror(reflecting: $0).children.first?.value }
                    .flatMap { Mirror(reflecting: $0).children.dropFirst().first?.value }
                visitValue(value, sample: first, path: "\(path)[*]", broadcastAncestor: broadcastAncestor)
            } else if let element = SchemaHelper.arrayElementType(from: type) {
                let first = sample.flatMap { Mirror(reflecting: $0).children.first?.value }
                visitValue(element, sample: first, path: "\(path)[*]", broadcastAncestor: broadcastAncestor)
            } else if let sample, Self.isPlainAggregate(sample) {
                // A plain struct or class: the encoder walks its stored properties with the same
                // player as its field, so a state node inside it is nested like a direct child.
                guard !(sample is any SnapshotValueConvertible), !(sample is any FullSnapshotValueConvertible) else { return }
                for child in Mirror(reflecting: sample).children {
                    guard let label = child.label else { continue }
                    visitValue(Swift.type(of: child.value), sample: child.value, path: "\(path).\(label)", broadcastAncestor: broadcastAncestor)
                }
            }
        }

        private static func isPlainAggregate(_ value: Any) -> Bool {
            switch Mirror(reflecting: value).displayStyle {
            case .struct?, .class?: true
            default: false
            }
        }

        /// A state node instance's `@Sync` values by field name, read through the property
        /// wrappers' storage (`_name` → `Sync._wrappedValue`).
        static func syncFieldValues(of node: Any) -> [String: Any] {
            var values: [String: Any] = [:]
            for child in Mirror(reflecting: node).children {
                guard let label = child.label, label.hasPrefix("_") else { continue }
                let wrapper = Mirror(reflecting: child.value)
                guard let stored = wrapper.children.first(where: { $0.label == "_wrappedValue" || $0.label == "wrappedValue" }) else { continue }
                values[String(label.dropFirst())] = stored.value
            }
            return values
        }
    }
}

/// A value behind a lock (Foundation's `NSLock`, so it builds on every platform).
private final class NestingLock<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// Fields whose value depends on the player, nested under a broadcast field (#179).
public struct SyncPolicyNestingError: Error, CustomStringConvertible, Equatable {
    public struct Violation: Sendable, Equatable {
        /// The field, from the root type: `Root.items[*].hand` (`[*]` is any key or element).
        public let path: String
        public let policy: PolicyType
        /// The broadcast field above it.
        public let broadcastAncestor: String
    }

    public let violations: [Violation]

    public var description: String {
        let lines = violations.map {
            "- \($0.path) is .\($0.policy.rawValue) under the .broadcast field \($0.broadcastAncestor)"
        }
        return """
        A field whose value depends on the player can't be nested under a .broadcast field: a \
        broadcast field is encoded once, without a player, so the nested field would not reach \
        its player in diffs (#179).
        \(lines.joined(separator: "\n"))
        Move the per-player data to a top-level field, for example `@Sync(.perPlayerSlice()) \
        var hands: [PlayerID: Hand]`, or make the parent per-player.
        """
    }
}

extension PolicyType {
    /// Whether the field's value is filtered per player (`.perPlayer`, `.perPlayerSlice`,
    /// `.custom`), so different players can see different values.
    /// An unrecognized policy (`.unknown`) counts as player-dependent: fail closed.
    var dependsOnPlayer: Bool {
        switch self {
        case .perPlayer, .perPlayerSlice, .custom, .unknown: true
        case .broadcast, .serverOnly, .masked: false
        }
    }

    /// Whether the field may be encoded once without a player (`.broadcast`, or an
    /// unrecognized policy, which fails closed).
    var mayBeBroadcast: Bool {
        self == .broadcast || self == .unknown
    }
}

/// Unwraps `Optional<T>` to `T` at the type level.
private protocol NestingOptionalTypeProtocol {
    static var nestingWrappedType: Any.Type { get }
}

extension Optional: NestingOptionalTypeProtocol {
    fileprivate static var nestingWrappedType: Any.Type { Wrapped.self }
}

private enum NestingOptionalHelper {
    static func wrappedType(of type: Any.Type) -> Any.Type? {
        (type as? any NestingOptionalTypeProtocol.Type)?.nestingWrappedType
    }
}
