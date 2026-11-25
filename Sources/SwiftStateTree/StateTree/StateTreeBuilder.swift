// Sources/SwiftStateTree/StateTree/StateTreeBuilder.swift

import SwiftStateTurns

/// Macro that validates and generates code for StateNode types.
///
/// This macro:
/// 1. Validates that all stored properties have @Sync or @Internal markers
/// 2. Generates `getSyncFields()` method implementation
/// 3. Generates `validateSyncFields()` method implementation
///
/// Example:
/// ```swift
/// @StateNodeBuilder
/// struct GameStateRootNode: StateNodeProtocol {
///     @Sync(.broadcast)
///     var players: [PlayerID: PlayerStateNode] = [:]
///     
///     @Sync(.serverOnly)
///     var hiddenDeck: [Card] = []
///     
///     @Internal
///     var lastProcessedTimestamp: Int64 = 0 // milliseconds
/// }
/// ```
///
/// An `@Sync` property whose declared type can hold a value of any type is a compile error
/// (#535): `any P`, `Any`, `AnyObject` or a composition `P & Q` at any depth (`[String: Any]`,
/// `(any P)?`), and `AnyHashable` and `AnyCodable` by name. Use a concrete type, or an enum with
/// a case for each kind of value.
///
/// The state is `PlainData` (`StateNodeProtocol` refines it): the macro writes the
/// `_plainDataCheck` member, with one check per `@Sync` and `@Internal` field on its wrapped
/// value, `#if` members included, so a class, a closure, `Any` or a nested type without
/// `@PlainData` is a compile error at the field. `Sync` and `Internal` require a `PlainData`
/// value, so a protocol spelled bare or a typealias that names an existential is refused there
/// too, and a generic node's parameter needs `T: PlainData`. Another property wrapper on a field
/// is refused, and so is `@PlainData` beside this macro (it writes the same member). A node
/// that conforms by hand uses `@PlainData`. See `docs/core/sync.md#what-registration-refuses`.
@attached(member, names: arbitrary)
public macro StateNodeBuilder() = #externalMacro(
    module: "SwiftStateTreeMacros",
    type: "StateNodeBuilderMacro"
)

/// Macro that automatically generates `SnapshotValueConvertible` protocol conformance.
///
/// This macro analyzes the struct's stored properties and generates a `toSnapshotValue()` method
/// that efficiently converts the struct to `SnapshotValue` without using runtime reflection.
///
/// Example:
/// ```swift
/// @SnapshotConvertible
/// struct PlayerState: Codable {
///     var name: String
///     var hpCurrent: Int
///     var hpMax: Int
/// }
/// ```
///
/// The macro automatically generates:
/// ```swift
/// extension PlayerState: SnapshotValueConvertible {
///     func toSnapshotValue() throws -> SnapshotValue {
///         return .object([
///             "name": .string(name),
///             "hpCurrent": .int(hpCurrent),
///             "hpMax": .int(hpMax)
///         ])
///     }
/// }
/// ```
///
/// `@SnapshotConvertible(atomic: true)` also declares the value atomic (`AtomicSnapshotValue`):
/// a change replaces the whole value, and its leaf paths are the stored properties in declaration
/// order, a nested atomic value contributing its own leaves, prefixed, and the schema field
/// metadata (`SchemaMetadataProvider`) is generated from the same properties. Every stored property
/// must have a type annotation and be a scalar (`AtomicScalarLeaf`) or an atomic value; the
/// compiler rejects anything else (optionals, collections).
///
/// A stored property whose declared type can hold a value of any type is a compile error
/// (#535): `any P`, `Any`, `AnyObject` or a composition `P & Q` at any depth (`[String: Any]`,
/// `(any P)?`), and `AnyHashable` and `AnyCodable` by name.
///
/// The type is `PlainData`: the macro also writes the conformance and the checks `@PlainData`
/// writes (every stored property needs a type annotation), so one attribute makes a state value
/// type. It writes neither when `@PlainData` or `@StateNodeBuilder` is beside it, since those
/// write the witness. See `docs/core/sync.md#what-registration-refuses`.
@attached(extension, conformances: SnapshotValueConvertible, FullSnapshotValueConvertible, SnapshotValueDecodable, AtomicSnapshotValue, SnapshotFieldListProvider, SnapshotConvertibleStoredFields, PlainData, names: named(toSnapshotValue), named(toFullSnapshotValue), named(init(fromSnapshotValue:)), named(atomicLeafPaths), named(getFieldMetadata), named(snapshotFieldMetadata), named(_snapshotStoredFields), named(_plainDataCheck))
public macro SnapshotConvertible(atomic: Bool = false) = #externalMacro(
    module: "SwiftStateTreeMacros",
    type: "SnapshotConvertibleMacro"
)

/// Macro that generates `getFieldMetadata()` for Actions and Events and `getResponseType()` for Actions.
///
/// This macro analyzes the struct's stored properties and generates a `static func getFieldMetadata()`
/// method that returns metadata for schema generation. For types conforming to `ActionPayload`,
/// it also generates `static func getResponseType()` to surface the associated `Response` type.
///
/// Example:
/// ```swift
/// @Payload
/// struct MyAction: ActionPayload {
///     let id: String
///     let count: Int
/// }
/// ```
@attached(member, names: named(getFieldMetadata), named(getResponseType), named(_writePayloadFields), named(_payloadHasTypedWriter), named(_payloadFieldForms), named(_payloadWireName), named(_payloadWireKeys))
@attached(extension, conformances: PlainData, names: named(_plainDataCheck))
public macro Payload() = #externalMacro(
    module: "SwiftStateTreeMacros",
    type: "PayloadMacro"
)
