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
/// `NIOLandHost.register` and `SchemaGenCLI.generate` run this check. Other hosts call
/// `validate(_:)` themselves.
public enum SyncPolicyNesting {
    /// Throws `SyncPolicyNestingError` listing every per-player field with a broadcast ancestor
    /// in `rootType`, at any depth.
    public static func validate(_ rootType: any StateNodeProtocol.Type) throws {
        var walker = Walker()
        walker.visitNode(rootType, path: String(describing: rootType), broadcastAncestor: nil)
        if !walker.violations.isEmpty {
            throw SyncPolicyNestingError(violations: walker.violations)
        }
    }

    private struct Walker {
        var violations: [SyncPolicyNestingError.Violation] = []
        /// Node types on the current path, so a recursive type is walked once per path.
        private var onPath: Set<ObjectIdentifier> = []

        mutating func visitNode(_ type: any StateNodeProtocol.Type, path: String, broadcastAncestor: String?) {
            let id = ObjectIdentifier(type)
            guard !onPath.contains(id) else { return }
            onPath.insert(id)
            defer { onPath.remove(id) }

            for field in type.getFieldMetadata() {
                guard let policy = field.policy else { continue }
                let fieldPath = "\(path).\(field.name)"
                if let ancestor = broadcastAncestor, policy.dependsOnPlayer {
                    violations.append(.init(path: fieldPath, policy: policy, broadcastAncestor: ancestor))
                }
                // A server-only subtree is never sent, so nothing below it can be under-sent.
                guard policy != .serverOnly else { continue }
                let ancestor = broadcastAncestor ?? (policy == .broadcast ? fieldPath : nil)
                visitValue(field.type, path: fieldPath, broadcastAncestor: ancestor)
            }
        }

        mutating func visitValue(_ type: Any.Type, path: String, broadcastAncestor: String?) {
            if let node = type as? any StateNodeProtocol.Type {
                visitNode(node, path: path, broadcastAncestor: broadcastAncestor)
            } else if let wrapped = NestingOptionalHelper.wrappedType(of: type) {
                visitValue(wrapped, path: path, broadcastAncestor: broadcastAncestor)
            } else if let value = SchemaHelper.dictionaryValueType(from: type) {
                visitValue(value, path: "\(path)[*]", broadcastAncestor: broadcastAncestor)
            } else if let element = SchemaHelper.arrayElementType(from: type) {
                visitValue(element, path: "\(path)[*]", broadcastAncestor: broadcastAncestor)
            }
        }
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
    var dependsOnPlayer: Bool {
        switch self {
        case .perPlayer, .perPlayerSlice, .custom: true
        case .broadcast, .serverOnly, .masked, .unknown: false
        }
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
