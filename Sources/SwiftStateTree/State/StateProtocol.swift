// Sources/SwiftStateTree/State/StateProtocol.swift

/// Protocol that all State types must conform to.
/// 
/// This protocol ensures that all State types are both `Codable` (for serialization)
/// and `Sendable` (for thread-safe usage across concurrency boundaries).
///
/// State types should be marked with the `@State` macro to ensure compile-time
/// validation that they conform to this protocol.
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
public protocol StateProtocol: Codable, Sendable {}

