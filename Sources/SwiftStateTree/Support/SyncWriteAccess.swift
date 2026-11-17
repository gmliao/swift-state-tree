// Sources/SwiftStateTree/Support/SyncWriteAccess.swift
//
// The #87 detector (#535 §3.7, D5 (a)): whether a handler took mutable access to synced state.

import Foundation

/// Counts mutable accesses to `@Sync` fields on the current thread while a handler runs.
///
/// The contract is **mutable access**, not actual change: `Sync`'s setter and `_modify` call
/// `noteAccess()` at entry (not `updateValueWithoutMarkingDirty(_:)`), so `try validateThenMutate(&state.x)` counts even when the
/// validation throws first. The documented rule is to validate before taking `inout` access.
///
/// The count lives in a POSIX thread-specific slot, not in the state: nothing is stored on a
/// `StateNode`, so equality, encoding, snapshots, the state hash and the record don't change. A
/// handler runs without an await (`LandKeeper.withMutableStateSync`), so its call stays on one
/// thread. The caller installs the count with `install()`, which returns the slot's previous
/// value, reads `accessedSinceInstall()` when the handler throws, and puts the previous value
/// back with `restore(_:)` (in a `defer`), so a nested call and a later keeper on the same pooled
/// thread start from their own count. Plain calls, not a closure-taking wrapper: the handler's
/// closure stays in the caller's isolation.
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

    /// The slot's value while installed with no access counted yet.
    private static var installed: UnsafeRawPointer? { UnsafeRawPointer(bitPattern: UInt(1)) }

    /// Installs the count at zero on this thread and returns the slot's previous value, for
    /// `restore(_:)`.
    @inline(__always)
    package static func install() -> UnsafeMutableRawPointer? {
        let previous = pthread_getspecific(key)
        pthread_setspecific(key, installed)
        return previous
    }

    /// Whether a `@Sync` field took mutable access since `install()` on this thread.
    @inline(__always)
    package static func accessedSinceInstall() -> Bool {
        pthread_getspecific(key).map { UnsafeRawPointer($0) } != installed
    }

    /// Puts back the slot's value from before `install()`.
    @inline(__always)
    package static func restore(_ previous: UnsafeMutableRawPointer?) {
        pthread_setspecific(key, previous.map { UnsafeRawPointer($0) })
    }

    /// Whether the count is installed on this thread (tests).
    package static var isInstalledForTesting: Bool {
        pthread_getspecific(key) != nil
    }
}
