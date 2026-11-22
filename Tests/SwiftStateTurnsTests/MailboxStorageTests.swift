import Foundation
import SwiftStateTurns
import Testing

/// A mail that runs `onDeinit` when it is released: a `deinit` that posts to the mailbox that
/// held it.
final class DeinitMail: Sendable {
    let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void = {}) {
        self.onDeinit = onDeinit
    }

    deinit { onDeinit() }
}

/// The mailbox's storage (plan §3.5, rev 4): a ring of `capacity` slots, with removed mail
/// released after the lock is dropped.
@Suite("Mailbox storage")
struct MailboxStorageTests {
    @Test("19: sustained turnover with the mailbox never empty keeps the storage at capacity")
    func ringStaysBounded() {
        let mailbox = TurnMailbox<Int>(capacity: 2)
        _ = mailbox.append(0)
        for i in 1 ... 10_000 {
            #expect(mailbox.append(i) == false)
            #expect(mailbox.removeHead(atOrBelow: mailbox.watermark) == i - 1)
        }
        #expect(mailbox.slotCountForTesting == 2)
        // Only the mail still pending is held: a stepped mail's slot is empty.
        #expect(mailbox.heldMailForTesting == 1)
        #expect(mailbox.removeAll() == [10_000])
        #expect(mailbox.heldMailForTesting == 0)
    }

    @Test("19: a check's watermark still stops at a mail posted after it, across the ring's wrap")
    func watermarkAcrossTheWrap() {
        let mailbox = TurnMailbox<Int>(capacity: 3)
        for i in 1 ... 5 {
            _ = mailbox.append(i)
            _ = mailbox.removeHead(atOrBelow: mailbox.watermark)
        }
        _ = mailbox.append(6)
        let watermark = mailbox.watermark
        _ = mailbox.append(7)
        #expect(mailbox.removeHead(atOrBelow: watermark) == 6)
        #expect(mailbox.removeHead(atOrBelow: watermark) == nil)
        #expect(mailbox.removeHead(atOrBelow: mailbox.watermark) == 7)
        #expect(mailbox.isEmpty)
    }

    @Test("20: a removed mail is released before the next removal, while another stays pending")
    func releasedAtItsRemoval() {
        let released = Released()
        let mailbox = TurnMailbox<DeinitMail>(capacity: 2)
        _ = mailbox.append(DeinitMail(onDeinit: { released.add("A") }))
        _ = mailbox.append(DeinitMail(onDeinit: { released.add("B") }))
        _ = mailbox.removeHead(atOrBelow: mailbox.watermark)
        // A storage that keeps handed-out mail until it empties would still hold A here.
        #expect(released.names == ["A"])
        #expect(mailbox.heldMailForTesting == 1)
        _ = mailbox.removeHead(atOrBelow: mailbox.watermark)
        #expect(released.names == ["A", "B"])
    }

    @Test("20: a mail whose deinit posts to the same mailbox is removed and released without a deadlock")
    func releaseOutsideTheLock() async {
        // Under the hang bound: a release under the lock deadlocks, and the test fails instead of
        // hanging the suite.
        let ended = await withinTurnHangBound { () -> Bool in
            let mailbox = TurnMailbox<DeinitMail>(capacity: 2)
            _ = mailbox.append(DeinitMail(onDeinit: { _ = mailbox.append(DeinitMail()) }))
            _ = mailbox.append(DeinitMail())
            // The removed mail is released here, after `removeHead` dropped the lock, with
            // another still pending.
            _ = mailbox.removeHead(atOrBelow: mailbox.watermark)
            guard mailbox.heldMailForTesting == 2 else { return false }
            // The same through `removeAll`, the take's path.
            _ = mailbox.removeAll()
            _ = mailbox.append(DeinitMail(onDeinit: { _ = mailbox.append(DeinitMail()) }))
            _ = mailbox.removeAll()
            return mailbox.removeAll().count == 1 && mailbox.isEmpty
        }
        #expect(ended == true)
    }
}

/// The names of the mail released so far, in order.
final class Released: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []

    func add(_ name: String) { lock.withLock { list.append(name) } }
    var names: [String] { lock.withLock { list } }
}
