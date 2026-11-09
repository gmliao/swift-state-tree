import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

/// The sync sequence of a state-update frame (#332), read from its first bytes without decoding
/// the frame: `[op, seq, …]` with op 0–3, or opcode 107's `[107, [op, seq, …], …]`, in
/// MessagePack or JSON, or the JSON object encoding's `seq` key. Nil for any other frame.
enum SyncSequencePeek {
    static func seq(_ data: Data) -> UInt64? {
        guard let first = data.first else { return nil }
        if first == UInt8(ascii: "[") { return jsonSeq(data) }
        if first == UInt8(ascii: "{") { return jsonObjectSeq(data) }
        return messagePackSeq(data)
    }

    /// A top-level `"seq":N` (only a state update has one), found by a byte scan that tracks
    /// nesting and strings: no parse, no allocation.
    private static let objectSeqKey = Array(#""seq":"#.utf8)

    private static func jsonObjectSeq(_ data: Data) -> UInt64? {
        let key = objectSeqKey
        var depth = 0
        var inString = false
        var escaped = false
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
                index += 1
                continue
            }
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
            case UInt8(ascii: "\""):
                if depth == 1, data[index...].starts(with: key) {
                    var cursor = index + key.count
                    var value: UInt64 = 0
                    var digits = 0
                    while cursor < data.endIndex, data[cursor] >= 0x30, data[cursor] <= 0x39 {
                        value = value &* 10 &+ UInt64(data[cursor] - 0x30)
                        cursor += 1
                        digits += 1
                    }
                    return digits > 0 ? value : nil
                }
                inString = true
            default: break
            }
            index += 1
        }
        return nil
    }

    // MARK: MessagePack

    private static func messagePackSeq(_ data: Data) -> UInt64? {
        var index = data.startIndex
        guard skipArrayHeader(data, &index), let op = readUInt(data, &index) else { return nil }
        if op == 107 {
            guard skipArrayHeader(data, &index), let inner = readUInt(data, &index), inner <= 3 else { return nil }
            return readUInt(data, &index)
        }
        guard op <= 3 else { return nil }
        return readUInt(data, &index)
    }

    private static func skipArrayHeader(_ data: Data, _ index: inout Data.Index) -> Bool {
        guard index < data.endIndex else { return false }
        let byte = data[index]
        switch byte {
        case 0x90...0x9F: index += 1
        case 0xDC: index += 3
        case 0xDD: index += 5
        default: return false
        }
        return index <= data.endIndex
    }

    private static func readUInt(_ data: Data, _ index: inout Data.Index) -> UInt64? {
        guard index < data.endIndex else { return nil }
        let byte = data[index]
        index += 1
        func bigEndian(_ count: Int) -> UInt64? {
            guard data.endIndex - index >= count else { return nil }
            var value: UInt64 = 0
            for _ in 0..<count {
                value = value << 8 | UInt64(data[index])
                index += 1
            }
            return value
        }
        switch byte {
        case 0x00...0x7F: return UInt64(byte)
        case 0xCC: return bigEndian(1)
        case 0xCD: return bigEndian(2)
        case 0xCE: return bigEndian(4)
        case 0xCF: return bigEndian(8)
        default: return nil
        }
    }

    // MARK: JSON

    private static func jsonSeq(_ data: Data) -> UInt64? {
        // "[op,seq," or "[107,[op,seq,", no whitespace (the server writes none).
        var index = data.startIndex
        func expect(_ ascii: UInt8) -> Bool {
            guard index < data.endIndex, data[index] == ascii else { return false }
            index += 1
            return true
        }
        func number() -> UInt64? {
            var value: UInt64 = 0
            var digits = 0
            while index < data.endIndex, data[index] >= 0x30, data[index] <= 0x39 {
                value = value &* 10 &+ UInt64(data[index] - 0x30)
                index += 1
                digits += 1
            }
            return digits > 0 ? value : nil
        }
        guard expect(UInt8(ascii: "[")), let op = number(), expect(UInt8(ascii: ",")) else { return nil }
        if op == 107 {
            guard expect(UInt8(ascii: "[")), let inner = number(), inner <= 3, expect(UInt8(ascii: ",")) else { return nil }
            return number()
        }
        guard op <= 3 else { return nil }
        return number()
    }
}

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
