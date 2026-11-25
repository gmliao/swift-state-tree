import Foundation
import Synchronization

/// A deterministic random number generator behind a lock: the type of `LandContext.random`.
///
/// Inside a land, the keeper builds one for each handler invocation from the land's generator,
/// and copies the generator back when the handler's step ends (#700, #765). A service kept past
/// its step draws from a copy that no longer moves the land. Draws must be synchronous inside the
/// handler; see `LandContext.random`.
///
/// Registered in `LandServices` before a land starts, a service gives the land its seed only
/// (`RngSeedProvider`): the keeper starts the land's generator from `seed`, and removes the
/// service from the contexts it builds.
public final class DeterministicRngService: Sendable, RngSeedProvider {
    /// The generator, inline: one allocation per service (`NSLock` is a class of its own).
    private let rng: Mutex<DeterministicRng>

    /// The seed used to initialize this RNG service.
    /// This is stored for deterministic replay purposes.
    public let seed: UInt64

    public init(seed: UInt64) {
        self.seed = seed
        self.rng = Mutex(DeterministicRng(seed: seed))
    }

    /// A service that continues `generator` (the keeper's land generator for one step), with the
    /// land's `seed` for `RngSeedProvider`.
    init(continuing generator: DeterministicRng, seed: UInt64) {
        self.seed = seed
        self.rng = Mutex(generator)
    }

    /// The generator's current state, for the keeper to write back when the step ends.
    var generator: DeterministicRng {
        rng.withLock { $0 }
    }

    public func nextInt(in range: ClosedRange<Int>) -> Int {
        rng.withLock { $0.nextInt(in: range) }
    }

    public func nextInt(in range: Range<Int>) -> Int {
        rng.withLock { $0.nextInt(in: range) }
    }

    public func nextFloat(in range: Range<Float>) -> Float {
        rng.withLock { $0.nextFloat(in: range) }
    }
}
