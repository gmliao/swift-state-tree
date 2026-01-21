// Tests/SwiftStateTreeTests/AsyncResolverConsistencyTests.swift
//
// Deterministic re-evaluation consistency test:
// - Live mode: schedule random joins/leaves/actions over ticks, record, hash per tick
// - Re-evaluation mode: load record, step ticks deterministically, hash per tick, compare

import Foundation
import Testing
@testable import SwiftStateTree
import Logging

// MARK: - Test State

@StateNodeBuilder
struct AsyncResolverConsistencyTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    @Sync(.broadcast)
    var playersJoined: [String: Int] = [:]

    @Sync(.broadcast)
    var counter: Int = 0

    public init() {}
}

// MARK: - Test Actions

@Payload
struct IncrementCounterConsistencyAction: ActionPayload {
    typealias Response = IncrementCounterConsistencyResponse
    let amount: Int
}

@Payload
struct IncrementCounterConsistencyResponse: ResponsePayload {
    let newValue: Int
}

// MARK: - Async Resolver

struct SlowDeterministicConsistencyResolver: ContextResolver {
    typealias Output = SlowDeterministicConsistencyOutput

    static func resolve(ctx: ResolverContext) async throws -> SlowDeterministicConsistencyOutput {
        // Simulate async latency; important: actor yields while sleeping.
        try await Task.sleep(for: .milliseconds(25))

        // Deterministic output (Hashable is NOT deterministic, so use DeterministicHash)
        let stable = DeterministicHash.stableInt32(ctx.playerID.rawValue)
        return SlowDeterministicConsistencyOutput(stableInt: stable)
    }
}

struct SlowDeterministicConsistencyOutput: ResolverOutput {
    let stableInt: Int32
}

// MARK: - Test Land Definition

private func createConsistencyTestLandDefinition() -> LandDefinition<AsyncResolverConsistencyTestState> {
    Land("async-resolver-consistency-test", using: AsyncResolverConsistencyTestState.self) {
        Rules {
            OnJoin(resolvers: SlowDeterministicConsistencyResolver.self) { (state: inout AsyncResolverConsistencyTestState, ctx: LandContext) in
                state.playersJoined[ctx.playerID.rawValue] = Int((ctx.slowDeterministicConsistency as SlowDeterministicConsistencyOutput?)?.stableInt ?? 0)
            }

            OnLeave(resolvers: SlowDeterministicConsistencyResolver.self) { (state: inout AsyncResolverConsistencyTestState, ctx: LandContext) in
                state.playersJoined.removeValue(forKey: ctx.playerID.rawValue)
            }

            HandleAction(IncrementCounterConsistencyAction.self, resolvers: SlowDeterministicConsistencyResolver.self) {
                (state: inout AsyncResolverConsistencyTestState, action: IncrementCounterConsistencyAction, ctx: LandContext) in
                let bias = Int((ctx.slowDeterministicConsistency as SlowDeterministicConsistencyOutput?)?.stableInt ?? 0) % 7
                state.counter += action.amount + bias
                return IncrementCounterConsistencyResponse(newValue: state.counter)
            }
        }

        Lifetime {
            // Interval won't be used in this test because we run with autoStartLoops:false and manual stepping.
            Tick(every: .seconds(3600)) { (state: inout AsyncResolverConsistencyTestState, _: LandContext) in
                state.ticks += 1
            }
        }
    }
}

// MARK: - Deterministic Hash

private func hashState(_ state: AsyncResolverConsistencyTestState) -> String {
    let syncEngine = SyncEngine()
    let snapshot: StateSnapshot
    do {
        snapshot = try syncEngine.snapshot(from: state, mode: .all)
    } catch {
        return "error"
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(snapshot) else {
        return "error"
    }
    return DeterministicHash.toHex64(DeterministicHash.fnv1a64(data))
}

// MARK: - Scheduling

private enum ScheduledOp {
    case join(player: String)
    case leave(player: String)
    case action(player: String, amount: Int)
}

private struct LcgRng {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    mutating func nextInt(_ upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}

private func buildSchedule(seed: UInt64, totalTicks: Int, players: [String]) -> [Int: [ScheduledOp]] {
    var rng = LcgRng(seed: seed)
    var schedule: [Int: [ScheduledOp]] = [:]

    // Join each player at a deterministic random tick in [0, totalTicks/4)
    var joinTickByPlayer: [String: Int] = [:]
    for p in players {
        let t = rng.nextInt(max(1, totalTicks / 4))
        joinTickByPlayer[p] = t
        schedule[t, default: []].append(.join(player: p))
    }

    // Random leaves for half players after they joined
    for p in players.enumerated().compactMap({ idx, p in idx % 2 == 0 ? p : nil }) {
        let joinTick = joinTickByPlayer[p] ?? 0
        let leaveTick = min(totalTicks - 1, joinTick + 5 + rng.nextInt(max(1, totalTicks / 2)))
        schedule[leaveTick, default: []].append(.leave(player: p))
    }

    // Random actions on random ticks after join; avoid acting before join
    let actionCount = totalTicks * 2
    for _ in 0..<actionCount {
        let p = players[rng.nextInt(players.count)]
        let joinTick = joinTickByPlayer[p] ?? 0
        let t = joinTick + 1 + rng.nextInt(max(1, totalTicks - joinTick - 1))
        let amount = 1 + rng.nextInt(5)
        schedule[t, default: []].append(.action(player: p, amount: amount))
    }

    return schedule
}

// MARK: - Test

@Test("Verify deterministic replay consistency with async resolvers and randomized scheduling")
func testAsyncResolverConsistency() async throws {
    let logger = createColoredLogger(
        loggerIdentifier: "com.swiftstatetree.async-test",
        scope: "AsyncResolverConsistencyTest"
    )

    let totalTicks = 80
    let seed: UInt64 = 0xC0FFEE
    let players = (0..<5).map { "p\($0)" }
    let schedule = buildSchedule(seed: seed, totalTicks: totalTicks, players: players)

    let tempDir = FileManager.default.temporaryDirectory
    let recordingFile = tempDir.appendingPathComponent("async-resolver-test-\(UUID().uuidString).json")

    defer {
        try? FileManager.default.removeItem(at: recordingFile)
    }

    let liveHashes = try await runLive(
        totalTicks: totalTicks,
        seed: seed,
        players: players,
        schedule: schedule,
        recordingFile: recordingFile.path,
        logger: logger
    )

    let replayHashes = try await runReevaluation(
        recordingFile: recordingFile.path,
        logger: logger
    )

    let maxTickId = max(liveHashes.keys.max() ?? -1, replayHashes.keys.max() ?? -1)
    var mismatches: [(Int64, String, String)] = []
    for tickId in 0...maxTickId {
        let a = liveHashes[tickId] ?? "missing"
        let b = replayHashes[tickId] ?? "missing"
        if a != b {
            mismatches.append((tickId, a, b))
        }
    }

    if !mismatches.isEmpty {
        var message = "Deterministic replay FAILED. Mismatches: \(mismatches.count)\n"
        for (tickId, a, b) in mismatches.prefix(10) {
            message += "  tick \(tickId): live=\(a) replay=\(b)\n"
        }
        struct ConsistencyTestError: Error {
            let message: String
        }
        Issue.record(ConsistencyTestError(message: message))
    }
    
    #expect(mismatches.isEmpty, "All ticks should match between live and replay modes")
}

// MARK: - Helper Functions

private func runLive(
    totalTicks: Int,
    seed: UInt64,
    players: [String],
    schedule: [Int: [ScheduledOp]],
    recordingFile: String,
    logger: Logger
) async throws -> [Int64: String] {
    let definition = createConsistencyTestLandDefinition()
    let keeper = LandKeeper<AsyncResolverConsistencyTestState>(
        definition: definition,
        initialState: AsyncResolverConsistencyTestState(),
        autoStartLoops: false
    )

    // Set record metadata (required)
    if let recorder = await keeper.getReevaluationRecorder() {
        let meta = ReevaluationRecordMetadata(
            landID: "async-resolver-consistency-test:local",
            landType: "async-resolver-consistency-test",
            createdAt: Date(),
            metadata: [
                "mapId": "test-map",
                "seed": "\(seed)"
            ],
            landDefinitionID: definition.id,
            initialStateHash: nil,
            landConfig: ["autoStartLoops": AnyCodable(false)],
            rngSeed: seed,
            ruleVariantId: nil,
            ruleParams: nil,
            version: "1.0",
            extensions: nil
        )
        await recorder.setMetadata(meta)
    }

    var opTasks: [Task<Void, Error>] = []
    var hashes: [Int64: String] = [:]

    for tick in 0..<totalTicks {
        if let ops = schedule[tick] {
            for op in ops {
                switch op {
                case .join(let player):
                    opTasks.append(Task {
                        try await keeper.join(
                            playerID: PlayerID(player),
                            clientID: ClientID("c-\(player)"),
                            sessionID: SessionID("s-\(player)")
                        )
                    })
                case .leave(let player):
                    opTasks.append(Task {
                        try await keeper.leave(
                            playerID: PlayerID(player),
                            clientID: ClientID("c-\(player)")
                        )
                    })
                case .action(let player, let amount):
                    opTasks.append(Task {
                        let envelope = ActionEnvelope(
                            typeIdentifier: String(describing: IncrementCounterConsistencyAction.self),
                            payload: AnyCodable(IncrementCounterConsistencyAction(amount: amount))
                        )
                        _ = try await keeper.handleActionEnvelope(
                            envelope,
                            playerID: PlayerID(player),
                            clientID: ClientID("c-\(player)"),
                            sessionID: SessionID("s-\(player)")
                        )
                    })
                }
            }
        }

        await keeper.stepTickOnce()
        let state = await keeper.currentState()
        hashes[Int64(tick)] = hashState(state)
    }

    // Wait for all async resolver tasks to complete, then flush a few more ticks.
    for t in opTasks {
        _ = try await t.value
    }

    for i in 0..<10 {
        await keeper.stepTickOnce()
        let tickId = Int64(totalTicks + i)
        let state = await keeper.currentState()
        hashes[tickId] = hashState(state)
    }

    guard let recorder = await keeper.getReevaluationRecorder() else {
        throw NSError(domain: "AsyncResolverConsistencyTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "ReevaluationRecorder not available"
        ])
    }
    try await recorder.save(to: recordingFile)
    logger.info("Recording saved", metadata: ["file": .string(recordingFile)])

    return hashes
}

private func runReevaluation(
    recordingFile: String,
    logger: Logger
) async throws -> [Int64: String] {
    let definition = createConsistencyTestLandDefinition()
    let source = try JSONReevaluationSource(filePath: recordingFile)
    let maxTickId = try await source.getMaxTickId()

    let keeper = LandKeeper<AsyncResolverConsistencyTestState>(
        definition: definition,
        initialState: AsyncResolverConsistencyTestState(),
        mode: .reevaluation,
        reevaluationSource: source,
        autoStartLoops: false
    )

    var hashes: [Int64: String] = [:]
    for tickId in 0...maxTickId {
        await keeper.stepTickOnce()
        let state = await keeper.currentState()
        hashes[tickId] = hashState(state)
    }

    logger.info("Re-evaluation completed", metadata: [
        "maxTickId": .stringConvertible(maxTickId)
    ])
    return hashes
}
