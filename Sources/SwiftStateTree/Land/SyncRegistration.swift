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
        /// A synced field holds a class (#464). Debug builds only: a release build doesn't run
        /// this walk (`SyncValueSemantics`).
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
        /// this row catches the ones a nested plain struct or `@SnapshotConvertible` type, or a
        /// hand-written state node's field metadata, brings in. Not seen by either: an `any P`
        /// reached through a typealias, and a plain struct's own property declared `Any` or
        /// `any P`, which is seen only as its default value's type. The land ends at the first
        /// conversion that throws. Debug builds only, like `.valueSemantics`.
        case existentialField(path: String, typeName: String)
        /// A synced `Decimal` (#597): it has no sync form, so the conversion would read its private
        /// stored fields and throw at the land's first sync. `path` is the field, from the root
        /// type (`Root.prices[*]`). A `.serverOnly` field isn't synced and may hold one; an
        /// `@Internal` field can't, since `Decimal` isn't `PlainData`. Debug builds only, like
        /// `.valueSemantics`: in a release build the conversion throws at the first sync.
        case decimalField(path: String)
        /// Two distinct types in the state share a name (#602), such as `A.Item` and `B.Item`.
        /// The schema and the atomic layout key each type by its name, so one would stand for
        /// both: in the path hashes, the generated client and the positional encoding.
        case typeNameCollision(SchemaTypeNameCollision)

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
            case .decimalField(let path):
                return "\(path): \(DecimalFields.advice)"
            case .typeNameCollision(let collision):
                return "the state's types are keyed by name, and \(collision)"
            }
        }
    }

    public let problems: [Problem]

    public var description: String {
        problems.map(\.description).joined(separator: "\n")
    }
}

/// The stored properties of a `@SnapshotConvertible` type with their declared types, emitted by
/// `@SnapshotConvertible`: the properties its `toSnapshotValue()` converts. It is public only
/// because the expansion in a user's module conforms to it; don't adopt it by hand.
///
/// The registration check (#535) looks into the type's storage through them, so it sees what a
/// value holds even when a default instance doesn't hold one (an empty collection). A property
/// without a type annotation is listed as `Any` and is checked only through a default instance's
/// value: one inside an empty collection isn't seen. A type that converts itself by hand doesn't
/// conform, and its storage isn't checked.
public protocol SnapshotConvertibleStoredFields {
    /// Implementation detail of `@SnapshotConvertible`, read by the registration check; not a
    /// stable API. Each stored property's name and declared type, in declaration order.
    static var _snapshotStoredFields: [(name: String, type: Any.Type)] { get }
}

/// Runs the synced-state rows for a state type and caches the result per type.
package enum SyncRegistration {
    /// Every synced-state problem of `rootType`. Walks the type and a default instance each call.
    package static func problems(_ rootType: any StateNodeProtocol.Type) -> [SyncRegistrationError.Problem] {
        var problems: [SyncRegistrationError.Problem] = []
        // The value walks guard a hand-written PlainData witness, the one way a class, an open
        // type or a Decimal reaches state past the compiler: debug builds only (P4-Q4 (b)).
        #if DEBUG
        walkProbe?.record()
        do {
            try SyncValueSemantics.validate(rootType)
        } catch let error as SyncValueSemanticsError {
            problems.append(.valueSemantics(error))
        } catch {
            preconditionFailure("SyncValueSemantics.validate threw \(error)")
        }
        #endif
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
        // The schema walk only runs on a state the rows above accept, as it does after
        // registration.
        if problems.isEmpty {
            problems += typeNameCollisions(rootType).map(SyncRegistrationError.Problem.typeNameCollision)
        }
        return problems
    }

    /// The state's distinct types that share a name (#602), found by the schema walk that
    /// `AtomicLayoutTable` runs, so a land is refused before its first sync builds a layout from
    /// them.
    ///
    /// The walk runs without the fingerprint's extraction probe, whichever entry point got here
    /// first: under it the walk also converts a set's element, and the verdict is cached per
    /// state type. The fingerprint's own walk checks set elements (`SchemaTypeNameRecorder`).
    private static func typeNameCollisions(_ rootType: any StateNodeProtocol.Type) -> [SchemaTypeNameCollision] {
        let recorder = SchemaTypeNameRecorder()
        var definitions: [String: JSONSchema] = [:]
        var visited: Set<String> = []
        SchemaExtractionProbe.$current.withValue(nil) {
            SchemaTypeNameRecorder.$current.withValue(recorder) {
                _ = TypeToSchemaConverter.convert(rootType, definitions: &definitions, visitedTypes: &visited)
            }
        }
        return recorder.collisions
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

    /// Counts the debug-only value walks this task runs (tests): one per call of
    /// `SyncValueSemantics.validate`, and one per value the `Decimal` and open-type checks look
    /// at. Unbound (nil) everywhere else. A release build compiles the walks out, so it never
    /// counts.
    @TaskLocal package static var walkProbe: RegistrationWalkProbe?

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
    /// through synced fields, optionals, collections and nested state nodes, as the sync converts
    /// them:
    /// - a `@SnapshotConvertible` type through its declared stored properties
    ///   (`SnapshotConvertibleStoredFields`), with or without a sample;
    /// - a plain struct through a default instance's values, so a property declared `Any` or
    ///   `any P` there is seen as the type of the value it holds (Mirror can't give the declared
    ///   type);
    /// - a type with a hand-written `toSnapshotValue()` converts its storage itself and isn't
    ///   looked into. A `FullSnapshotValueConvertible` conformance alone doesn't count: the live
    ///   conversion ignores it.
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
            #if DEBUG
            SyncRegistration.walkProbe?.record()
            if type == Decimal.self {
                problems.append(.decimalField(path: path))
                return
            }
            if isOpenType(type) {
                problems.append(.existentialField(path: path, typeName: String(describing: type)))
                return
            }
            #endif
            if let node = type as? any StateNodeProtocol.Type {
                visitNode(node, sample: sample ?? node.init(), path: path)
            } else if let wrapped = NestingOptionalHelper.wrappedType(of: type) {
                let inner = sample.flatMap { Mirror(reflecting: $0).children.first?.value }
                visitValue(wrapped, sample: inner, path: path)
            } else if let value = SchemaHelper.dictionaryValueType(from: type) {
                if let key = SchemaHelper.dictionaryKeyType(from: type) {
                    #if DEBUG
                    if isOpenType(key) {
                        problems.append(.existentialField(path: "\(path)[key]", typeName: String(describing: key)))
                    } else if !isSupportedKeyType(key) {
                        problems.append(.unsupportedKey(path: path, keyType: String(describing: key)))
                    }
                    #else
                    if !isSupportedKeyType(key) {
                        problems.append(.unsupportedKey(path: path, keyType: String(describing: key)))
                    }
                    #endif
                }
                let first = sample.flatMap { Mirror(reflecting: $0).children.first?.value }
                    .flatMap { Mirror(reflecting: $0).children.dropFirst().first?.value }
                visitValue(value, sample: first, path: "\(path)[*]")
            } else if let element = SchemaHelper.arrayElementType(from: type) ?? SyncSetHelper.elementType(of: type) {
                let first = sample.flatMap { Mirror(reflecting: $0).children.first?.value }
                visitValue(element, sample: first, path: "\(path)[*]")
            } else if let stored = type as? any SnapshotConvertibleStoredFields.Type {
                // A type that holds itself (`var children: [Tree]`) is walked once per path.
                let id = ObjectIdentifier(type)
                guard !onPath.contains(id) else { return }
                onPath.insert(id)
                defer { onPath.remove(id) }
                var values: [String: Any] = [:]
                if let sample {
                    for child in Mirror(reflecting: sample).children {
                        if let label = child.label { values[label] = child.value }
                    }
                }
                for field in stored._snapshotStoredFields {
                    let value = values[field.name]
                    if field.type == Any.self {
                        // No type annotation: the value's type stands in.
                        guard let value else { continue }
                        visitValue(Swift.type(of: value), sample: value, path: "\(path).\(field.name)")
                    } else {
                        visitValue(field.type, sample: value, path: "\(path).\(field.name)")
                    }
                }
            } else if let sample, Mirror(reflecting: sample).displayStyle == .struct {
                guard !(sample is any SnapshotValueConvertible) else { return }
                for child in Mirror(reflecting: sample).children {
                    guard let label = child.label else { continue }
                    visitValue(Swift.type(of: child.value), sample: child.value, path: "\(path).\(label)")
                }
            }
        }
    }
}

/// Counts the registration's debug-only value walks (tests; `SyncRegistration.walkProbe`).
package final class RegistrationWalkProbe: Sendable {
    private let count = RegistrationLock(0)

    package init() {}

    /// How many walks and checked values were counted.
    package var walks: Int { count.withLock { $0 } }

    func record() {
        count.withLock { $0 += 1 }
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
