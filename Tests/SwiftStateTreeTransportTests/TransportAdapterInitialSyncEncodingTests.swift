// Tests/SwiftStateTreeTransportTests/TransportAdapterInitialSyncEncodingTests.swift
//
// Verifies initial sync encoding and field coverage for different state update encodings.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct InitialSyncEncodingTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
    
    @Sync(.perPlayerSlice())
    var playerScores: [PlayerID: Int] = [:]
}

actor RecordingTransport: Transport {
    var delegate: TransportDelegate?
    private var sentMessages: [Data] = []
    private var onSend: (@Sendable (Data, SwiftStateTreeTransport.EventTarget) async -> Void)?

    func setDelegate(_ delegate: TransportDelegate?) {
        self.delegate = delegate
    }
    
    func setOnSend(_ onSend: (@Sendable (Data, SwiftStateTreeTransport.EventTarget) async -> Void)?) {
        self.onSend = onSend
    }

    func start() async throws { }
    func stop() async throws { }

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sentMessages.append(message)
        if let onSend = onSend {
            Task { await onSend(message, target) }
        }
    }

    func recordedMessages() async -> [Data] {
        sentMessages
    }
}

private func decodeOpcodePatchPaths(from data: Data) throws -> [String] {
    guard let payload = try JSONSerialization.jsonObject(with: data) as? [Any] else {
        throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid opcode payload"])
    }
    
    // Opcode JSON array state update format is:
    // [updateOpcode, patch1, patch2, ...]
    // (playerID/playerSlot was removed from the payload)
    guard payload.count >= 2 else {
        throw NSError(domain: "TestError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Opcode payload missing patches"])
    }
    
    var paths: [String] = []
    for entry in payload.dropFirst(1) {
        guard let patch = entry as? [Any], let path = patch.first as? String else {
            continue
        }
        paths.append(path)
    }
    return paths
}

@Test("TransportAdapter initial sync encodes broadcast and per-player fields (jsonObject)")
func testTransportAdapterInitialSyncJsonObjectIncludesBroadcastAndPerPlayer() async throws {
    let definition = Land(
        "encoding-test",
        using: InitialSyncEncodingTestState.self
    ) {
        Rules {
            OnJoin { (state: inout InitialSyncEncodingTestState, ctx: LandContext) in
                state.ticks = 5
                state.playerScores[ctx.playerID] = 42
            }
        }
    }
    
    let transport = RecordingTransport()
    let keeper = LandKeeper(definition: definition, initialState: InitialSyncEncodingTestState())
    let encodingConfig = TransportEncodingConfig(message: .json, stateUpdate: .jsonObject)
    let adapter = TransportAdapter<InitialSyncEncodingTestState>(
        keeper: keeper,
        transport: transport,
        landID: "encoding-test",
        encodingConfig: encodingConfig
    )
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    let playerID = PlayerID("player-1")
    
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    try await simulateRouterJoin(
        adapter: adapter,
        keeper: keeper,
        sessionID: sessionID,
        clientID: clientID,
        playerID: playerID
    )
    
    let messages = await transport.recordedMessages()
    #expect(messages.count == 1, "Expected one initial sync message")
    
    let update = try JSONDecoder().decode(StateUpdate.self, from: messages[0])
    switch update {
    case .firstSync(let patches):
        let paths = Set(patches.map { $0.path })
        #expect(paths.contains("/ticks"), "Expected broadcast field patch in firstSync")
        #expect(paths.contains("/playerScores"), "Expected per-player field patch in firstSync")
    default:
        Issue.record("Expected .firstSync for initial sync, got: \(update)")
    }
}

@Test("TransportAdapter initial sync encodes broadcast and per-player fields (opcodeJsonArray)")
func testTransportAdapterInitialSyncOpcodeIncludesBroadcastAndPerPlayer() async throws {
    let definition = Land(
        "encoding-test",
        using: InitialSyncEncodingTestState.self
    ) {
        Rules {
            OnJoin { (state: inout InitialSyncEncodingTestState, ctx: LandContext) in
                state.ticks = 5
                state.playerScores[ctx.playerID] = 42
            }
        }
    }
    
    let transport = RecordingTransport()
    let keeper = LandKeeper(definition: definition, initialState: InitialSyncEncodingTestState())
    let encodingConfig = TransportEncodingConfig(message: .json, stateUpdate: .opcodeJsonArray)
    let adapter = TransportAdapter<InitialSyncEncodingTestState>(
        keeper: keeper,
        transport: transport,
        landID: "encoding-test",
        encodingConfig: encodingConfig
    )
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-1")
    let clientID = ClientID("cli-1")
    let playerID = PlayerID("player-1")
    
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    try await simulateRouterJoin(
        adapter: adapter,
        keeper: keeper,
        sessionID: sessionID,
        clientID: clientID,
        playerID: playerID
    )
    
    let messages = await transport.recordedMessages()
    #expect(messages.count == 1, "Expected one initial sync message")
    
    let payload = try JSONSerialization.jsonObject(with: messages[0]) as? [Any]
    let opcode = payload?.first as? Int
    #expect(opcode == StateUpdateOpcode.firstSync.rawValue, "Expected firstSync opcode")
    
    let paths = try decodeOpcodePatchPaths(from: messages[0])
    #expect(paths.contains("/ticks"), "Expected broadcast field patch in opcode payload")
    #expect(paths.contains("/playerScores"), "Expected per-player field patch in opcode payload")
}

@Test("TransportAdapter uses playerSlot in opcode encoding for compression")
func testTransportAdapterUsesPlayerSlotInOpcodeEncoding() async throws {
    let definition = Land(
        "playerSlot-test",
        using: InitialSyncEncodingTestState.self
    ) {
        Rules {
            OnJoin { (state: inout InitialSyncEncodingTestState, ctx: LandContext) in
                state.ticks = 10
                state.playerScores[ctx.playerID] = 100
            }
        }
    }
    
    let transport = RecordingTransport()
    let keeper = LandKeeper(definition: definition, initialState: InitialSyncEncodingTestState())
    let encodingConfig = TransportEncodingConfig(message: .json, stateUpdate: .opcodeJsonArray)
    let adapter = TransportAdapter<InitialSyncEncodingTestState>(
        keeper: keeper,
        transport: transport,
        landID: "playerSlot-test",
        encodingConfig: encodingConfig
    )
    await transport.setDelegate(adapter)
    
    let sessionID = SessionID("sess-slot-1")
    let clientID = ClientID("cli-1")
    let playerID = PlayerID("player-very-long-id-string-for-compression-test")
    
    await adapter.onConnect(sessionID: sessionID, clientID: clientID)
    
    // Use performJoin to get the actual join result with playerSlot
    let playerSession = PlayerSession(
        playerID: playerID.rawValue,
        deviceID: "dev-1",
        metadata: [:]
    )
    let joinResult = try await adapter.performJoin(
        playerSession: playerSession,
        clientID: clientID,
        sessionID: sessionID,
        authInfo: nil
    )
    
    guard let result = joinResult else {
        Issue.record("Join should succeed")
        return
    }
    
    // Verify playerSlot was allocated
    let allocatedSlot = await adapter.getPlayerSlot(for: result.playerID)
    #expect(allocatedSlot != nil, "playerSlot should be allocated after join")
    #expect(allocatedSlot == result.playerSlot, "playerSlot from join result should match getPlayerSlot")
    
    // Send initial sync (this should use playerSlot in encoding)
    await adapter.syncStateForNewPlayer(playerID: result.playerID, sessionID: sessionID)
    
    let messages = await transport.recordedMessages()
    #expect(messages.count >= 1, "Expected at least one message (initial sync)")
    
    // Decode the first sync message and verify it uses playerSlot (Int) not playerID (String)
    guard let payload = try JSONSerialization.jsonObject(with: messages[0]) as? [Any] else {
        Issue.record("Failed to decode payload")
        return
    }
    #expect(payload.count >= 2, "Payload should have at least opcode and one patch")
    
    let opcode = payload[0] as? Int
    #expect(opcode == StateUpdateOpcode.firstSync.rawValue, "Expected firstSync opcode")
    
    // NOTE: playerID/playerSlot was removed from the state update payload.
    // payload[1] is the first patch entry.
    #expect(!(payload[1] is String), "StateUpdate payload should not include playerID string")
    
    // Verify compression: compare size with and without playerSlot
    // Create a message without playerSlot for comparison (playerSlot is currently not included in payload)
    let encoder = OpcodeJSONStateUpdateEncoder()
    let update = StateUpdate.firstSync([
        StatePatch(path: "/ticks", operation: .set(.int(10))),
        StatePatch(path: "/playerScores", operation: .set(.object([playerID.rawValue: .int(100)])))
    ])
    
    let dataWithoutSlot = try encoder.encode(update: update, landID: "playerSlot-test", playerID: playerID)
    let dataWithSlot = try encoder.encode(update: update, landID: "playerSlot-test", playerID: playerID, playerSlot: allocatedSlot)
    
    // Verify current behavior: playerSlot is ignored for opcodeJsonArray state updates (no player identifier field).
    #expect(dataWithSlot.count == dataWithoutSlot.count, "playerSlot should not affect encoded size for state updates")
    
    // Verify the payload shape remains stable
    guard let payloadWithSlot = try JSONSerialization.jsonObject(with: dataWithSlot) as? [Any] else {
        Issue.record("Failed to decode payload with slot")
        return
    }
    #expect(payloadWithSlot.count >= 2, "Payload with slot should include at least opcode and one patch")
    #expect(!(payloadWithSlot[1] is String), "Encoded payload should not include playerID string")
}
