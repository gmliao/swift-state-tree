// Sources/SwiftStateTreeNIO/NIOWebSocketConnection.swift
//
// WebSocketConnection implementation for NIO.

import Foundation
import NIOCore
import NIOWebSocket
import SwiftStateTreeTransport

/// WebSocketConnection implementation using SwiftNIO channels.
///
/// This provides a bridge between the Transport layer's `WebSocketConnection`
/// protocol and NIO's channel-based WebSocket handling.
public struct NIOWebSocketConnection: WebSocketConnection, ClosedAwaitingConnection, @unchecked Sendable {
    private let channel: Channel
    private weak var handler: WebSocketSessionHandler?

    init(channel: Channel, handler: WebSocketSessionHandler) {
        self.channel = channel
        self.handler = handler
    }

    public func send(_ data: Data) async throws {
        guard let handler = handler else {
            throw NIOWebSocketError.connectionClosed
        }

        // Convert Data to ByteBuffer
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        // Send via handler (which ensures we're on the right event loop)
        handler.send(buffer)
    }

    public func close() async throws {
        handler?.close()
    }

    public func close(with close: SessionClose) async throws {
        handler?.close(
            code: WebSocketErrorCode(codeNumber: Int(close.code)),
            reason: close.reason,
            grace: close.closeGrace.map(TimeAmount.init)
        )
    }

    /// Returns once the channel has closed.
    package func closed() async {
        try? await channel.closeFuture.get()
    }
}

// MARK: - Errors

/// Errors that can occur in NIO WebSocket operations.
public enum NIOWebSocketError: Error, Sendable {
    /// The connection has been closed.
    case connectionClosed
    /// Failed to write to the channel.
    case writeFailed
}
