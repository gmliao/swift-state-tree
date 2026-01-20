import Foundation

/// Thread-safe deterministic random number generator service.
///
/// This service wraps `DeterministicRng` with thread-safe access using locks,
/// making it suitable for use in concurrent game logic handlers.
///
/// The seed is stored and exposed via `RngSeedProvider` protocol for deterministic replay.
public final class DeterministicRngService: @unchecked Sendable, RngSeedProvider {
    private var rng: DeterministicRng
    private let lock = NSLock()
    
    /// The seed used to initialize this RNG service.
    /// This is stored for deterministic replay purposes.
    public let seed: UInt64

    public init(seed: UInt64) {
        self.seed = seed
        self.rng = DeterministicRng(seed: seed)
    }

    public func nextInt(in range: ClosedRange<Int>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rng.nextInt(in: range)
    }

    public func nextInt(in range: Range<Int>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rng.nextInt(in: range)
    }

    public func nextFloat(in range: Range<Float>) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return rng.nextFloat(in: range)
    }
}
