// Sources/SwiftStateTreeDeterministicMath/Overflow/OverflowPolicy.swift
//
// Overflow policy configuration for deterministic math operations.
// Provides centralized overflow handling strategies.

import Foundation

/// Overflow handling policy for deterministic math operations.
///
/// This enum defines how overflow should be handled in arithmetic operations
/// to ensure deterministic behavior across platforms and replays.
public enum OverflowPolicy: Sendable {
    /// Wrapping overflow (default for deterministic behavior).
    ///
    /// Values wrap around when they exceed the type's range.
    /// Example: `Int32.max + 1` wraps to `Int32.min`.
    ///
    /// This is the default policy because it ensures deterministic behavior
    /// across all platforms and is the most efficient.
    case wrapping
    
    /// Clamping overflow.
    ///
    /// Values are clamped to the type's range when they would overflow.
    /// Example: `Int32.max + 1` clamps to `Int32.max`.
    ///
    /// Note: This is less efficient than wrapping and may not be suitable
    /// for all game logic scenarios.
    case clamping
    
    /// Trapping overflow (crashes on overflow).
    ///
    /// Operations trap (crash) when overflow would occur.
    /// This is useful for debugging but should not be used in production.
    ///
    /// Note: This is the least efficient option and should only be used
    /// during development to catch overflow issues.
    case trapping
}

/// Helper functions for applying overflow policies to arithmetic operations.
///
/// These functions provide a centralized way to apply overflow policies
/// to arithmetic operations, ensuring consistent behavior.
public enum OverflowHandler: Sendable {
    /// Add two Int32 values with the specified overflow policy.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand side value.
    ///   - rhs: The right-hand side value.
    ///   - policy: The overflow policy to apply.
    /// - Returns: The result of the addition.
    public static func add(_ lhs: Int32, _ rhs: Int32, policy: OverflowPolicy) -> Int32 {
        switch policy {
        case .wrapping:
            return lhs &+ rhs
        case .clamping:
            let result = Int64(lhs) + Int64(rhs)
            if result > Int32.max {
                return Int32.max
            } else if result < Int32.min {
                return Int32.min
            } else {
                return Int32(result)
            }
        case .trapping:
            return lhs + rhs  // Will trap on overflow
        }
    }
    
    /// Subtract two Int32 values with the specified overflow policy.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand side value.
    ///   - rhs: The right-hand side value.
    ///   - policy: The overflow policy to apply.
    /// - Returns: The result of the subtraction.
    public static func subtract(_ lhs: Int32, _ rhs: Int32, policy: OverflowPolicy) -> Int32 {
        switch policy {
        case .wrapping:
            return lhs &- rhs
        case .clamping:
            let result = Int64(lhs) - Int64(rhs)
            if result > Int32.max {
                return Int32.max
            } else if result < Int32.min {
                return Int32.min
            } else {
                return Int32(result)
            }
        case .trapping:
            return lhs - rhs  // Will trap on overflow
        }
    }
    
    /// Multiply an Int32 value by a scalar with the specified overflow policy.
    ///
    /// - Parameters:
    ///   - value: The value to multiply.
    ///   - scalar: The scalar multiplier.
    ///   - policy: The overflow policy to apply.
    /// - Returns: The result of the multiplication.
    public static func multiply(_ value: Int32, by scalar: Int32, policy: OverflowPolicy) -> Int32 {
        switch policy {
        case .wrapping:
            return value &* scalar
        case .clamping:
            let result = Int64(value) * Int64(scalar)
            if result > Int32.max {
                return Int32.max
            } else if result < Int32.min {
                return Int32.min
            } else {
                return Int32(result)
            }
        case .trapping:
            return value * scalar  // Will trap on overflow
        }
    }
}
