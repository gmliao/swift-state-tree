import Foundation

/// Deterministic random number generator for use in game logic.
///
/// This RNG uses a deterministic algorithm that produces the same sequence
/// of random numbers when initialized with the same seed, ensuring consistent
/// behavior across platforms and enabling deterministic replay.
public struct DeterministicRng: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed == 0 ? 0x9e3779b97f4a7c15 : seed
    }

    public mutating func nextUInt32() -> UInt32 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return UInt32(truncatingIfNeeded: z ^ (z >> 31))
    }

    public mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let lower = range.lowerBound
        let upper = range.upperBound
        guard lower <= upper else { return lower }
        let span = UInt64(upper - lower + 1)
        let value = UInt64(nextUInt32()) % span
        return lower + Int(value)
    }

    public mutating func nextInt(in range: Range<Int>) -> Int {
        let lower = range.lowerBound
        let upper = range.upperBound - 1
        guard lower <= upper else { return lower }
        return nextInt(in: lower...upper)
    }

    public mutating func nextFloat(in range: Range<Float>) -> Float {
        let upper = range.upperBound
        let lower = range.lowerBound
        if upper <= lower { return lower }
        let unit = Float(nextUInt32()) / Float(UInt32.max)
        return lower + (unit * (upper - lower))
    }
}

/// Helper for generating deterministic seeds from land identifiers.
public enum DeterministicSeed {
    /// Generate a deterministic seed from a land ID.
    ///
    /// This ensures that the same land ID always produces the same seed,
    /// enabling deterministic behavior across server restarts and replays.
    public static func fromLandID(_ landID: String) -> UInt64 {
        DeterministicHash.fnv1a64(landID)
    }
}
