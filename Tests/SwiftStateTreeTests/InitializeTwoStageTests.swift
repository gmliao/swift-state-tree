// Tests/SwiftStateTreeTests/InitializeTwoStageTests.swift
//
// OnInitialize in two stages (#593): `validate` reads the state and the resolver outputs and may
// throw; `apply` writes and can't. A live `validate` throw fails the initialization as an
// OnInitialize resolver failure with `.failLand` does, with nothing written or recorded. A record
// holds OnInitialize only when the live `validate` passed, so a replayed `validate` that throws
// fails the initialize check, at both replay sites (the initialize record before tick 0, and the
// lifecycle item inside tick 0 of a record without one).

import Foundation
import Logging
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeReevaluationMonitor

// MARK: - The docs' example (docs/core/land-dsl.md, "An Initialization That Can Be Refused")

@StateNodeBuilder
struct RoomState: StateNodeProtocol {
    @Sync(.broadcast)
    var maxPlayers: Int = 0
    /// What ran, in order, for the tests: "finalize", "destroyWhenEmpty".
    @Sync(.broadcast)
    var log: [String] = []

    init() {}
}

struct RoomConfigOutput: ResolverOutput {
    let maxPlayers: Int
}

enum RoomSetupError: Error, Equatable {
    case noConfig
}

/// Throws for a land ID that contains "missing"; otherwise a room for 4.
struct RoomConfigResolver: ContextResolver {
    typealias Output = RoomConfigOutput
    static func resolve(ctx: ResolverContext) async throws -> RoomConfigOutput {
        if ctx.landID.contains("missing") { throw RoomSetupError.noConfig }
        return RoomConfigOutput(maxPlayers: 4)
    }
}

/// The docs' block, with destroy handlers that log, so a test can see they didn't run.
private func makeRoomDefinition() -> LandDefinition<RoomState> {
    Land("room", using: RoomState.self) {
        Lifetime {
            OnInitialize(
                resolvers: RoomConfigResolver.self,
                onResolverFailure: .continue,
                validate: { (_: RoomState, ctx: ValidateContext) throws -> RoomConfigOutput in
                    guard let config: RoomConfigOutput = ctx.roomConfig else { throw RoomSetupError.noConfig }
                    return config
                },
                apply: { (state: inout RoomState, config: RoomConfigOutput, _: LandContext) in
                    state.maxPlayers = config.maxPlayers
                }
            )
            OnFinalize { (state: inout RoomState, _: LandContext) in state.log.append("finalize") }
            DestroyWhenEmpty(after: .seconds(3600)) { (state: inout RoomState, _: LandContext) in
                state.log.append("destroyWhenEmpty")
            }
        }
    }
}

// MARK: - The replay land: a validate the test can make refuse

/// The land IDs whose OnInitialize `validate` refuses: the test flips one between the live run
/// and its replay. Keyed by land ID, so parallel tests don't share an entry.
private enum InitializeRefusals {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var landIDs: Set<String> = []

    static func refuse(_ landID: String) { lock.withLock { _ = landIDs.insert(landID) } }
    static func isRefused(_ landID: String) -> Bool { lock.withLock { landIDs.contains(landID) } }
}

private struct ReplayRefusedError: Error, Equatable, CustomStringConvertible {
    var description: String { "ReplayRefusedError" }
}

/// A tick land whose OnInitialize writes its plan; `voidForm` picks the form without a plan.
private func makeReplayDefinition(voidForm: Bool = false) -> LandDefinition<RoomState> {
    let refuse: @Sendable (ValidateContext) throws -> Void = { ctx in
        if InitializeRefusals.isRefused(ctx.landID) { throw ReplayRefusedError() }
    }
    if voidForm {
        return Land("init-replay", using: RoomState.self) {
            Lifetime {
                Tick(every: .milliseconds(50)) { (_: inout RoomState, _: LandContext) in }
                OnInitialize(validate: { (_: RoomState, ctx: ValidateContext) in
                    try refuse(ctx)
                }, apply: { (state: inout RoomState, _: LandContext) in
                    state.maxPlayers = 2
                })
            }
        }
    }
    return Land("init-replay", using: RoomState.self) {
        Lifetime {
            Tick(every: .milliseconds(50)) { (_: inout RoomState, _: LandContext) in }
            OnInitialize(resolvers: RoomConfigResolver.self, validate: { (_: RoomState, ctx: ValidateContext) throws -> Int in
                try refuse(ctx)
                guard let config: RoomConfigOutput = ctx.roomConfig else { throw RoomSetupError.noConfig }
                return config.maxPlayers
            }, apply: { (state: inout RoomState, maxPlayers: Int, _: LandContext) in
                state.maxPlayers = maxPlayers
            })
        }
    }
}

// MARK: - Helpers

/// Notes `onLandDestroyed` (and wakes `waitUntilDestroyed()`), and counts the events the keeper
/// sends in turn.
private final class InitStageTransport: LandKeeperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var destroyedFlag = false
    private var destroyWaiters: [CheckedContinuation<Void, Never>] = []
    private var sent = 0
    var destroyed: Bool { lock.withLock { destroyedFlag } }
    var eventsSent: Int { lock.withLock { sent } }

    /// Returns once the keeper has called `onLandDestroyed`.
    func waitUntilDestroyed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if destroyedFlag { return true }
                destroyWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async { lock.withLock { sent += 1 } }
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            destroyedFlag = true
            defer { destroyWaiters = [] }
            return destroyWaiters
        }
        waiters.forEach { $0.resume() }
    }
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        lock.withLock { sent += events.count }
        return InTurnSyncOutput(includeSync ? .committed(clearDirtyFlags: true) : .notRequested)
    }
    func waitForWriterDrainForInTurnSync() async {}
}

private let player = PlayerID("p-1")
private let client = ClientID("c-p-1")
private let session = SessionID("s-p-1")

/// A keeper whose land ID is set before anything waits for the initialization. With
/// `recording`, its recorder gets the metadata a saved record needs.
private func makeKeeper(
    _ definition: LandDefinition<RoomState>,
    landID: String,
    recording: Bool = false,
    transport: InitStageTransport = InitStageTransport()
) async throws -> LandKeeper<RoomState> {
    let keeper = LandKeeper<RoomState>(
        definition: definition,
        initialState: RoomState(),
        enableLiveStateHashRecording: recording,
        autoStartLoops: false,
        transport: transport
    )
    await keeper.setLandID(landID)
    if recording {
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: landID,
            landType: definition.id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            landDefinitionID: definition.id,
            rngSeed: DeterministicSeed.fromLandID(landID),
            version: ReevaluationRecordVersion.current
        ))
    }
    return keeper
}

/// The initialization failed with `expected`: a join is denied as retryable, a leave throws
/// `LandInitializationError`, the land is torn down, and the state is the initial one (no
/// handler wrote, the destroy handlers included).
private func expectRefused<E: Error & Equatable>(
    _ keeper: LandKeeper<RoomState>,
    _ transport: InitStageTransport,
    with expected: E,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    do {
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        Issue.record("Expected landShuttingDown", sourceLocation: sourceLocation)
    } catch let error as JoinError {
        if case .landShuttingDown = error {} else { Issue.record("Unexpected join error: \(error)", sourceLocation: sourceLocation) }
    }
    do {
        try await keeper.leave(playerID: player, clientID: client, sessionID: session)
        Issue.record("Expected LandInitializationError", sourceLocation: sourceLocation)
    } catch let error as LandInitializationError {
        #expect(error.underlying as? E == expected, "the refusal is the error", sourceLocation: sourceLocation)
    }
    _ = try await withinDeadline("the land is torn down", sourceLocation: sourceLocation) { () async -> Void in
        await transport.waitUntilDestroyed()
    }
    let state = await keeper.currentState()
    #expect(state.maxPlayers == 0 && state.log == [], "nothing was written, not by a destroy handler either", sourceLocation: sourceLocation)
    #expect(transport.eventsSent == 0, sourceLocation: sourceLocation)
}

/// The record's JSON view at a temporary path (removed by the caller). With
/// `dropInitializeRecord`, frame 0 loses its initialize record: OnInitialize then replays as
/// tick 0's lifecycle item, as for a record older than 2.1.
private func saveRecord(_ keeper: LandKeeper<RoomState>, dropInitializeRecord: Bool) async throws -> String {
    await keeper.waitForRecorderSubmissionsForTesting()
    let recorder = try #require(await keeper.getReevaluationRecorder())
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("init-two-stage-\(UUID().uuidString).sstr").path
    try await recorder.save(to: path)
    try ReevaluationRecordFile.convertToJSONViewForTesting(atPath: path)
    let jsonPath = path + ".json"
    try FileManager.default.moveItem(atPath: path, toPath: jsonPath)
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: jsonPath))) as? [String: Any])
    if dropInitializeRecord {
        var frames = try #require(object["tickFrames"] as? [[String: Any]])
        let index = try #require(frames.firstIndex { $0["initialize"] != nil }, "the live run recorded an initialize record")
        frames[index].removeValue(forKey: "initialize")
        object["tickFrames"] = frames
    }
    try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: jsonPath))
    return jsonPath
}

/// A live run that initializes, joins and ticks twice, recorded; its land ID.
private func recordLiveRun(_ definition: LandDefinition<RoomState>, dropInitializeRecord: Bool) async throws -> (path: String, landID: String) {
    let landID = "init-replay:\(UUID().uuidString)"
    let keeper = try await makeKeeper(definition, landID: landID, recording: true)
    try await keeper.join(playerID: player, clientID: client, sessionID: session)
    await keeper.stepTickOnce()
    await keeper.stepTickOnce()
    return (try await saveRecord(keeper, dropInitializeRecord: dropInitializeRecord), landID)
}

/// The monitor's runner over the whole record: its initialize verdict after the last step.
private func runnerVerdict(_ definition: LandDefinition<RoomState>, _ path: String) async throws -> ReevaluationEngine.InitializeVerification {
    let runner = try await ConcreteReevaluationRunner(definition: definition, recordFilePath: path)
    try await runner.prepare()
    while try await runner.step() != nil {}
    return await runner.initializeVerification()
}

/// A verdict that failed because OnInitialize's `validate` threw in replay, naming the error.
private func expectReplayRefusal(_ verdict: ReevaluationEngine.InitializeVerification, sourceLocation: SourceLocation = #_sourceLocation) {
    guard case .failed(let reason) = verdict else {
        Issue.record("expected a failed initialize check, got \(verdict)", sourceLocation: sourceLocation)
        return
    }
    #expect(reason.contains("OnInitialize's validate threw in replay"), "\(reason)", sourceLocation: sourceLocation)
    #expect(reason.contains("ReplayRefusedError"), "\(reason)", sourceLocation: sourceLocation)
}

// MARK: - Destroy handlers (#593 §1)

/// Throws, so the destroy handler it belongs to is skipped.
struct FailingFinalizeResolver: ContextResolver {
    typealias Output = RoomConfigOutput
    static func resolve(ctx: ResolverContext) async throws -> RoomConfigOutput {
        throw RoomSetupError.noConfig
    }
}

/// OnDestroyWhenEmpty and OnFinalize log; with `failingResolver`, OnFinalize's resolver throws.
private func makeDestroyDefinition(failingResolver: Bool) -> LandDefinition<RoomState> {
    let destroyWhenEmpty: LifetimeDirective<RoomState> = DestroyWhenEmpty(after: .seconds(3600)) { (state: inout RoomState, _: LandContext) in
        state.log.append("destroyWhenEmpty")
    }
    if failingResolver {
        return Land("destroy-handlers", using: RoomState.self) {
            Lifetime {
                destroyWhenEmpty
                OnFinalize(resolvers: FailingFinalizeResolver.self) { (state: inout RoomState, _: LandContext) in
                    state.log.append("finalize")
                }
            }
        }
    }
    return Land("destroy-handlers", using: RoomState.self) {
        Lifetime {
            destroyWhenEmpty
            OnFinalize { (state: inout RoomState, _: LandContext) in state.log.append("finalize") }
        }
    }
}

// MARK: - Tests

@Suite("OnInitialize in two stages (#593)", .timeLimit(.minutes(1)))
struct InitializeTwoStageTests {
    @Test("The docs' example: with .continue, a resolver that throws leaves no config, and validate refuses: the initialization fails with nothing written; log only, no metric")
    func refusalFailsTheInitialization() async throws {
        let metrics = ResolverDeadlineMetrics(), transport = InitStageTransport()
        try await ResolverDeadline.$metricsForTesting.withValue(metrics) {
            let keeper = try await makeKeeper(makeRoomDefinition(), landID: "room:missing:\(UUID().uuidString)", transport: transport)
            try await expectRefused(keeper, transport, with: RoomSetupError.noConfig)
        }
        #expect(metrics.snapshot.initFailures == 0, "a refusal is not a resolver failure")
    }

    @Test("A refusal records nothing: no initialize record, no lifecycle event")
    func refusalRecordsNothing() async throws {
        let transport = InitStageTransport()
        let keeper = try await makeKeeper(makeRoomDefinition(), landID: "room:missing:\(UUID().uuidString)", recording: true, transport: transport)
        try await expectRefused(keeper, transport, with: RoomSetupError.noConfig)
        await keeper.waitForRecorderSubmissionsForTesting()
        let frames = await (try #require(await keeper.getReevaluationRecorder())).getAllFrames()
        #expect(frames.allSatisfy { $0.initialize == nil && $0.lifecycleEvents.isEmpty }, "\(frames)")
    }

    @Test("The docs' example: validate reads the resolver's output, and apply gets it as the plan")
    func validatePassesThePlan() async throws {
        let keeper = try await makeKeeper(makeRoomDefinition(), landID: "room:ok:\(UUID().uuidString)")
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        #expect(await keeper.currentState().maxPlayers == 4)
    }

    @Test("The form without a plan: apply runs after validate passes, and nothing runs after validate refuses")
    func voidForm() async throws {
        let passing = try await makeKeeper(makeReplayDefinition(voidForm: true), landID: "init-replay:\(UUID().uuidString)")
        try await passing.join(playerID: player, clientID: client, sessionID: session)
        #expect(await passing.currentState().maxPlayers == 2)

        let landID = "init-replay:\(UUID().uuidString)"
        InitializeRefusals.refuse(landID)
        let transport = InitStageTransport()
        let refused = try await makeKeeper(makeReplayDefinition(voidForm: true), landID: landID, transport: transport)
        try await expectRefused(refused, transport, with: ReplayRefusedError())
    }

    @Test("InitializeHandler's public inits run as the DSL's forms do")
    func handlerInits() throws {
        let ctx = LandContext(
            landID: "init-handler",
            playerID: player,
            clientID: client,
            sessionID: session,
            services: LandServices(),
            logger: Logger(label: "test"),
            deviceID: nil,
            metadata: [:],
            emitEventHandler: { _, _ in },
            requestSyncNowHandler: { },
            requestSyncBroadcastOnlyHandler: { }
        )
        var state = RoomState()
        try InitializeHandler<RoomState> { (state: inout RoomState, _: LandContext) in state.maxPlayers = 1 }.invoke(&state, ctx)
        #expect(state.maxPlayers == 1)
        try InitializeHandler<RoomState>(validate: { (state: RoomState, _: ValidateContext) -> Int in state.maxPlayers + 1 },
                                         apply: { (state: inout RoomState, next: Int, _: LandContext) in state.maxPlayers = next }).invoke(&state, ctx)
        #expect(state.maxPlayers == 2)
        let refusing = InitializeHandler<RoomState>(validate: { (_: RoomState, _: ValidateContext) in throw RoomSetupError.noConfig },
                                                    apply: { (state: inout RoomState, _: LandContext) in state.maxPlayers = 9 })
        #expect(throws: RoomSetupError.noConfig) { try refusing.invoke(&state, ctx) }
        #expect(state.maxPlayers == 2, "apply didn't run")
    }

    @Test("A recorded OnInitialize replays through validate and apply, with the state hashes equal", arguments: [false, true])
    func replayPasses(dropInitializeRecord: Bool) async throws {
        let definition = makeReplayDefinition()
        let (path, _) = try await recordLiveRun(definition, dropInitializeRecord: dropInitializeRecord)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ReevaluationEngine.run(definition: definition, initialState: RoomState(), recordFilePath: path)
        #expect(result.initialize == (dropInitializeRecord ? .notRecorded : .passed))
        #expect(!result.recordedStateHashes.isEmpty)
        #expect(result.tickHashes == result.recordedStateHashes)
        #expect(try await runnerVerdict(definition, path) == (dropInitializeRecord ? .notRecorded : .passed))
    }

    @Test("A replayed validate that throws fails the initialize check, through the engine and the runner, at both replay sites", arguments: [false, true])
    func replayedRefusalFailsTheCheck(dropInitializeRecord: Bool) async throws {
        let definition = makeReplayDefinition()
        let (path, landID) = try await recordLiveRun(definition, dropInitializeRecord: dropInitializeRecord)
        defer { try? FileManager.default.removeItem(atPath: path) }
        // The live validate passed; the replay's refuses: validate was not deterministic.
        InitializeRefusals.refuse(landID)
        let result = try await ReevaluationEngine.run(definition: definition, initialState: RoomState(), recordFilePath: path)
        expectReplayRefusal(result.initialize)
        #expect(result.tickHashes != result.recordedStateHashes, "nothing was written, so the replayed state differs")
        expectReplayRefusal(try await runnerVerdict(definition, path))
    }

    @Test("Destroy handlers: each runs exactly once; a resolver that throws skips its handler, and the teardown goes on", arguments: [false, true])
    func destroyHandlers(failingResolver: Bool) async throws {
        let transport = InitStageTransport()
        let keeper = try await makeKeeper(makeDestroyDefinition(failingResolver: failingResolver), landID: "destroy:\(UUID().uuidString)", transport: transport)
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        await keeper.forceShutdown()
        #expect(transport.destroyed, "the teardown finished")
        #expect(await keeper.currentState().log == (failingResolver ? ["destroyWhenEmpty"] : ["destroyWhenEmpty", "finalize"]))
    }
}
