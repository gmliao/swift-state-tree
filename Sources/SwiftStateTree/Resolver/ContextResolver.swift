import Foundation

/// A resolver named by its type, for the join entries (`CanJoin`, `OnJoin`, `OnLeave`) until
/// #769 R3, and for destroy-when-empty executors set on `LandDefinition`. Actions, `OnInitialize`
/// and `OnFinalize` declare `Resolver` values instead.
///
/// `resolve` loads data from outside the land (a database, a cache, an API) and reads the join's
/// context: `ctx.playerID`, `ctx.landID`, `ctx.currentState` and `ctx.services`. It is async;
/// the handler runs, synchronously, once every resolver of its entry has finished.
///
/// Example:
/// ```swift
/// struct UserProfileResolver: ContextResolver {
///     static func resolve(ctx: ResolverContext) async throws -> UserProfile {
///         guard let store = ctx.services.get(ProfileStore.self) else {
///             throw ResolverError.missingParameter("ProfileStore")
///         }
///         return try await store.profile(for: ctx.playerID)
///     }
/// }
/// ```
public protocol ContextResolver {
    /// The output type that this resolver produces.
    ///
    /// Must conform to `ResolverOutput` protocol.
    associatedtype Output: ResolverOutput

    /// Resolve the context data asynchronously.
    ///
    /// Runs before the handler that declares it, in parallel with the entry's other resolvers.
    ///
    /// - Parameter ctx: The join's context: the player, the land, the current state and the
    ///                  services.
    /// - Returns: The resolved output data.
    /// - Throws: Errors from data loading operations.
    static func resolve(
        ctx: ResolverContext
    ) async throws -> Output
}
