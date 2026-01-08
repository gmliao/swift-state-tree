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
    
    /// The scale factor squared (scale * scale = 1_000_000).
    ///
    /// Used for squared distance calculations and other operations requiring scale^2.
    public static let scaleSquared: Int64 = Int64(scale) * Int64(scale)
    
    /// The scale factor cubed (scale * scale * scale = 1_000_000_000).
    ///
    /// Used for high-precision division operations in collision detection (e.g., ray-AABB intersection).
    public static let scaleCubed: Int64 = Int64(scale) * Int64(scale) * Int64(scale)
    
    /// The scale factor as Float (1000.0).
    ///
    /// Used for Float-based conversions and calculations.
    public static let scaleFloat: Float = Float(scale)
    
    /// The scale factor squared as Float (1_000_000.0).
    ///
    /// Used for Float-based squared distance calculations.
    public static let scaleSquaredFloat: Float = Float(scaleSquared)
    
    /// Maximum safe Float value that can be quantized without overflow.
    ///
    /// This is the maximum value that can be safely represented using Int32
    /// with the current scale factor. Values exceeding this will overflow
    /// when quantized.
    ///
    /// For scale = 1000: maxSafeValue ≈ ±2,147,483.647
    public static let maxSafeValue: Float = Float(Int32.max) / scaleFloat
    
    /// Minimum safe Float value that can be quantized without overflow.
    ///
    /// This is the minimum value that can be safely represented using Int32
    /// with the current scale factor. Values below this will overflow
    /// when quantized.
    ///
    /// For scale = 1000: minSafeValue ≈ ±2,147,483.648
    public static let minSafeValue: Float = Float(Int32.min) / scaleFloat
    
    /// Maximum safe Int32 value for fixed-point operations.
    ///
    /// This is the maximum Int32 value that can be safely used in operations
    /// without causing overflow in intermediate calculations.
    ///
    /// For operations involving squaring (e.g., magnitudeSquared), the safe
    /// maximum is approximately sqrt(Int32.max) ≈ 46,340 to prevent overflow
    /// when squaring.
    public static let maxSafeInt32: Int32 = Int32(sqrt(Double(Int32.max)))
    
    /// Minimum safe Int32 value for fixed-point operations.
    ///
    /// This is the minimum Int32 value that can be safely used in operations
    /// without causing overflow in intermediate calculations.
    public static let minSafeInt32: Int32 = -maxSafeInt32
    
    /// Maximum safe coordinate value for distance calculations using Int64.
    ///
    /// This is the maximum coordinate value that can be safely used in distance calculations
    /// without causing Int64 overflow when computing `dx² + dy²`.
    ///
    /// **Why Int32.max / 2?** The maximum possible difference between two coordinates is
    /// `Int32.max - Int32.min ≈ 4,294,967,295`, and `dx²` would be `1.844e19`, which exceeds
    /// `Int64.max (9.22e18)`. To ensure `dx² + dy² ≤ Int64.max`, we need `|dx| ≤ sqrt(Int64.max / 2) ≈ 2,147,483,647`.
    /// Since `dx = x1 - x2`, we need `|x| ≤ Int32.max / 2 = 1,073,741,823` to guarantee safety.
    ///
    /// For scale = 1000: WORLD_MAX_COORDINATE ≈ ±1,073,741,823 fixed-point units (≈ ±1,073,741.823 Float units).
    public static let WORLD_MAX_COORDINATE: Int32 = Int32.max / 2
    
    /// Minimum safe coordinate value for distance calculations using Int64.
    ///
    /// This is the minimum coordinate value that can be safely used in distance calculations.
    public static let WORLD_MIN_COORDINATE: Int32 = -WORLD_MAX_COORDINATE
    
    /// Maximum safe circle radius for ICircle.
    ///
    /// This is the maximum radius value that can be safely used in ICircle operations
    /// without causing issues with `boundingAABB()` or other operations that require Int32.
    ///
    /// **Why Int32.max?** Since `IAABB2` and `IVec2` use Int32 coordinates, and `boundingAABB()`
    /// needs to compute `center ± radius`, we limit radius to `Int32.max` to ensure the result
    /// can be represented as Int32.
    ///
    /// For scale = 1000: MAX_CIRCLE_RADIUS ≈ 2,147,483,647 fixed-point units (≈ 2,147,483.647 Float units).
    public static let MAX_CIRCLE_RADIUS: Int64 = Int64(Int32.max)
    
    /// Minimum safe circle radius for ICircle.
    public static let MIN_CIRCLE_RADIUS: Int64 = 0
    
    /// Quantize a Float value to Int32 using the fixed scale.
    ///
    /// - Parameters:
    ///   - value: The Float value to quantize.
    ///   - rounding: The rounding rule to apply (default: `.toNearestOrAwayFromZero`).
    /// - Returns: The quantized Int32 value.
    ///
    /// Example:
    /// ```swift
    /// let quantized = FixedPoint.quantize(1.5)  // Returns 1500
    /// ```
    public static func quantize(
        _ value: Float,
        rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) -> Int32 {
        let scaled = value * scaleFloat
        let rounded = scaled.rounded(rounding)
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
        return Float(value) / scaleFloat
    }
    
    /// Dequantize an Int64 value back to Float using the fixed scale.
    ///
    /// - Parameter value: The Int64 value to dequantize.
    /// - Returns: The dequantized Float value.
    ///
    /// This is used for values that may exceed Int32 range (e.g., ICircle.radius).
    ///
    /// Example:
    /// ```swift
    /// let dequantized = FixedPoint.dequantize(Int64(1500))  // Returns 1.5
    /// ```
    public static func dequantize(_ value: Int64) -> Float {
        return Float(value) / scaleFloat
    }
    
    /// Clamp a Float value to the valid range for Int32 quantization.
    ///
    /// This prevents overflow when quantizing extreme values.
    ///
    /// - Parameter value: The Float value to clamp.
    /// - Returns: The clamped Float value within Int32 range.
    public static func clampToInt32Range(_ value: Float) -> Float {
        let maxValue = Float(Int32.max) / scaleFloat
        let minValue = Float(Int32.min) / scaleFloat
        return max(minValue, min(maxValue, value))
    }
    
    /// Clamp a Float value to the safe world coordinate range.
    ///
    /// This ensures coordinates can be safely used in distance calculations
    /// without causing Int64 overflow.
    ///
    /// - Parameter value: The Float value to clamp.
    /// - Returns: The clamped Float value within WORLD_MAX_COORDINATE range.
    public static func clampToWorldRange(_ value: Float) -> Float {
        let maxValue = Float(WORLD_MAX_COORDINATE) / scaleFloat
        let minValue = Float(WORLD_MIN_COORDINATE) / scaleFloat
        return max(minValue, min(maxValue, value))
    }
    
    /// Clamp an Int64 radius value to the safe range for ICircle.
    ///
    /// This ensures radius can be safely used in ICircle operations
    /// without causing issues with boundingAABB() or other Int32 operations.
    ///
    /// - Parameter radius: The Int64 radius value to clamp.
    /// - Returns: The clamped Int64 radius value within MAX_CIRCLE_RADIUS range.
    public static func clampCircleRadius(_ radius: Int64) -> Int64 {
        return max(MIN_CIRCLE_RADIUS, min(MAX_CIRCLE_RADIUS, radius))
    }
}
