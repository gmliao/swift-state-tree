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

@StateNodeBuilder
struct LandRandomState: StateNodeProtocol {
    @Sync(.broadcast)
    var draws: [Int] = []

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

/// A `ctx.random` kept past its handler.
private final class RetainedRandom: Sendable {
    private let service = Mutex<DeterministicRngService?>(nil)
    func keep(_ value: DeterministicRngService) { service.withLock { $0 = value } }
    func take() -> DeterministicRngService? { service.withLock { $0 } }
}

/// Every handler that replay repeats from the record draws once into the state.
private func makeSequenceLand() -> LandDefinition<LandRandomState> {
    Land("land-random", using: LandRandomState.self) {
        ClientEvents { Register(LandRandomEvent.self) }
        Rules {
            OnJoin { state, ctx in state.draws.append(draw(ctx)) }
            OnLeave { state, ctx in state.draws.append(draw(ctx)) }
            HandleAction(LandRandomAction.self) { state, _, ctx in
                state.draws.append(draw(ctx))
                return LandRandomAck(ok: true)
            }
            HandleEvent(LandRandomEvent.self) { state, _, ctx in state.draws.append(draw(ctx)) }
            HandleServerInput(LandRandomInput.self) { state, _, ctx in state.draws.append(draw(ctx)) }
        }
        Lifetime {
            OnInitialize { state, ctx in state.draws.append(draw(ctx)) }
            Tick(every: .seconds(3600)) { state, ctx in state.draws.append(draw(ctx)) }
        }
    }
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
        let landID = "land-random:sequence"
        let keeper = LandKeeper<LandRandomState>(
            definition: makeSequenceLand(),
            initialState: LandRandomState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false,
            landID: landID
        )
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await keeper.awaitInitialization()
        let seed = try #require(await keeper.getRngSeed())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: landID, landType: "land-random", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            metadata: [:], landDefinitionID: "land-random", rngSeed: seed
        ))
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        let pendingAction = Task { try await keeper.handleActionEnvelope(action(), playerID: player, clientID: client, sessionID: session) }
        let pendingEvent = Task { try await keeper.handleClientEvent(AnyClientEvent(LandRandomEvent(n: 1)), playerID: player, clientID: client, sessionID: session) }
        let pendingInput = Task { await keeper.submitServerInput(LandRandomInput(n: 1)) }
        await keeper.stepTickOnce()
        _ = try await pendingAction.value
        try await pendingEvent.value
        _ = await pendingInput.value
        try await keeper.leave(playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        await keeper.waitForRecorderSubmissionsForTesting()

        let live = await keeper.currentState().draws
        #expect(live.count == 9, "OnInitialize, OnJoin, three ticks, an action, an event, an input, OnLeave: \(live)")
        #expect(live == expectedDraws(seed: seed, count: live.count))

        let path = recordPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await recorder.save(to: path)
        let result = try await ReevaluationEngine.run(definition: makeSequenceLand(), initialState: LandRandomState(), recordFilePath: path)
        #expect(!result.recordedStateHashes.isEmpty)
        let diverged = result.recordedStateHashes.filter { result.tickHashes[$0.key] != $0.value }.keys.sorted()
        #expect(diverged.isEmpty, "ticks whose replayed hash differs from the live one: \(diverged)")
    }

    @Test("A retained ctx.random draws from a copy: the land's sequence doesn't move")
    func retainedServiceIsIsolated() async throws {
        let retained = RetainedRandom()
        let definition = Land("land-random-retained", using: LandRandomState.self) {
            Rules {
                HandleAction(LandRandomAction.self) { state, _, ctx in
                    retained.keep(ctx.random)
                    state.draws.append(draw(ctx))
                    return LandRandomAck(ok: true)
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { state, ctx in state.draws.append(draw(ctx)) }
            }
        }
        let keeper = LandKeeper<LandRandomState>(definition: definition, initialState: LandRandomState(), autoStartLoops: false, landID: "land-random:retained")
        await keeper.awaitInitialization()
        let seed = try #require(await keeper.getRngSeed())
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        let submission = try await keeper.submitAction(action(), playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        let kept = try #require(retained.take(), "the action's handler ran (\(submission))")
        let outside = (0..<3).map { _ in kept.nextInt(in: drawRange) }
        await keeper.stepTickOnce()
        _ = kept.nextInt(in: drawRange)
        await keeper.stepTickOnce()

        let live = await keeper.currentState().draws
        #expect(live.count == 5, "four ticks and the action: \(live)")
        #expect(live == expectedDraws(seed: seed, count: live.count), "the retained service's draws didn't move the land")
        #expect(outside.count == 3)
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
        let keeper = LandKeeper<LandRandomState>(definition: definition, initialState: LandRandomState(), autoStartLoops: false, landID: "land-random:throw")
        await keeper.awaitInitialization()
        let seed = try #require(await keeper.getRngSeed())
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        let submission = try await keeper.submitAction(action(), playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()

        let live = await keeper.currentState().draws
        let all5 = expectedDraws(seed: seed, count: 5)
        #expect(live == [all5[0], all5[3], all5[4]], "a tick; the refused action's two draws, then the tick in its turn; a tick: \(live) vs \(all5) (\(submission))")
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
