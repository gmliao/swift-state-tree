// Sources/SwiftStateTree/Support/SyncWriteAccess.swift
//
// The #87 detector (#535 §3.7, D5 (a)): whether a handler took mutable access to synced state.

import Foundation

/// Counts mutable accesses to `@Sync` fields on the current thread while a handler runs.
///
/// The contract is **mutable access**, not actual change: `Sync`'s setter and `_modify` call
/// `noteAccess()` at entry, so `try validateThenMutate(&state.x)` counts even when the
/// validation throws first. The documented rule is to validate before taking `inout` access.
///
/// The count lives in a POSIX thread-specific slot, not in the state: nothing is stored on a
/// `StateNode`, so equality, encoding, snapshots, the state hash and the record don't change. A
/// handler runs without an await (`LandKeeper.withMutableStateSync`), so its call stays on one
/// thread. `counting(_:)` saves the slot's previous value and restores it, so a nested call and
/// a later keeper on the same pooled thread start from their own count.
///
/// The slot holds `(count << 1) | 1` while installed and nothing otherwise, so a write outside a
/// handler costs one thread-specific read. The count wraps; only "changed or not" is compared.
package enum SyncWriteAccess {
    private static let key: pthread_key_t = {
        var key = pthread_key_t()
        let status = pthread_key_create(&key, nil)
        precondition(status == 0, "pthread_key_create failed: \(status)")
        return key
    }()

    /// Called by `Sync`'s setter and `_modify` at entry.
    @inline(__always)
    static func noteAccess() {
        guard let slot = pthread_getspecific(key) else { return }
        let next = UInt(bitPattern: slot) &+ 2
        pthread_setspecific(key, UnsafeRawPointer(bitPattern: next))
    }

    /// Runs `body` with the count installed at zero. Returns its result, or rethrows its error
    /// with whether it took mutable access to a `@Sync` field before throwing.
    package static func counting<R>(_ body: () throws -> R) throws(AccessedThrow) -> R {
        let previous = pthread_getspecific(key)
        let installed = UnsafeRawPointer(bitPattern: UInt(1))
        pthread_setspecific(key, installed)
        defer { pthread_setspecific(key, previous) }
        do {
            return try body()
        } catch {
            let accessed = pthread_getspecific(key).map { UnsafeRawPointer($0) } != installed
            throw AccessedThrow(error: error, accessed: accessed)
        }
    }

    /// A handler's error and whether it took mutable access before it.
    package struct AccessedThrow: Error {
        package let error: any Error
        package let accessed: Bool
    }

    /// Whether the count is installed on this thread (tests).
    package static var isInstalledForTesting: Bool {
        pthread_getspecific(key) != nil
    }
}
