import Testing
import Foundation

struct ReplayPOCTests {

    struct MockAction: Sendable, Equatable {
        let name: String
        let resolvedAt: Int64
        let resolverOutput: String
    }

    /// Mock resolver that uses a predetermined schedule (action -> resolveAtTick) instead of real time.
    /// Deterministic: no Task.sleep, no scheduling races.
    actor MockAsyncResolver {
        /// Schedule: action name -> tick when it "resolves"
        let schedule: [String: Int64]

        init(schedule: [String: Int64] = [:]) {
            self.schedule = schedule
        }

        /// Resolve immediately with mock result. resolvedAt comes from schedule.
        func resolve(action: String, resolvesAtTick: Int64) -> (output: String, resolvedAt: Int64) {
            let resolvedAt = schedule[action] ?? resolvesAtTick
            return ("\(action)-Resolved", resolvedAt)
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
        let resolver: MockAsyncResolver
        
        init(replayData: [Int64: [MockAction]]? = nil, resolverSchedule: [String: Int64] = [:]) {
            self.resolver = MockAsyncResolver(schedule: resolverSchedule)
            if let data = replayData {
                self.isReplay = true
                self.recorder = data
            } else {
                self.isReplay = false
            }
        }
        
        func handleAction(name: String, resolvesAtTick: Int64) {
            let task = Task {
                let (output, resolvedAt) = await resolver.resolve(action: name, resolvesAtTick: resolvesAtTick)
                await self.enqueueResolvedAction(name: name, output: output, resolvedAt: resolvedAt)
            }
            pendingTasks.append(task)
        }
        
        private func enqueueResolvedAction(name: String, output: String, resolvedAt: Int64) {
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
                //    (Optimization: could use a more efficient data structure; array is sufficient here)
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
        // Use mock schedule: Fast resolves at tick 2, Slow at tick 5.
        // No real time - deterministic, no scheduling races.
        let keeper = MockLandKeeper(resolverSchedule: ["Fast": 2, "Slow": 5])
        
        // Send "Slow" first, then "Fast" - order of submission doesn't matter;
        // execution order is determined by resolvedAt (mock schedule).
        await keeper.handleAction(name: "Slow", resolvesAtTick: 5)
        await keeper.handleAction(name: "Fast", resolvesAtTick: 2)
        
        // Let async tasks enqueue (they complete immediately with mock)
        await keeper.waitForPendingTasks()
        
        // Run ticks - Fast (resolvedAt 2) executes at tick 3, Slow (resolvedAt 5) at tick 6
        for _ in 0..<10 {
            await keeper.runTick()
        }
        
        let history = await keeper.getHistory()
        
        #expect(!history.isEmpty, "History should not be empty")
        
        let fastIndex = history.firstIndex { $0.contains("Fast") }
        let slowIndex = history.firstIndex { $0.contains("Slow") }
        
        #expect(fastIndex != nil, "Fast action missing")
        #expect(slowIndex != nil, "Slow action missing")
        
        if let f = fastIndex, let s = slowIndex {
            #expect(f < s, "Fast action should execute before Slow action (Fast resolvedAt=2 < Slow resolvedAt=5)")
        }
    }

    @Test("Verify Replay Mode matches Live Mode")
    func testReplayMode() async throws {
        // 1. Live Run - use mock schedule, no real time
        let liveKeeper = MockLandKeeper(resolverSchedule: ["Action1": 2, "Action2": 4])
        await liveKeeper.handleAction(name: "Action1", resolvesAtTick: 2)
        await liveKeeper.handleAction(name: "Action2", resolvesAtTick: 4)
        
        await liveKeeper.waitForPendingTasks()
        
        for _ in 0..<8 {
            await liveKeeper.runTick()
        }
        
        let liveHistory = await liveKeeper.getHistory()
        let recordedData = await liveKeeper.getRecorder()
        
        #expect(!liveHistory.isEmpty)
        
        // 2. Replay Run
        let replayKeeper = MockLandKeeper(replayData: recordedData)
        
        for _ in 0..<8 {
            await replayKeeper.runTick()
        }
        
        let replayHistory = await replayKeeper.getHistory()
        
        #expect(replayHistory == liveHistory, "Replay history must match Live history")
    }
}
