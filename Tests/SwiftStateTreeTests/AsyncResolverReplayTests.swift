// Tests/SwiftStateTreeTests/AsyncResolverReplayTests.swift
//
// Tests to verify async resolver recording and re-evaluation functionality

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test State

@StateNodeBuilder
struct AsyncResolverTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: String = ""
    
    @Sync(.broadcast)
    var resolverValue: String = ""
    
    public init() {}
}

// MARK: - Test Actions

@Payload
struct AsyncResolverTestAction: ActionPayload {
    typealias Response = AsyncResolverTestResponse
    
    let input: String
}

@Payload
struct AsyncResolverTestResponse: ResponsePayload {
    let success: Bool
    let value: String
}

// MARK: - Test Resolver with Async Delay

/// Test resolver that simulates async I/O with configurable delay
struct TestAsyncResolver: ContextResolver {
    typealias Output = TestResolverOutput
    
    static func resolve(
        ctx: ResolverContext
    ) async throws -> TestResolverOutput {
        // Simulate async I/O operation (e.g., database query)
        // Use a short delay to test async behavior without slowing tests too much
        try await Task.sleep(for: .milliseconds(10))
        
        // Generate deterministic value based on PlayerID (Swift Hashable is not deterministic)
        let stable = DeterministicHash.stableInt32(ctx.playerID.rawValue)
        let value = "resolved-\(stable % 1000)"
        
        return TestResolverOutput(value: value)
    }
}

struct TestResolverOutput: ResolverOutput {
    let value: String
}

// MARK: - Tests

@Test("Async resolver output is recorded correctly in live mode")
func testAsyncResolverRecording() async throws {
    let definition = Land(
        "async-resolver-test",
        using: AsyncResolverTestState.self
    ) {
        Rules {
            HandleAction(AsyncResolverTestAction.self, resolvers: TestAsyncResolver.self) {
                (state: inout AsyncResolverTestState, action: AsyncResolverTestAction, ctx: LandContext) in
                // Access resolver output (explicit type cast for dynamic member lookup)
                if let resolverOutput = ctx.testAsync as TestResolverOutput? {
                    state.resolverValue = resolverOutput.value
                    state.value = action.input
                    return AsyncResolverTestResponse(success: true, value: resolverOutput.value)
                }
                return AsyncResolverTestResponse(success: false, value: "")
            }
        }
        Lifetime {
            // Use manual tick stepping in this test (autoStartLoops: false).
            Tick(every: .seconds(3600)) { (_: inout AsyncResolverTestState, _: LandContext) in }
        }
    }
    
    let keeper = LandKeeper<AsyncResolverTestState>(
        definition: definition,
        initialState: AsyncResolverTestState(),
        autoStartLoops: false
    )
    
    let playerID = PlayerID("test-player")
    let clientID = ClientID("test-client")
    let sessionID = SessionID("test-session")
    
    try await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID)
    
    // Send action with async resolver
    let action = AsyncResolverTestAction(input: "test-input")
    let envelope = ActionEnvelope(
        typeIdentifier: String(describing: AsyncResolverTestAction.self),
        payload: AnyCodable(action)
    )
    
    // Execute resolver (async), enqueue action, then step a tick to apply it.
    _ = try await keeper.handleActionEnvelope(
        envelope,
        playerID: playerID,
        clientID: clientID,
        sessionID: sessionID
    )
    await keeper.stepTickOnce()

    let state = await keeper.currentState()
    
    // Check if resolver output was recorded and used
    #expect(state.value == "test-input", "Action input should be stored")
    #expect(!state.resolverValue.isEmpty, "Resolver output should be available after async resolution")
    
    // Verify resolver output is deterministic (same PlayerID produces same value)
    let expectedHash = DeterministicHash.stableInt32(PlayerID("test-player").rawValue) % 1000
    let expectedValue = "resolved-\(expectedHash)"
    #expect(state.resolverValue == expectedValue, "Resolver output should be deterministic")
}

@Test("Async resolver output is used directly in re-evaluation mode")
func testAsyncResolverReplay() async throws {
    // This test would require:
    // 1. Recording actions with resolver outputs in live mode
    // 2. Creating a JSONReevaluationSource from the record
    // 3. Running re-evaluation mode and verifying resolver outputs are used directly
    
    // For now, this is a placeholder test structure
    // Full implementation would require:
    // - ReevaluationRecorder.save() to create record file
    // - JSONReevaluationSource to load record
    // - LandKeeper(mode: .reevaluation, reevaluationSource: ...) to run re-evaluation
    
    // TODO: Implement full re-evaluation test once ReevaluationRecorder.save() is integrated
}
