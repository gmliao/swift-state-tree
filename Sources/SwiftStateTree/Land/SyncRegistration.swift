// Sources/SwiftStateTree/Land/SyncRegistration.swift
//
// The synced-state rows of the registration check (#535 plan §4): what a land's state type
// alone decides, found before any land of it runs.

import Foundation

/// Synced-state problems of a land's state type, found from the type and a default instance
/// (#535). Each is one the sync conversion would otherwise meet only at run time, where it ends
/// the land.
public struct SyncRegistrationError: Error, CustomStringConvertible, Sendable, Equatable {
    public enum Problem: Sendable, Equatable, CustomStringConvertible {
        /// A synced field holds a class (#464).
        case valueSemantics(SyncValueSemanticsError)
        /// A player-dependent field under a `.broadcast` field (#179).
        case policyNesting(SyncPolicyNestingError)
        /// A dictionary whose key type the conversion can't turn into a string: not `String`,
        /// `PlayerID` or `CustomStringConvertible` (`SyncError.unsupportedKey` at run time).
        /// `path` is the dictionary's field, from the root type (`Root.items[*]`).
        case unsupportedKey(path: String, keyType: String)

        public var description: String {
            switch self {
            case .valueSemantics(let error):
                return error.description
            case .policyNesting(let error):
                return error.description
            case .unsupportedKey(let path, let keyType):
                return "\(path): key type \(keyType) doesn't convert to a string; use String, PlayerID or a "
                    + "CustomStringConvertible key"
            }
        }
    }

    public let problems: [Problem]

    public var description: String {
        problems.map(\.description).joined(separator: "\n")
    }
}

/// Runs the synced-state rows for a state type and caches the result per type.
package enum SyncRegistration {
    /// Every synced-state problem of `rootType`. Walks the type and a default instance each call.
    package static func problems(_ rootType: any StateNodeProtocol.Type) -> [SyncRegistrationError.Problem] {
        var problems: [SyncRegistrationError.Problem] = []
        do {
            try SyncValueSemantics.validate(rootType)
        } catch let error as SyncValueSemanticsError {
            problems.append(.valueSemantics(error))
        } catch {
            preconditionFailure("SyncValueSemantics.validate threw \(error)")
        }
        do {
            try SyncPolicyNesting.validate(rootType)
        } catch let error as SyncPolicyNestingError {
            problems.append(.policyNesting(error))
        } catch {
            preconditionFailure("SyncPolicyNesting.validate threw \(error)")
        }
        var keys = KeyWalker()
        keys.visitNode(rootType, sample: rootType.init(), path: String(describing: rootType))
        problems += keys.problems
        return problems
    }

    /// `problems(_:)`, cached process-wide per state type, failures included.
    ///
    /// The checks call `State.init()` and look into its values, so the cache relies on a stated
    /// contract: **a state type's default `init()` is deterministic** (the same values on every
    /// call; no clock, random source or global state). The walk runs outside the lock; two
    /// callers racing on a new type may both walk it, and under the contract their results are
    /// the same, so the first insert wins.
    package static func cachedProblems(_ rootType: any StateNodeProtocol.Type) -> [SyncRegistrationError.Problem] {
        let id = ObjectIdentifier(rootType)
        if let cached = cache.withLock({ $0[id] }) { return cached }
        let result = problems(rootType)
        return cache.withLock { entries in
            if let first = entries[id] { return first }
            entries[id] = result
            return result
        }
    }

    /// Whether `rootType`'s result is cached (tests).
    package static func isCachedForTesting(_ rootType: any StateNodeProtocol.Type) -> Bool {
        cache.withLock { $0[ObjectIdentifier(rootType)] != nil }
    }

    private static let cache = RegistrationLock<[ObjectIdentifier: [SyncRegistrationError.Problem]]>([:])

    /// Whether the conversion turns a key of `type` into a string (`SnapshotValue.makeKeyString`).
    package static func isSupportedKeyType(_ type: Any.Type) -> Bool {
        type == String.self || type == PlayerID.self || type is any CustomStringConvertible.Type
    }

    /// Finds dictionaries with an unsupported key type, through the same structure as the other
    /// two walks: synced fields, optionals, collections, nested state nodes, and plain structs
    /// through a default instance's values. A type with its own `toSnapshotValue()` converts its
    /// storage itself and isn't looked into.
    private struct KeyWalker {
        var problems: [SyncRegistrationError.Problem] = []
        private var onPath: Set<ObjectIdentifier> = []

        mutating func visitNode(_ type: any StateNodeProtocol.Type, sample: Any?, path: String) {
            let id = ObjectIdentifier(type)
            guard !onPath.contains(id) else { return }
            onPath.insert(id)
            defer { onPath.remove(id) }
            let fieldSamples = sample.map(SyncPolicyNesting.syncFieldValues(of:)) ?? [:]
            for field in type.getFieldMetadata() where field.policy != nil && field.policy != .serverOnly {
                let fieldSample = fieldSamples[field.name]
                let fieldType = field.type == Any.self ? fieldSample.map { Swift.type(of: $0) } ?? field.type : field.type
                visitValue(fieldType, sample: fieldSample, path: "\(path).\(field.name)")
            }
        }

        mutating func visitValue(_ type: Any.Type, sample: Any?, path: String) {
            if let node = type as? any StateNodeProtocol.Type {
                visitNode(node, sample: sample ?? node.init(), path: path)
            } else if let wrapped = NestingOptionalHelper.wrappedType(of: type) {
                let inner = sample.flatMap { Mirror(reflecting: $0).children.first?.value }
                visitValue(wrapped, sample: inner, path: path)
            } else if let value = SchemaHelper.dictionaryValueType(from: type) {
                if let key = SchemaHelper.dictionaryKeyType(from: type), !isSupportedKeyType(key) {
                    problems.append(.unsupportedKey(path: path, keyType: String(describing: key)))
                }
                let first = sample.flatMap { Mirror(reflecting: $0).children.first?.value }
                    .flatMap { Mirror(reflecting: $0).children.dropFirst().first?.value }
                visitValue(value, sample: first, path: "\(path)[*]")
            } else if let element = SchemaHelper.arrayElementType(from: type) ?? SyncSetHelper.elementType(of: type) {
                let first = sample.flatMap { Mirror(reflecting: $0).children.first?.value }
                visitValue(element, sample: first, path: "\(path)[*]")
            } else if let sample, Mirror(reflecting: sample).displayStyle == .struct {
                guard !(sample is any SnapshotValueConvertible), !(sample is any FullSnapshotValueConvertible) else { return }
                for child in Mirror(reflecting: sample).children {
                    guard let label = child.label else { continue }
                    visitValue(Swift.type(of: child.value), sample: child.value, path: "\(path).\(label)")
                }
            }
        }
    }
}

/// A value behind a lock (Foundation's `NSLock`, so it builds on every platform).
private final class RegistrationLock<Value>: @unchecked Sendable {
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
