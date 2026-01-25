import Foundation

/// Deterministic hash utilities for consistent hashing across platforms.
///
/// Uses FNV-1a algorithm which is:
/// - Deterministic (same input always produces same output)
/// - Fast (simple XOR and multiply operations)
/// - No external dependencies (no CryptoKit required)
///
/// Note: Swift's built-in `Hashable` is NOT deterministic (uses random seed per run).
public enum DeterministicHash {
    
    // MARK: - FNV-1a Constants
    
    /// FNV-1a 64-bit offset basis
    private static let fnv64OffsetBasis: UInt64 = 14695981039346656037
    
    /// FNV-1a 64-bit prime
    private static let fnv64Prime: UInt64 = 1099511628211
    
    // MARK: - Hash Functions
    
    /// Compute 64-bit FNV-1a hash of data.
    ///
    /// - Parameter data: Input data to hash
    /// - Returns: 64-bit unsigned integer hash
    public static func fnv1a64(_ data: Data) -> UInt64 {
        var hash = fnv64OffsetBasis
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* fnv64Prime
        }
        return hash
    }
    
    /// Compute 64-bit FNV-1a hash of a string (UTF-8 encoded).
    ///
    /// - Parameter string: Input string to hash
    /// - Returns: 64-bit unsigned integer hash
    public static func fnv1a64(_ string: String) -> UInt64 {
        fnv1a64(Data(string.utf8))
    }
    
    /// Compute 32-bit FNV-1a hash of data.
    ///
    /// Uses XOR-folding of 64-bit hash to produce 32-bit result.
    ///
    /// - Parameter data: Input data to hash
    /// - Returns: 32-bit unsigned integer hash
    public static func fnv1a32(_ data: Data) -> UInt32 {
        let hash64 = fnv1a64(data)
        // XOR-fold to 32 bits
        return UInt32(truncatingIfNeeded: hash64 ^ (hash64 >> 32))
    }
    
    /// Compute 32-bit FNV-1a hash of a string (UTF-8 encoded).
    ///
    /// - Parameter string: Input string to hash
    /// - Returns: 32-bit unsigned integer hash
    public static func fnv1a32(_ string: String) -> UInt32 {
        fnv1a32(Data(string.utf8))
    }
    
    /// Compute positive Int32 hash suitable for player slots.
    ///
    /// - Parameter string: Input string (e.g., accountKey)
    /// - Returns: Positive Int32 hash (0x00000000 to 0x7FFFFFFF)
    public static func stableInt32(_ string: String) -> Int32 {
        Int32(bitPattern: fnv1a32(string) & 0x7FFFFFFF)
    }
    
    // MARK: - Hex String Conversion

    private static func paddedLowerHex<T: FixedWidthInteger & UnsignedInteger>(
        _ value: T,
        width: Int
    ) -> String {
        let hex = String(value, radix: 16, uppercase: false)
        if hex.count >= width {
            // FixedWidthInteger values should not exceed the requested width,
            // but keep this defensive to avoid surprises.
            return String(hex.suffix(width))
        }
        return String(repeating: "0", count: width - hex.count) + hex
    }
    
    /// Convert 64-bit hash to 16-character hex string.
    public static func toHex64(_ hash: UInt64) -> String {
        paddedLowerHex(hash, width: 16)
    }
    
    /// Convert 32-bit hash to 8-character hex string.
    public static func toHex32(_ hash: UInt32) -> String {
        paddedLowerHex(hash, width: 8)
    }
}
