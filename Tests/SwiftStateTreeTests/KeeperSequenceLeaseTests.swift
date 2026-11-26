// Tests/SwiftStateTreeTests/KeeperSequenceLeaseTests.swift
//
// The sequence lease (#700 K1b-5 D15.3): a handler step lends the model's counter to its
// contexts, which number their events at emit time, and stages their sync requests by the tick
// each context captured; the step takes both back when it ends.

import Foundation
import Testing
@testable import SwiftStateTree

@Payload
struct SequenceLeaseNotice: ServerEventPayload {
    let n: Int
}

@Suite("The sequence lease: the step's counter and staged sync requests (#700 K1b-5 D15.3)")
struct KeeperSequenceLeaseTests {
    @Test("Events take numbers from the lent counter in emit order, and the counter comes back with the takes")
    func eventsNumberFromTheLentCounter() {
        let lease = KeeperSequenceLease()
        let collector = KeeperOutputCollector()
        var counter = KeeperSequenceCounter()
        counter.next = 7
        lease.lend(counter)
        lease.emit(AnyServerEvent(SequenceLeaseNotice(n: 1)), to: .all, tickId: 3, into: collector)
        lease.emit(AnyServerEvent(SequenceLeaseNotice(n: 2)), to: .all, tickId: 3, into: collector)
        let (back, requests) = lease.end()
        #expect(collector.emittedEvents.map(\.sequence) == [7, 8])
        #expect(collector.emittedEvents.map(\.tickId) == [3, 3])
        #expect(back.next == 9)
        #expect(requests.isEmpty)
    }

    @Test("Sync requests are staged by the tick their context captured, and a new lend starts empty")
    func requestsAreStagedByTick() {
        let lease = KeeperSequenceLease()
        lease.lend(KeeperSequenceCounter())
        lease.requestSync(broadcastOnly: false, tickId: 4)
        lease.requestSync(broadcastOnly: true, tickId: 4)
        lease.requestSync(broadcastOnly: true, tickId: 5)
        let (_, requests) = lease.end()
        #expect(requests[4]?.syncNow == true)
        #expect(requests[4]?.syncBroadcastOnly == true)
        #expect(requests[5]?.syncNow == false)
        #expect(requests[5]?.syncBroadcastOnly == true)
        lease.lend(KeeperSequenceCounter())
        #expect(lease.end().requests.isEmpty)
        #expect(lease.unlentCount == 0)
    }

    @Test("A re-evaluation counter keeps its overflow check through the lend")
    func overflowCheckSurvivesTheLend() {
        let lease = KeeperSequenceLease()
        var counter = KeeperSequenceCounter()
        counter.checksOverflow = true
        counter.next = .max
        lease.lend(counter)
        lease.emit(AnyServerEvent(SequenceLeaseNotice(n: 1)), to: .all, tickId: 0, into: KeeperOutputCollector())
        let back = lease.end().counter
        #expect(back.exhausted)
        #expect(back.next == .max)
    }
}
