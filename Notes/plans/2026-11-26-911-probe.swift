// P-911-2 (#911 plan): a probe, kept with the plan; not in the test tree. Two closes for one session, on #913's head.
// (a) The supersede's ordered 4017 is pending behind a held frame, then sendFinalFrameAndClose
//     on the now-ended session. (b) sendFinalFrameAndClose's ordered 1000 is pending behind a
//     held frame, then the supersede.
import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeTestSupport
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

private actor ProbeConnection: WebSocketConnection {
    private(set) var events: [String] = []
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    let attempted = TestGate()
    let closedSignal = TestGate()
    init() { attempted.open(); closedSignal.open() }
    func holdSends() { holding = true }
    func releaseSends() { holding = false; let r = held; held = []; r.forEach { $0.resume() } }
    func send(_ data: Data, kind: WebSocketFrameKind) async throws {
        await attempted.arrive()
        if holding { await withCheckedContinuation { held.append($0) } }
        events.append("sent \(String(decoding: data, as: UTF8.self).prefix(24))")
    }
    func close() async throws { events.append("closed 1000 (plain)"); await closedSignal.arrive() }
    func close(with close: SessionClose) async throws { events.append("closed \(close.code)"); await closedSignal.arrive() }
}

@Suite("PROBE 911", .timeLimit(.minutes(1)))
struct Probe911Tests {
    @Test("PROBE 911", arguments: ["a", "b"])
    func probe(_ variant: String) async throws {
        let definition = Land("probe-911", using: RegisterSessionTestState.self) { Rules {} }
        let transport = WebSocketTransport()
        let bound = await transport.holdBoundClosesForTesting()
        defer { bound.open() }
        let keeper = LandKeeper(definition: definition, initialState: RegisterSessionTestState(), autoStartLoops: false)
        let adapter = TransportAdapter<RegisterSessionTestState>(keeper: keeper, transport: transport, landID: "probe-911")
        await keeper.setTransport(adapter)
        await adapter.trackDetachedClosesForTesting()
        func join(_ s: String, _ c: ProbeConnection) async throws {
            let id = SessionID(s)
            _ = await transport.handleConnection(sessionID: id, connection: c, authInfo: nil)
            let g = await transport.connectionGeneration(for: id)
            _ = try await keeper.join(session: PlayerSession(playerID: "p1", deviceID: "dev", metadata: [:]),
                                      clientID: ClientID("c-\(s)"), sessionID: id, services: LandServices())
            await adapter.onConnect(sessionID: id, clientID: ClientID("c-\(s)"))
            await adapter.registerSession(sessionID: id, clientID: ClientID("c-\(s)"), playerID: PlayerID("p1"), authInfo: nil, connectionGeneration: g)
            await adapter.waitForOutboundIdleForTesting()
        }
        let a = SessionID("a")
        let old = ProbeConnection()
        try await join("a", old)
        await transport.flushSessionQueues()
        await old.holdSends()
        let frame = await adapter.sessionFrame(Data("A-last-frame".utf8), kind: .text, to: a)
        _ = await adapter.outboundWriter.enqueue([frame])
        #expect(await old.attempted.waitForArrivals(1))
        if variant == "a" {
            try await join("a2", ProbeConnection())
            await adapter.sendFinalFrameAndClose(Data("A-error-frame".utf8), kind: .text, to: a)
        } else {
            await adapter.sendFinalFrameAndClose(Data("A-error-frame".utf8), kind: .text, to: a)
            try await join("a2", ProbeConnection())
        }
        await adapter.waitForDetachedClosesForTesting()
        await adapter.waitForOutboundIdleForTesting()
        let whileHeld = await old.events
        await old.releaseSends()
        _ = await old.closedSignal.waitForArrivals(1)
        await adapter.waitForOutboundIdleForTesting()
        print("probe-911 \(variant): while held=\(whileHeld) final=\(await old.events) atBound=\(await transport.finalFrameClosesAtBound) droppedAfterMarker=\(await transport.framesDroppedAfterCloseMarker)")
        await keeper.forceShutdown()
    }
}
