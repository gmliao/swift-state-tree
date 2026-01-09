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
    /// **⚠️ Deprecated: This limit is no longer enforced in actual operations.**
    ///
    /// This was the historical maximum Int32 value (approximately sqrt(Int32.max) ≈ 46,340)
    /// that could be safely used in operations without causing overflow when squaring.
    ///
    /// **Current status**: All operations (magnitudeSquared, distanceSquared, dot product, etc.)
    /// now use Int64 internally, so this limit no longer applies. The actual coordinate limit
    /// is `WORLD_MAX_COORDINATE` (Int32.max / 2 ≈ 1,073,741,823), which is much larger.
    ///
    /// **Usage**: This value is retained for backward compatibility and testing purposes only.
    /// For new code, use `WORLD_MAX_COORDINATE` instead.
    public static let maxSafeInt32: Int32 = Int32(sqrt(Double(Int32.max)))
    
    /// Minimum safe Int32 value for fixed-point operations.
    ///
    /// **⚠️ Deprecated: This limit is no longer enforced in actual operations.**
    ///
    /// See `maxSafeInt32` for details. For new code, use `WORLD_MIN_COORDINATE` instead.
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

    /// Fixed-point scale for trigonometric results (sin/cos).
    public static let trigScale: Int64 = 1_000_000

    /// Fixed-point scale for radians used in trigonometric calculations.
    public static let angleScale: Int64 = 1_000_000_000

    /// Pi in fixed-point radians.
    public static let pi: Int64 = 3_141_592_654

    /// Half pi in fixed-point radians.
    public static let halfPi: Int64 = pi / 2

    /// Two pi in fixed-point radians.
    public static let twoPi: Int64 = pi * 2

    /// CORDIC gain for 24 iterations, scaled by trigScale.
    private static let cordicK: Int64 = 607_253

    /// Arctangent table for CORDIC (radians scaled by angleScale).
    private static let cordicAngles: [Int64] = [
        785_398_163, 463_647_609, 244_978_663, 124_354_995,
        62_418_810, 31_239_833, 15_623_729, 7_812_341,
        3_906_230, 1_953_123, 976_562, 488_281,
        244_141, 122_070, 61_035, 30_518,
        15_259, 7_629, 3_815, 1_907,
        954, 477, 238, 119
    ]

    /// Computes sin/cos for an angle in fixed-point degrees.
    ///
    /// - Parameter degrees: Angle in fixed-point degrees (1000 = 1 degree).
    /// - Returns: sin/cos in fixed-point with trigScale.
    public static func sinCosDegrees(_ degrees: Int32) -> (sin: Int32, cos: Int32) {
        let numerator = Int64(degrees) * pi
        let denominator = Int64(180 * FixedPoint.scale)
        let radians = numerator >= 0
            ? (numerator + denominator / 2) / denominator
            : (numerator - denominator / 2) / denominator
        return sinCosRadians(radians)
    }

    /// Computes atan2 in fixed-point degrees.
    ///
    /// - Parameters:
    ///   - y: Y component in fixed-point.
    ///   - x: X component in fixed-point.
    /// - Returns: Angle in fixed-point degrees (1000 = 1 degree).
    public static func atan2Degrees(y: Int32, x: Int32) -> Int32 {
        if x == 0 && y == 0 {
            return 0
        }

        if x == 0 {
            return y > 0 ? 90 * FixedPoint.scale : -90 * FixedPoint.scale
        }

        var x64 = Int64(x)
        var y64 = Int64(y)
        var angleOffset: Int64 = 0

        if x64 < 0 {
            angleOffset = y64 >= 0 ? pi : -pi
            x64 = -x64
            y64 = -y64
        }

        if y64 == 0 {
            let numerator = angleOffset * Int64(180 * FixedPoint.scale)
            let degrees = numerator >= 0
                ? (numerator + pi / 2) / pi
                : (numerator - pi / 2) / pi
            return Int32(clamping: degrees)
        }

        var z: Int64 = 0
        for i in 0..<cordicAngles.count {
            let di: Int64 = y64 >= 0 ? 1 : -1
            let xNew = x64 + di * (y64 >> i)
            let yNew = y64 - di * (x64 >> i)
            z += di * cordicAngles[i]
            x64 = xNew
            y64 = yNew
        }

        let angleRad = z + angleOffset
        let numerator = angleRad * Int64(180 * FixedPoint.scale)
        let degrees = numerator >= 0
            ? (numerator + pi / 2) / pi
            : (numerator - pi / 2) / pi
        return Int32(clamping: degrees)
    }

    /// Computes the integer square root of a non-negative Int64.
    ///
    /// - Parameter value: The value to compute the square root for.
    /// - Returns: The floor of sqrt(value), or 0 when value is <= 0.
    ///
    /// This uses an integer algorithm to avoid floating-point math and
    /// provides deterministic results across platforms.
    public static func sqrtInt64(_ value: Int64) -> Int64 {
        guard value > 0 else {
            return 0
        }

        var remainder = UInt64(value)
        var result: UInt64 = 0
        var bit: UInt64 = 1 << 62

        while bit > remainder {
            bit >>= 2
        }

        while bit != 0 {
            let candidate = result + bit
            if remainder >= candidate {
                remainder -= candidate
                result = (result >> 1) + bit
            } else {
                result >>= 1
            }
            bit >>= 2
        }

        return Int64(result)
    }

    private static func sinCosRadians(_ radians: Int64) -> (sin: Int32, cos: Int32) {
        var angle = radians % twoPi
        if angle > pi {
            angle -= twoPi
        } else if angle < -pi {
            angle += twoPi
        }

        var cosSign: Int64 = 1
        if angle > halfPi {
            angle = pi - angle
            cosSign = -1
        } else if angle < -halfPi {
            angle = -pi - angle
            cosSign = -1
        }

        var x = cordicK
        var y: Int64 = 0
        var z = angle

        for i in 0..<cordicAngles.count {
            let di: Int64 = z >= 0 ? 1 : -1
            let xNew = x - di * (y >> i)
            let yNew = y + di * (x >> i)
            z -= di * cordicAngles[i]
            x = xNew
            y = yNew
        }

        let cosValue = Int32(clamping: x * cosSign)
        let sinValue = Int32(clamping: y)
        return (sinValue, cosValue)
    }
}
