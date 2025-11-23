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

