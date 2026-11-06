// Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerRejectionTests.swift
//
// A connection the transport rejects (its SessionID is held, #69 join PR 4c) must not reach the
// transport again: its frames and its disconnect are keyed by the ID another connection holds.

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
import Testing
@testable import SwiftStateTreeNIO

private final class RecordingDelegate: TransportDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var events: [String] { lock.withLock { log } }

    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {
        lock.withLock { log.append("connect") }
    }

    func onDisconnect(sessionID: SessionID, clientID: ClientID) async {
        lock.withLock { log.append("disconnect") }
    }

    func onMessage(_ message: Data, from sessionID: SessionID) async {
        lock.withLock { log.append("message:\(String(decoding: message, as: UTF8.self))") }
    }
}

private func makeHandler(_ sessionID: SessionID, transport: WebSocketTransport) throws -> (EmbeddedChannel, WebSocketSessionHandler) {
    let channel = EmbeddedChannel()
    let handler = WebSocketSessionHandler(
        sessionID: sessionID,
        path: "/test",
        transport: transport,
        eventLoop: channel.eventLoop,
        logger: Logger(label: "test")
    )
    try channel.pipeline.syncOperations.addHandler(handler)
    return (channel, handler)
}

private func sendText(_ text: String, on channel: EmbeddedChannel) throws {
    try channel.writeInbound(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: text)))
    channel.embeddedEventLoop.run()
}

@Suite("WebSocketSessionHandler: a rejected connection")
struct WebSocketSessionHandlerRejectionTests {
    @Test("Its frames and its disconnect never reach the transport; the holder stays connected")
    func rejectedConnectionIsInert() async throws {
        let delegate = RecordingDelegate()
        let transport = WebSocketTransport()
        await transport.setDelegate(delegate)
        let id = SessionID("shared")

        let (holder, holderHandler) = try makeHandler(id, transport: transport)
        await holderHandler.waitForInboundIdle()
        #expect(delegate.events == ["connect"])

        let (intruder, intruderHandler) = try makeHandler(id, transport: transport)
        try sendText("from-intruder", on: intruder)
        _ = try? intruder.finish()
        await intruderHandler.waitForInboundIdle()

        #expect(await transport.connectionsRejectedSessionIDInUse == 1)
        #expect(delegate.events == ["connect"], "no message and no disconnect for the holder's ID")
        #expect(await transport.connectionGeneration(for: id) != nil, "the holder is still connected")

        try sendText("from-holder", on: holder)
        _ = try? holder.finish()
        await holderHandler.waitForInboundIdle()
        #expect(delegate.events == ["connect", "message:from-holder", "disconnect"])
    }
}
