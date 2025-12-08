// Sources/SwiftStateTree/StateTree/StateTreeBuilder.swift

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
///     var lastProcessedTimestamp: Date = Date()
/// }
/// ```
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
@attached(extension, conformances: SnapshotValueConvertible, names: named(toSnapshotValue))
public macro SnapshotConvertible() = #externalMacro(
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
@attached(member, names: named(getFieldMetadata), named(getResponseType))
public macro Payload() = #externalMacro(
    module: "SwiftStateTreeMacros",
    type: "PayloadMacro"
)
