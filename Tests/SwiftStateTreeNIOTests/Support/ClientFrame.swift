// Tests/SwiftStateTreeNIOTests/Support/ClientFrame.swift
// A WebSocket frame as a client sends it, for tests that feed frames to the session handler.

import NIOCore
import NIOWebSocket

extension WebSocketFrame {
    /// A frame as a client sends it: masked (RFC 6455 §5.1) with a fixed non-zero key, the payload
    /// stored masked, so `unmaskedData` gives `data` back.
    ///
    /// Use it for every frame fed to the handler. A test that means to send an unmasked frame
    /// builds it with `WebSocketFrame(fin:opcode:data:)` and says so.
    static func client(
        fin: Bool = true,
        rsv1: Bool = false,
        rsv2: Bool = false,
        rsv3: Bool = false,
        opcode: WebSocketOpcode,
        data: ByteBuffer
    ) -> WebSocketFrame {
        let key = WebSocketMaskingKey([0x37, 0xfa, 0x21, 0x3d])!
        var masked = data
        masked.webSocketMask(key)
        return WebSocketFrame(
            fin: fin, rsv1: rsv1, rsv2: rsv2, rsv3: rsv3, opcode: opcode, maskKey: key, data: masked)
    }
}
