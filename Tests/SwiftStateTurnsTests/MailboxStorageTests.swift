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

    @Test("20: a mail whose deinit posts to the same mailbox is removed and released without a deadlock")
    func releaseOutsideTheLock() {
        let mailbox = TurnMailbox<DeinitMail>(capacity: 2)
        _ = mailbox.append(DeinitMail(onDeinit: { _ = mailbox.append(DeinitMail()) }))
        // The removed mail is released here, after `removeHead` dropped the lock.
        _ = mailbox.removeHead(atOrBelow: mailbox.watermark)
        #expect(!mailbox.isEmpty)
        // The same through `removeAll`, the take's path.
        _ = mailbox.removeAll()
        _ = mailbox.append(DeinitMail(onDeinit: { _ = mailbox.append(DeinitMail()) }))
        _ = mailbox.removeAll()
        #expect(mailbox.removeAll().count == 1)
        #expect(mailbox.isEmpty)
    }
}
