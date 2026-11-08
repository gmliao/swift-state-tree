import Foundation

/// One scope's dynamic-key slots for the opcode state-update encoders: a key is sent as
/// `[slot, "key"]` on first use and as `slot` after that.
///
/// Slots don't depend on the order a frame's patches come in (#292). The diff's patch order
/// follows dictionary iteration, which Swift seeds per process, so assigning slots on first use
/// let two keys first seen in one frame swap slots between runs (and the encoded size change when
/// the swap crossed a MessagePack integer-width boundary). An encoder calls `reserve(_:)` with
/// every key a frame uses before encoding it: the frame's new keys get their slots in UTF-8 byte
/// order, and each is still defined at its first use.
///
/// Keys are identified by their UTF-8 bytes, not by `String` equality, which treats canonically
/// equivalent spellings (NFC `é`, NFD `e` + U+0301) as one key. The wire carries bytes and a client
/// compares them, so two spellings get two slots and two definitions.
final class DynamicKeyTable: @unchecked Sendable {
    /// A key by its UTF-8 bytes.
    private struct Bytes: Hashable {
        let key: String

        static func == (lhs: Bytes, rhs: Bytes) -> Bool {
            lhs.key.utf8.elementsEqual(rhs.key.utf8)
        }

        func hash(into hasher: inout Hasher) {
            let hashed: Void? = key.utf8.withContiguousStorageIfAvailable {
                hasher.combine(bytes: UnsafeRawBufferPointer($0))
            }
            if hashed == nil {
                for byte in key.utf8 { hasher.combine(byte) }
            }
        }
    }

    private var keyToSlot: [Bytes: Int] = [:]
    /// Keys with a slot that haven't been sent yet: their first use is a definition.
    private var undefined: Set<Bytes> = []
    private var nextSlot: Int = 0
    private let lock = NSLock()

    /// Gives every key of `keys` without a slot one, in UTF-8 byte order. Their first `getSlot`
    /// reports them new.
    func reserve<Keys: Sequence>(_ keys: Keys) where Keys.Element == String {
        lock.lock()
        defer { lock.unlock() }
        var new: Set<Bytes> = []
        for key in keys where keyToSlot[Bytes(key: key)] == nil {
            new.insert(Bytes(key: key))
        }
        guard !new.isEmpty else { return }
        for key in new.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
            keyToSlot[key] = nextSlot
            nextSlot += 1
            undefined.insert(key)
        }
    }

    /// The key's slot, and whether this is its first use (it must be sent as a definition).
    /// A key that wasn't reserved gets the next slot.
    func getSlot(for key: String) -> (slot: Int, isNew: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let key = Bytes(key: key)
        if let existing = keyToSlot[key] {
            return (existing, undefined.remove(key) != nil)
        }
        let slot = nextSlot
        nextSlot += 1
        keyToSlot[key] = slot
        return (slot, true)
    }
}
