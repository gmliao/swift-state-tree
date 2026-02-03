// Tests/SwiftStateTreeNIOTests/WebSocketFragmentReassemblerTests.swift
//
// Unit tests for WebSocket fragment reassembly (RFC 6455).

import Foundation
import NIOCore
import NIOWebSocket
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
        var fragmentBuffer: ByteBuffer? = nil
        let data = [UInt8]("hello".utf8)
        let frame = makeFrame(fin: true, opcode: .binary, data: data)

        let result = WebSocketFragmentReassembler.process(frame: frame, fragmentBuffer: &fragmentBuffer)

        #expect(fragmentBuffer == nil)
        if case .complete(let received) = result {
            #expect(Data(received) == Data(data))
        } else {
            Issue.record("Expected .complete, got \(result)")
        }
    }

    @Test("Single text frame with fin yields complete message")
    func testSingleTextFrame() throws {
        var fragmentBuffer: ByteBuffer? = nil
        let data = [UInt8]("world".utf8)
        let frame = makeFrame(fin: true, opcode: .text, data: data)

        let result = WebSocketFragmentReassembler.process(frame: frame, fragmentBuffer: &fragmentBuffer)

        #expect(fragmentBuffer == nil)
        if case .complete(let received) = result {
            #expect(Data(received) == Data(data))
        } else {
            Issue.record("Expected .complete, got \(result)")
        }
    }

    // MARK: - Fragmented Messages

    @Test("Binary fragment then continuation with fin reassembles")
    func testBinaryFragmentedMessage() throws {
        var fragmentBuffer: ByteBuffer? = nil
        let part1 = [UInt8]("hel".utf8)
        let part2 = [UInt8]("lo".utf8)

        let frame1 = makeFrame(fin: false, opcode: .binary, data: part1)
        let result1 = WebSocketFragmentReassembler.process(frame: frame1, fragmentBuffer: &fragmentBuffer)

        #expect(result1 == .incomplete)
        #expect(fragmentBuffer != nil)

        let frame2 = makeFrame(fin: true, opcode: .continuation, data: part2)
        let result2 = WebSocketFragmentReassembler.process(frame: frame2, fragmentBuffer: &fragmentBuffer)

        #expect(fragmentBuffer == nil)
        if case .complete(let received) = result2 {
            #expect(Data(received) == Data("hello".utf8))
        } else {
            Issue.record("Expected .complete, got \(result2)")
        }
    }

    @Test("Text fragment then continuation with fin reassembles")
    func testTextFragmentedMessage() throws {
        var fragmentBuffer: ByteBuffer? = nil
        let part1 = [UInt8]("foo".utf8)
        let part2 = [UInt8]("bar".utf8)

        let frame1 = makeFrame(fin: false, opcode: .text, data: part1)
        let result1 = WebSocketFragmentReassembler.process(frame: frame1, fragmentBuffer: &fragmentBuffer)

        #expect(result1 == .incomplete)
        #expect(fragmentBuffer != nil)

        let frame2 = makeFrame(fin: true, opcode: .continuation, data: part2)
        let result2 = WebSocketFragmentReassembler.process(frame: frame2, fragmentBuffer: &fragmentBuffer)

        #expect(fragmentBuffer == nil)
        if case .complete(let received) = result2 {
            #expect(Data(received) == Data("foobar".utf8))
        } else {
            Issue.record("Expected .complete, got \(result2)")
        }
    }

    @Test("Three fragments reassemble correctly")
    func testThreeFragments() throws {
        var fragmentBuffer: ByteBuffer? = nil
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
        if case .complete(let received) = result {
            #expect(Data(received) == Data("abc".utf8))
        } else {
            Issue.record("Expected .complete, got \(result)")
        }
    }

    // MARK: - Protocol Errors

    @Test("Continuation without preceding fragment is ignored")
    func testContinuationWithoutPrecedingFragment() throws {
        var fragmentBuffer: ByteBuffer? = nil
        let frame = makeFrame(fin: true, opcode: .continuation, data: [1, 2, 3])

        let result = WebSocketFragmentReassembler.process(frame: frame, fragmentBuffer: &fragmentBuffer)

        #expect(result == .ignored)
        #expect(fragmentBuffer == nil)
    }

    @Test("Binary frame while reassembling resets and yields new message")
    func testBinaryFrameWhileReassembling() throws {
        var fragmentBuffer: ByteBuffer? = nil
        _ = WebSocketFragmentReassembler.process(
            frame: makeFrame(fin: false, opcode: .binary, data: [1, 2, 3]),
            fragmentBuffer: &fragmentBuffer
        )
        #expect(fragmentBuffer != nil)

        let frame = makeFrame(fin: true, opcode: .binary, data: [4, 5, 6])
        let result = WebSocketFragmentReassembler.process(frame: frame, fragmentBuffer: &fragmentBuffer)

        #expect(result == .complete(Data([4, 5, 6])))
        #expect(fragmentBuffer == nil)
    }

    @Test("Text frame while reassembling resets and yields new message")
    func testTextFrameWhileReassembling() throws {
        var fragmentBuffer: ByteBuffer? = nil
        _ = WebSocketFragmentReassembler.process(
            frame: makeFrame(fin: false, opcode: .text, data: [1, 2, 3]),
            fragmentBuffer: &fragmentBuffer
        )

        let frame = makeFrame(fin: true, opcode: .text, data: [7, 8, 9])
        let result = WebSocketFragmentReassembler.process(frame: frame, fragmentBuffer: &fragmentBuffer)

        #expect(result == .complete(Data([7, 8, 9])))
        #expect(fragmentBuffer == nil)
    }

    // MARK: - Max Size

    @Test("Initial fragment exceeding max size returns exceededMaxSize")
    func testInitialFragmentExceedsMaxSize() throws {
        var fragmentBuffer: ByteBuffer? = nil
        let oversized = [UInt8](repeating: 0, count: WebSocketFragmentReassembler.maxFragmentSize + 1)
        let frame = makeFrame(fin: false, opcode: .binary, data: oversized)

        let result = WebSocketFragmentReassembler.process(frame: frame, fragmentBuffer: &fragmentBuffer)

        #expect(result == .exceededMaxSize)
        #expect(fragmentBuffer == nil)
    }

    @Test("Continuation causing total to exceed max size returns exceededMaxSize")
    func testContinuationExceedsMaxSize() throws {
        var fragmentBuffer: ByteBuffer? = nil
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
        var fragmentBuffer: ByteBuffer? = nil
        let data = [UInt8](repeating: 42, count: WebSocketFragmentReassembler.maxFragmentSize)
        let frame = makeFrame(fin: true, opcode: .binary, data: data)

        let result = WebSocketFragmentReassembler.process(frame: frame, fragmentBuffer: &fragmentBuffer)

        if case .complete(let received) = result {
            #expect(received.count == WebSocketFragmentReassembler.maxFragmentSize)
        } else {
            Issue.record("Expected .complete, got \(result)")
        }
    }
}
