// Examples/GameDemo/Sources/LoadTestPacing/ErrorFramePeek.swift
//
// Tells an error message from other server frames by its first bytes, without decoding it.
// EncodingBenchmark counts the inputs the server refused with it (`--inputs-from-wire`).

import Foundation

/// Whether a server frame is an error message (opcode 106, `MessageKindOpcode.error`): `[106, …]`
/// in MessagePack or JSON, or the JSON object encoding's `"kind":"error"`. The JSON object form is
/// searched only in frames up to `jsonObjectMaxBytes` (an error frame is a few hundred bytes, and
/// state frames have no `kind` key), so large state frames cost one comparison.
public enum ErrorFramePeek {
    /// `MessageKindOpcode.error` (in the transport module, which this library doesn't import;
    /// the tests pin the two equal).
    public static let errorOpcode: UInt8 = 106
    public static let jsonObjectMaxBytes = 4096

    private static let jsonKind = Array(#""kind":"error""#.utf8)
    private static let jsonArrayPrefix = Array("[\(errorOpcode)".utf8)

    public static func isError(_ frame: Data) -> Bool {
        guard let first = frame.first else { return false }
        let start = frame.startIndex
        switch first {
        case 0x90 ... 0x9f:  // MessagePack fixarray: the opcode is the next byte (a positive fixint)
            return frame.count > 1 && frame[start + 1] == errorOpcode
        case 0xdc:  // MessagePack array 16
            return frame.count > 3 && frame[start + 3] == errorOpcode
        case 0xdd:  // MessagePack array 32
            return frame.count > 5 && frame[start + 5] == errorOpcode
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
