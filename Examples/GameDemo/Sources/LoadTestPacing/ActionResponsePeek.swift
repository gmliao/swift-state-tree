// Examples/GameDemo/Sources/LoadTestPacing/ActionResponsePeek.swift
//
// Tells an action response from other server frames by its first bytes, without decoding it.
// EncodingBenchmark counts the replies the tickless visibility land sends with it
// (`--game-type visibility-test-tickless`).

import Foundation

/// Whether a server frame is an action response (opcode 102, `MessageKindOpcode.actionResponse`):
/// `[102, …]` in MessagePack or JSON, or the JSON object encoding's `"kind":"actionResponse"`.
/// The JSON object form is searched only in frames up to `jsonObjectMaxBytes` (a response is a
/// few hundred bytes, and state frames have no `kind` key), so large state frames cost one
/// comparison. An ACK of a tick land is an action response too.
public enum ActionResponsePeek {
    /// `MessageKindOpcode.actionResponse` (in the transport module, which this library doesn't
    /// import; the tests pin the two equal).
    public static let actionResponseOpcode: UInt8 = 102
    public static let jsonObjectMaxBytes = 4096

    private static let jsonKind = Array(#""kind":"actionResponse""#.utf8)
    private static let jsonArrayPrefix = Array("[\(actionResponseOpcode)".utf8)

    public static func isActionResponse(_ frame: Data) -> Bool {
        guard let first = frame.first else { return false }
        let start = frame.startIndex
        switch first {
        case 0x90 ... 0x9f:  // MessagePack fixarray: the opcode is the next byte (a positive fixint)
            return frame.count > 1 && frame[start + 1] == actionResponseOpcode
        case 0xdc:  // MessagePack array 16
            return frame.count > 3 && frame[start + 3] == actionResponseOpcode
        case 0xdd:  // MessagePack array 32
            return frame.count > 5 && frame[start + 5] == actionResponseOpcode
        case UInt8(ascii: "["):
            guard frame.count > jsonArrayPrefix.count, frame.starts(with: jsonArrayPrefix) else { return false }
            let next = frame[start + jsonArrayPrefix.count]
            return next == UInt8(ascii: ",") || next == UInt8(ascii: "]") || next == UInt8(ascii: " ")
        case UInt8(ascii: "{"):
            return frame.count <= jsonObjectMaxBytes && frame.firstRange(of: jsonKind) != nil
        default:
            return false
        }
    }
}
