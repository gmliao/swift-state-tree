// Tests/SwiftStateTreeTransportTests/TransportAdapterInitialSyncOrderingTests.swift
//
// Verifies join response and initial sync ordering, including rejoin after UI leave.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct InitialSyncOrderingTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
}

private func messageOrder(from messages: [Data]) -> [String] {
    var order: [String] = []
    let decoder = JSONDecoder()
    for message in messages {
        if let transportMessage = try? decoder.decode(TransportMessage.self, from: message) {
            switch transportMessage.kind {
            case .joinResponse:
                order.append("joinResponse")
            default:
                order.append("transport:\(transportMessage.kind.rawValue)")
            }
            continue
        }
        if let update = try? decoder.decode(StateUpdate.self, from: message) {
            switch update {
            case .noChange:
                order.append("noChange")
            case .firstSync:
                order.append("firstSync")
            case .diff:
                order.append("diff")
            }
        }
    }
    return order
}

@Test("Join sends joinResponse then firstSync, even if syncNow runs during join")
func testJoinResponseBeforeFirstSyncWhenSyncNowRuns() async throws {
    let definition = Land("ordering-test", using: InitialSyncOrderingTestState.self) {
        Rules {
            OnJoin { (state: inout InitialSyncOrderingTestState, _: LandContext) in
                state.ticks += 1
            }
        }
    }
    
    let transport = RecordingTransport()
    let keeper = LandKeeper(definition: definition, initialState: InitialSyncOrderingTestState())
    let adapter = TransportAdapter<InitialSyncOrderingTestState>(
        keeper: keeper,
        transport: transport,
        landID: "ordering-test",
        enableLegacyJoin: true
    )
    await transport.setDelegate(adapter)
    await keeper.setTransport(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    
    await transport.setOnSend { data, _ in
        if let msg = try? JSONDecoder().decode(TransportMessage.self, from: data),
           msg.kind == .joinResponse {
            await adapter.syncNow()
        }
    }
    
    let joinRequest = TransportMessage.join(
        requestID: "req-1",
        landType: "ordering-test",
        landInstanceId: nil,
        playerID: "player-1",
        deviceID: "device-1",
        metadata: nil
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    try await Task.sleep(for: .milliseconds(100))
    
    let messages = await transport.recordedMessages()
    let order = messageOrder(from: messages)
    
    #expect(order == ["joinResponse", "firstSync"], "Expected joinResponse before firstSync, got \(order)")
}

@Test("UI leave (disconnect) then rejoin sends a fresh firstSync")
func testUiLeaveHomeRejoinSendsFirstSync() async throws {
    let definition = Land("rejoin-test", using: InitialSyncOrderingTestState.self) {
        Rules {
            OnJoin { (state: inout InitialSyncOrderingTestState, _: LandContext) in
                state.ticks += 1
            }
        }
    }
    
    let transport = RecordingTransport()
    let keeper = LandKeeper(definition: definition, initialState: InitialSyncOrderingTestState())
    let adapter = TransportAdapter<InitialSyncOrderingTestState>(
        keeper: keeper,
        transport: transport,
        landID: "rejoin-test",
        enableLegacyJoin: true
    )
    await transport.setDelegate(adapter)
    await keeper.setTransport(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    let joinRequest = TransportMessage.join(
        requestID: "req-1",
        landType: "rejoin-test",
        landInstanceId: nil,
        playerID: "player-1",
        deviceID: "device-1",
        metadata: nil
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    await adapter.onMessage(joinData, from: sessionID)
    
    try await Task.sleep(for: .milliseconds(100))
    _ = await transport.recordedMessages()
    
    await adapter.onDisconnect(sessionID: sessionID, clientID: clientID)
    
    let rejoinSessionID = SessionID("sess-2")
    let rejoinClientID = ClientID("cli-2")
    
    await adapter.onConnect(sessionID: rejoinSessionID, clientID: rejoinClientID)
    let rejoinRequest = TransportMessage.join(
        requestID: "req-2",
        landType: "rejoin-test",
        landInstanceId: nil,
        playerID: "player-1",
        deviceID: "device-2",
        metadata: nil
    )
    let rejoinData = try JSONEncoder().encode(rejoinRequest)
    await adapter.onMessage(rejoinData, from: rejoinSessionID)
    
    try await Task.sleep(for: .milliseconds(100))
    
    let messages = await transport.recordedMessages()
    let order = messageOrder(from: messages)
    let lastTwo = Array(order.suffix(2))
    
    #expect(lastTwo == ["joinResponse", "firstSync"], "Expected rejoin to end with joinResponse then firstSync, got \(lastTwo)")
}

@Test("syncNow skips players that are initial syncing (no diff sent during firstSync)")
func testSyncNowSkipsInitialSyncingPlayers() async throws {
    let definition = Land("skip-test", using: InitialSyncOrderingTestState.self) {
        Rules {
            OnJoin { (state: inout InitialSyncOrderingTestState, _: LandContext) in
                state.ticks += 1
            }
        }
    }
    
    let transport = RecordingTransport()
    let keeper = LandKeeper(definition: definition, initialState: InitialSyncOrderingTestState())
    let adapter = TransportAdapter<InitialSyncOrderingTestState>(
        keeper: keeper,
        transport: transport,
        landID: "skip-test",
        enableLegacyJoin: true
    )
    await transport.setDelegate(adapter)
    await keeper.setTransport(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    
    // Start join process
    let joinRequest = TransportMessage.join(
        requestID: "req-1",
        landType: "skip-test",
        landInstanceId: nil,
        playerID: "player-1",
        deviceID: "device-1",
        metadata: nil
    )
    let joinData = try JSONEncoder().encode(joinRequest)
    
    // Trigger syncNow during join (simulating concurrent sync)
    // This should be called right after joinResponse is sent, while firstSync is being prepared
    await transport.setOnSend { data, target in
        if let msg = try? JSONDecoder().decode(TransportMessage.self, from: data),
           msg.kind == .joinResponse {
            // Trigger syncNow right after joinResponse, while player is initial syncing
            await adapter.syncNow()
        }
    }
    
    await adapter.onMessage(joinData, from: sessionID)
    
    try await Task.sleep(for: .milliseconds(100))
    
    let messages = await transport.recordedMessages()
    let order = messageOrder(from: messages)
    
    // Verify: Should have joinResponse and firstSync
    #expect(order.contains("joinResponse"), "Should have joinResponse")
    #expect(order.contains("firstSync"), "Should have firstSync")
    
    // Verify: firstSync should come after joinResponse, and no diff should appear between them
    // The key assertion: if syncNow runs during initial sync, it should NOT send diff to the new player
    // So we should only see: [joinResponse, firstSync] and no diff before firstSync
    if let joinResponseIndex = order.firstIndex(of: "joinResponse"),
       let firstSyncIndex = order.firstIndex(of: "firstSync") {
        // Check if there's a diff between joinResponse and firstSync
        let messagesBetween = order[(joinResponseIndex + 1)..<firstSyncIndex]
        #expect(!messagesBetween.contains("diff"), "Should NOT have diff between joinResponse and firstSync. Got: \(messagesBetween)")
    }
}
