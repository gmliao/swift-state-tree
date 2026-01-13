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

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) async throws {
        sentMessages.append(message)
        if let onSend = onSend {
            await onSend(message, target)
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
    
    guard payload.count >= 3 else {
        throw NSError(domain: "TestError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Opcode payload missing patches"])
    }
    
    var paths: [String] = []
    for entry in payload.dropFirst(2) {
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
    #expect(payload.count >= 2, "Payload should have at least opcode and player identifier")
    
    let opcode = payload[0] as? Int
    #expect(opcode == StateUpdateOpcode.firstSync.rawValue, "Expected firstSync opcode")
    
    // Verify playerSlot is used (Int) instead of playerID (String)
    let playerIdentifier = payload[1]
    #expect(playerIdentifier is Int, "Player identifier should be Int (playerSlot), not String")
    if let slotValue = playerIdentifier as? Int, let allocatedSlotValue = allocatedSlot {
        #expect(slotValue == Int(allocatedSlotValue), "Player identifier should match allocated playerSlot")
    } else {
        Issue.record("Failed to compare playerSlot values")
    }
    #expect(playerIdentifier as? String == nil, "Player identifier should NOT be String (playerID)")
    
    // Verify compression: compare size with and without playerSlot
    // Create a message without playerSlot for comparison
    let encoder = OpcodeJSONStateUpdateEncoder()
    let update = StateUpdate.firstSync([
        StatePatch(path: "/ticks", operation: .set(.int(10))),
        StatePatch(path: "/playerScores", operation: .set(.object([playerID.rawValue: .int(100)])))
    ])
    
    let dataWithoutSlot = try encoder.encode(update: update, landID: "playerSlot-test", playerID: playerID)
    let dataWithSlot = try encoder.encode(update: update, landID: "playerSlot-test", playerID: playerID, playerSlot: allocatedSlot)
    
    // Verify compression effect
    #expect(dataWithSlot.count < dataWithoutSlot.count, "Data with playerSlot should be smaller than data with playerID string")
    
    // Verify the actual payload uses playerSlot
    guard let payloadWithSlot = try JSONSerialization.jsonObject(with: dataWithSlot) as? [Any] else {
        Issue.record("Failed to decode payload with slot")
        return
    }
    if let slotValue = payloadWithSlot[1] as? Int, let allocatedSlotValue = allocatedSlot {
        #expect(slotValue == Int(allocatedSlotValue), "Encoded payload should use playerSlot")
    } else {
        Issue.record("Failed to verify playerSlot in encoded payload")
    }
    #expect(payloadWithSlot[1] as? String == nil, "Encoded payload should NOT use playerID string")
}
