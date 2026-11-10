// Tests/SwiftStateTreeTransportTests/TransportSessionCloseTests.swift
//
// Server-side session close bookkeeping: the ended-session set stays bounded under SessionID
// reuse, an unconfirmed server close is forgotten after a timeout, and a transport that cannot
// close sessions is reported once.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

private actor SilentConnection: WebSocketConnection {
    func send(_ data: Data) async throws {}
    func close() async throws {}  // never reports a disconnect back
}

/// Counts the delegate's disconnects.
private actor DisconnectCounter: TransportDelegate {
    private(set) var disconnects = 0
    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {}
    func onDisconnect(sessionID: SessionID, clientID: ClientID) async { disconnects += 1 }
    func onMessage(_ message: Data, from sessionID: SessionID) async {}
}

/// Keeps each scheduled close expiry for the test to run when it chooses.
private final class ExpiryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Duration, @Sendable () async -> Void)] = []
    func record(_ deadline: Duration, _ expire: @escaping @Sendable () async -> Void) {
        lock.withLock { entries.append((deadline, expire)) }
    }
    var only: (Duration, @Sendable () async -> Void)? {
        lock.withLock { entries.count == 1 ? entries[0] : nil }
    }
    var all: [(Duration, @Sendable () async -> Void)] {
        lock.withLock { entries }
    }
}

/// Once `hold()` is called, holds every send until `releaseAll()` (so the writer backs up); `closeSession` is the
/// protocol's no-op default.
private actor NoCloseTransport: Transport {
    var delegate: TransportDelegate?
    private var held: [CheckedContinuation<Void, Never>] = []
    private var holding = false
    func hold() { holding = true }
    func sendSessionFrames(_ frames: [SessionFrame]) async {
        guard holding else { return }
        await withCheckedContinuation { held.append($0) }
    }
    func releaseAll() {
        holding = false
        let pending = held
        held = []
        for continuation in pending { continuation.resume() }
    }
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {}
}

@StateNodeBuilder
struct SessionCloseTestState: StateNodeProtocol {
    @Sync(.broadcast) var value: Int = 0
    init() {}
}

@Payload
struct SessionCloseEvent: ServerEventPayload {
    let message: String
    init(message: String) { self.message = message }
}

@Suite("Session close bookkeeping")
struct TransportSessionCloseTests {
    @Test("EndedSessionSet stays bounded when the same SessionIDs are removed and inserted again")
    func endedSessionSetIsBoundedUnderReuse() {
        var set = EndedSessionSet(capacity: 8)
        let ids = (0..<4).map { SessionID("reuse-\($0)") }
        for _ in 0..<1000 {
            for id in ids {
                set.insert(id)
                set.remove(id)
                set.insert(id)
            }
        }
        #expect(set.orderCount <= 3 * 8, "insertion log length \(set.orderCount)")
        for id in ids { #expect(set.contains(id)) }
        // Capacity still evicts the oldest sessions.
        for n in 0..<20 { set.insert(SessionID("fresh-\(n)")) }
        #expect(!set.contains(ids[0]))
        #expect(set.contains(SessionID("fresh-19")))
    }

    @Test("an unconfirmed server close is forgotten after the timeout; a confirmed one at once")
    func unconfirmedServerCloseExpires() async throws {
        // The test runs the expiry itself instead of sleeping past the timeout: a 3 s poll for a
        // 50 ms expiry missed its deadline beside CPU-heavy tests (#447).
        let transport = WebSocketTransport()
        await transport.setServerCloseConfirmTimeout(.milliseconds(50))
        let expiries = ExpiryRecorder()
        await transport.setServerCloseExpiryForTesting { deadline, expire in expiries.record(deadline, expire) }
        let silent = SessionID("close-silent")
        await transport.handleConnection(sessionID: silent, connection: SilentConnection())
        await transport.closeSession(silent)
        #expect(await transport.pendingServerClosedSessionCount() == 1, "waiting for the disconnect callback")
        let (deadline, expire) = try #require(expiries.only)
        #expect(deadline == .milliseconds(50), "the configured timeout")
        await expire()
        #expect(await transport.pendingServerClosedSessionCount() == 0, "expired after the timeout")
        #expect(await transport.unconfirmedServerClosesForTesting == 1)

        let confirmed = SessionID("close-confirmed")
        await transport.handleConnection(sessionID: confirmed, connection: SilentConnection())
        await transport.closeSession(confirmed)
        await transport.handleDisconnection(sessionID: confirmed)  // the server's own callback
        #expect(await transport.pendingServerClosedSessionCount() == 0, "confirmed before its expiry")
        // Its expiry, when it comes, finds nothing to expire.
        let confirmedExpiry = try #require(expiries.all.count == 2 ? expiries.all[1].1 : nil)
        await confirmedExpiry()
        #expect(await transport.unconfirmedServerClosesForTesting == 1, "the confirmed close isn't counted")
    }

    @Test("A close with a grace past the confirm timeout: confirmed by its callback, one disconnect, nothing expired (#339)")
    func graceOutlastsConfirmTimeout() async throws {
        let transport = WebSocketTransport()
        let delegate = DisconnectCounter()
        await transport.setDelegate(delegate)
        let expiries = ExpiryRecorder()
        await transport.setServerCloseExpiryForTesting { deadline, expire in expiries.record(deadline, expire) }
        let id = SessionID("close-grace")
        await transport.handleConnection(sessionID: id, connection: SilentConnection())
        await transport.closeSession(id, with: SessionClose(code: SessionClose.Code.unresponsive, closeGrace: .seconds(15)))
        #expect(await delegate.disconnects == 1, "closeSession told the delegate")
        let (deadline, expire) = try #require(expiries.only)
        #expect(deadline == .seconds(25), "the confirm timeout (10 s) plus the grace")
        // The order the deadline guarantees: the channel closes at the grace's end (at most the
        // close-frame timeout + the grace), so its callback comes before the expiry.
        await transport.handleDisconnection(sessionID: id)
        #expect(await delegate.disconnects == 1, "the server's own callback doesn't notify again")
        await expire()
        #expect(await transport.unconfirmedServerClosesForTesting == 0, "confirmed, not expired")
        #expect(await transport.pendingServerClosedSessionCount() == 0)
        #expect(await delegate.disconnects == 1)
    }

    @Test("Without a grace the confirm deadline is the timeout; a negative grace adds nothing")
    func confirmDeadlineWithoutGrace() async {
        let transport = WebSocketTransport()
        #expect(await transport.serverCloseConfirmDeadline(for: .normal) == .seconds(10))
        #expect(await transport.serverCloseConfirmDeadline(for: SessionClose(code: 4010, closeGrace: .zero)) == .seconds(10))
        #expect(await transport.serverCloseConfirmDeadline(for: SessionClose(code: 4010, closeGrace: .seconds(-3))) == .seconds(10))
    }

    @Test("a transport whose closeSession is the no-op default is reported once")
    func noOpCloseSessionIsReported() async throws {
        let transport = NoCloseTransport()
        #expect(transport.supportsCloseSession == false)
        #expect(WebSocketTransport().supportsCloseSession == true)
        let land = Land("close-noop", using: SessionCloseTestState.self) {
            ServerEvents { Register(SessionCloseEvent.self) }
            Rules {}
        }
        let keeper = LandKeeper<SessionCloseTestState>(definition: land, initialState: SessionCloseTestState())
        let adapter = TransportAdapter<SessionCloseTestState>(
            keeper: keeper,
            transport: transport,
            landID: "close-noop",
            transportEnvConfig: TransportEnvConfig(
                enableDirtyTracking: true,
                useSnapshotForSync: true,
                syncStrategy: .delta,
                enableChangeObjectMetrics: false,
                changeObjectMetricsLogEvery: 10,
                changeObjectMetricsEmaAlpha: 0.2,
                enableAutoDirtyTracking: false,
                autoDirtyOffThreshold: 0.55,
                autoDirtyOnThreshold: 0.30,
                autoDirtyRequiredConsecutiveSamples: 30,
                profilingConfig: nil,
                outboundWriterMaxBytes: 1
            ),
            encodingConfig: .json
        )
        await transport.setDelegate(adapter)
        #expect(await adapter.warnedNoCloseSession == false)
        for n in 0..<2 {
            let session = SessionID("close-noop-\(n)")
            let client = ClientID("close-noop-client-\(n)")
            await adapter.onConnect(sessionID: session, clientID: client)
            try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: PlayerID("close-noop-player-\(n)"))
        }
        // A 1-byte ceiling: any element queued behind another is dropped and its sessions ended.
        await transport.hold()
        for n in 0..<50 {
            await adapter.sendEvent(AnyServerEvent(SessionCloseEvent(message: "close-noop-\(n)")), to: .all)
        }
        #expect(await adapter.outboundCeilingDisconnectCount() > 0)
        #expect(await adapter.warnedNoCloseSession == true)
        await transport.releaseAll()
    }
}
