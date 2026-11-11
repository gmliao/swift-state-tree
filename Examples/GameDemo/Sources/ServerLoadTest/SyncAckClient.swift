import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

/// Each simulated client's last received sync sequence (#332), acked once a second the way the
/// SDK does. The load test's connections apply nothing, so "received" is "applied".
/// Lock-protected, not an actor: every delivered frame records here, and a shared actor would add
/// a hop per frame that every client contends on.
final class SyncAckClients: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSeq: [SessionID: UInt64] = [:]
    private var acksSentCount = 0
    private var serverClosesByCode: [UInt16: Int] = [:]

    var acksSent: Int { lock.withLock { acksSentCount } }
    /// Server closes by close code (4010 slow consumer, 4011 unresponsive, 4012 unencodable view, …).
    var serverCloses: [UInt16: Int] { lock.withLock { serverClosesByCode } }

    func received(_ seq: UInt64, sessionID: SessionID) {
        lock.withLock {
            if seq > lastSeq[sessionID] ?? 0 { lastSeq[sessionID] = seq }
        }
    }

    func ended(_ sessionID: SessionID) {
        _ = lock.withLock { lastSeq.removeValue(forKey: sessionID) }
    }

    func closedByServer(_ sessionID: SessionID, code: UInt16) {
        lock.withLock {
            lastSeq.removeValue(forKey: sessionID)
            serverClosesByCode[code, default: 0] += 1
        }
    }

    /// One ack per client with a sequence, in the run's message encoding.
    func acks(binary: Bool) -> [(SessionID, Data)] {
        let snapshot = lock.withLock { () -> [SessionID: UInt64] in
            acksSentCount += lastSeq.count
            return lastSeq
        }
        return snapshot.map { ($0.key, SyncAckFrame.encode(seq: $0.value, binary: binary)) }
    }
}
