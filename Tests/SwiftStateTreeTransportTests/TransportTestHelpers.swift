// Tests/SwiftStateTreeTransportTests/TransportTestHelpers.swift

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

/// Simulate the join process usually handled by LandRouter.
/// This allows testing TransportAdapter in isolation without needing the full LandRouter stack.
///
/// Steps:
/// 1. Calls `keeper.join` to execute OnJoin rules and update Land state.
/// 2. Calls `adapter.registerSession` to bind the session in the adapter.
/// 3. Sends initial state snapshot (simulates what happens AFTER JoinResponse is sent).
///
/// Note: In production, the order is:
/// 1. performJoin() - keeper.join + registerSession
/// 2. sendJoinResponse() - client receives join confirmation
/// 3. syncStateForNewPlayer() - client receives initial state
///
/// In tests, we simulate this without the actual JoinResponse message.
func simulateRouterJoin<State: StateNodeProtocol>(
    adapter: TransportAdapter<State>,
    keeper: LandKeeper<State>,
    sessionID: SessionID,
    clientID: ClientID,
    playerID: PlayerID,
    authInfo: AuthenticatedInfo? = nil
) async throws {
    let playerSession = PlayerSession(
        playerID: playerID.rawValue,
        deviceID: "dev-mock-\(playerID.rawValue)",
        metadata: authInfo?.metadata ?? [:]
    )
    
    // 1. Join Keeper (executes OnJoin rules)
    // We explicitly call keeper.join here because TransportAdapter expects the keeper to be aware of the player
    // AND TransportAdapter.registerSession expects to be called AFTER a successful join.
    let decision = try await keeper.join(
        session: playerSession,
        clientID: clientID,
        sessionID: sessionID,
        services: LandServices()
    )
    
    guard case .allow(let finalPlayerID) = decision else {
        throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Join denied"])
    }
    
    // 2. Register with Adapter
    await adapter.registerSession(
        sessionID: sessionID,
        clientID: clientID,
        playerID: finalPlayerID,
        authInfo: authInfo
    )
    
    // 3. Allocate playerSlot (simulates what performJoin does)
    _ = await adapter.allocatePlayerSlot(accountKey: finalPlayerID.rawValue, for: finalPlayerID)
    
    // 4. Send initial state snapshot
    // In production this happens AFTER JoinResponse is sent to ensure correct message order.
    // In tests we call it directly since we don't have the actual WebSocket message flow.
    await adapter.syncStateForNewPlayer(playerID: finalPlayerID, sessionID: sessionID)
    // The adapter's outbound writer sends asynchronously; let firstSync reach the transport.
    #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
}

/// Holds one sync cycle in flight at `TransportAdapter.debugCycleHoldBeforeEndSync`: after the
/// cycle enqueued its frames, before its `endSync` hop (the cycle still owns the sync flag).
///
/// Replaces holding the transport's `sendBatch`: with the outbound writer (#60) the cycle no
/// longer awaits the transport, so a blocked transport does not keep a cycle in flight.
final class SyncCycleHold: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?

    /// Installs the hold on `adapter`; it only acts once armed.
    func install<State: StateNodeProtocol>(on adapter: TransportAdapter<State>) async {
        await adapter.setDebugCycleHoldBeforeEndSync { [self] in await self.holdIfArmed() }
    }

    /// The next cycle that reaches the hold point waits there until `release()`.
    func arm() {
        lock.lock(); defer { lock.unlock() }
        armed = true
    }

    var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return held != nil
    }

    /// Lets the held cycle continue. With no cycle held, disarms the hold instead. Arming again
    /// before releasing a held cycle holds the next cycle that reaches the hold point.
    func release() {
        lock.lock()
        let continuation = held
        held = nil
        if continuation == nil { armed = false }
        lock.unlock()
        continuation?.resume()
    }

    private func holdIfArmed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            guard armed else {
                lock.unlock()
                continuation.resume()
                return
            }
            armed = false
            held = continuation
            lock.unlock()
        }
    }

    /// Polls until a cycle is held (no fixed sleeps as synchronization).
    func waitUntilHeld(timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !isHeld {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for a sync cycle to be held")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
