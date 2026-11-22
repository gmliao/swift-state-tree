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

@Payload
struct RoomOpenedEvent: ServerEventPayload {
    let maxPlayers: Int
}

/// `apply`'s outputs: it logs the land ID it sees (so a replay that sees another ID diverges),
/// emits an event and requests a sync, so a refusal's "nothing goes out" can fail.
private func openRoom(_ state: inout RoomState, maxPlayers: Int, _ ctx: LandContext) {
    state.maxPlayers = maxPlayers
    state.log.append("init:\(ctx.landID)")
    ctx.emitEvent(RoomOpenedEvent(maxPlayers: maxPlayers), to: .all)
    ctx.requestSyncNow()
}

/// A tick land (or, with `tickless`, a land without a tick handler) whose OnInitialize writes its
/// plan; `voidForm` picks the form without a plan.
private func makeReplayDefinition(voidForm: Bool = false, tickless: Bool = false) -> LandDefinition<RoomState> {
    let refuse: @Sendable (ValidateContext) throws -> Void = { ctx in
        if InitializeRefusals.isRefused(ctx.landID) { throw ReplayRefusedError() }
    }
    let onInitialize: LifetimeDirective<RoomState> = voidForm
        ? OnInitialize(validate: { (_: RoomState, ctx: ValidateContext) in
            try refuse(ctx)
        }, apply: { (state: inout RoomState, ctx: LandContext) in
            openRoom(&state, maxPlayers: 2, ctx)
        })
        : OnInitialize(resolvers: RoomConfigResolver.self, validate: { (_: RoomState, ctx: ValidateContext) throws -> Int in
            try refuse(ctx)
            guard let config: RoomConfigOutput = ctx.roomConfig else { throw RoomSetupError.noConfig }
            return config.maxPlayers
        }, apply: { (state: inout RoomState, maxPlayers: Int, ctx: LandContext) in
            openRoom(&state, maxPlayers: maxPlayers, ctx)
        })
    if tickless {
        return Land("init-replay", using: RoomState.self) {
            ServerEvents { Register(RoomOpenedEvent.self) }
            Lifetime { onInitialize }
        }
    }
    return Land("init-replay", using: RoomState.self) {
        ServerEvents { Register(RoomOpenedEvent.self) }
        Lifetime {
            Tick(every: .milliseconds(50)) { (_: inout RoomState, _: LandContext) in }
            onInitialize
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
    private var syncs = 0
    var destroyed: Bool { lock.withLock { destroyedFlag } }
    var eventsSent: Int { lock.withLock { sent } }
    var syncsRun: Int { lock.withLock { syncs } }

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
        lock.withLock {
            sent += events.count
            if includeSync { syncs += 1 }
        }
        return InTurnSyncOutput(includeSync ? .committed(clearDirtyFlags: true) : .notRequested)
    }
    func waitForWriterDrainForInTurnSync() async {}
}

private let player = PlayerID("p-1")
private let client = ClientID("c-p-1")
private let session = SessionID("s-p-1")

/// A keeper built with its land ID, before its eager initialization can start. With
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
        // At construction: the eager initialization reads it (`ctx.landID`).
        landID: landID,
        transport: transport
    )
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
    #expect(transport.eventsSent == 0 && transport.syncsRun == 0, "nothing went out", sourceLocation: sourceLocation)
}

/// The record's JSON view at a temporary path (removed by the caller). With
/// `dropInitializeRecord`, frame 0 loses its initialize record: OnInitialize then replays as
/// tick 0's lifecycle item, as for a record older than 2.1.
/// With `moveInitializeToTickOne`, a malformed record: no initialize record, and the initialize
/// lifecycle item in tick 1 instead of tick 0.
private func saveRecord(_ keeper: LandKeeper<RoomState>, dropInitializeRecord: Bool, moveInitializeToTickOne: Bool = false) async throws -> String {
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
        if moveInitializeToTickOne {
            let from = try #require(frames.firstIndex { ($0["tickId"] as? Int) == 0 })
            let to = try #require(frames.firstIndex { ($0["tickId"] as? Int) == 1 })
            var events = try #require(frames[from]["lifecycleEvents"] as? [[String: Any]])
            let item = try #require(events.firstIndex { ($0["kind"] as? String) == LandKeeper<RoomState>.LifecycleKind.initialize.rawValue })
            var moved = events.remove(at: item)
            moved["tickId"] = 1
            frames[from]["lifecycleEvents"] = events
            frames[to]["lifecycleEvents"] = [moved] + ((frames[to]["lifecycleEvents"] as? [[String: Any]]) ?? [])
        }
        object["tickFrames"] = frames
    }
    try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: jsonPath))
    return jsonPath
}

/// A live run that initializes, joins and (on a tick land) ticks twice, recorded; its land ID.
private func recordLiveRun(
    _ definition: LandDefinition<RoomState>,
    dropInitializeRecord: Bool,
    tickless: Bool = false
) async throws -> (path: String, landID: String) {
    let landID = "init-replay:\(UUID().uuidString)"
    let keeper = try await makeKeeper(definition, landID: landID, recording: true)
    try await keeper.join(playerID: player, clientID: client, sessionID: session)
    if !tickless {
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
    }
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

// MARK: - Waiters, .failLand, the hosted run

/// OnInitialize's resolver, held at the gate keyed by the land ID's last part
/// ("init-wait:<key>"), then a room for 4.
struct GatedRoomConfigResolver: ContextResolver {
    typealias Output = RoomConfigOutput
    static func resolve(ctx: ResolverContext) async throws -> RoomConfigOutput {
        let key = Int(ctx.landID.split(separator: ":").last ?? "") ?? 0
        await DeliveryGates.gate(key).enterAndWait()
        return RoomConfigOutput(maxPlayers: 4)
    }
}

@Payload
struct InitWaitAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct InitWaitAction: ActionPayload {
    typealias Response = InitWaitAck
    let n: Int
}

struct InitWaitInput: ServerInputPayload {
    let n: Int
}

/// A land whose OnInitialize waits at its resolver's gate and then refuses; an action and a
/// server input are declared, so calls of each kind can wait for the initialization.
private func makeWaitDefinition() -> LandDefinition<RoomState> {
    Land("init-wait", using: RoomState.self) {
        Rules {
            HandleAction(InitWaitAction.self) { (state: inout RoomState, _: InitWaitAction, _: LandContext) in
                state.log.append("action")
                return InitWaitAck(ok: true)
            }
            HandleServerInput(InitWaitInput.self) { (state: inout RoomState, _: InitWaitInput, _: LandContext) in
                state.log.append("input")
            }
        }
        Lifetime {
            OnInitialize(resolvers: GatedRoomConfigResolver.self, validate: { (_: RoomState, _: ValidateContext) in
                throw RoomSetupError.noConfig
            }, apply: { (state: inout RoomState, _: LandContext) in
                state.log.append("init")
            })
        }
    }
}

/// The land IDs whose OnInitialize `validate` ran: a resolver failure with `.failLand` must stop
/// the initialization before it.
private enum ValidateRuns {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var landIDs: Set<String> = []

    static func note(_ landID: String) { lock.withLock { _ = landIDs.insert(landID) } }
    static func ran(_ landID: String) -> Bool { lock.withLock { landIDs.contains(landID) } }
}

/// A two-stage OnInitialize with the default `.failLand`, whose resolver throws for a land ID
/// that contains "missing".
private func makeFailLandDefinition() -> LandDefinition<RoomState> {
    Land("init-fail-land", using: RoomState.self) {
        Lifetime {
            OnInitialize(resolvers: RoomConfigResolver.self, validate: { (_: RoomState, ctx: ValidateContext) -> Int in
                ValidateRuns.note(ctx.landID)
                return 1
            }, apply: { (state: inout RoomState, maxPlayers: Int, _: LandContext) in
                state.maxPlayers = maxPlayers
            })
        }
    }
}

/// A tick land whose OnInitialize writes nothing: a replayed refusal leaves every tick hash
/// matching, so only the initialize check can report it.
private func makeNoWriteDefinition() -> LandDefinition<RoomState> {
    Land("init-no-write", using: RoomState.self) {
        Lifetime {
            Tick(every: .milliseconds(50)) { (_: inout RoomState, _: LandContext) in }
            OnInitialize(validate: { (_: RoomState, ctx: ValidateContext) in
                if InitializeRefusals.isRefused(ctx.landID) { throw ReplayRefusedError() }
            }, apply: { (_: inout RoomState, _: LandContext) in })
        }
    }
}

/// Builds the monitor's runner for the record, as a hosted replay does.
private struct InitRunnerFactory: ReevaluationTargetFactory {
    let definition: LandDefinition<RoomState>
    func createRunner(landType _: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        try await ConcreteReevaluationRunner(definition: definition, recordFilePath: recordFilePath)
    }
}

/// A hosted run of the record, to its end: its terminal status.
private func hostedRun(_ definition: LandDefinition<RoomState>, _ path: String) async throws -> ReevaluationStatus {
    let service = ReevaluationRunnerService(factory: InitRunnerFactory(definition: definition))
    service.startVerification(landType: definition.id, recordFilePath: path)
    let task = try #require(service.verificationTaskForTesting(), "no verification run was started")
    await task.value
    return service.getStatus()
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

    @Test("The form without a plan: apply runs after validate passes, with its event and sync, and nothing runs or goes out after validate refuses")
    func voidForm() async throws {
        let passingTransport = InitStageTransport()
        let passing = try await makeKeeper(makeReplayDefinition(voidForm: true), landID: "init-replay:\(UUID().uuidString)", transport: passingTransport)
        try await passing.join(playerID: player, clientID: client, sessionID: session)
        #expect(await passing.currentState().maxPlayers == 2)
        #expect(passingTransport.eventsSent == 1 && passingTransport.syncsRun >= 1, "apply's outputs go out, so the refusal's check can fail")

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

    @Test("A replayed validate that throws fails the initialize check, through the engine and the runner, at both replay sites, on a tick and a tickless land", arguments: [false, true], [false, true])
    func replayedRefusalFailsTheCheck(dropInitializeRecord: Bool, tickless: Bool) async throws {
        let definition = makeReplayDefinition(tickless: tickless)
        let (path, landID) = try await recordLiveRun(definition, dropInitializeRecord: dropInitializeRecord, tickless: tickless)
        defer { try? FileManager.default.removeItem(atPath: path) }
        // The live validate passed; the replay's refuses: validate was not deterministic.
        InitializeRefusals.refuse(landID)
        let result = try await ReevaluationEngine.run(definition: definition, initialState: RoomState(), recordFilePath: path)
        expectReplayRefusal(result.initialize)
        #expect(result.tickHashes != result.recordedStateHashes, "nothing was written, so the replayed state differs")
        expectReplayRefusal(try await runnerVerdict(definition, path))
    }

    @Test("The replay keepers use the record's land ID: apply logs it, and every replayed tick matches, through the engine and both runner inits", arguments: [false, true])
    func replayKeepersUseTheRecordsLandID(dropInitializeRecord: Bool) async throws {
        let definition = makeReplayDefinition()
        let (path, landID) = try await recordLiveRun(definition, dropInitializeRecord: dropInitializeRecord)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let verdict: ReevaluationEngine.InitializeVerification = dropInitializeRecord ? .notRecorded : .passed
        let result = try await ReevaluationEngine.run(definition: definition, initialState: RoomState(), recordFilePath: path)
        #expect(result.initialize == verdict)
        #expect(!result.recordedStateHashes.isEmpty)
        #expect(result.tickHashes == result.recordedStateHashes, "apply logged the record's land ID, \(landID)")
        let runners = [
            try await ConcreteReevaluationRunner(definition: definition, recordFilePath: path),
            try await ConcreteReevaluationRunner(definition: definition, initialState: RoomState(), recordFilePath: path),
        ]
        for runner in runners {
            try await runner.prepare()
            var steps = 0
            while let step = try await runner.step() {
                steps += 1
                #expect(step.isMatch, "tick \(step.tickId): \(step.stateHash) vs \(String(describing: step.recordedHash))")
            }
            #expect(steps > 0)
            #expect(await runner.initializeVerification() == verdict)
        }
    }

    @Test("A malformed record whose OnInitialize replays in tick 1: a refusal there still fails the check, in the engine and the runner")
    func lateInitializeRefusalFailsTheCheck() async throws {
        let definition = makeReplayDefinition()
        let landID = "init-replay:\(UUID().uuidString)"
        let keeper = try await makeKeeper(definition, landID: landID, recording: true)
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        let path = try await saveRecord(keeper, dropInitializeRecord: true, moveInitializeToTickOne: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        InitializeRefusals.refuse(landID)
        expectReplayRefusal(try await ReevaluationEngine.run(definition: definition, initialState: RoomState(), recordFilePath: path).initialize)
        expectReplayRefusal(try await runnerVerdict(definition, path))
    }

    @Test("initializeVerdict: a refusal fails a passed or unrecorded check; an earlier failure keeps its reason; no refusal keeps the verdict")
    func initializeVerdictMerge() {
        typealias Engine = ReevaluationEngine
        #expect(Engine.initializeVerdict(.passed, afterTickRefusal: "later") == .failed(reason: "later"))
        #expect(Engine.initializeVerdict(.notRecorded, afterTickRefusal: "later") == .failed(reason: "later"))
        #expect(Engine.initializeVerdict(.failed(reason: "earlier"), afterTickRefusal: "later") == .failed(reason: "earlier"))
        #expect(Engine.initializeVerdict(.passed, afterTickRefusal: nil) == .passed)
        #expect(Engine.initializeVerdict(.failed(reason: "earlier"), afterTickRefusal: nil) == .failed(reason: "earlier"))
    }

    @Test("Calls waiting while OnInitialize's resolver is held get the refusal: a join JOIN_DENIED, an action LandInitializationError, a server input draining")
    func waitersGetTheRefusal() async throws {
        let key = DeliveryGates.freshKey()
        let transport = InitStageTransport()
        // Released on every exit, a late entry included, so a failed wait doesn't leave the
        // resolver parked.
        defer { DeliveryGates.gate(key).release() }
        let keeper = try await makeKeeper(makeWaitDefinition(), landID: "init-wait:\(key)", transport: transport)
        guard await DeliveryGates.gate(key).waitUntilEntered() else { return }

        let join = Task { () -> (any Error)? in
            do { try await keeper.join(playerID: player, clientID: client, sessionID: session); return nil } catch { return error }
        }
        let action = Task { () -> (any Error)? in
            do {
                _ = try await keeper.handleActionEnvelope(
                    ActionEnvelope(typeIdentifier: String(describing: InitWaitAction.self), payload: AnyCodable(InitWaitAction(n: 1))),
                    playerID: player, clientID: client, sessionID: session
                )
                return nil
            } catch { return error }
        }
        let input = Task { await keeper.submitServerInput(InitWaitInput(n: 1)) }
        // All three wait on the running initialization before it ends.
        let allWaiting = try await withinDeadline("three calls wait on the initialization") {
            await keeper.waitForInitializationWaitersForTesting(3)
        }
        // A timeout has recorded its own issue.
        guard let allWaiting else { return }
        guard allWaiting else {
            Issue.record("the initialization ended before every call waited on it")
            return
        }
        DeliveryGates.gate(key).release()

        let joinError = await join.value
        if case .landShuttingDown? = joinError as? JoinError {} else { Issue.record("join: \(String(describing: joinError))") }
        let actionError = await action.value
        #expect((actionError as? LandInitializationError)?.underlying as? RoomSetupError == .noConfig, "action: \(String(describing: actionError))")
        #expect(await input.value == .refused(.draining))
        _ = try await withinDeadline("the land is torn down") { () async -> Void in await transport.waitUntilDestroyed() }
        #expect(await keeper.currentState().log == [], "no handler ran")
    }

    // Deadlines off: the resolver's init deadline would end the initialization too, which also
    // resumes the watcher with `false`. Only the cancellation may resume it here.
    @Test("A cancelled wait for initialization waiters returns false, while the initialization is still held", .resolverDeadlinesOff)
    func cancelledWaiterWaitReturnsFalse() async throws {
        let key = DeliveryGates.freshKey()
        // Released on every exit, a late entry included.
        defer { DeliveryGates.gate(key).release() }
        let keeper = try await makeKeeper(makeWaitDefinition(), landID: "init-wait:\(key)")
        guard await DeliveryGates.gate(key).waitUntilEntered() else { return }
        let (registrations, registered) = AsyncStream<Void>.makeStream()
        let wait = Task { await keeper.waitForInitializationWaitersForTesting(1, registered: { registered.yield() }) }
        defer {
            registered.finish()
            wait.cancel()
        }
        // Cancelled once its watcher is registered, so the cancellation handler resumes it.
        let notice = try await withinDeadline("the watcher registers") { () async -> Bool in
            var notices = registrations.makeAsyncIterator()
            return await notices.next() != nil
        }
        guard let notice else { return }
        try #require(notice, "the watcher registered")
        wait.cancel()
        let reached = try await withinDeadline("the cancelled wait returns") { await wait.value }
        #expect(reached == false)
    }

    @Test("Two stages with .failLand: a resolver that throws fails the initialization before validate runs, counted as a resolver failure")
    func twoStageFailLand() async throws {
        let metrics = ResolverDeadlineMetrics(), transport = InitStageTransport()
        let landID = "init-fail-land:missing:\(UUID().uuidString)"
        try await ResolverDeadline.$metricsForTesting.withValue(metrics) {
            let keeper = try await makeKeeper(makeFailLandDefinition(), landID: landID, transport: transport)
            do {
                try await keeper.leave(playerID: player, clientID: client, sessionID: session)
                Issue.record("Expected LandInitializationError")
            } catch is LandInitializationError {}
            _ = try await withinDeadline("the land is torn down") { () async -> Void in await transport.waitUntilDestroyed() }
            #expect(await keeper.currentState().maxPlayers == 0)
        }
        #expect(!ValidateRuns.ran(landID), "validate didn't run")
        #expect(metrics.snapshot.initFailures == 1)
    }

    @Test("A hosted replay fails on a refused OnInitialize even when every tick hash matches; the same record without the refusal completes")
    func hostedRunFailsOnTheInitializeCheck() async throws {
        let definition = makeNoWriteDefinition()
        let (path, landID) = try await recordLiveRun(definition, dropInitializeRecord: false)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let clean = try await hostedRun(definition, path)
        #expect(clean.phase == .completed, "\(clean.errorMessage)")
        #expect(clean.mismatchedTicks == 0)

        InitializeRefusals.refuse(landID)
        let refused = try await hostedRun(definition, path)
        #expect(refused.mismatchedTicks == 0, "every tick hash matched")
        #expect(refused.phase == .failed)
        #expect(refused.errorMessage.contains("OnInitialize's validate threw in replay"), "\(refused.errorMessage)")
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
