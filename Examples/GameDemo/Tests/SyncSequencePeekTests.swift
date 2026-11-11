import Foundation
import Testing
import LoadTestPacing

/// `SyncSequencePeek`: a state-update frame's op and sync sequence from its first bytes, in the
/// forms the server writes (JSON and MessagePack arrays, opcode 107's merged frame, the JSON object).
@Suite("Sync sequence peek")
struct SyncSequencePeekTests {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    @Test("JSON arrays: op and seq of a state update, 107's inner op, nothing for a message")
    func jsonArrays() {
        #expect(SyncSequencePeek.stateOp(json("[1,7,[]]")) == 1)
        #expect(SyncSequencePeek.seq(json("[1,7,[]]")) == 7)
        #expect(SyncSequencePeek.stateOp(json("[2,8,[]]")) == 2)
        #expect(SyncSequencePeek.stateOp(json("[107,[3,9,[]],[]]")) == 3)
        #expect(SyncSequencePeek.seq(json("[107,[3,9,[]],[]]")) == 9)
        // A transport message (opcodes from 100), and 107 wrapping one: neither is a state update.
        #expect(SyncSequencePeek.stateOp(json("[105,\"join-1\",true]")) == nil)
        #expect(SyncSequencePeek.stateOp(json("[107,[105,1],[]]")) == nil)
        #expect(SyncSequencePeek.seq(json("[105,\"join-1\",true]")) == nil)
    }

    @Test("MessagePack arrays: fixarray and array16 headers, one-byte and wider integers")
    func messagePackArrays() {
        // [1, 7, []]
        #expect(SyncSequencePeek.stateOp(Data([0x93, 0x01, 0x07, 0x90])) == 1)
        #expect(SyncSequencePeek.seq(Data([0x93, 0x01, 0x07, 0x90])) == 7)
        // [2, 300, []] with seq as uint16
        #expect(SyncSequencePeek.stateOp(Data([0x93, 0x02, 0xCD, 0x01, 0x2C, 0x90])) == 2)
        #expect(SyncSequencePeek.seq(Data([0x93, 0x02, 0xCD, 0x01, 0x2C, 0x90])) == 300)
        // [107, [1, 5, []], []] under an array16 header
        let merged = Data([0xDC, 0x00, 0x02, 0x6B, 0x93, 0x01, 0x05, 0x90, 0x90])
        #expect(SyncSequencePeek.stateOp(merged) == 1)
        #expect(SyncSequencePeek.seq(merged) == 5)
        // [105, …]: a transport message.
        #expect(SyncSequencePeek.stateOp(Data([0x92, 0x69, 0xC3])) == nil)
        // Not an array at all.
        #expect(SyncSequencePeek.stateOp(Data([0x81, 0xA1, 0x61, 0x01])) == nil)
    }

    @Test("The JSON object encoding has a seq but no op; an empty frame has neither")
    func objectsAndEmpty() {
        let object = json(#"{"type":"firstSync","seq":4,"patches":[{"seq":99}]}"#)
        #expect(SyncSequencePeek.seq(object) == 4)
        #expect(SyncSequencePeek.stateOp(object) == nil)
        #expect(SyncSequencePeek.stateOp(Data()) == nil)
        #expect(SyncSequencePeek.seq(Data()) == nil)
    }
}
