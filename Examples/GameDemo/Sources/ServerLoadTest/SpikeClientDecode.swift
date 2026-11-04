// Spike only (client-cost measurement, never merged): an env-gated client model for ServerLoadTest.
//
// LOADTEST_CLIENT_DECODE=1: every frame a client receives is fully decoded as the TS SDK does for
// messagepack (unpack, opcode dispatch, 107 split, PathHash -> path with dynamic-key slots, patch
// ops) and applied to a flat per-session path -> value map. Records "clientDecode" (µs per frame)
// and "clientRTT" (action -> actionResponse).
// Always (A and B): "clientUpdateInterval" per session for state frames (opcodes 0/1/2/107),
// detected from the frame header without decoding.

import Foundation
import SwiftStateTree
import SwiftStateTreeMessagePack

enum SpikeClientModel {
    static let decodeEnabled = ProcessInfo.processInfo.environment["LOADTEST_CLIENT_DECODE"] == "1"
    static let sendActions = ProcessInfo.processInfo.environment["LOADTEST_SEND"] == "action"
    nonisolated(unsafe) static var reversePathHashes: [UInt32: String] = [:]

    final class SessionState: @unchecked Sendable {
        var lastUpdate: ContinuousClock.Instant?
        var broadcastKeys: [Int: String] = [:]
        var perPlayerKeys: [Int: String] = [:]
        var state: [String: MessagePackValue] = [:]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: SessionState] = [:]
    nonisolated(unsafe) private static var pending: [String: ContinuousClock.Instant] = [:]

    static func session(_ id: String) -> SessionState {
        lock.lock(); defer { lock.unlock() }
        if let s = sessions[id] { return s }
        let s = SessionState(); sessions[id] = s; return s
    }

    static func noteSent(requestID: String) {
        lock.lock(); pending[requestID] = ContinuousClock.now; lock.unlock()
    }

    private static func noteResponse(requestID: String) {
        lock.lock(); let sent = pending.removeValue(forKey: requestID); lock.unlock()
        if let sent { SpikeMetrics.record("clientRTT", duration: ContinuousClock.now - sent) }
    }

    /// Opcode of a messagepack array frame from its header, without decoding.
    static func peekOpcode(_ data: Data) -> Int? {
        guard let b0 = data.first else { return nil }
        var i = data.startIndex
        switch b0 {
        case 0x90...0x9f: i += 1
        case 0xdc: i += 3
        case 0xdd: i += 5
        default: return nil
        }
        guard i < data.endIndex else { return nil }
        let b = data[i]
        if b < 0x80 { return Int(b) }
        if b == 0xcc, i + 1 < data.endIndex { return Int(data[i + 1]) }
        return nil
    }

    /// Called for every frame the server sends to `sessionID` (same task as the transport send).
    static func received(_ data: Data, sessionID: String) {
        let s = session(sessionID)
        if let op = peekOpcode(data), op <= 2 || op == 107 {
            let now = ContinuousClock.now
            if let last = s.lastUpdate { SpikeMetrics.record("clientUpdateInterval", duration: now - last) }
            s.lastUpdate = now
        }
        guard decodeEnabled else { return }
        let start = SpikeMetrics.now()
        defer { SpikeMetrics.record("clientDecode", since: start) }
        guard let value = try? unpack(data), case .array(let items) = value, let op = items.first?.intValue else { return }
        switch op {
        case 107:
            guard items.count >= 3, case .array(let statePayload) = items[1] else { return }
            apply(statePayload, keys: \.broadcastKeys, session: s)
            if case .array(let events) = items[2] {
                for case .array(let e) in events { _ = e.count >= 2 ? e[1].stringValue : nil }
            }
        case 0, 1, 2:
            apply(items, keys: \.perPlayerKeys, session: s)
        case 102:
            // actionResponse: [102, requestID, response]
            if items.count >= 2, let rid = items[1].stringValue { noteResponse(requestID: rid) }
        default:
            break
        }
    }

    private static func apply(
        _ payload: [MessagePackValue],
        keys: ReferenceWritableKeyPath<SessionState, [Int: String]>,
        session s: SessionState
    ) {
        guard let op = payload.first?.intValue else { return }
        if op == 1 { s[keyPath: keys].removeAll(); s.state.removeAll() }
        for entry in payload.dropFirst() {
            guard case .array(let e) = entry, e.count >= 3, let hash = e[0].intValue else { continue }
            var dynamicKeys: [String] = []
            func resolve(_ raw: MessagePackValue) -> String? {
                switch raw {
                case .nil: return nil
                case .string(let k): return k
                case .int, .uint:
                    return s[keyPath: keys][raw.intValue ?? -1] ?? String(raw.intValue ?? -1)
                case .array(let pair) where pair.count == 2:
                    if let slot = pair[0].intValue, let k = pair[1].stringValue {
                        s[keyPath: keys][slot] = k; return k
                    }
                    return nil
                default: return nil
                }
            }
            if case .array(let raw) = e[1], !(raw.count == 2 && raw[0].intValue != nil && raw[1].stringValue != nil) {
                dynamicKeys = raw.compactMap(resolve)
            } else if let k = resolve(e[1]) {
                dynamicKeys = [k]
            }
            guard let pattern = reversePathHashes[UInt32(truncatingIfNeeded: hash)] else { continue }
            var it = dynamicKeys.makeIterator()
            let path = "/" + pattern.split(separator: ".", omittingEmptySubsequences: false)
                .map { $0 == "*" ? (it.next() ?? "*") : String($0) }
                .joined(separator: "/")
            switch e[2].intValue {
            case 2?: s.state.removeValue(forKey: path)  // remove
            default: s.state[path] = e.count > 3 ? e[3] : .nil
            }
        }
    }
}

extension MessagePackValue {
    var intValue: Int? {
        switch self {
        case .int(let v): return Int(v)
        case .uint(let v): return Int(v)
        default: return nil
        }
    }
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
