// Sources/SwiftStateTree/StateTree/StateTreeProtocol.swift

/// Protocol that marks a type as a StateTree.
/// 
/// StateTree is the single source of truth for domain state.
/// Types conforming to this protocol should:
/// - Be marked with `@StateTreeBuilder` macro for compile-time validation
/// - Have stored properties marked with `@Sync` (for synchronization) or `@Internal` (for server-only use)
/// - Computed properties are automatically skipped from validation
/// - Conform to `Sendable` for thread-safe usage
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
///     
///     var totalPlayers: Int {
///         players.count
///     }
/// }
/// ```
public protocol StateTreeProtocol: Sendable {
    // Protocol serves as a marker to identify StateTree types
    // All conforming types must be Sendable for thread-safe usage
}

