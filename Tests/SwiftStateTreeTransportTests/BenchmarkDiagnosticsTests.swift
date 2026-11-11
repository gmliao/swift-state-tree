import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

// The two `Diagnostics` hooks a benchmark needs to drive lands through a router by hand: a land
// manager whose live keepers don't start their loops, and a transport flush that returns once
// every session's connection has its queued frames.

private func steppedLand(_ landID: LandID) -> LandDefinition<ManagerTestState> {
    Land("stepped", using: ManagerTestState.self) {
        Rules {}
        Lifetime {
            Tick(every: .milliseconds(50)) { (state: inout ManagerTestState, _: LandContext) in
                state.ticks += 1
            }
            StateSync(every: .milliseconds(50)) { (_: ManagerTestState, _: LandContext) in }
        }
    }
}

private func landManager(autoStartLoops: Bool?) -> LandManager<ManagerTestState> {
    if let autoStartLoops {
        return LandManager<ManagerTestState>(
            landFactory: steppedLand,
            initialStateFactory: { _ in ManagerTestState() },
            autoStartLoops: autoStartLoops
        )
    }
    return LandManager<ManagerTestState>(landFactory: steppedLand, initialStateFactory: { _ in ManagerTestState() })
}

@Suite("Benchmark diagnostics: a land manager without loops")
struct LandManagerWithoutLoopsTests {
    @Test("Its live keepers start no loop, and one step moves the tick by exactly one")
    func noLoops() async throws {
        let manager = landManager(autoStartLoops: false)
        let landID = LandID("stepped:room-1")
        let container = try await manager.getOrCreateLand(
            landID: landID, definition: steppedLand(landID), initialState: ManagerTestState(), metadata: [:]
        )
        let keeper = container.keeper
        #expect(keeper.hasPeriodicSync == false)
        #expect(await keeper.hasTickLoopForTesting() == false)
        #expect(await keeper.currentState().ticks == 0)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().ticks == 1)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().ticks == 2)
        await manager.shutdownAllLands()
    }

    @Test("With autoStartLoops true, and through the public init, the loops start as before")
    func loopsByDefault() async throws {
        for manager in [landManager(autoStartLoops: true), landManager(autoStartLoops: nil)] {
            let landID = LandID("stepped:room-1")
            let container = try await manager.getOrCreateLand(
                landID: landID, definition: steppedLand(landID), initialState: ManagerTestState(), metadata: [:]
            )
            #expect(container.keeper.hasPeriodicSync)
            #expect(await container.keeper.hasTickLoopForTesting())
            await manager.shutdownAllLands()
        }
    }
}

/// A connection whose sends wait at a gate, recording what was handed to it.
private final class HeldConnection: WebSocketConnection, @unchecked Sendable {
    let gate = TestGate()
    private let lock = NSLock()
    private var sent: [Data] = []
    private let failing: Bool

    init(failing: Bool = false) {
        self.failing = failing
    }

    var received: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    func send(_ data: Data) async throws {
        await gate.arrive()
        if failing { throw CancellationError() }
        lock.withLock { sent.append(data) }
    }

    func close() async throws {}
}

/// Sets when `operation` returns.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

@Suite("Benchmark diagnostics: flushing the transport's session queues")
struct WebSocketTransportFlushTests {
    @Test("A flush waits for a held send, and returns once it is handed to the connection")
    func waitsForHeldSend() async throws {
        let transport = WebSocketTransport()
        let connection = HeldConnection()
        let session = SessionID("s1")
        _ = await transport.handleConnection(sessionID: session, connection: connection)
        await transport.send(Data("frame".utf8), to: .session(session))
        #expect(await connection.gate.waitForArrivals(1))

        let flushed = Flag()
        let flush = Task {
            await transport.flushSessionQueues()
            flushed.set()
        }
        // The send is held at the gate: the flush can't have returned. Its marker sits behind
        // the frame, so nothing but the drain reaching it resumes the flush.
        await Task.yield()
        #expect(flushed.isSet == false)
        #expect(connection.received.isEmpty)

        connection.gate.open()
        await flush.value
        #expect(flushed.isSet)
        #expect(connection.received == [Data("frame".utf8)])
    }

    @Test("A flush with no sessions returns at once")
    func noSessions() async {
        await WebSocketTransport().flushSessionQueues()
    }

    @Test("A session closed during the flush doesn't hang it")
    func closedDuringFlush() async throws {
        let transport = WebSocketTransport()
        let connection = HeldConnection()
        let session = SessionID("s1")
        _ = await transport.handleConnection(sessionID: session, connection: connection)
        await transport.send(Data("frame".utf8), to: .session(session))
        #expect(await connection.gate.waitForArrivals(1))

        let flush = Task { await transport.flushSessionQueues() }
        // The queue's removal finishes its stream and cancels its drain: the drain ends, and its
        // flush waiter is released, though its marker is never read.
        await transport.handleDisconnection(sessionID: session)
        connection.gate.open()
        await flush.value
    }

    @Test("A session whose drain ended on a failed send counts as flushed")
    func drainEndedOnFailedSend() async throws {
        let transport = WebSocketTransport()
        let connection = HeldConnection(failing: true)
        let session = SessionID("s1")
        _ = await transport.handleConnection(sessionID: session, connection: connection)
        connection.gate.open()
        await transport.send(Data("frame".utf8), to: .session(session))
        // The failed send ends the drain; a flush after it finds the stream terminated.
        #expect(await connection.gate.waitForArrivals(1))
        await transport.flushSessionQueues()
        // And a second one, after the drain released its waiters for good.
        await transport.flushSessionQueues()
    }
}
