// Sources/SwiftStateTreeNIO/WebSocketFragmentReassembler.swift
//
// Reassembles fragmented WebSocket messages (RFC 6455).

import Foundation
import NIOCore
import NIOWebSocket

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

    /// Result of processing a frame
    enum ProcessResult: Sendable, Equatable {
        /// Complete message ready (single frame or reassembled fragments)
        case complete(Data)
        /// Frame consumed, waiting for more fragments
        case incomplete
        /// Frame ignored (e.g. continuation without preceding fragment, or protocol error)
        case ignored
        /// Fragment exceeded max size, buffer reset
        case exceededMaxSize
    }

    /// Process a WebSocket frame and return a complete message if available.
    ///
    /// - Parameters:
    ///   - frame: The WebSocket frame to process
    ///   - fragmentBuffer: In-out buffer for accumulating fragments (caller must persist)
    /// - Returns: Process result
    static func process(
        frame: WebSocketFrame,
        fragmentBuffer: inout ByteBuffer?
    ) -> ProcessResult {
        switch frame.opcode {
        case .binary, .text:
            if fragmentBuffer != nil {
                fragmentBuffer = nil
            }
            if frame.fin {
                return extractData(from: frame.unmaskedData)
            } else {
                return startFragment(from: frame.unmaskedData, into: &fragmentBuffer)
            }

        case .continuation:
            guard var buffer = fragmentBuffer else {
                return .ignored
            }
            var frameData = frame.unmaskedData
            let newSize = buffer.readableBytes + frameData.readableBytes
            guard newSize <= maxFragmentSize else {
                fragmentBuffer = nil
                return .exceededMaxSize
            }
            buffer.writeBuffer(&frameData)
            fragmentBuffer = buffer

            if frame.fin {
                fragmentBuffer = nil
                guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
                    return .ignored
                }
                return .complete(Data(bytes))
            }
            return .incomplete

        default:
            return .ignored
        }
    }

    private static func extractData(from buffer: ByteBuffer) -> ProcessResult {
        var buf = buffer
        guard let bytes = buf.readBytes(length: buf.readableBytes) else {
            return .ignored
        }
        return .complete(Data(bytes))
    }

    private static func startFragment(from frameData: ByteBuffer, into buffer: inout ByteBuffer?) -> ProcessResult {
        guard frameData.readableBytes <= maxFragmentSize else {
            return .exceededMaxSize
        }
        buffer = frameData
        return .incomplete
    }
}
