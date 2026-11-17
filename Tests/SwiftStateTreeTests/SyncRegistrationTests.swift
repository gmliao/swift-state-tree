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

/// Open types a hand-written or nested type can bring in, where the macros can't see them: a
/// plain struct's stored properties aren't read by `@StateNodeBuilder`.
struct RegistrationOpenHolder: @unchecked Sendable {
    var bag: [String: Any] = [:]
    var hashed: [AnyHashable: Int] = [:]
    var boxed: AnyCodable? = nil
    var list: [AnyObject] = []
}

@StateNodeBuilder
struct RegistrationOpenRoot: StateNodeProtocol {
    @Sync(.broadcast) var holder: RegistrationOpenHolder = RegistrationOpenHolder()
    @Sync(.broadcast) var count: Int = 0
    init() {}
}

/// The documented gap: an existential behind a typealias isn't refused; a value that converts
/// passes, and the land ends at the first conversion that throws.
protocol RegistrationGapPayload: Sendable {}
extension Int: RegistrationGapPayload {}
typealias RegistrationAnyGapPayload = any RegistrationGapPayload

@StateNodeBuilder
struct RegistrationGapRoot: StateNodeProtocol {
    @Sync(.broadcast) var payload: RegistrationAnyGapPayload = 0
    init() {}
}

/// A state the backstop refuses, with a field OnInitialize would set.
@StateNodeBuilder
struct RegistrationBackstopRoot: StateNodeProtocol {
    @Sync(.broadcast) var keyed: [RegistrationOpaqueKey: Int] = [:]
    @Sync(.serverOnly) var initialized: Bool = false
    init() {}
}

/// Records the land's destruction and wakes whoever waits for it.
private actor RegistrationDestroyFlag: LandKeeperTransport {
    private var destroyed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {
        destroyed = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func waitUntilDestroyed() async {
        if destroyed { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private func isUnsupportedKey(_ problem: SyncRegistrationError.Problem) -> Bool {
    if case .unsupportedKey = problem { true } else { false }
}

/// A key the generated decoder reads back (`SnapshotKeyDecodable`, so a var-only
/// `@SnapshotConvertible` holding it compiles) but the sync can't write: no string form.
struct RegistrationDecodableKey: Hashable, Sendable, SnapshotKeyDecodable {
    var id: Int
    init(id: Int) { self.id = id }
    init?(snapshotKey: String) { nil }
}

/// `@SnapshotConvertible` storage (#535 review): the macro's `toSnapshotValue()` converts every
/// stored property, so registration looks into it through the declared types.
@SnapshotConvertible
struct RegistrationLoadout: Sendable {
    var byKey: [RegistrationDecodableKey: Int] = [:]
    var tag: Int = 0
}

/// A let-only one (no decoder is generated).
@SnapshotConvertible
struct RegistrationFrozenLoadout: Sendable {
    let byKey: [RegistrationOpaqueKey: Int]
}

/// A property without a type annotation: its value's type stands in.
@SnapshotConvertible
struct RegistrationUntypedLoadout: Sendable {
    var byKey = [RegistrationDecodableKey: Int]()
}

/// A type that holds itself: the walk ends.
@SnapshotConvertible
struct RegistrationTree: Sendable {
    var children: [RegistrationTree] = []
    var byKey: [RegistrationDecodableKey: Int] = [:]
}

/// Only a full-state conversion of its own: the live conversion ignores it and reflects the
/// fields, so they are checked.
struct RegistrationFullOnly: FullSnapshotValueConvertible, Sendable {
    var byKey: [RegistrationOpaqueKey: Int] = [:]
    func toFullSnapshotValue() throws -> SnapshotValue { .null }
}

/// A hand-written conversion: its storage is its own, and isn't checked (the documented gap).
struct RegistrationHandWritten: SnapshotValueConvertible, Sendable {
    var byKey: [RegistrationOpaqueKey: Int] = [:]
    func toSnapshotValue() throws -> SnapshotValue { .null }
}

/// A plain struct's own property declared `Any`: Mirror gives only the value, an `Int` here, so
/// registration can't see the declaration (the documented gap).
struct RegistrationPlainAny: @unchecked Sendable {
    var value: Any = 0
}

@StateNodeBuilder
struct RegistrationConvertibleRoot: StateNodeProtocol {
    @Sync(.broadcast) var loadout: RegistrationLoadout = RegistrationLoadout()
    @Sync(.broadcast) var frozen: RegistrationFrozenLoadout = RegistrationFrozenLoadout(byKey: [:])
    @Sync(.broadcast) var untyped: RegistrationUntypedLoadout = RegistrationUntypedLoadout()
    @Sync(.broadcast) var tree: RegistrationTree = RegistrationTree()
    @Sync(.broadcast) var fullOnly: RegistrationFullOnly = RegistrationFullOnly()
    @Sync(.broadcast) var loadouts: [RegistrationLoadout] = []
    @Sync(.broadcast) var handWritten: RegistrationHandWritten = RegistrationHandWritten()
    @Sync(.broadcast) var plainAny: RegistrationPlainAny = RegistrationPlainAny()
    init() {}
}

// MARK: - Tests

@Suite("Synced-state registration rows (#535 §4)", .timeLimit(.minutes(1)))
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

    @Test("Open types (Any, AnyObject, AnyHashable, AnyCodable) are found as elements, keys, values and wrapped types")
    func openTypes() {
        let problems = SyncRegistration.problems(RegistrationOpenRoot.self)
        #expect(problems == [
            .existentialField(path: "RegistrationOpenRoot.holder.bag[*]", typeName: "Any"),
            .existentialField(path: "RegistrationOpenRoot.holder.hashed[key]", typeName: "AnyHashable"),
            .existentialField(path: "RegistrationOpenRoot.holder.boxed", typeName: "AnyCodable"),
            .existentialField(path: "RegistrationOpenRoot.holder.list[*]", typeName: "AnyObject"),
        ], "\(problems)")
    }

    @Test("An existential behind a typealias is the documented gap: registration passes it")
    func typealiasGap() {
        #expect(SyncRegistration.problems(RegistrationGapRoot.self).isEmpty)
    }

    @Test("validateForRegistration reports the synced-state rows in LandRegistrationError.sync, whatever the context")
    func definitionEntryPoint() throws {
        let land = Land("registration-keys", using: RegistrationMixedRoot.self) { Rules {} }
        for context in [LandRegistrationContext.encodingIndependent, LandRegistrationContext(payloadsCompressed: true)] {
            let error = try #require(throws: LandRegistrationError.self) { try land.validateForRegistration(context: context) }
            #expect(error.landType == "registration-keys")
            #expect(error.payload == nil)
            #expect(error.sync?.problems == SyncRegistration.problems(RegistrationMixedRoot.self))
            #expect(error.description.contains("RegistrationMixedRoot.keyed"))
        }
        try Land("registration-clean", using: RegistrationCleanRoot.self) { Rules {} }
            .validateForRegistration(context: .encodingIndependent)
        let registry = try #require(throws: LandRegistrationError.self) {
            try SyncRegistration.validate(RegistrationKeysRoot.self, landType: "RegistrationKeysRoot")
        }
        #expect(registry.sync?.problems.allSatisfy(isUnsupportedKey) == true)
    }

    @Test("The backstop: a keeper whose state fails the check fails its initialization, before OnInitialize, and is torn down")
    func backstop() async throws {
        let definition = Land("registration-backstop", using: RegistrationBackstopRoot.self) {
            Lifetime {
                OnInitialize { (state: inout RegistrationBackstopRoot, _: LandContext) in
                    state.initialized = true
                }
            }
            Rules {}
        }
        let transport = RegistrationDestroyFlag()
        let keeper = LandKeeper<RegistrationBackstopRoot>(
            definition: definition, initialState: RegistrationBackstopRoot(), autoStartLoops: false, transport: transport
        )
        let failure = try await #require(throws: LandInitializationError.self) {
            try await keeper.leave(playerID: PlayerID("p-1"), clientID: ClientID("c-p-1"), sessionID: SessionID("s-p-1"))
        }
        let registration = try #require(failure.underlying as? LandRegistrationError)
        #expect(registration.landType == "registration-backstop")
        #expect(registration.sync?.problems == [
            .unsupportedKey(path: "RegistrationBackstopRoot.keyed", keyType: "RegistrationOpaqueKey"),
        ])
        await transport.waitUntilDestroyed()
        #expect(await keeper.currentState().initialized == false, "OnInitialize didn't run")
    }

    @Test("ReevaluationEngine.run refuses the definition before it reads the record")
    func reevaluationRefuses() async throws {
        let land = Land("registration-replay", using: RegistrationMixedRoot.self) { Rules {} }
        let error = try await #require(throws: LandRegistrationError.self) {
            _ = try await ReevaluationEngine.run(
                definition: land, initialState: RegistrationMixedRoot(), recordFilePath: "/nonexistent/record.json"
            )
        }
        #expect(error.sync?.problems.count == 2)
    }

    @Test("@SnapshotConvertible storage is checked through its declared types, also with no sample; a FullSnapshotValueConvertible-only type is reflected; a hand-written conversion and a plain struct's own Any aren't seen")
    func convertibleStorage() throws {
        let problems = SyncRegistration.problems(RegistrationConvertibleRoot.self)
        let decodable = "RegistrationDecodableKey", opaque = "RegistrationOpaqueKey"
        #expect(problems == [
            ("loadout.byKey", decodable), ("frozen.byKey", opaque), ("untyped.byKey", decodable), ("tree.byKey", decodable),
            ("fullOnly.byKey", opaque), ("loadouts[*].byKey", decodable),
        ].map { .unsupportedKey(path: "RegistrationConvertibleRoot.\($0.0)", keyType: $0.1) }, "\(problems)")
        // The macro lists the stored properties with their declared types; untyped ones as Any.
        #expect(RegistrationLoadout._snapshotStoredFields.map(\.name) == ["byKey", "tag"])
        #expect(ObjectIdentifier(RegistrationLoadout._snapshotStoredFields[0].type) == ObjectIdentifier([RegistrationDecodableKey: Int].self))
        #expect(ObjectIdentifier(RegistrationUntypedLoadout._snapshotStoredFields[0].type) == ObjectIdentifier(Any.self))
        // What the gaps leave: the hand-written type converts itself; the plain Any holds an Int
        // now, and a value it can't convert later ends the land (ExistentialGapTests).
        var later = RegistrationPlainAny()
        later.value = [RegistrationOpaqueKey(id: 1): 1]
        #expect(throws: SyncError.self) { _ = try SnapshotValue.make(from: later) }
    }
}
