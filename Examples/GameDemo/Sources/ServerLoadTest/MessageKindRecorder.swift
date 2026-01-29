// Sources/ServerLoadTest/MessageKindRecorder.swift
//
// Records message kinds for egress (server→client) when running 1 room
// to analyze stateUpdate vs event vs joinResponse breakdown.

import Foundation

/// When rooms == 1, records each outgoing message kind (stateUpdate, event, joinResponse, etc.)
/// by peeking at payload. Used to verify whether server events could be batched with state updates.
actor MessageKindRecorder {
    private var counts: [String: Int] = [:]

    /// Classify wire data and record. Safe to call from any context.
    func record(data: Data) {
        let kind = Self.classify(data)
        counts[kind, default: 0] += 1
    }

    func summary() -> [String: Int] {
        counts
    }

    /// Peek at payload to infer kind. JSON: "kind" or opcode array [0].
    /// MessagePack: fixarray (0x90–0x9f), first element = opcode (0,1,2 = stateUpdate; 103 = event; 105 = joinResponse).
    private static func classify(_ data: Data) -> String {
        guard !data.isEmpty else { return "empty" }
        if data[0] == 0x7b {
            return classifyJSON(data)
        }
        if data.count >= 2, (data[0] & 0xF0) == 0x90 {
            return classifyMessagePackArray(data)
        }
        return "unknown"
    }

    private static func classifyJSON(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return "jsonInvalid" }
        if let dict = json as? [String: Any], let k = dict["kind"] as? String {
            return k
        }
        if let array = json as? [Any], let opcode = array.first as? Int {
            return opcodeToKind(opcode)
        }
        return "jsonOther"
    }

    private static func classifyMessagePackArray(_ data: Data) -> String {
        guard data.count >= 2 else { return "msgpackShort" }
        let firstByte = data[1]
        if firstByte <= 0x7F {
            return opcodeToKind(Int(firstByte))
        }
        return "msgpackOther"
    }

    private static func opcodeToKind(_ opcode: Int) -> String {
        switch opcode {
        case 0, 1, 2: return "stateUpdate"
        case 101: return "action"
        case 102: return "actionResponse"
        case 103: return "event"
        case 104: return "join"
        case 105: return "joinResponse"
        case 106: return "error"
        default: return "opcode\(opcode)"
        }
    }
}
