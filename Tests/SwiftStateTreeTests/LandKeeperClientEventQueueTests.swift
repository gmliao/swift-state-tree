// Tests/SwiftStateTreeTests/LandKeeperClientEventQueueTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct ClientEventQueueTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    @Sync(.broadcast)
    var totalCookies: Int = 0
}

@Payload
struct ClickCookieEvent: ClientEventPayload {
    let amount: Int
}

@Test("Client event executes on tick when tick handler is configured")
func testClientEventQueuedUntilTick() async throws {
    let definition = Land("client-event-queue-test", using: ClientEventQueueTestState.self) {
        ClientEvents {
            Register(ClickCookieEvent.self)
        }

        Rules {
            HandleEvent(ClickCookieEvent.self) { (state: inout ClientEventQueueTestState, event: ClickCookieEvent, _: LandContext) in
                state.totalCookies += event.amount
            }
        }

        Lifetime {
            Tick(every: .milliseconds(200)) { (state: inout ClientEventQueueTestState, _: LandContext) in
                state.ticks += 1
            }
        }
    }

    let keeper = LandKeeper(definition: definition, initialState: ClientEventQueueTestState())
    let playerID = PlayerID("alice")
    let clientID = ClientID("c1")
    let sessionID = SessionID("s1")

    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)

    let event = AnyClientEvent(ClickCookieEvent(amount: 5))
    try await keeper.handleClientEvent(event, playerID: playerID, clientID: clientID, sessionID: sessionID)

    // Before first tick, event should not be applied yet.
    let stateBeforeTick = await keeper.currentState()
    #expect(stateBeforeTick.totalCookies == 0, "Event should be queued until the next tick")

    // Wait for at least one tick to fire.
    try await Task.sleep(for: .milliseconds(300))

    let stateAfterTick = await keeper.currentState()
    #expect(stateAfterTick.totalCookies == 5, "Event should be applied during tick processing")
    #expect(stateAfterTick.ticks >= 1, "Tick handler should have executed at least once")
}

@Test("Tickless land records events with valid tick ID")
func testTicklessLandRecordsWithValidTickId() async throws {
    let definition = Land("tickless-test", using: ClientEventQueueTestState.self) {
        ClientEvents {
            Register(ClickCookieEvent.self)
        }

        Rules {
            HandleEvent(ClickCookieEvent.self) { (state: inout ClientEventQueueTestState, event: ClickCookieEvent, _: LandContext) in
                state.totalCookies += event.amount
            }
        }

        // No tick handler - this is a tickless land
    }

    let recordingFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("tickless-test-\(UUID().uuidString).json")

    defer {
        try? FileManager.default.removeItem(at: recordingFile)
    }

    let keeper = LandKeeper(
        definition: definition,
        initialState: ClientEventQueueTestState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false
    )

    if let recorder = await keeper.getReevaluationRecorder() {
        let meta = ReevaluationRecordMetadata(
            landID: "tickless-test:local",
            landType: "tickless-test",
            createdAt: Date(),
            metadata: [:],
            landDefinitionID: definition.id,
            initialStateHash: nil,
            landConfig: ["autoStartLoops": AnyCodable(false)],
            rngSeed: 0,
            ruleVariantId: nil,
            ruleParams: nil,
            version: "1.0",
            extensions: nil
        )
        await recorder.setMetadata(meta)
    }

    let playerID = PlayerID("alice")
    let clientID = ClientID("c1")
    let sessionID = SessionID("s1")
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)

    let event = AnyClientEvent(ClickCookieEvent(amount: 10))
    try await keeper.handleClientEvent(event, playerID: playerID, clientID: clientID, sessionID: sessionID)

    // Wait for async processing
    try await Task.sleep(for: .milliseconds(100))

    guard let recorder = await keeper.getReevaluationRecorder() else {
        Issue.record("ReevaluationRecorder not available")
        return
    }
    try await recorder.save(to: recordingFile.path)

    // Verify the recording has valid tick IDs (not -1)
    let source = try JSONReevaluationSource(filePath: recordingFile.path)
    let maxTickId = try await source.getMaxTickId()
    #expect(maxTickId >= 0, "Tickless land should record with valid tick ID (>= 0), got \(maxTickId)")

    // Verify we can replay it
    let result = try await ReevaluationEngine.run(
        definition: definition,
        initialState: ClientEventQueueTestState(),
        recordFilePath: recordingFile.path
    )
    #expect(result.maxTickId >= 0, "Replay should process at least one tick")
}
