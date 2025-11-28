import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTreeTransport
import SwiftStateTree
import NIOCore
import NIOFoundationCompat

/// Adapter to use Hummingbird WebSockets with SwiftStateTreeTransport.
public struct HummingbirdStateTreeAdapter: Sendable {
    /// The transport instance managing the state tree connections.
    public let transport: WebSocketTransport
    
    public init(transport: WebSocketTransport) {
        self.transport = transport
    }
    
    /// Handler for Hummingbird WebSocket connection.
    ///
    /// Usage:
    /// ```swift
    /// let adapter = HummingbirdStateTreeAdapter(transport: myTransport)
    /// router.ws("/ws") { inbound, outbound, context in
    ///     await adapter.handle(inbound: inbound, outbound: outbound, context: context)
    /// }
    /// ```
    public func handle(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        context: some WebSocketContext
    ) async {
        // Generate a session ID (in a real app, this might come from auth headers or handshake)
        let sessionID = SessionID(UUID().uuidString)
        
        // Create connection wrapper
        let connection = HummingbirdWebSocketConnection(outbound: outbound)
        
        // Register connection
        await transport.handleConnection(sessionID: sessionID, connection: connection)
        
        // Handle incoming messages
        do {
            for try await message in inbound.messages(maxSize: .max) {
                switch message {
                case .text(let text):
                    if let data = text.data(using: .utf8) {
                        await transport.handleIncomingMessage(sessionID: sessionID, data: data)
                    }
                case .binary(let buffer):
                    var mutableBuffer = buffer
                    if let data = mutableBuffer.readData(length: mutableBuffer.readableBytes) {
                        await transport.handleIncomingMessage(sessionID: sessionID, data: data)
                    }
                }
            }
        } catch {
            // Connection error
        }
        
        // Handle disconnection
        await transport.handleDisconnection(sessionID: sessionID)
    }
}

/// Concrete implementation of WebSocketConnection for Hummingbird.
public struct HummingbirdWebSocketConnection: WebSocketConnection {
    let outbound: WebSocketOutboundWriter
    
    public func send(_ data: Data) async throws {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await outbound.write(.binary(buffer))
    }
    
    public func close() async throws {
        try await outbound.close(.normalClosure, reason: nil)
    }
}
