// Tests/SwiftStateTreeNIOTests/WebSocketFragmentReassemblerTests.swift
//
// Unit tests for WebSocket fragment reassembly (RFC 6455).

import Foundation
import NIOCore
import NIOWebSocket
import SwiftStateTreeTransport
import Testing
@testable import SwiftStateTreeNIO

@Suite("WebSocket Fragment Reassembler Tests")
struct WebSocketFragmentReassemblerTests {

    // MARK: - Helpers

    private func makeFrame(fin: Bool, opcode: WebSocketOpcode, data: [UInt8]) -> WebSocketFrame {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return WebSocketFrame(fin: fin, opcode: opcode, data: buffer)
    }

    // MARK: - Single Frame (No Fragmentation)

    @Test("Single binary frame with fin yields complete message")
    func testSingleBinaryFrame() throws {
        var fragmentBuffer: WebSocketFragmentReassembler.PartialMessage? = nil
        let data = [UInt8]("hello".utf8)
        let frame = makeFrame(fin: true, opcode: .binary, data: data)

        let result = WebSocketFragmentReassembler.process(frame: frame, fragmentBuffer: &fragmentBuffer)

        #expect(fragmentBuffer == nil)
        if case .complete(let received, _) = result {
            #expect(Data(received) == Data(data))
        } else {
            Issue.record("Expected .complete, got \(result)")
        }
    }

    @Test("Single text frame with fin yields complete message")
    func testSingleTextFrame() throws {
        var fragmentBuffer: WebSocketFragmentReassembler.PartialMessage? = nil
        let data = [UInt8]("world".utf8)
        let frame = makeFrame(fin: true, opcode: .text, data: data)

        let result = WebSocketFragmentReassembler.process(frame: frame, fragmentBuffer: &fragmentBuffer)

        #expect(fragmentBuffer == nil)
        if case .complete(let received, _) = result {
            #expect(Data(received) == Data(data))
        } else {
            Issue.record("Expected .complete, got \(result)")
        }
    }

    // MARK: - Fragmented Messages

    @Test("Binary fragment then continuation with fin reassembles")
    func testBinaryFragmentedMessage() throws {
        var fragmentBuffer: WebSocketFragmentReassembler.PartialMessage? = nil
        let part1 = [UInt8]("hel".utf8)
        let part2 = [UInt8]("lo".utf8)

        let frame1 = makeFrame(fin: false, opcode: .binary, data: part1)
        let result1 = WebSocketFragmentReassembler.process(frame: frame1, fragmentBuffer: &fragmentBuffer)

        #expect(result1 == .incomplete)
        #expect(fragmentBuffer != nil)

        let frame2 = makeFrame(fin: true, opcode: .continuation, data: part2)
        let result2 = WebSocketFragmentReassembler.process(frame: frame2, fragmentBuffer: &fragmentBuffer)

        #expect(fragmentBuffer == nil)
        if case .complete(let received, _) = result2 {
            #expect(Data(received) == Data("hello".utf8))
        } else {
            Issue.record("Expected .complete, got \(result2)")
        }
    }

    @Test("Text fragment then continuation with fin reassembles")
    func testTextFragmentedMessage() throws {
        var fragmentBuffer: WebSocketFragmentReassembler.PartialMessage? = nil
        let part1 = [UInt8]("foo".utf8)
        let part2 = [UInt8]("bar".utf8)

        let frame1 = makeFrame(fin: false, opcode: .text, data: part1)
        let result1 = WebSocketFragmentReassembler.process(frame: frame1, fragmentBuffer: &fragmentBuffer)

        #expect(result1 == .incomplete)
        #expect(fragmentBuffer != nil)

        let frame2 = makeFrame(fin: true, opcode: .continuation, data: part2)
        let result2 = WebSocketFragmentReassembler.process(frame: frame2, fragmentBuffer: &fragmentBuffer)

        #expect(fragmentBuffer == nil)
        if case .complete(let received, _) = result2 {
            #expect(Data(received) == Data("foobar".utf8))
        } else {
            Issue.record("Expected .complete, got \(result2)")
        }
    }

    @Test("Three fragments reassemble correctly")
    func testThreeFragments() throws {
        var fragmentBuffer: WebSocketFragmentReassembler.PartialMessage? = nil
        let part1 = [UInt8]("a".utf8)
        let part2 = [UInt8]("b".utf8)
        let part3 = [UInt8]("c".utf8)

        _ = WebSocketFragmentReassembler.process(
            frame: makeFrame(fin: false, opcode: .binary, data: part1),
            fragmentBuffer: &fragmentBuffer
        )
        #expect(fragmentBuffer != nil)

        _ = WebSocketFragmentReassembler.process(
            frame: makeFrame(fin: false, opcode: .continuation, data: part2),
            fragmentBuffer: &fragmentBuffer
        )
        #expect(fragmentBuffer != nil)

        let result = WebSocketFragmentReassembler.process(
            frame: makeFrame(fin: true, opcode: .continuation, data: part3),
            fragmentBuffer: &fragmentBuffer
        )

        #expect(fragmentBuffer == nil)
        if case .complete(let received, _) = result {
            #expect(Data(received) == Data("abc".utf8))
        } else {
            Issue.record("Expected .complete, got \(result)")
        }
    }

    // MARK: - Bad fragment sequences (RFC 6455 §5.4, #822)

    @Test("A continuation with nothing to continue is a bad fragment sequence", arguments: [true, false])
    func orphanContinuationIsRefused(fin: Bool) {
        var fragmentBuffer: WebSocketFragmentReassembler.PartialMessage? = nil
        let frame = makeFrame(fin: fin, opcode: .continuation, data: [1, 2, 3])

        let result = WebSocketFragmentReassembler.process(frame: frame, fragmentBuffer: &fragmentBuffer)

        #expect(result == .badFragmentSequence)
        #expect(fragmentBuffer == nil)
    }

    @Test("A continuation after a finished message is a bad fragment sequence")
    func continuationAfterFinishedMessageIsRefused() {
        var fragmentBuffer: WebSocketFragmentReassembler.PartialMessage? = nil
        _ = WebSocketFragmentReassembler.process(frame: makeFrame(fin: false, opcode: .binary, data: [1]), fragmentBuffer: &fragmentBuffer)
        let finished = WebSocketFragmentReassembler.process(frame: makeFrame(fin: true, opcode: .continuation, data: [2]), fragmentBuffer: &fragmentBuffer)
        #expect(finished == .complete(Data([1, 2]), .binary))

        let orphan = WebSocketFragmentReassembler.process(frame: makeFrame(fin: true, opcode: .continuation, data: [3]), fragmentBuffer: &fragmentBuffer)

        #expect(orphan == .badFragmentSequence)
        #expect(fragmentBuffer == nil)
    }

    @Test(
        "A text or binary opener while a message is unfinished is a bad fragment sequence",
        arguments: [WebSocketOpcode.text, .binary], [true, false]
    )
    func openerMidMessageIsRefused(opener: WebSocketOpcode, fin: Bool) {
        for first in [WebSocketOpcode.text, .binary] {
            var fragmentBuffer: WebSocketFragmentReassembler.PartialMessage? = nil
            let started = WebSocketFragmentReassembler.process(frame: makeFrame(fin: false, opcode: first, data: Array("ab".utf8)), fragmentBuffer: &fragmentBuffer)
            #expect(started == .incomplete)

            let result = WebSocketFragmentReassembler.process(frame: makeFrame(fin: fin, opcode: opener, data: Array("cd".utf8)), fragmentBuffer: &fragmentBuffer)

            #expect(result == .badFragmentSequence, "\(first) then \(opener) fin=\(fin)")
            #expect(fragmentBuffer == nil, "the unfinished message is dropped")
        }
    }

    // MARK: - Max Size

    @Test("Initial fragment exceeding max size returns exceededMaxSize")
    func testInitialFragmentExceedsMaxSize() throws {
        var fragmentBuffer: WebSocketFragmentReassembler.PartialMessage? = nil
        let oversized = [UInt8](repeating: 0, count: WebSocketFragmentReassembler.maxFragmentSize + 1)
        let frame = makeFrame(fin: false, opcode: .binary, data: oversized)

        let result = WebSocketFragmentReassembler.process(frame: frame, fragmentBuffer: &fragmentBuffer)

        #expect(result == .exceededMaxSize)
        #expect(fragmentBuffer == nil)
    }

    @Test("Continuation causing total to exceed max size returns exceededMaxSize")
    func testContinuationExceedsMaxSize() throws {
        var fragmentBuffer: WebSocketFragmentReassembler.PartialMessage? = nil
        let part1 = [UInt8](repeating: 0, count: WebSocketFragmentReassembler.maxFragmentSize - 10)
        let part2 = [UInt8](repeating: 0, count: 20)  // total would exceed

        _ = WebSocketFragmentReassembler.process(
            frame: makeFrame(fin: false, opcode: .binary, data: part1),
            fragmentBuffer: &fragmentBuffer
        )

        let result = WebSocketFragmentReassembler.process(
            frame: makeFrame(fin: true, opcode: .continuation, data: part2),
            fragmentBuffer: &fragmentBuffer
        )

        #expect(result == .exceededMaxSize)
        #expect(fragmentBuffer == nil)
    }

    @Test("Fragment at exactly max size is accepted")
    func testFragmentAtMaxSize() throws {
        var fragmentBuffer: WebSocketFragmentReassembler.PartialMessage? = nil
        let data = [UInt8](repeating: 42, count: WebSocketFragmentReassembler.maxFragmentSize)
        let frame = makeFrame(fin: true, opcode: .binary, data: data)

        let result = WebSocketFragmentReassembler.process(frame: frame, fragmentBuffer: &fragmentBuffer)

        if case .complete(let received, _) = result {
            #expect(received.count == WebSocketFragmentReassembler.maxFragmentSize)
        } else {
            Issue.record("Expected .complete, got \(result)")
        }
    }

    // MARK: - Frame type and UTF-8 (#813)

    @Test("A message keeps its first frame's type: text through continuations, binary as binary")
    func messageKeepsItsFrameType() {
        var partial: WebSocketFragmentReassembler.PartialMessage? = nil
        _ = WebSocketFragmentReassembler.process(frame: makeFrame(fin: false, opcode: .text, data: Array("ab".utf8)), fragmentBuffer: &partial)
        let text = WebSocketFragmentReassembler.process(frame: makeFrame(fin: true, opcode: .continuation, data: Array("cd".utf8)), fragmentBuffer: &partial)
        #expect(text == .complete(Data("abcd".utf8), .text))
        let binary = WebSocketFragmentReassembler.process(frame: makeFrame(fin: true, opcode: .binary, data: [0xFF, 0xFE]), fragmentBuffer: &partial)
        #expect(binary == .complete(Data([0xFF, 0xFE]), .binary), "a binary message isn't checked for UTF-8")
    }

    @Test("A text message that isn't UTF-8 is refused, unfragmented and fragmented")
    func invalidUTF8IsRefused() {
        var partial: WebSocketFragmentReassembler.PartialMessage? = nil
        let single = WebSocketFragmentReassembler.process(frame: makeFrame(fin: true, opcode: .text, data: [0x68, 0xC0, 0xAF]), fragmentBuffer: &partial)
        #expect(single == .invalidUTF8, "an overlong form")
        _ = WebSocketFragmentReassembler.process(frame: makeFrame(fin: false, opcode: .text, data: Array("ok".utf8)), fragmentBuffer: &partial)
        let fragmented = WebSocketFragmentReassembler.process(frame: makeFrame(fin: true, opcode: .continuation, data: [0xED, 0xA0, 0x80]), fragmentBuffer: &partial)
        #expect(fragmented == .invalidUTF8, "a surrogate in the last fragment")
        #expect(partial == nil)
        let truncated = WebSocketFragmentReassembler.process(frame: makeFrame(fin: true, opcode: .text, data: [0x61, 0xE2, 0x82]), fragmentBuffer: &partial)
        #expect(truncated == .invalidUTF8, "a sequence cut off at the message's end")
    }

    @Test("A valid sequence split across a fragment boundary is accepted")
    func splitSequenceIsValid() {
        var partial: WebSocketFragmentReassembler.PartialMessage? = nil
        // U+20AC (EURO SIGN) is E2 82 AC: the first fragment ends inside it.
        let first = WebSocketFragmentReassembler.process(frame: makeFrame(fin: false, opcode: .text, data: [0x61, 0xE2]), fragmentBuffer: &partial)
        #expect(first == .incomplete)
        let middle = WebSocketFragmentReassembler.process(frame: makeFrame(fin: false, opcode: .continuation, data: [0x82]), fragmentBuffer: &partial)
        #expect(middle == .incomplete)
        let last = WebSocketFragmentReassembler.process(frame: makeFrame(fin: true, opcode: .continuation, data: [0xAC, 0x62]), fragmentBuffer: &partial)
        #expect(last == .complete(Data("a\u{20AC}b".utf8), .text))
    }
}
