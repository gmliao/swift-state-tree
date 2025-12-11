import Foundation

/// Protocol that marks a type as a ResolverOutput.
///
/// All Resolver outputs must conform to this protocol to ensure type safety
/// and clear separation from StateNode types.
///
/// ResolverOutput types:
/// - Do NOT enter the StateTree
/// - Do NOT sync to clients
/// - Do NOT participate in diff calculations
/// - Are context data for Action/Event handlers to reference
///
/// Example:
/// ```swift
/// struct ProductInfo: ResolverOutput {
///     let id: ProductID
///     let name: String
///     let price: Decimal
///     let stock: Int
/// }
/// ```
public protocol ResolverOutput: Codable & Sendable {
    // Currently empty protocol, providing type marker and future extensibility
    // All Resolver output data types must conform to this protocol
}
