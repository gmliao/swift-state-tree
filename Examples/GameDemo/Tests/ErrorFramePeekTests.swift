import Foundation
import LoadTestPacing
import SwiftStateTree
import SwiftStateTreeTransport
import Testing

/// `ErrorFramePeek`: EncodingBenchmark's count of refused inputs (`--inputs-from-wire`) reads it
/// on every frame a room sends, so it must find every error frame the server's encoders write and
/// nothing else.
@Suite("Error frame peek")
struct ErrorFramePeekTests {
    @Test("The opcode is MessageKindOpcode.error")
    func opcode() {
        #expect(Int(ErrorFramePeek.errorOpcode) == MessageKindOpcode.error.rawValue)
    }

    @Test("An error message from each message encoding is found")
    func errorFrames() throws {
        let error = TransportMessage.error(ErrorPayload(code: "INVALID_ACTION", message: "the payload doesn't decode"))
        for message in [TransportEncoding.json, .opcodeJsonArray, .messagepack] {
            let config = TransportEncodingConfig(message: message, stateUpdate: .opcodeMessagePack)
            let frame = try config.makeMessageEncoder().encode(error)
            #expect(ErrorFramePeek.isError(frame), "\(message): \(frame.prefix(16).map { String($0) })")
        }
    }

    @Test("Other frames aren't errors")
    func otherFrames() {
        // State updates: `[op, seq, ...]` in JSON and MessagePack (fixarray of 3: op 2, seq 5, []).
        #expect(!ErrorFramePeek.isError(Data("[2,5,[]]".utf8)))
        #expect(!ErrorFramePeek.isError(Data([0x93, 0x02, 0x05, 0x90])))
        // Another message kind, and an opcode that only starts with 106.
        #expect(!ErrorFramePeek.isError(Data("[102,\"r1\",{}]".utf8)))
        #expect(!ErrorFramePeek.isError(Data("[1060,1]".utf8)))
        #expect(!ErrorFramePeek.isError(Data([0x92, 0x66, 0x01])))  // [102, 1]
        // JSON objects: another kind, and a frame over the bound, which isn't searched.
        #expect(!ErrorFramePeek.isError(Data(#"{"kind":"actionResponse","payload":{}}"#.utf8)))
        let large = #"{"patches":[""# + String(repeating: "x", count: ErrorFramePeek.jsonObjectMaxBytes) + #""],"kind":"error"}"#
        #expect(!ErrorFramePeek.isError(Data(large.utf8)))
        #expect(ErrorFramePeek.isError(Data(#"{"payload":{},"kind":"error"}"#.utf8)))
        #expect(!ErrorFramePeek.isError(Data()))
    }
}
