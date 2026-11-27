// Sources/SwiftStateTree/Support/KeyedBarrierWaits.swift

/// Callers parked on a key until a step releases it: a keyed barrier wait. A caller parks with
/// an ID it took first; a release of its key resumes every waiter parked on that key; the
/// caller's own cancel resumes it with `CancellationError` only if no release took it first.
/// Each waiter leaves the table before it resumes, so it resumes exactly once.
///
/// Kept on the keeper's side for the join that waits for its player's leave in flight (#943),
/// until the turn core's generic barrier wait (#953) replaces it: park on a key, release from
/// the step that ends the barrier.
struct KeyedBarrierWaits<Key: Hashable & Sendable> {
    typealias Waiter = CheckedContinuation<Void, any Error>

    private var parked: [Key: [UInt64: Waiter]] = [:]
    private var nextID: UInt64 = 0

    /// A fresh ID for a caller about to park, taken before its cancellation handler is
    /// installed, so the handler can name the waiter.
    mutating func makeID() -> UInt64 {
        defer { nextID += 1 }
        return nextID
    }

    /// Parks `waiter` on `key` under `id`.
    mutating func park(_ key: Key, id: UInt64, _ waiter: Waiter) {
        parked[key, default: [:]][id] = waiter
    }

    /// The waiters parked on `key`.
    func count(_ key: Key) -> Int {
        parked[key]?.count ?? 0
    }

    /// The barrier on `key` ends: every waiter parked on it leaves the table and resumes.
    mutating func release(_ key: Key) {
        for waiter in (parked.removeValue(forKey: key) ?? [:]).values { waiter.resume() }
    }

    /// Every barrier ends: every waiter leaves the table and resumes.
    mutating func releaseAll() {
        let all = parked
        parked.removeAll()
        for waiter in all.values.flatMap(\.values) { waiter.resume() }
    }

    /// The waiter's own cancel: removes it and resumes it with `CancellationError`. Returns
    /// false when a release took it out first (it has resumed already).
    mutating func cancel(_ key: Key, id: UInt64) -> Bool {
        guard let waiter = parked[key]?.removeValue(forKey: id) else { return false }
        if parked[key]?.isEmpty == true { parked[key] = nil }
        waiter.resume(throwing: CancellationError())
        return true
    }
}
