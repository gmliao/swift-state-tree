// Tests/SwiftStateTreeTests/SchemaFingerprintTests.swift
//
// The record schema fingerprint (#521 D15): a stable hash of what a record's payloads and
// snapshots are decoded against. It is pinned, so it is deterministic across processes and
// platforms (the pin holds on macOS and on CI's Linux image, with the per-process hash seed
// random in each run). One change at a time changes it; renames under the same wire key, field
// order, documentation and a default's value (computed when the process runs) don't. A type whose fields it can't list makes it throw, and a land
// that records refuses such a definition at registration. Replay refuses a record without one,
// or with another one, before its first step.

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeReevaluationMonitor

// MARK: - Fixture types

/// The base land's types. Each variant below changes one of them under the same name: a def is
/// named by the type's name alone, so the variant is compared field by field.
enum FPv1 {
    @StateNodeBuilder
    struct FPState: StateNodeProtocol {
        @Sync(.broadcast) var hp: Int = 0
        @Sync(.broadcast) var name: String = ""
        init() {}
    }

    @Payload
    struct FPEvent: ServerEventPayload {
        let amount: Int
    }

    @Payload
    struct FPResponse: ResponsePayload {
        let ok: Bool
    }

    @Payload
    struct FPAction: ActionPayload {
        typealias Response = FPResponse
        let value: Int
    }

    @Payload
    struct FPInput: ServerInputPayload {
        let tag: String
    }

    @Payload
    struct FPNote: ClientEventPayload {
        let text: String
    }
}

/// Defaults a macro computes when the process runs: a `Set` (its order depends on the hash
/// seed) and a fresh UUID.
@StateNodeBuilder
struct FPRuntimeDefaultState: StateNodeProtocol {
    @Sync(.broadcast) var tags: Set<String> = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"]
    @Sync(.broadcast) var token: String = UUID().uuidString
    init() {}
}

/// A state field added.
enum FPStateAdded {
    @StateNodeBuilder
    struct FPState: StateNodeProtocol {
        @Sync(.broadcast) var hp: Int = 0
        @Sync(.broadcast) var name: String = ""
        @Sync(.broadcast) var level: Int = 0
        init() {}
    }
}

/// A state field's type changed.
enum FPStateTyped {
    @StateNodeBuilder
    struct FPState: StateNodeProtocol {
        @Sync(.broadcast) var hp: Double = 0
        @Sync(.broadcast) var name: String = ""
        init() {}
    }
}

/// A state field's sync policy changed.
enum FPStatePolicy {
    @StateNodeBuilder
    struct FPState: StateNodeProtocol {
        @Sync(.serverOnly) var hp: Int = 0
        @Sync(.broadcast) var name: String = ""
        init() {}
    }
}

/// A state field's default value changed.
enum FPStateDefault {
    @StateNodeBuilder
    struct FPState: StateNodeProtocol {
        @Sync(.broadcast) var hp: Int = 1
        @Sync(.broadcast) var name: String = ""
        init() {}
    }
}

/// The base state with its fields declared in the other order.
enum FPStateReordered {
    @StateNodeBuilder
    struct FPState: StateNodeProtocol {
        @Sync(.broadcast) var name: String = ""
        @Sync(.broadcast) var hp: Int = 0
        init() {}
    }
}

/// An event field added.
enum FPEventField {
    @Payload
    struct FPEvent: ServerEventPayload {
        let amount: Int
        let source: String
    }
}

/// An event field given a default: not part of the shape, since a synthesized `Decodable` reads
/// the key whether or not the property has a default.
enum FPEventDefaulted {
    @Payload
    struct FPEvent: ServerEventPayload {
        var amount: Int = 5
    }
}

/// A field with a default value added (`@Payload` fields can't be optional): additive, refused too.
enum FPEventOptional {
    @Payload
    struct FPEvent: ServerEventPayload {
        let amount: Int
        var note: String = ""
    }
}

/// A response field added: the action names the new response.
enum FPResponseField {
    @Payload
    struct FPResponse: ResponsePayload {
        let ok: Bool
        let reason: String
    }

    @Payload
    struct FPAction: ActionPayload {
        typealias Response = FPResponse
        let value: Int
    }
}

/// A server input field added.
enum FPInputField {
    @Payload
    struct FPInput: ServerInputPayload {
        let tag: String
        let count: Int
    }
}

/// The action's property renamed under its wire key, and under another key.
enum FPActionRenamedSameKey {
    @Payload
    struct FPAction: ActionPayload {
        typealias Response = FPv1.FPResponse
        let amountValue: Int
        enum CodingKeys: String, CodingKey {
            case amountValue = "value"
        }
    }
}

enum FPActionRenamedOtherKey {
    @Payload
    struct FPAction: ActionPayload {
        typealias Response = FPv1.FPResponse
        let amountValue: Int
        enum CodingKeys: String, CodingKey {
            case amountValue = "amount"
        }
    }
}

/// A second action, for "an action added".
@Payload
struct FPExtraAction: ActionPayload {
    typealias Response = FPv1.FPResponse
    let flag: Bool
}

/// A `Set` field: its element's fields are hashed, and an element whose fields can't be listed
/// is refused.
enum FPSetV1 {
    @PlainData
    @SnapshotConvertible
    struct FPTag: Codable, Hashable, Sendable {
        let id: Int
    }

    @Payload
    struct FPEvent: ServerEventPayload {
        let amount: Int
        let tags: Set<FPTag>
    }
}

enum FPSetElementField {
    @PlainData
    @SnapshotConvertible
    struct FPTag: Codable, Hashable, Sendable {
        let id: Int
        let label: String
    }

    @Payload
    struct FPEvent: ServerEventPayload {
        let amount: Int
        let tags: Set<FPTag>
    }
}

enum FPSetUnbuildable {
    @PlainData
    struct FPTag: Codable, Hashable, Sendable {
        let id: Int
    }

    @Payload
    struct FPEvent: ServerEventPayload {
        let amount: Int
        let tags: Set<FPTag>
    }
}

/// A `CaseIterable` raw-value enum field: its raw values are hashed.
enum FPEnumV1 {
    @PlainData
    enum FPKind: String, Codable, CaseIterable, Sendable {
        case first, second
    }

    @Payload
    struct FPEvent: ServerEventPayload {
        let amount: Int
        let kind: FPKind
    }
}

enum FPEnumCaseAdded {
    @PlainData
    enum FPKind: String, Codable, CaseIterable, Sendable {
        case first, second, third
    }

    @Payload
    struct FPEvent: ServerEventPayload {
        let amount: Int
        let kind: FPKind
    }
}

enum FPEnumRevalued {
    @PlainData
    enum FPKind: String, Codable, CaseIterable, Sendable {
        case first, second = "2nd"
    }

    @Payload
    struct FPEvent: ServerEventPayload {
        let amount: Int
        let kind: FPKind
    }
}

/// Two actions and two responses, the responses swapped: every def is the same, only which
/// action returns which differs.
@Payload
struct FPResponseA: ResponsePayload {
    let ok: Bool
}

@Payload
struct FPResponseB: ResponsePayload {
    let code: Int
}

enum FPResponsesV1 {
    @Payload
    struct FPAction: ActionPayload {
        typealias Response = FPResponseA
        let value: Int
    }

    @Payload
    struct FPOtherAction: ActionPayload {
        typealias Response = FPResponseB
        let flag: Bool
    }
}

enum FPResponsesSwapped {
    @Payload
    struct FPAction: ActionPayload {
        typealias Response = FPResponseB
        let value: Int
    }

    @Payload
    struct FPOtherAction: ActionPayload {
        typealias Response = FPResponseA
        let flag: Bool
    }
}

/// `a` is keyed `"b"`, and `b` (defaulted) is left out of `CodingKeys`: one wire key, two fields.
@Payload
struct FPCollidingKeys: ServerEventPayload {
    let a: Int
    var b: Int = 0

    enum CodingKeys: String, CodingKey {
        case a = "b"
    }
}

/// A nested value no sample of which can be built: required fields, no `@SnapshotConvertible`.
@PlainData
struct FPInner: Codable, Sendable {
    let x: Int
}

@Payload
struct FPUnbuildableEvent: ServerEventPayload {
    let inner: FPInner
}

/// Field-less payloads and an `AnyCodable` field: hashed as they are.
@Payload
struct FPFieldlessAction: ActionPayload {
    typealias Response = FPv1.FPResponse
}

@Payload
struct FPFieldlessEvent: ServerEventPayload {}

/// A server input and a client event without `@Payload` that have fields: their fields can't be
/// listed.
@PlainData
struct FPPlainInput: ServerInputPayload {
    let tag: String
}

/// A server event without `@Payload`: no positional writer, and unlistable fields.
@PlainData
struct FPPlainEvent: ServerEventPayload {
    let tag: String
}

@PlainData
struct FPPlainNote: ClientEventPayload {
    let text: String
}

/// `CodingKeys` raw values: a backticked name, a key equal to the property's name (not listed)
/// and a renamed key.
@Payload
struct FPKeyed: ServerEventPayload {
    let `default`: Int
    let same: Int
    let renamed: String

    enum CodingKeys: String, CodingKey {
        case `default` = "d"
        case same = "same"
        case renamed = "r"
    }
}

/// A keyword property in a snapshot value: its snapshot key and field name have no backticks.
/// With a `let`, the macro declares the fields (no decoder).
@SnapshotConvertible
struct FPSnapshotKeyed: Codable, Sendable {
    let `default`: Int
    let plain: Int
}

/// The same with `var`s and an `init()`: the macro generates `init(fromSnapshotValue:)`.
@SnapshotConvertible
struct FPSnapshotKeyedDecodable: Codable, Sendable {
    var `default`: Int = 0
    var plain: Int = 0
    init() {}
}

/// The two cases `@Payload`'s key list can't see.
@Payload
struct FPKeysInExtension: ServerEventPayload {
    let amountValue: Int
}

extension FPKeysInExtension {
    enum CodingKeys: String, CodingKey {
        case amountValue = "amount"
    }
}

@Payload
struct FPCustomEncode: ServerEventPayload {
    let amountValue: Int

    init(amountValue: Int) { self.amountValue = amountValue }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(amountValue)
    }

    init(from decoder: Decoder) throws {
        amountValue = try decoder.singleValueContainer().decode(Int.self)
    }
}

// MARK: - Land builders

private let fpLandID = "fp-test"

/// The fixture land with each part given: every variant is this land with one part replaced.
private func fpLand<S: StateNodeProtocol, E: ServerEventPayload, A: ActionPayload, I: ServerInputPayload>(
    _: S.Type,
    event _: E.Type,
    action _: A.Type,
    input _: I.Type
) -> LandDefinition<S> {
    Land(fpLandID, using: S.self) {
        ClientEvents { Register(FPv1.FPNote.self) }
        ServerEvents { Register(E.self) }
        Rules {
            // Registered for the schema only; a registered client event needs a handler (#771).
            HandleEvent(FPv1.FPNote.self) { _, _, _ in }
            // No action is sent in these tests: the handler only declares the action and its response.
            HandleAction(A.self) { _, _, _ in fatalError("no action is sent") }
            HandleServerInput(I.self) { _, _, _ in }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { _, _ in }
        }
    }
}

/// The base land with two actions in place of one.
private func fpTwoActions<A: ActionPayload, B: ActionPayload>(_: A.Type, _: B.Type) -> LandDefinition<FPv1.FPState> {
    Land(fpLandID, using: FPv1.FPState.self) {
        ClientEvents { Register(FPv1.FPNote.self) }
        ServerEvents { Register(FPv1.FPEvent.self) }
        Rules {
            // Registered for the schema only; a registered client event needs a handler (#771).
            HandleEvent(FPv1.FPNote.self) { _, _, _ in }
            HandleAction(A.self) { _, _, _ in fatalError("no action is sent") }
            HandleAction(B.self) { _, _, _ in fatalError("no action is sent") }
            HandleServerInput(FPv1.FPInput.self) { _, _, _ in }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { _, _ in }
        }
    }
}

/// The base land with `E` as its server event.
private func fpWithEvent<E: ServerEventPayload>(_: E.Type) -> LandDefinition<FPv1.FPState> {
    fpLand(FPv1.FPState.self, event: E.self, action: FPv1.FPAction.self, input: FPv1.FPInput.self)
}

private func fpBase() -> LandDefinition<FPv1.FPState> {
    fpLand(FPv1.FPState.self, event: FPv1.FPEvent.self, action: FPv1.FPAction.self, input: FPv1.FPInput.self)
}

private func fpWithExtraAction() -> LandDefinition<FPv1.FPState> {
    Land(fpLandID, using: FPv1.FPState.self) {
        ClientEvents { Register(FPv1.FPNote.self) }
        ServerEvents { Register(FPv1.FPEvent.self) }
        Rules {
            // Registered for the schema only; a registered client event needs a handler (#771).
            HandleEvent(FPv1.FPNote.self) { _, _, _ in }
            HandleAction(FPv1.FPAction.self) { _, _, _ in FPv1.FPResponse(ok: true) }
            HandleAction(FPExtraAction.self) { _, _, _ in FPv1.FPResponse(ok: true) }
            HandleServerInput(FPv1.FPInput.self) { _, _, _ in }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { _, _ in }
        }
    }
}

private func fingerprint<S: StateNodeProtocol>(_ definition: LandDefinition<S>) throws -> String {
    try ReevaluationSchemaFingerprint.compute(for: definition)
}

// MARK: - Tests

@Suite("Record schema fingerprint (#521 D15)")
struct SchemaFingerprintTests {
    @Test("The fixture land's fingerprint is pinned: the same in every process and on every platform")
    func pinned() throws {
        let value = try fingerprint(fpBase())
        #expect(value == "7f24c179d65684ff", "\(value)")
        #expect(value.count == 16)
        #expect(try fingerprint(fpBase()) == value)
    }

    @Test("Defaults computed when the process runs (a Set's order, a fresh UUID) keep the fingerprint across definition builds; it is pinned")
    func runtimeDefaultsKeepIt() throws {
        func build() -> LandDefinition<FPRuntimeDefaultState> {
            Land("fp-runtime-default", using: FPRuntimeDefaultState.self) { Rules {} }
        }
        // The schema holds each build's own UUID, so hashing the value would differ.
        let token = { (land: LandDefinition<FPRuntimeDefaultState>) in
            try SchemaExtractor.extract(from: land).defs["FPRuntimeDefaultState"]?.properties?["token"]?.defaultValue
        }
        #expect(try token(build()) != nil)
        #expect(try token(build()) != token(build()))
        let value = try fingerprint(build())
        #expect(try fingerprint(build()) == value)
        #expect(value == "ca5b2ce4acf4e548", "\(value)")
    }

    @Test("Each one-part change gives a new fingerprint")
    func sensitive() throws {
        let base = try fingerprint(fpBase())
        let variants: [(String, String)] = [
            ("a state field added", try fingerprint(fpLand(FPStateAdded.FPState.self, event: FPv1.FPEvent.self, action: FPv1.FPAction.self, input: FPv1.FPInput.self))),
            ("a state field's type", try fingerprint(fpLand(FPStateTyped.FPState.self, event: FPv1.FPEvent.self, action: FPv1.FPAction.self, input: FPv1.FPInput.self))),
            ("a sync policy", try fingerprint(fpLand(FPStatePolicy.FPState.self, event: FPv1.FPEvent.self, action: FPv1.FPAction.self, input: FPv1.FPInput.self))),
            ("an event field", try fingerprint(fpLand(FPv1.FPState.self, event: FPEventField.FPEvent.self, action: FPv1.FPAction.self, input: FPv1.FPInput.self))),
            ("an event field with a default", try fingerprint(fpLand(FPv1.FPState.self, event: FPEventOptional.FPEvent.self, action: FPv1.FPAction.self, input: FPv1.FPInput.self))),
            ("a response field", try fingerprint(fpLand(FPv1.FPState.self, event: FPv1.FPEvent.self, action: FPResponseField.FPAction.self, input: FPv1.FPInput.self))),
            ("a server input field", try fingerprint(fpLand(FPv1.FPState.self, event: FPv1.FPEvent.self, action: FPv1.FPAction.self, input: FPInputField.FPInput.self))),
            ("an action's wire key", try fingerprint(fpLand(FPv1.FPState.self, event: FPv1.FPEvent.self, action: FPActionRenamedOtherKey.FPAction.self, input: FPv1.FPInput.self))),
            ("an action added", try fingerprint(fpWithExtraAction())),
        ]
        for (change, value) in variants {
            #expect(value != base, "\(change)")
        }
        #expect(Set(variants.map(\.1)).count == variants.count, "each change gives its own value")
    }

    @Test("A Set's element type, a CaseIterable enum's raw values and which response an action returns are hashed")
    func leavesAndLinks() throws {
        let set = try fingerprint(fpWithEvent(FPSetV1.FPEvent.self))
        #expect(try fingerprint(fpWithEvent(FPSetElementField.FPEvent.self)) != set, "a Set element's field")
        let kind = try fingerprint(fpWithEvent(FPEnumV1.FPEvent.self))
        #expect(try fingerprint(fpWithEvent(FPEnumCaseAdded.FPEvent.self)) != kind, "an enum case added")
        #expect(try fingerprint(fpWithEvent(FPEnumRevalued.FPEvent.self)) != kind, "an enum case's raw value")
        let responses = try fingerprint(fpTwoActions(FPResponsesV1.FPAction.self, FPResponsesV1.FPOtherAction.self))
        #expect(
            try fingerprint(fpTwoActions(FPResponsesSwapped.FPAction.self, FPResponsesSwapped.FPOtherAction.self)) != responses,
            "two actions' responses swapped"
        )
        // Stable: the same land built again, and its actions registered in the other order.
        #expect(try fingerprint(fpWithEvent(FPSetV1.FPEvent.self)) == set)
        #expect(try fingerprint(fpTwoActions(FPResponsesV1.FPOtherAction.self, FPResponsesV1.FPAction.self)) == responses)
    }

    @Test("Two fields under one wire key, and a Set element whose fields can't be listed, make the fingerprint throw, and registration refuses them")
    func collisionAndSetElementRefused() throws {
        let colliding = fpWithEvent(FPCollidingKeys.self)
        #expect(Self.thrownError { try fingerprint(colliding) } as? SchemaFingerprintError == .wireKeyCollision(type: "FPCollidingKeys", key: "b"))
        let error = try #require(throws: LandRegistrationError.self) {
            try colliding.validateForRegistration(context: LandRegistrationContext(recordsForReplay: true))
        }
        #expect(error.schemaFingerprint == .wireKeyCollision(type: "FPCollidingKeys", key: "b"))
        #expect(error.description.contains("\"b\""))

        #expect(Self.thrownError { try fingerprint(fpWithEvent(FPSetUnbuildable.FPEvent.self)) } as? SchemaFingerprintError == .unbuildableType("FPTag"))
    }

    @Test("A property renamed under the same wire key, fields reordered, a default's value changed and a payload field given a default keep the fingerprint")
    func stable() throws {
        let base = try fingerprint(fpBase())
        #expect(try fingerprint(fpLand(FPStateDefault.FPState.self, event: FPv1.FPEvent.self, action: FPv1.FPAction.self, input: FPv1.FPInput.self)) == base)
        #expect(try fingerprint(fpWithEvent(FPEventDefaulted.FPEvent.self)) == base)
        #expect(try fingerprint(fpLand(FPv1.FPState.self, event: FPv1.FPEvent.self, action: FPActionRenamedSameKey.FPAction.self, input: FPv1.FPInput.self)) == base)
        #expect(try fingerprint(fpLand(FPStateReordered.FPState.self, event: FPv1.FPEvent.self, action: FPv1.FPAction.self, input: FPv1.FPInput.self)) == base)
    }

    @Test("@Payload lists the wire keys of its own CodingKeys; keys in an extension and a custom encode(to:) aren't seen")
    func wireKeys() {
        #expect(FPActionRenamedSameKey.FPAction._payloadWireKeys == ["amountValue": "value"])
        #expect(FPActionRenamedOtherKey.FPAction._payloadWireKeys == ["amountValue": "amount"])
        #expect(FPv1.FPAction._payloadWireKeys.isEmpty)
        #expect(FPKeyed._payloadWireKeys == ["default": "d", "renamed": "r"])
        // The macro reads the declaration only: these two give the property names.
        #expect(FPKeysInExtension._payloadWireKeys.isEmpty)
        #expect(FPCustomEncode._payloadWireKeys.isEmpty)
    }

    @Test("A backticked property is named without its backticks: @Payload's field metadata and field forms, @SnapshotConvertible's field metadata and snapshot keys")
    func backtickedNames() throws {
        #expect(FPKeyed.getFieldMetadata().map(\.name) == ["default", "renamed", "same"])
        #expect(FPKeyed._payloadFieldForms.map(\.name) == ["default", "renamed", "same"])
        #expect(FPSnapshotKeyed.snapshotFieldMetadata.map(\.name).sorted() == ["default", "plain"])
        let snapshot = try FPSnapshotKeyed(default: 1, plain: 2).toSnapshotValue()
        #expect(snapshot == .object(["default": .int(1), "plain": .int(2)]))
        #expect(try FPSnapshotKeyed(default: 1, plain: 2).toFullSnapshotValue() == snapshot)
        var decodable = FPSnapshotKeyedDecodable()
        decodable.default = 1
        decodable.plain = 2
        #expect(try decodable.toSnapshotValue() == snapshot)
        #expect(try FPSnapshotKeyedDecodable(fromSnapshotValue: snapshot).default == 1)
    }

    @Test("A land refused for another registration row isn't fingerprinted: schemaFingerprint is nil, and the row is kept")
    func fingerprintSkippedWhenAnotherRowFails() throws {
        // A server event without @Payload: no positional writer (the payload row, with
        // compression on), and fields the fingerprint can't list.
        let land = Land(fpLandID, using: FPv1.FPState.self) {
            ServerEvents { Register(FPPlainEvent.self) }
            Rules {}
        }
        #expect(Self.thrownError { try fingerprint(land) } as? SchemaFingerprintError == .unbuildableType("FPPlainEvent"))
        let error = try #require(throws: LandRegistrationError.self) {
            try land.validateForRegistration(context: LandRegistrationContext(payloadsCompressed: true, recordsForReplay: true))
        }
        #expect(error.payload?.typesWithoutWriter == ["server event FPPlainEvent"])
        #expect(error.schemaFingerprint == nil)
    }

    @Test("A land refused for its synced state isn't fingerprinted: the sync row is kept and schemaFingerprint is nil")
    func fingerprintSkippedWhenSyncFails() throws {
        // A class in a synced field (`.valueSemantics`). The fingerprint walk would throw the same
        // LandRegistrationError, so the error alone can't show the `sync == nil` clause held; the
        // definition's fingerprint cache can: it is still empty when the walk didn't run.
        let land = Land("fp-sync-problem", using: ValueCheckClassFieldRoot.self) { Rules {} }
        let error = try #require(throws: LandRegistrationError.self) {
            try land.validateForRegistration(context: LandRegistrationContext(recordsForReplay: true))
        }
        #expect(error.sync?.problems.contains(where: { if case .valueSemantics = $0 { true } else { false } }) == true)
        #expect(error.schemaFingerprint == nil)
        #expect(try land.schemaFingerprintCache.value { "not computed" }.get() == "not computed")
    }

    @Test("Field-less payloads are hashed as they are")
    func fieldlessIsHashed() throws {
        let land = Land("fp-fieldless", using: FPv1.FPState.self) {
            ServerEvents {
                Register(FPFieldlessEvent.self)
            }
            Rules {
                HandleAction(FPFieldlessAction.self) { _, _, _ in FPv1.FPResponse(ok: true) }
            }
        }
        #expect(try fingerprint(land).count == 16)
    }

    @Test("A type whose fields can't be listed makes the fingerprint throw, naming the type", arguments: ["nested", "input", "client event"])
    func unlistableFieldsThrow(kind: String) throws {
        let (error, expectedType): (Error?, String) = switch kind {
        case "nested":
            (Self.thrownError { try fingerprint(fpLand(FPv1.FPState.self, event: FPUnbuildableEvent.self, action: FPv1.FPAction.self, input: FPv1.FPInput.self)) }, "FPInner")
        case "input":
            (Self.thrownError { try fingerprint(fpLand(FPv1.FPState.self, event: FPv1.FPEvent.self, action: FPv1.FPAction.self, input: FPPlainInput.self)) }, "FPPlainInput")
        default:
            (Self.thrownError {
                try fingerprint(Land(fpLandID, using: FPv1.FPState.self) {
                    ClientEvents { Register(FPPlainNote.self) }
                    Rules {
                        // Registered for the schema only; a registered client event needs a handler (#771).
                        HandleEvent(FPPlainNote.self) { _, _, _ in }
                    }
                })
            }, "FPPlainNote")
        }
        #expect(error as? SchemaFingerprintError == .unbuildableType(expectedType))
        #expect("\(error.map { "\($0)" } ?? "")".contains("@Payload"))
    }

    @Test("Registration refuses a land whose fingerprint can't be computed when its records will replay, and accepts it otherwise")
    func registrationRefusesUnlistable() throws {
        let land = fpLand(FPv1.FPState.self, event: FPUnbuildableEvent.self, action: FPv1.FPAction.self, input: FPv1.FPInput.self)
        try land.validateForRegistration(context: LandRegistrationContext(recordsForReplay: false))
        try land.validateForRegistration(context: .encodingIndependent)
        let error = try #require(throws: LandRegistrationError.self) {
            try land.validateForRegistration(context: LandRegistrationContext(recordsForReplay: true))
        }
        #expect(error.schemaFingerprint == .unbuildableType("FPInner"))
        #expect(error.description.contains("'\(fpLandID)'"))
        #expect(error.description.contains("FPInner"))
        try fpBase().validateForRegistration(context: LandRegistrationContext(recordsForReplay: true))
    }

    @Test("A recorded land's record holds its fingerprint and version 3.6")
    func recordHoldsFingerprint() async throws {
        let path = try await recordFixtureLand(fpBase(), initialState: FPv1.FPState())
        defer { try? FileManager.default.removeItem(atPath: path) }
        let metadata = try await ReevaluationRecordFile.openSource(filePath: path).getMetadata()
        #expect(metadata.version == "3.6")
        #expect(metadata.schemaFingerprint == (try fingerprint(fpBase())))
    }

    @Test("A directly built keeper whose land has no fingerprint records none, and its record is refused at replay")
    func unlistableKeeperRecordsNone() async throws {
        let land = fpLand(FPv1.FPState.self, event: FPUnbuildableEvent.self, action: FPv1.FPAction.self, input: FPv1.FPInput.self)
        let path = try await recordFixtureLand(land, initialState: FPv1.FPState())
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try await ReevaluationRecordFile.openSource(filePath: path).getMetadata().schemaFingerprint == nil)
        await #expect(throws: ReevaluationRecordFingerprintError.missing(recordedVersion: "3.6")) {
            _ = try await ReevaluationEngine.run(definition: fpBase(), initialState: FPv1.FPState(), recordFilePath: path)
        }
    }

    @Test("ReevaluationEngine.run and the runner refuse a record whose fingerprint differs, with both values, before the first step")
    func mismatchRefused() async throws {
        let path = try await recordFixtureLand(fpBase(), initialState: FPv1.FPState())
        defer { try? FileManager.default.removeItem(atPath: path) }
        let changed = fpLand(FPv1.FPState.self, event: FPEventField.FPEvent.self, action: FPv1.FPAction.self, input: FPv1.FPInput.self)
        let recorded = try fingerprint(fpBase())
        let current = try fingerprint(changed)

        await #expect(throws: ReevaluationRecordFingerprintError.mismatch(recorded: recorded, current: current)) {
            _ = try await ReevaluationEngine.run(definition: changed, initialState: FPv1.FPState(), recordFilePath: path)
        }
        do {
            _ = try await ConcreteReevaluationRunner(definition: changed, initialState: FPv1.FPState(), recordFilePath: path)
            Issue.record("expected the runner to refuse the record")
        } catch let error as ReevaluationReplayCompatibilityError {
            guard case .schemaFingerprintMismatch(let r, let c) = error else {
                Issue.record("expected a fingerprint mismatch, got \(error)")
                return
            }
            #expect(r == recorded && c == current)
            #expect((error as NSError).code == 2004)
            #expect(error.errorUserInfo["code"] as? String == "RECORD_SCHEMA_FINGERPRINT_MISMATCH")
        }

        // The same record replays against its own land.
        let result = try await ReevaluationEngine.run(definition: fpBase(), initialState: FPv1.FPState(), recordFilePath: path)
        #expect(result.maxTickId >= 0)
        #expect(result.tickHashes == result.recordedStateHashes)
    }

    private static func thrownError(_ body: () throws -> Void) -> Error? {
        do {
            try body()
            return nil
        } catch {
            return error
        }
    }
}

/// Records a few ticks of `definition` with a live keeper and returns the record's path.
private func recordFixtureLand<S: StateNodeProtocol>(_ definition: LandDefinition<S>, initialState: S) async throws -> String {
    let keeper = LandKeeper<S>(
        definition: definition,
        initialState: initialState,
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        landID: "\(fpLandID):local"
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: "\(fpLandID):local",
        landType: fpLandID,
        createdAt: Date(timeIntervalSince1970: 0),
        metadata: [:],
        landDefinitionID: fpLandID,
        rngSeed: DeterministicSeed.fromLandID("\(fpLandID):local"),
        version: ReevaluationRecordVersion.current
    ))
    for _ in 0..<3 {
        await keeper.stepTickOnce()
    }
    await keeper.waitForRecorderSubmissionsForTesting()
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString).sstr").path
    try await recorder.save(to: path)
    return path
}
