import Foundation

/// Protocol for resolvers that provide context data to Action/Event handlers.
///
/// Resolvers are responsible for loading data from external sources (DB, Redis, API, etc.)
/// and providing it to Action/Event handlers. The `resolve()` method is async to allow
/// for I/O operations, but all resolve operations must complete before the Action/Event
/// handler executes (which is synchronous).
///
/// Example:
/// ```swift
/// struct ProductInfoResolver: ContextResolver {
///     public typealias Output = ProductInfo
///
///     public static func resolve(
///         ctx: ResolverContext
///     ) async throws -> ProductInfo {
///         let action = ctx.actionPayload as? UpdateCartAction
///         guard let productID = action?.productID else {
///             throw ResolverError.missingParameter("productID")
///         }
///         let data = try await ctx.services.database.fetchProduct(by: productID)
///         return ProductInfo(
///             id: data.id,
///             name: data.name,
///             price: data.price,
///             stock: data.stock
///         )
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
    /// This method is called before the Action/Event handler executes.
    /// All resolvers declared in `@Resolvers` are executed in parallel.
    ///
    /// - Parameter ctx: The resolver context providing access to action/event payloads,
    ///                  current state, services, and other request information.
    /// - Returns: The resolved output data.
    /// - Throws: Errors from data loading operations.
    static func resolve(
        ctx: ResolverContext
    ) async throws -> Output
}
