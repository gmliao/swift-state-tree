// Sources/SwiftStateTree/State/StateProtocol.swift

/// Protocol that all State types must conform to.
///
/// This protocol ensures that all State types are `Codable` (for serialization), `Sendable`
/// (for thread-safe usage across concurrency boundaries) and `PlainData` (no class, closure or
/// existential at any depth). `@SnapshotConvertible` or `@PlainData` writes the `PlainData`
/// witness; a conformer without either doesn't compile.
///
/// Example:
/// ```swift
/// @SnapshotConvertible
/// struct PlayerState: StateProtocol {
///     var name: String
///     var hpCurrent: Int
///     var hpMax: Int
/// }
/// ```
public protocol StateProtocol: PlainData, Codable, Sendable {}

