// Sources/SwiftStateTree/StateTree/StateTreeBuilder.swift

/// Macro that validates and generates code for StateTree types.
///
/// This macro:
/// 1. Validates that all stored properties have @Sync or @Internal markers
/// 2. Generates `getSyncFields()` method implementation
/// 3. Generates `validateSyncFields()` method implementation
///
/// Example:
/// ```swift
/// @StateTreeBuilder
/// struct GameStateTree: StateTreeProtocol {
///     @Sync(.broadcast)
///     var players: [PlayerID: PlayerState] = [:]
///     
///     @Sync(.serverOnly)
///     var hiddenDeck: [Card] = []
///     
///     @Internal
///     var lastProcessedTimestamp: Date = Date()
/// }
/// ```
@attached(member, names: arbitrary)
public macro StateTreeBuilder() = #externalMacro(
    module: "SwiftStateTreeMacros",
    type: "StateTreeBuilderMacro"
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

/// Macro that validates State types conform to StateProtocol.
///
/// This macro ensures that all State types:
/// - Conform to `StateProtocol` (which requires `Codable` and `Sendable`)
/// - Are struct types (not classes)
///
/// The macro performs compile-time validation and does not generate any code.
/// It serves as a marker and validation tool to ensure type safety.
///
/// Example:
/// ```swift
/// @State
/// struct PlayerState: StateProtocol {
///     var name: String
///     var hpCurrent: Int
///     var hpMax: Int
/// }
/// ```
@attached(peer)
public macro State() = #externalMacro(
    module: "SwiftStateTreeMacros",
    type: "StateMacro"
)

