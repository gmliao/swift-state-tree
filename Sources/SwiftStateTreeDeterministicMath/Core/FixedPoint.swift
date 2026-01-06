// Sources/SwiftStateTreeDeterministicMath/Core/FixedPoint.swift
//
// Fixed-point math utilities for deterministic server-authoritative games.
// Provides quantization and dequantization functions to convert between Float and Int32.

import Foundation

/// Fixed-point math configuration and utilities.
///
/// This struct provides a centralized way to manage fixed-point arithmetic
/// for deterministic game logic. All quantization uses a fixed scale factor
/// to ensure consistent behavior across platforms and replays.
public struct FixedPoint: Sendable {
    /// The scale factor used for quantization (default: 1000).
    ///
    /// This means 1.0 in Float becomes 1000 in Int32.
    /// Higher values provide more precision but reduce the range of representable values.
    public static let scale: Int32 = 1000
    
    /// Quantize a Float value to Int32 using the fixed scale.
    ///
    /// Uses `.toNearestOrAwayFromZero` rounding rule for deterministic cross-platform behavior.
    /// This ensures consistent quantization across Swift server and TypeScript client.
    ///
    /// - Parameter value: The Float value to quantize.
    /// - Returns: The quantized Int32 value.
    ///
    /// Example:
    /// ```swift
    /// let quantized = FixedPoint.quantize(1.5)  // Returns 1500
    /// let quantizedNeg = FixedPoint.quantize(-1.5)  // Returns -1500 (away from zero)
    /// ```
    public static func quantize(_ value: Float) -> Int32 {
        let scaled = value * Float(scale)
        // Use .toNearestOrAwayFromZero for deterministic cross-platform consistency
        // This matches TypeScript's roundToNearestOrAwayFromZero implementation
        let rounded = scaled.rounded(.toNearestOrAwayFromZero)
        return Int32(rounded)
    }
    
    /// Dequantize an Int32 value back to Float using the fixed scale.
    ///
    /// - Parameter value: The Int32 value to dequantize.
    /// - Returns: The dequantized Float value.
    ///
    /// Example:
    /// ```swift
    /// let dequantized = FixedPoint.dequantize(1500)  // Returns 1.5
    /// ```
    public static func dequantize(_ value: Int32) -> Float {
        return Float(value) / Float(scale)
    }
    
    /// Clamp a Float value to the valid range for Int32 quantization.
    ///
    /// This prevents overflow when quantizing extreme values.
    ///
    /// - Parameter value: The Float value to clamp.
    /// - Returns: The clamped Float value within Int32 range.
    public static func clampToInt32Range(_ value: Float) -> Float {
        let maxValue = Float(Int32.max) / Float(scale)
        let minValue = Float(Int32.min) / Float(scale)
        return max(minValue, min(maxValue, value))
    }
}
