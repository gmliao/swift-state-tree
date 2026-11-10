import Foundation

/// Which state types have had their fallback fields logged in this process: the list is the same
/// for every land of a type, so the first adapter on the typed tables logs it.
final class SyncTableFallbackLog: @unchecked Sendable {
    static let shared = SyncTableFallbackLog()
    private let lock = NSLock()
    private var logged: Set<ObjectIdentifier> = []

    /// True for the first call with `type`.
    func isFirst(_ type: Any.Type) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return logged.insert(ObjectIdentifier(type)).inserted
    }
}
