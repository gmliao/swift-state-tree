// Tests/SwiftStateTreeTests/SyncRegistrationTests.swift
//
// #535 plan §4: the synced-state rows of the registration check, found from the type and a
// default instance, and cached per state type.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Fixtures

/// A hashable key with no string form: the conversion throws `unsupportedKey` for it.
struct RegistrationOpaqueKey: Hashable, Sendable {
    var id: Int
}

/// A key the conversion turns into a string through `description`.
struct RegistrationNamedKey: Hashable, Sendable, CustomStringConvertible {
    var id: Int
    var description: String { "k\(id)" }
}

/// A plain struct with a dictionary keyed by the opaque key.
struct RegistrationKeyHolder: Sendable {
    var byKey: [RegistrationOpaqueKey: Int] = [:]
}

/// Spelled through an alias: the macro doesn't expand a dictionary literal type inside an array.
typealias RegistrationOpaqueMap = [RegistrationOpaqueKey: Int]

@StateNodeBuilder
struct RegistrationKeyNode: StateNodeProtocol {
    @Sync(.broadcast) var nested: [RegistrationOpaqueKey: Int] = [:]
    init() {}
}

@StateNodeBuilder
struct RegistrationKeysRoot: StateNodeProtocol {
    @Sync(.broadcast) var direct: [RegistrationOpaqueKey: Int] = [:]
    @Sync(.broadcast) var optional: [RegistrationOpaqueKey: Int]? = nil
    @Sync(.broadcast) var inArray: [RegistrationOpaqueMap] = []
    @Sync(.broadcast) var holder: RegistrationKeyHolder = RegistrationKeyHolder()
    @Sync(.broadcast) var node: RegistrationKeyNode = RegistrationKeyNode()
    // Not sent: never converted.
    @Sync(.serverOnly) var hidden: [RegistrationOpaqueKey: Int] = [:]
    @Sync(.broadcast) var named: [RegistrationNamedKey: Int] = [:]
    @Sync(.broadcast) var byInt: [Int: String] = [:]
    @Sync(.broadcast) var byPlayer: [PlayerID: Int] = [:]
    @Sync(.broadcast) var byString: [String: Int] = [:]
    init() {}
}

@StateNodeBuilder
struct RegistrationCleanRoot: StateNodeProtocol {
    @Sync(.broadcast) var byInt: [Int: String] = [:]
    @Sync(.broadcast) var byPlayer: [PlayerID: Int] = [:]
    init() {}
}

/// A class in a synced field, and an opaque key: two rows in one result.
final class RegistrationObject: @unchecked Sendable {}

@StateNodeBuilder
struct RegistrationMixedRoot: StateNodeProtocol {
    @Sync(.broadcast) var object: RegistrationObject = RegistrationObject()
    @Sync(.broadcast) var keyed: [RegistrationOpaqueKey: Int] = [:]
    init() {}
}

/// A second type for the cache test, used nowhere else.
@StateNodeBuilder
struct RegistrationCacheRoot: StateNodeProtocol {
    @Sync(.broadcast) var keyed: [RegistrationOpaqueKey: Int] = [:]
    init() {}
}

// MARK: - Tests

@Suite("Synced-state registration rows (#535 §4)")
struct SyncRegistrationTests {
    @Test("An unsupported key type is found through fields, optionals, collections, plain structs and nested nodes; a supported or server-only one isn't")
    func unsupportedKeys() {
        let problems = SyncRegistration.problems(RegistrationKeysRoot.self)
        let paths = problems.compactMap { problem -> String? in
            if case .unsupportedKey(let path, let keyType) = problem {
                #expect(keyType == "RegistrationOpaqueKey")
                return path
            }
            return nil
        }
        #expect(paths == [
            "RegistrationKeysRoot.direct",
            "RegistrationKeysRoot.optional",
            "RegistrationKeysRoot.inArray[*]",
            "RegistrationKeysRoot.holder.byKey",
            "RegistrationKeysRoot.node.nested",
        ])
        #expect(problems.count == paths.count, "no other row: \(problems)")
    }

    @Test("The key check agrees with the conversion: a key it accepts converts, one it refuses throws unsupportedKey")
    func keyCheckMatchesConversion() throws {
        #expect(SyncRegistration.isSupportedKeyType(Int.self))
        #expect(SyncRegistration.isSupportedKeyType(RegistrationNamedKey.self))
        #expect(SyncRegistration.isSupportedKeyType(PlayerID.self))
        #expect(!SyncRegistration.isSupportedKeyType(RegistrationOpaqueKey.self))
        _ = try SnapshotValue.make(from: [RegistrationNamedKey(id: 1): 1])
        #expect(throws: SyncError.self) { _ = try SnapshotValue.make(from: [RegistrationOpaqueKey(id: 1): 1]) }
    }

    @Test("A clean type has no problem; the existing rows come back as their own errors, beside the key row")
    func rows() {
        #expect(SyncRegistration.problems(RegistrationCleanRoot.self).isEmpty)
        let problems = SyncRegistration.problems(RegistrationMixedRoot.self)
        #expect(problems.count == 2)
        guard case .valueSemantics(let error) = problems.first else {
            Issue.record("expected the value-semantics row first: \(problems)")
            return
        }
        #expect(error.violations.map(\.path) == ["RegistrationMixedRoot.object"])
        #expect(problems.last == .unsupportedKey(path: "RegistrationMixedRoot.keyed", keyType: "RegistrationOpaqueKey"))
        let description = SyncRegistrationError(problems: problems).description
        #expect(description.contains("value types") && description.contains("RegistrationMixedRoot.keyed"))
    }

    @Test("The cached result, failures included, is the walk's, and is kept per type")
    func cache() {
        #expect(!SyncRegistration.isCachedForTesting(RegistrationCacheRoot.self))
        let first = SyncRegistration.cachedProblems(RegistrationCacheRoot.self)
        #expect(SyncRegistration.isCachedForTesting(RegistrationCacheRoot.self))
        #expect(first == SyncRegistration.problems(RegistrationCacheRoot.self))
        #expect(first == [.unsupportedKey(path: "RegistrationCacheRoot.keyed", keyType: "RegistrationOpaqueKey")])
        #expect(SyncRegistration.cachedProblems(RegistrationCacheRoot.self) == first)
    }
}
