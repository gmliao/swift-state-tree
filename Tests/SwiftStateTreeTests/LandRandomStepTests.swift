// Tests/SwiftStateTreeTests/LandRandomStepTests.swift
//
// The land's generator is keeper state (#700 K1b-3, #765): each handler that replay repeats from
// the record draws from a service built for its call and written back when it returns; handlers
// that replay doesn't repeat draw from copies; resolvers don't reach it.

import Foundation
import Logging
import Synchronization
import Testing
@testable import SwiftStateTree
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct LandRandomState: StateNodeProtocol {
    @Sync(.broadcast)
    var draws: [Int] = []

    /// The handler that made each draw, beside `draws`, where a test names them.
    @Sync(.broadcast)
    var drawnBy: [String] = []

    init() {}
}

@Payload
struct LandRandomAction: ActionPayload {
    typealias Response = LandRandomAck
    let n: Int
}

@Payload
struct LandRandomAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct LandRandomEvent: ClientEventPayload {
    let n: Int
}

@Payload
struct LandRandomInput: ServerInputPayload {
    let n: Int
}

private let drawRange = 0...1_000_000

private func draw(_ ctx: LandContext) -> Int {
    ctx.random.nextInt(in: drawRange)
}

/// The first `count` values a generator seeded with `seed` draws.
private func expectedDraws(seed: UInt64, count: Int, skipping skip: Int = 0) -> [Int] {
    var generator = DeterministicRng(seed: seed)
    for _ in 0..<skip { _ = generator.nextInt(in: drawRange) }
    return (0..<count).map { _ in generator.nextInt(in: drawRange) }
}

/// The next `count` values `generator` draws, without moving it.
private func nextDraws(of generator: DeterministicRng, count: Int) -> [Int] {
    var copy = generator
    return (0..<count).map { _ in copy.nextInt(in: drawRange) }
}

/// Draws that handlers outside the land's state record: CanJoin, the sync handler, the drain's.
private final class DrawLog: Sendable {
    private let entries = Mutex<[(String, Int)]>([])
    func add(_ name: String, _ value: Int) { entries.withLock { $0.append((name, value)) } }
    func values(_ name: String) -> [Int] { entries.withLock { $0.filter { $0.0 == name }.map(\.1) } }
    func names() -> [String] { entries.withLock { $0.map(\.0) } }
}

/// Each `ctx.random` kept past its handler, by handler.
private final class RetainedRandom: Sendable {
    private let services = Mutex<[(String, DeterministicRngService)]>([])
    func keep(_ name: String, _ value: DeterministicRngService) { services.withLock { $0.append((name, value)) } }
    /// The service `name`'s `index`-th call kept.
    func take(_ name: String, _ index: Int = 0) -> DeterministicRngService? {
        services.withLock { kept in
            let named = kept.filter { $0.0 == name }
            return index < named.count ? named[index].1 : nil
        }
    }
}

/// Draws once into the state, and names the handler that drew.
private func draw(_ name: String, into state: inout LandRandomState, _ ctx: LandContext) {
    state.draws.append(draw(ctx))
    state.drawnBy.append(name)
}

/// Every handler that replay repeats from the record draws once into the state.
private func makeSequenceLand() -> LandDefinition<LandRandomState> {
    Land("land-random", using: LandRandomState.self) {
        ClientEvents { Register(LandRandomEvent.self) }
        Rules {
            OnJoin { state, ctx in draw("join", into: &state, ctx) }
            OnLeave { state, ctx in draw("leave", into: &state, ctx) }
            HandleAction(LandRandomAction.self) { state, _, ctx in
                draw("action", into: &state, ctx)
                return LandRandomAck(ok: true)
            }
            HandleEvent(LandRandomEvent.self) { state, _, ctx in draw("event", into: &state, ctx) }
            HandleServerInput(LandRandomInput.self) { state, _, ctx in draw("input", into: &state, ctx) }
        }
        Lifetime {
            OnInitialize { state, ctx in draw("initialize", into: &state, ctx) }
            Tick(every: .seconds(3600)) { state, ctx in draw("tick", into: &state, ctx) }
        }
    }
}

/// `definition` with its client events registered through the public descriptor init, which
/// has no decode: their handlers decode them when applied (the `.undecoded` payload).
private func withUndecodedClientEvents(_ definition: LandDefinition<LandRandomState>) -> LandDefinition<LandRandomState> {
    let registry = EventRegistry<AnyClientEvent>(registered: definition.clientEventRegistry.registered.map {
        AnyEventDescriptor(type: $0.type, eventName: $0.eventName, direction: $0.direction)
    })
    return LandDefinition(
        id: definition.id,
        stateType: definition.stateType,
        clientEventRegistry: registry,
        serverEventRegistry: definition.serverEventRegistry,
        config: definition.config,
        actionHandlers: definition.actionHandlers,
        eventHandlers: definition.eventHandlers,
        serverInputHandlers: definition.serverInputHandlers,
        duplicateHandlers: definition.duplicateHandlers,
        clientEventMismatches: definition.clientEventMismatches,
        unrecognizedNodes: definition.unrecognizedNodes,
        resolverDeclarationProblems: definition.resolverDeclarationProblems,
        lifetimeHandlers: definition.lifetimeHandlers,
        servicesType: definition.servicesType,
        acceptsServices: definition.acceptsServices
    )
}

/// A recording keeper for `definition`, initialized, with its record's metadata set.
private func makeRecordingKeeper(
    _ definition: LandDefinition<LandRandomState>, landID: String
) async throws -> (keeper: LandKeeper<LandRandomState>, recorder: ReevaluationRecorder, seed: UInt64) {
    let keeper = LandKeeper<LandRandomState>(
        definition: definition,
        initialState: LandRandomState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        landID: landID
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await keeper.awaitInitialization()
    let seed = try #require(await keeper.getRngSeed())
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: landID, landType: definition.id, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        metadata: [:], landDefinitionID: definition.id, rngSeed: seed
    ))
    return (keeper, recorder, seed)
}

/// Saves `keeper`'s record (without its initialize record when `dropInitializeRecord`, so replay
/// runs OnInitialize as tick 0's lifecycle item) and replays it with `definition`.
private func replayRecord(
    of keeper: LandKeeper<LandRandomState>,
    _ recorder: ReevaluationRecorder,
    definition: LandDefinition<LandRandomState>,
    dropInitializeRecord: Bool = false
) async throws -> ReevaluationEngine.RunResult {
    await keeper.waitForRecorderSubmissionsForTesting()
    let path = recordPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try await recorder.save(to: path)
    guard dropInitializeRecord else {
        return try await ReevaluationEngine.run(definition: definition, initialState: LandRandomState(), recordFilePath: path)
    }
    try ReevaluationRecordFile.convertToJSONViewForTesting(atPath: path)
    let jsonPath = path + ".json"
    try FileManager.default.moveItem(atPath: path, toPath: jsonPath)
    defer { try? FileManager.default.removeItem(atPath: jsonPath) }
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: jsonPath))) as? [String: Any])
    var frames = try #require(object["tickFrames"] as? [[String: Any]])
    let index = try #require(frames.firstIndex { $0["initialize"] != nil }, "the live run recorded an initialize record")
    frames[index].removeValue(forKey: "initialize")
    object["tickFrames"] = frames
    try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: jsonPath))
    return try await ReevaluationEngine.run(definition: definition, initialState: LandRandomState(), recordFilePath: jsonPath)
}

/// The ticks whose replayed hash differs from the live one; fails when no tick was compared.
private func divergedTicks(_ result: ReevaluationEngine.RunResult, sourceLocation: SourceLocation = #_sourceLocation) -> [Int64] {
    #expect(!result.recordedStateHashes.isEmpty, "the live run recorded tick hashes", sourceLocation: sourceLocation)
    return result.recordedStateHashes.filter { result.tickHashes[$0.key] != $0.value }.keys.sorted()
}

private let player = PlayerID("p1")
private let client = ClientID("c1")
private let session = SessionID("s1")

private func action(_ n: Int = 1) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: LandRandomAction.self), payload: AnyCodable(LandRandomAction(n: n)))
}

private func recordPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("land-random-\(UUID().uuidString).sstr").path
}

@Suite("The land's generator is keeper state (#700 K1b-3, #765)")
struct LandRandomStepTests {
    @Test("Every handler replay repeats continues one sequence, and replay repeats it through the inline tick")
    func sequenceContinuesAndReplays() async throws {
        let (keeper, recorder, seed) = try await makeRecordingKeeper(makeSequenceLand(), landID: "land-random:sequence")
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        // A tick land takes each input at intake and applies them in intake order, at the next tick.
        _ = try await keeper.handleActionEnvelope(action(), playerID: player, clientID: client, sessionID: session)
        try await keeper.handleClientEvent(AnyClientEvent(LandRandomEvent(n: 1)), playerID: player, clientID: client, sessionID: session)
        _ = await keeper.submitServerInput(LandRandomInput(n: 1))
        await keeper.stepTickOnce()
        try await keeper.leave(playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()

        let state = await keeper.currentState()
        let order = ["initialize", "join", "tick", "action", "event", "input", "tick", "leave", "tick"]
        #expect(state.drawnBy == order)
        #expect(state.draws == expectedDraws(seed: seed, count: order.count), "each handler drew the land's next value, in this order: \(order)")

        let result = try await replayRecord(of: keeper, recorder, definition: makeSequenceLand())
        #expect(result.initialize == .passed)
        let diverged = divergedTicks(result)
        #expect(diverged.isEmpty, "ticks whose replayed hash differs from the live one: \(diverged)")
    }

    @Test("A client event whose descriptor has no decode draws in turn, live and replayed")
    func undecodedClientEventDraws() async throws {
        let definition = withUndecodedClientEvents(makeSequenceLand())
        #expect(definition.clientEventRegistry.registered.allSatisfy { $0.decodeClientEvent == nil })
        let (keeper, recorder, seed) = try await makeRecordingKeeper(definition, landID: "land-random:undecoded")
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        try await keeper.handleClientEvent(AnyClientEvent(LandRandomEvent(n: 1)), playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()

        let state = await keeper.currentState()
        let order = ["initialize", "join", "tick", "event", "tick"]
        #expect(state.drawnBy == order)
        #expect(state.draws == expectedDraws(seed: seed, count: order.count))

        let result = try await replayRecord(of: keeper, recorder, definition: withUndecodedClientEvents(makeSequenceLand()))
        let diverged = divergedTicks(result)
        #expect(diverged.isEmpty, "ticks whose replayed hash differs from the live one: \(diverged)")
    }

    @Test("A record without an initialize record replays OnInitialize as a lifecycle item, drawing in turn")
    func initializeFallbackDrawsInTurn() async throws {
        let (keeper, recorder, seed) = try await makeRecordingKeeper(makeSequenceLand(), landID: "land-random:init-fallback")
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        let state = await keeper.currentState()
        #expect(state.drawnBy == ["initialize", "join", "tick", "tick"])
        #expect(state.draws == expectedDraws(seed: seed, count: 4))

        let result = try await replayRecord(of: keeper, recorder, definition: makeSequenceLand(), dropInitializeRecord: true)
        #expect(result.initialize == .notRecorded, "replay took the lifecycle fallback")
        let diverged = divergedTicks(result)
        #expect(diverged.isEmpty, "ticks whose replayed hash differs from the live one: \(diverged)")
    }

    @Test("Each handler call gets its own service; one kept past its call continues its own sequence")
    func retainedServiceIsIsolated() async throws {
        let retained = RetainedRandom()
        let definition = Land("land-random-retained", using: LandRandomState.self) {
            Rules {
                HandleAction(LandRandomAction.self) { state, _, ctx in
                    retained.keep("action", ctx.random)
                    state.draws.append(draw(ctx))
                    return LandRandomAck(ok: true)
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { state, ctx in
                    retained.keep("tick", ctx.random)
                    state.draws.append(draw(ctx))
                }
            }
        }
        let keeper = LandKeeper<LandRandomState>(definition: definition, initialState: LandRandomState(), autoStartLoops: false, landID: "land-random:retained")
        await keeper.awaitInitialization()
        let seed = try #require(await keeper.getRngSeed())
        let all = expectedDraws(seed: seed, count: 6)
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        let submission = try await keeper.submitAction(action(), playerID: player, clientID: client, sessionID: session)
        // The action draws the land's second value, then the tick its third.
        await keeper.stepTickOnce()
        let kept = try #require(retained.take("action"), "the action's handler ran (\(submission))")
        let laterCall = try #require(retained.take("tick", 1), "the second tick's handler ran")
        #expect(kept !== laterCall, "a later handler call gets a new service, not the kept one reset")

        // After the later call's step: the kept service continues from its own last draw (the
        // action's), not from where the land's generator is.
        let outside = (0..<3).map { _ in kept.nextInt(in: drawRange) }
        #expect(outside == Array(all[2...4]), "the kept service continues the action's sequence")
        await keeper.stepTickOnce()

        let live = await keeper.currentState().draws
        #expect(live == Array(all[0...3]), "three ticks and the action; the kept service's draws didn't move the land")
    }

    @Test("Resolvers don't reach an RNG, whichever registration it came from (#765)")
    func resolversGetNoRandom() async throws {
        LandRandomResolverProbe.reset()
        let definition = Land("land-random-resolver", using: LandRandomState.self) {
            Rules {
                OnJoin(resolvers: LandRandomResolverProbe.self) { state, _, ctx in
                    state.draws.append(draw(ctx))
                }
            }
        }
        var landServices = LandServices()
        landServices.register(DeterministicRngService(seed: 42), as: DeterministicRngService.self)
        var playerServices = LandServices()
        playerServices.register(DeterministicRngService(seed: 7), as: DeterministicRngService.self)
        let keeper = LandKeeper<LandRandomState>(definition: definition, initialState: LandRandomState(), services: landServices, autoStartLoops: false, landID: "land-random:resolver")
        await keeper.awaitInitialization()
        #expect(await keeper.getRngSeed() == 42, "a caller-registered service gives the land its seed")
        try await keeper.join(playerID: player, clientID: client, sessionID: session, services: playerServices)

        #expect(LandRandomResolverProbe.sawRandom() == [false])
        #expect(await keeper.currentState().draws == expectedDraws(seed: 42, count: 1), "the handler draws from the land's generator, seeded 42")
    }

    @Test("CanJoin and the sync handler draw from copies; the land's sequence doesn't move")
    func canJoinAndSyncAreDetached() async throws {
        let log = DrawLog()
        let definition = Land("land-random-detached", using: LandRandomState.self) {
            Rules {
                CanJoin { _, session, ctx in
                    log.add("canJoin", draw(ctx))
                    return .allow(playerID: PlayerID(session.playerID))
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { state, ctx in state.draws.append(draw(ctx)) }
                StateSync(every: .seconds(3600)) { _, ctx in log.add("sync", draw(ctx)) }
            }
        }
        let keeper = LandKeeper<LandRandomState>(definition: definition, initialState: LandRandomState(), landID: "land-random:detached")
        await keeper.awaitInitialization()
        let seed = try #require(await keeper.getRngSeed())
        await keeper.stepTickOnce()
        let before = await keeper.landRandomForTesting
        _ = try await keeper.join(session: PlayerSession(playerID: "p1", deviceID: "dev", metadata: [:]), clientID: client, sessionID: session, services: LandServices())
        await keeper.runSyncLoopIterationForTesting()
        await keeper.runSyncLoopIterationForTesting()
        #expect(await keeper.landRandomForTesting.nextDrawsMatch(before))
        await keeper.stepTickOnce()
        await keeper.forceShutdown()

        let next = nextDraws(of: before, count: 1)
        #expect(log.values("canJoin") == next, "CanJoin draws the land's next value from a copy")
        #expect(log.values("sync") == next + next, "each sync handler call draws from a fresh copy")
        let live = await keeper.currentState().draws
        #expect(live == expectedDraws(seed: seed, count: 2), "the ticks continue the land's sequence unmoved")
    }

    @Test("CanJoin with a resolver takes its copy after the resolver; the recorded run replays")
    func canJoinWithResolverIsDetachedAndReplays() async throws {
        let log = DrawLog()
        let gate = TestGate()
        LandRandomGatedResolver.gate.withLock { $0 = gate }
        defer { LandRandomGatedResolver.gate.withLock { $0 = nil } }
        let makeLand = {
            Land("land-random-canjoin-resolver", using: LandRandomState.self) {
                Rules {
                    CanJoin(resolvers: LandRandomGatedResolver.self) { _, session, output, ctx in
                        log.add("resolver", output?.value ?? -1)
                        log.add("canJoin", draw(ctx))
                        return .allow(playerID: PlayerID(session.playerID))
                    }
                }
                Lifetime {
                    Tick(every: .seconds(3600)) { state, ctx in state.draws.append(draw(ctx)) }
                }
            }
        }
        let (keeper, recorder, seed) = try await makeRecordingKeeper(makeLand(), landID: "land-random:canjoin-resolver")
        let all = expectedDraws(seed: seed, count: 3)
        await keeper.stepTickOnce()
        let joining = Task {
            try await keeper.join(session: PlayerSession(playerID: "p1", deviceID: "dev", metadata: [:]), clientID: client, sessionID: session, services: LandServices())
        }
        #expect(await gate.waitForArrivals(1), "CanJoin's resolver started")
        // A tick while the resolver is held moves the land's generator.
        await keeper.stepTickOnce()
        gate.open()
        _ = try await joining.value
        await keeper.stepTickOnce()

        #expect(log.values("resolver") == expectedResolverDraw(), "the resolver drew from its own generator")
        #expect(log.values("canJoin") == [all[2]], "CanJoin's copy was taken after the resolver, from the land's generator as the held tick left it")
        #expect(await keeper.currentState().draws == all, "three ticks; CanJoin didn't move the land")

        let result = try await replayRecord(of: keeper, recorder, definition: makeLand())
        let diverged = divergedTicks(result)
        #expect(diverged.isEmpty, "ticks whose replayed hash differs from the live one: \(diverged)")
    }

    @Test("A viewer joining a reevaluation keeper runs CanJoin on a copy: the replayed draws still match")
    func viewerCanJoinOnReplayIsDetached() async throws {
        let log = DrawLog()
        let makeLand = {
            Land("land-random-viewer", using: LandRandomState.self) {
                Rules {
                    CanJoin { _, session, ctx in
                        log.add("canJoin", draw(ctx))
                        return .allow(playerID: PlayerID(session.playerID))
                    }
                }
                Lifetime {
                    Tick(every: .seconds(3600)) { state, ctx in state.draws.append(draw(ctx)) }
                }
            }
        }
        let landID = "land-random:viewer"
        let live = LandKeeper<LandRandomState>(
            definition: makeLand(), initialState: LandRandomState(),
            enableLiveStateHashRecording: true, autoStartLoops: false, landID: landID
        )
        let recorder = try #require(await live.getReevaluationRecorder())
        await live.awaitInitialization()
        let liveSeed = try #require(await live.getRngSeed())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: landID, landType: "land-random-viewer", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            metadata: [:], landDefinitionID: "land-random-viewer", rngSeed: liveSeed
        ))
        await live.stepTickOnce()
        await live.stepTickOnce()
        await live.waitForRecorderSubmissionsForTesting()
        let path = recordPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await recorder.save(to: path)

        // Replay registers the recorded seed, as the engine does.
        var replayServices = LandServices()
        replayServices.register(DeterministicRngService(seed: liveSeed), as: DeterministicRngService.self)
        let replay = LandKeeper<LandRandomState>(
            definition: makeLand(), initialState: LandRandomState(),
            mode: .reevaluation,
            reevaluationSource: try ReevaluationRecordFile.openSource(filePath: path),
            services: replayServices,
            autoStartLoops: false
        )
        await replay.awaitInitialization()
        await replay.stepTickOnce()
        let before = await replay.landRandomForTesting
        _ = try await replay.join(session: PlayerSession(playerID: "viewer", deviceID: "dev", metadata: [:]), clientID: ClientID("v"), sessionID: SessionID("v"), services: LandServices())
        #expect(log.values("canJoin") == nextDraws(of: before, count: 1), "CanJoin drew the next value from a copy")
        #expect(await replay.landRandomForTesting.nextDrawsMatch(before), "the viewer's CanJoin didn't move the replayed generator")
        await replay.stepTickOnce()
        let replayed = await replay.currentState().draws
        let recorded = await live.currentState().draws
        #expect(replayed == recorded, "replayed \(replayed), recorded \(recorded)")
    }

    @Test("The drain's three handlers continue one copy; the land's generator isn't written")
    func drainHandlersShareOneCopy() async throws {
        let log = DrawLog()
        let definition = Land("land-random-drain", using: LandRandomState.self) {
            Rules {
                OnJoin { state, ctx in state.draws.append(draw(ctx)) }
            }
            Lifetime {
                DestroyWhenEmpty(after: .seconds(3600)) { _, ctx in log.add("destroyWhenEmpty", draw(ctx)) }
                OnFinalize { _, ctx in log.add("finalize", draw(ctx)) }
                AfterFinalize { _, ctx in log.add("afterFinalize", draw(ctx)) }
            }
        }
        let keeper = LandKeeper<LandRandomState>(definition: definition, initialState: LandRandomState(), autoStartLoops: false, landID: "land-random:drain")
        await keeper.awaitInitialization()
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        let before = await keeper.landRandomForTesting
        await keeper.forceShutdown()

        #expect(log.names() == ["destroyWhenEmpty", "finalize", "afterFinalize"])
        let next = nextDraws(of: before, count: 3)
        #expect(log.values("destroyWhenEmpty") + log.values("finalize") + log.values("afterFinalize") == next)
        #expect(await keeper.landRandomForTesting.nextDrawsMatch(before), "the drain wrote nothing back")
    }

    @Test("Draws before a handler throws are kept; the next step continues after them")
    func drawsBeforeAThrowAreKept() async throws {
        let refusing = AnyActionHandler<LandRandomState>(
            type: LandRandomAction.self,
            responseType: LandRandomAck.self,
            invoke: { _, _, ctx in
                _ = draw(ctx)
                _ = draw(ctx)
                throw LandRandomRefused()
            },
            resolvers: nil
        )
        let definition = Land("land-random-throw", using: LandRandomState.self) {
            Rules { refusing }
            Lifetime {
                Tick(every: .seconds(3600)) { state, ctx in state.draws.append(draw(ctx)) }
            }
        }
        let (keeper, recorder, seed) = try await makeRecordingKeeper(definition, landID: "land-random:throw")
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        let submission = try await keeper.submitAction(action(), playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()

        let live = await keeper.currentState().draws
        let all5 = expectedDraws(seed: seed, count: 5)
        #expect(live == [all5[0], all5[3], all5[4]], "a tick; the refused action's two draws, then the tick in its turn; a tick: \(live) vs \(all5) (\(submission))")

        // The refused action is recorded before its handler runs, so replay runs it again and
        // must make the same two draws before the throw.
        let result = try await replayRecord(of: keeper, recorder, definition: definition)
        let diverged = divergedTicks(result)
        #expect(diverged.isEmpty, "ticks whose replayed hash differs from the live one: \(diverged)")
    }

    @Test("The seed: a caller-registered service's, else the land ID's, else the definition ID's")
    func seedSources() async throws {
        var services = LandServices()
        services.register(DeterministicRngService(seed: 42), as: DeterministicRngService.self)
        let registered = LandKeeper<LandRandomState>(definition: makeSequenceLand(), initialState: LandRandomState(), services: services, autoStartLoops: false, landID: "land-random:seed")
        #expect(await registered.getRngSeed() == 42)
        let byLandID = LandKeeper<LandRandomState>(definition: makeSequenceLand(), initialState: LandRandomState(), autoStartLoops: false, landID: "land-random:seed")
        #expect(await byLandID.getRngSeed() == DeterministicSeed.fromLandID("land-random:seed"))
        let byDefinition = LandKeeper<LandRandomState>(definition: makeSequenceLand(), initialState: LandRandomState(), autoStartLoops: false)
        #expect(await byDefinition.getRngSeed() == DeterministicSeed.fromLandID("land-random"))
    }

    @Test("A context built without a keeper falls back to a service in its services")
    func keeperlessContextFallsBack() {
        let service = DeterministicRngService(seed: 9)
        var services = LandServices()
        services.register(service, as: DeterministicRngService.self)
        let ctx = LandContext(
            landID: "keeperless", playerID: PlayerID("p"), clientID: ClientID("c"), sessionID: SessionID("s"),
            services: services, logger: Logger(label: "test"), deviceID: nil, metadata: [:],
            emitEventHandler: { _, _ in }, requestSyncNowHandler: {}, requestSyncBroadcastOnlyHandler: {})
        #expect(ctx.random === service)
    }
}

private struct LandRandomRefused: Error {}

private extension DeterministicRng {
    /// Whether this generator draws what `other` draws next: the two are at the same position.
    func nextDrawsMatch(_ other: DeterministicRng) -> Bool {
        nextDraws(of: self, count: 4) == nextDraws(of: other, count: 4)
    }
}

@PlainData
struct LandRandomResolverOutput: ResolverOutput, Equatable {
    let sawRandom: Bool
}

@PlainData
struct LandRandomResolverDraw: ResolverOutput, Equatable {
    let value: Int
}

/// The first value `LandRandomGatedResolver`'s own generator draws.
private func expectedResolverDraw() -> [Int] { expectedDraws(seed: 5, count: 1) }

/// A resolver that waits at `gate` (when one is set), then draws from its own generator, not
/// the land's.
struct LandRandomGatedResolver: ContextResolver {
    typealias Output = LandRandomResolverDraw
    static let gate = Mutex<TestGate?>(nil)
    static func resolve(ctx: ResolverContext) async throws -> LandRandomResolverDraw {
        if let gate = gate.withLock({ $0 }) { await gate.arrive() }
        var own = DeterministicRng(seed: 5)
        return LandRandomResolverDraw(value: own.nextInt(in: drawRange))
    }
}

/// Reports whether a resolver's services hold a `DeterministicRngService`.
struct LandRandomResolverProbe: ContextResolver {
    typealias Output = LandRandomResolverOutput
    private static let seen = Mutex<[Bool]>([])
    static func reset() { seen.withLock { $0 = [] } }
    static func sawRandom() -> [Bool] { seen.withLock { $0 } }
    static func resolve(ctx: ResolverContext) async throws -> LandRandomResolverOutput {
        let saw = ctx.services.get(DeterministicRngService.self) != nil
        seen.withLock { $0.append(saw) }
        return LandRandomResolverOutput(sawRandom: saw)
    }
}
