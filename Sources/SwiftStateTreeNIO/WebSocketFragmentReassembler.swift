// Sources/SwiftStateTreeNIO/WebSocketFragmentReassembler.swift
//
// Reassembles fragmented WebSocket messages (RFC 6455).

import Foundation
import NIOCore
import NIOWebSocket
import SwiftStateTreeTransport

/// Reassembles WebSocket frames into complete messages.
///
/// Handles fragmented messages where the client sends:
/// - First frame: binary/text with fin=false
/// - Continuation frames: opcode .continuation, fin=false until last
/// - Last frame: opcode .continuation with fin=true
///
/// Single-frame messages (fin=true) are passed through immediately.
enum WebSocketFragmentReassembler {
    /// Maximum total size for a reassembled fragmented message (prevents memory exhaustion)
    static let maxFragmentSize = 1 << 20  // 1 MiB

    /// A fragmented message being reassembled: the bytes so far, and the type its first frame
    /// gave it (continuation frames carry none).
    struct PartialMessage {
        var bytes: ByteBuffer
        let kind: WebSocketFrameKind
    }

    /// Result of processing a frame
    enum ProcessResult: Sendable, Equatable {
        /// Complete message ready (single frame or reassembled fragments), with its frame type.
        /// A text message's bytes are valid UTF-8.
        case complete(Data, WebSocketFrameKind)
        /// Frame consumed, waiting for more fragments
        case incomplete
        /// Frame ignored (e.g. continuation without preceding fragment, or protocol error)
        case ignored
        /// Fragment exceeded max size, buffer reset
        case exceededMaxSize
        /// A text message whose bytes aren't valid UTF-8: the connection fails with 1007
        /// (RFC 6455 §8.1). Checked once the message is complete, so a sequence split across
        /// two fragments is valid.
        case invalidUTF8
    }

    /// Process a WebSocket frame and return a complete message if available.
    ///
    /// - Parameters:
    ///   - frame: The WebSocket frame to process
    ///   - fragmentBuffer: In-out state of a fragmented message being reassembled (caller must
    ///     persist)
    /// - Returns: Process result
    static func process(
        frame: WebSocketFrame,
        fragmentBuffer: inout PartialMessage?
    ) -> ProcessResult {
        switch frame.opcode {
        case .binary, .text:
            if fragmentBuffer != nil {
                fragmentBuffer = nil
            }
            let kind: WebSocketFrameKind = frame.opcode == .text ? .text : .binary
            if frame.fin {
                return complete(frame.unmaskedData, kind: kind)
            } else {
                return startFragment(from: frame.unmaskedData, kind: kind, into: &fragmentBuffer)
            }

        case .continuation:
            guard var partial = fragmentBuffer else {
                return .ignored
            }
            var frameData = frame.unmaskedData
            let newSize = partial.bytes.readableBytes + frameData.readableBytes
            guard newSize <= maxFragmentSize else {
                fragmentBuffer = nil
                return .exceededMaxSize
            }
            partial.bytes.writeBuffer(&frameData)
            fragmentBuffer = partial

            if frame.fin {
                fragmentBuffer = nil
                return complete(partial.bytes, kind: partial.kind)
            }
            return .incomplete

        default:
            return .ignored
        }
    }

    /// The complete message in `buffer`, or `.invalidUTF8` for a text message that isn't UTF-8.
    private static func complete(_ buffer: ByteBuffer, kind: WebSocketFrameKind) -> ProcessResult {
        var buf = buffer
        guard let bytes = buf.readBytes(length: buf.readableBytes) else {
            return .ignored
        }
        if kind == .text, !isValidUTF8(bytes) {
            return .invalidUTF8
        }
        return .complete(Data(bytes), kind)
    }

    /// Whether `bytes` are well-formed UTF-8: the standard library's strict decoder, which
    /// refuses overlong forms, surrogates and code points past U+10FFFF.
    static func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    private static func startFragment(
        from frameData: ByteBuffer,
        kind: WebSocketFrameKind,
        into buffer: inout PartialMessage?
    ) -> ProcessResult {
        guard frameData.readableBytes <= maxFragmentSize else {
            return .exceededMaxSize
        }
        buffer = PartialMessage(bytes: frameData, kind: kind)
        return .incomplete
    }
}
