import Testing
import Foundation

struct ReplayPOCTests {

    struct MockAction: Sendable, Equatable {
        let name: String
        let resolvedAt: Int64
        let resolverOutput: String
    }

    // Mock Resolver that simulates async work
    actor MockAsyncResolver {
        func resolve(action: String, delay: Duration) async -> String {
            try? await Task.sleep(for: delay)
            return "\(action)-Resolved"
        }
    }

    // Mock LandKeeper
    actor MockLandKeeper {
        var tickId: Int64 = 0
        var actionQueue: [MockAction] = []
        var history: [String] = []
        var pendingTasks: [Task<Void, Never>] = []
        
        // For recording/replay
        var recorder: [Int64: [MockAction]] = [:]
        let isReplay: Bool
        let resolver = MockAsyncResolver()
        
        init(replayData: [Int64: [MockAction]]? = nil) {
            if let data = replayData {
                self.isReplay = true
                self.recorder = data
            } else {
                self.isReplay = false
            }
        }
        
        func handleAction(name: String, delay: Duration) {
            let task = Task {
                let output = await resolver.resolve(action: name, delay: delay)
                self.enqueueResolvedAction(name: name, output: output)
            }
            pendingTasks.append(task)
        }
        
        private func enqueueResolvedAction(name: String, output: String) {
            // The action is "resolved" at the current tick
            let resolvedAt = self.tickId
            let action = MockAction(name: name, resolvedAt: resolvedAt, resolverOutput: output)
            actionQueue.append(action)
        }
        
        func runTick() {
            tickId += 1
            
            var actionsToExecute: [MockAction] = []
            
            if isReplay {
                // In replay mode, we strictly follow the recorded history.
                // We bypass the actionQueue and resolver logic entirely.
                if let recorded = recorder[tickId] {
                    actionsToExecute = recorded
                }
            } else {
                // Live Mode:
                // 1. Identify actions ready to execute.
                //    Rule: Action must have resolved in a PREVIOUS tick (resolvedAt < currentTick).
                let readyActions = actionQueue.filter { $0.resolvedAt < tickId }
                
                // 2. Deterministic Sort.
                //    Primary: resolvedAt (earlier resolves first)
                //    Secondary: Name (or some other deterministic tie-breaker)
                actionsToExecute = readyActions.sorted {
                    if $0.resolvedAt != $1.resolvedAt {
                        return $0.resolvedAt < $1.resolvedAt
                    }
                    return $0.name < $1.name
                }
                
                // 3. Remove executed actions from queue
                //    (Optimization: could use a more efficient data structure, but array is fine for POC)
                if !actionsToExecute.isEmpty {
                    // Rebuild queue excluding executed ones
                    // Since MockAction is Equatable, we can filter.
                    // But to be safe against duplicates, let's just keep those NOT in readyActions.
                    // (Assuming instances are unique enough or logic holds).
                    // Better: Filter by resolvedAt >= tickId, since we grabbed everything < tickId.
                    actionQueue = actionQueue.filter { $0.resolvedAt >= tickId }
                    
                    // 4. Record execution for Replay
                    recorder[tickId] = actionsToExecute
                }
            }
            
            // Execute actions
            for action in actionsToExecute {
                history.append("Tick \(tickId): Executed \(action.name) (Resolved at \(action.resolvedAt)) Output: \(action.resolverOutput)")
            }
        }
        
        func getHistory() -> [String] {
            return history
        }
        
        func getRecorder() -> [Int64: [MockAction]] {
            return recorder
        }
        
        // Helper to wait for background tasks in tests
        func waitForPendingTasks() async {
            for task in pendingTasks {
                _ = await task.result
            }
        }
    }

    @Test("Verify deterministic execution order in Live Mode")
    func testLiveModeExecution() async throws {
        let keeper = MockLandKeeper()
        
        // Send "Slow" first, then "Fast"
        // Slow takes 100ms, Fast takes 10ms.
        // Fast should resolve earlier and thus execute in an earlier tick.
        await keeper.handleAction(name: "Slow", delay: .milliseconds(100))
        await keeper.handleAction(name: "Fast", delay: .milliseconds(10))
        
        // Run ticks for a while
        // We need to allow time for the async tasks to complete in the background
        // In a real game loop, runTick happens periodically.
        // Here we simulate the loop.
        
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(10))
            await keeper.runTick()
        }
        
        // Wait for any stragglers if necessary (though the loop should cover it)
        await keeper.waitForPendingTasks()
        
        let history = await keeper.getHistory()
        
        // Expectation: Fast executes before Slow
        // And history is not empty
        #expect(!history.isEmpty, "History should not be empty")
        
        // We expect specific messages
        let fastIndex = history.firstIndex { $0.contains("Fast") }
        let slowIndex = history.firstIndex { $0.contains("Slow") }
        
        #expect(fastIndex != nil, "Fast action missing")
        #expect(slowIndex != nil, "Slow action missing")
        
        if let f = fastIndex, let s = slowIndex {
            #expect(f < s, "Fast action should execute before Slow action")
        }
    }

    @Test("Verify Replay Mode matches Live Mode")
    func testReplayMode() async throws {
        // 1. Live Run
        let liveKeeper = MockLandKeeper()
        await liveKeeper.handleAction(name: "Action1", delay: .milliseconds(20))
        await liveKeeper.handleAction(name: "Action2", delay: .milliseconds(50))
        
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(10))
            await liveKeeper.runTick()
        }
        await liveKeeper.waitForPendingTasks()
        
        let liveHistory = await liveKeeper.getHistory()
        let recordedData = await liveKeeper.getRecorder()
        
        #expect(!liveHistory.isEmpty)
        
        // 2. Replay Run
        let replayKeeper = MockLandKeeper(replayData: recordedData)
        
        // In replay, we don't call handleAction. We just run ticks.
        // And we expect the exact same history.
        
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(10))
            await replayKeeper.runTick()
        }
        
        let replayHistory = await replayKeeper.getHistory()
        
        #expect(replayHistory == liveHistory, "Replay history must match Live history")
    }
}
