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
        /// A synced type that can hold a value of any type (#535 D8 (b)): `Any`, `AnyObject`,
        /// `AnyHashable` or `AnyCodable`, as a collection's element, key or value or an optional's
        /// wrapped type. What it holds can't be checked here. `@StateNodeBuilder` and
        /// `@SnapshotConvertible` refuse these, and `any P`, where the declared type spells them;
        /// this row catches the ones a hand-written conformance or a nested type brings in. An
        /// `any P` reached through a typealias isn't seen by either: the land ends at the first
        /// conversion that throws.
        case existentialField(path: String, typeName: String)

        public var description: String {
            switch self {
            case .valueSemantics(let error):
                return error.description
            case .policyNesting(let error):
                return error.description
            case .unsupportedKey(let path, let keyType):
                return "\(path): key type \(keyType) doesn't convert to a string; use String, PlayerID or a "
                    + "CustomStringConvertible key"
            case .existentialField(let path, let typeName):
                return "\(path): \(typeName) holds a value of any type, which can't be checked; use a concrete "
                    + "type, or an enum with a case for each kind of value"
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
        var types = TypeWalker()
        types.visitNode(rootType, sample: rootType.init(), path: String(describing: rootType))
        problems += types.problems
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

    /// Throws `LandRegistrationError` with `rootType`'s synced-state problems, for an entry point
    /// that has a state type but no land definition (`LandTypeRegistry`). `landType` names what
    /// is being registered.
    package static func validate(_ rootType: any StateNodeProtocol.Type, landType: String) throws {
        let problems = cachedProblems(rootType)
        if !problems.isEmpty {
            throw LandRegistrationError(landType: landType, payload: nil, sync: SyncRegistrationError(problems: problems))
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

    /// The types that hold a value of any type (`existentialField`).
    package static func isOpenType(_ type: Any.Type) -> Bool {
        let id = ObjectIdentifier(type)
        return id == ObjectIdentifier(Any.self) || id == ObjectIdentifier(AnyObject.self)
            || id == ObjectIdentifier(AnyHashable.self) || id == ObjectIdentifier(AnyCodable.self)
    }

    /// Finds dictionaries with an unsupported key type and open types (`existentialField`),
    /// through the same structure as the other two walks: synced fields, optionals, collections,
    /// nested state nodes, and plain structs through a default instance's values. A type with its
    /// own `toSnapshotValue()` converts its storage itself and isn't looked into.
    private struct TypeWalker {
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
                // A field whose metadata says `Any` (a conformance that doesn't name the type):
                // its value's type stands in, as in the other two walks. The macros refuse a field
                // declared `Any`.
                if field.type == Any.self {
                    guard let fieldSample else { continue }
                    visitValue(Swift.type(of: fieldSample), sample: fieldSample, path: "\(path).\(field.name)")
                } else {
                    visitValue(field.type, sample: fieldSample, path: "\(path).\(field.name)")
                }
            }
        }

        mutating func visitValue(_ type: Any.Type, sample: Any?, path: String) {
            if isOpenType(type) {
                problems.append(.existentialField(path: path, typeName: String(describing: type)))
            } else if let node = type as? any StateNodeProtocol.Type {
                visitNode(node, sample: sample ?? node.init(), path: path)
            } else if let wrapped = NestingOptionalHelper.wrappedType(of: type) {
                let inner = sample.flatMap { Mirror(reflecting: $0).children.first?.value }
                visitValue(wrapped, sample: inner, path: path)
            } else if let value = SchemaHelper.dictionaryValueType(from: type) {
                if let key = SchemaHelper.dictionaryKeyType(from: type) {
                    if isOpenType(key) {
                        problems.append(.existentialField(path: "\(path)[key]", typeName: String(describing: key)))
                    } else if !isSupportedKeyType(key) {
                        problems.append(.unsupportedKey(path: path, keyType: String(describing: key)))
                    }
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
