// Tests/SwiftStateTreeTests/KeeperCoreDifferentialTests.swift
//
// #700 K2-1's differential: each routed flow is driven twice on the same inputs, through the
// keeper's own path and through a test `TurnCore` running `KeeperModel`, and the replies, the
// model and the side are compared (plan §6). The core isn't wired into the keeper: the harness
// below is the core's only adopter, and it starts `.land` itself (`.startLand`).
//
// Out of scope here (plan §16 items 16–18): the input drain's hold and its idle waiters, the
// action jobs, the initialization and the destroy drain. No case below holds `.inputDrain`,
// waits on the drain's idle waiters, starts a job, or sends a deferred input; the harness
// checks the last two.

import Foundation
import Testing
import SwiftStateTurns
import SwiftStateTreeTestSupport
@testable import SwiftStateTree

// MARK: - The land

@StateNodeBuilder
struct CoreDiffState: StateNodeProtocol {
    @Sync(.broadcast)
    var log: [String] = []

    public init() {}
}

/// An error with an identity: the cases compare the value each path's caller gets.
struct CoreDiffError: Error, Equatable {
    let token: Int
}

@Payload
struct CoreDiffAck: ResponsePayload {
    let n: Int
}

/// No resolvers: answers `n`, or `validate` throws `CoreDiffError(token: n)` when `fails`.
@Payload
struct CoreDiffAction: ActionPayload {
    typealias Response = CoreDiffAck
    let n: Int
    let fails: Bool
}

/// Logs `n`, or `validate` throws `CoreDiffError(token: n)` when `fails`.
@Payload
struct CoreDiffEvent: ClientEventPayload {
    let n: Int
    let fails: Bool
}

@Payload
struct CoreDiffServerEvent: ServerEventPayload {
    let n: Int
}

@PlainData
struct CoreDiffOutput: ResolverOutput {
    let value: Int
}

/// What a land's OnLeave resolver does, keyed by its land ID: succeeds, or throws
/// `CoreDiffError(token: 77)`.
private enum CoreDiffLeaveFailures {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var failing: Set<String> = []

    static func set(_ landID: String, failing fails: Bool) {
        lock.withLock { if fails { failing.insert(landID) } else { failing.remove(landID) } }
    }
    static func fails(_ landID: String) -> Bool { lock.withLock { failing.contains(landID) } }
}

struct CoreDiffJoinResolver: ContextResolver {
    typealias Output = CoreDiffOutput
    static func resolve(ctx: ResolverContext) async throws -> CoreDiffOutput { CoreDiffOutput(value: 1) }
}

struct CoreDiffLeaveResolver: ContextResolver {
    typealias Output = CoreDiffOutput
    static func resolve(ctx: ResolverContext) async throws -> CoreDiffOutput {
        if CoreDiffLeaveFailures.fails(ctx.landID) { throw CoreDiffError(token: 77) }
        return CoreDiffOutput(value: 2)
    }
}

/// The shapes a case picks.
struct CoreDiffShape: Sendable, CustomStringConvertible {
    var tick: Bool
    /// CanJoin and OnJoin each with a resolver (else without).
    var joinResolvers: Bool
    /// OnLeave with a resolver; without one, the leave appends in L1.
    var leaveResolver: Bool
    /// No OnLeave at all: L1 ends the leave at once.
    var noOnLeave = false
    /// `DestroyWhenEmpty(after: 1 h)`: an emptied land stages the timer's start.
    var destroysWhenEmpty = false

    var description: String {
        "\(tick ? "tick" : "tickless"), join resolvers \(joinResolvers), leave resolver \(leaveResolver)\(noOnLeave ? ", no OnLeave" : "")\(destroysWhenEmpty ? ", destroys when empty" : "")"
    }
}

@Sendable private func coreDiffTick(_ state: inout CoreDiffState, _ ctx: LandContext) {
    state.log.append("tick")
    ctx.emitEvent(CoreDiffServerEvent(n: 1), to: .all)
    ctx.emitEvent(CoreDiffServerEvent(n: 2), to: .all)
}

private func coreDiffDefinition(_ shape: CoreDiffShape) -> LandDefinition<CoreDiffState> {
    Land("core-diff", using: CoreDiffState.self) {
        AccessControl { MaxPlayers(4) }
        ClientEvents { Register(CoreDiffEvent.self) }
        ServerEvents { Register(CoreDiffServerEvent.self) }
        Rules {
            if shape.joinResolvers {
                CanJoin(resolvers: CoreDiffJoinResolver.self) { _, session, _, _ in .allow(playerID: PlayerID(session.playerID)) }
                OnJoin(resolvers: CoreDiffJoinResolver.self) { state, _, ctx in state.log.append("join:\(ctx.playerID.rawValue)") }
            } else {
                CanJoin { _, session, _ in .allow(playerID: PlayerID(session.playerID)) }
                OnJoin { state, ctx in state.log.append("join:\(ctx.playerID.rawValue)") }
            }
            if !shape.noOnLeave {
                if shape.leaveResolver {
                    OnLeave(resolvers: CoreDiffLeaveResolver.self) { state, _, ctx in state.log.append("leave:\(ctx.playerID.rawValue)") }
                } else {
                    OnLeave { state, ctx in state.log.append("leave:\(ctx.playerID.rawValue)") }
                }
            }
            HandleAction(CoreDiffAction.self, validate: { _, action, _ in
                if action.fails { throw CoreDiffError(token: action.n) }
            }, apply: { state, action, _ in
                state.log.append("action:\(action.n)")
                return CoreDiffAck(n: action.n)
            })
            HandleEvent(CoreDiffEvent.self, validate: { _, event, _ in
                if event.fails { throw CoreDiffError(token: event.n) }
            }, apply: { state, event, _ in
                state.log.append("event:\(event.n)")
            })
        }
        // `Lifetime`'s builder takes no `if`: one block per combination. Two events per tick: the
        // eventful path (§16 item 11).
        if shape.tick && shape.destroysWhenEmpty {
            Lifetime {
                Tick(every: .seconds(3600)) { state, ctx in coreDiffTick(&state, ctx) }
                DestroyWhenEmpty(after: .seconds(3600))
            }
        } else if shape.tick {
            Lifetime {
                Tick(every: .seconds(3600)) { state, ctx in coreDiffTick(&state, ctx) }
            }
        } else if shape.destroysWhenEmpty {
            Lifetime {
                DestroyWhenEmpty(after: .seconds(3600))
            }
        }
    }
}

// MARK: - The harness

/// The core's test adopter: runs `KeeperModel` on a `TurnCore`, performs its effects (the
/// resolvers, the record's hand-off) and keeps its outputs.
actor KeeperCoreHarness<State: StateNodeProtocol>: TurnActor {
    typealias M = KeeperModel<State>
    let core: TurnCore<KeeperModel<State>>
    let store: KeeperSideStore
    nonisolated let definition: LandDefinition<State>
    private(set) var flushed: [KeeperOutput] = []
    /// Every input sent and every effect result, by route name, so a case can check that no
    /// deferred input reached the machine.
    private(set) var inputsSeen: [String] = []
    /// When set, every `.awaitRecordTaken` effect waits here before it runs (released: passes).
    nonisolated let recordGate: WatermarkGate?

    init(_ twin: (model: KeeperModel<State>, behavior: KeeperBehavior<State>, store: KeeperSideStore), recordGate: WatermarkGate? = nil) {
        self.recordGate = recordGate
        core = TurnCore(machine: twin.model, behavior: twin.behavior, queueLimit: 1024, maxReleasesPerBatch: 64, clock: SystemTurnClock())
        store = twin.store
        definition = twin.behavior.definition
    }

    /// Binds the side store to this actor and starts `.land` (as the owner's initialization
    /// will, K2-2), unless `startsLand` is false.
    func start(startsLand: Bool = true) {
        store.bind(to: self)
        guard startsLand else { return }
        note(.startLand)
        send(.startLand)
    }

    var droppedOutputs: Int { core.stats.droppedOutputs }

    /// Yields once per input drain's end (the side's `input-drain-end` probe), and counts them.
    /// Install after `start` (the store must be bound) and before the drain.
    func drainEnds() -> (stream: AsyncStream<Void>, count: CoreDiffCounter) {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let count = CoreDiffCounter()
        store.withSide { side in
            side.probe = { name in
                guard name == "input-drain-end" else { return }
                count.increment()
                continuation.yield()
            }
        }
        return (stream, count)
    }

    /// The folds the flush received, in order.
    var flushedFolds: [PendingFold] {
        flushed.compactMap { if case let .fold(fold) = $0 { fold } else { nil } }
    }

    /// Sends an input that has no reply; its step and flush run before this returns.
    func drive(_ input: KeeperInput<State>) {
        note(input)
        send(input)
    }

    func call(_ input: KeeperInput<State>) async throws -> KeeperReply<State> {
        note(input)
        return try await sendAndWait(input, cancellation: .ignoresCancel)
    }

    func ask(_ question: KeeperQuery) -> KeeperAnswer<State> {
        query(question)
    }

    func differentialRead() -> KeeperDifferentialRead<State> {
        let model = core.read { copy $0 }
        return store.withSide { KeeperDifferentialRead(model: model, side: $0) }
    }

    private func note(_ input: KeeperInput<State>) { inputsSeen.append(input.routeName) }
    private func noteResult(_ name: String) { inputsSeen.append(name) }

    @concurrent nonisolated func perform(_ effect: KeeperEffect<State>) async -> KeeperInput<State>? {
        let handlers = definition.lifetimeHandlers
        let result: KeeperInput<State>?
        switch effect {
        case let .join(request, stage, caller):
            switch request {
            case let .runCanJoinResolvers(resolverContext, landContext):
                result = .joinStepped(stage, caller: caller, await Self.resolve(handlers.canJoinResolverExecutors, resolverContext, landContext, .canJoin))
            case let .runOnJoinResolvers(_, _, resolverContext, landContext):
                result = .joinStepped(stage, caller: caller, await Self.resolve(handlers.onJoinResolverExecutors, resolverContext, landContext, .onJoin))
            default:
                Issue.record("a join effect that isn't a resolver run: \(request)")
                result = nil
            }
        case let .leave(request, continuation):
            guard case let .runOnLeaveResolvers(capture, resolverContext, landContext) = request else {
                Issue.record("a leave effect that isn't a resolver run: \(request)")
                return nil
            }
            result = .leaveStepped(capture, continuation, await Self.resolve(handlers.onLeaveResolverExecutors, resolverContext, landContext, .onLeave))
        case let .awaitRecordTaken(submission, applied, endsTickWork):
            await recordGate?.enterAndWait()
            await submission?.taken()
            result = .recordTaken(applied: applied, endsTickWork: endsTickWork)
        case .action, .initialize, .destroyHandler:
            Issue.record("K2-1 routes no \(effect) effect")
            result = nil
        }
        if let result { await noteResult(result.routeName) }
        return result
    }

    func flush(_ outputs: consuming [KeeperOutput]) {
        flushed.append(contentsOf: outputs)
    }

    private static func resolve(
        _ executors: [any AnyResolverExecutor],
        _ resolverContext: ResolverContext,
        _ landContext: LandContext,
        _ kind: ResolverAbandonment.Kind
    ) async -> Result<[String: HeldResolverOutput], any Error> {
        do {
            let ctx = try await ResolverExecutor.executeResolvers(
                executors: executors,
                resolverContext: resolverContext,
                landContext: landContext,
                abandonment: ResolverAbandonment(kind: kind, counter: LandAbandonmentCounter(), metrics: ResolverDeadline.metrics)
            )
            return .success(ctx.getAllResolverOutputs())
        } catch {
            return .failure(error)
        }
    }
}

final class CoreDiffCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

// MARK: - What the two paths are compared on

/// The model's and the side's state the routed flows change, as plain values.
struct CoreDiffDigest: Equatable, Sendable, CustomStringConvertible {
    var log: [String]
    /// player → client, session, generation.
    var players: [String: [String]]
    var nextSequence: Int64
    var lastCommittedTick: Int64
    var reservations: [String: Int]
    var pendingSequences: [Int64]
    var heldResults: Int
    var inFlightWork: Int
    var inputDrainScheduled: Bool
    var actionJobs: Int
    var playerServices: [String: UInt64]
    var violations: [String]
    var holdsDestroyTicket: Bool
    var failure: LandFailure?

    var description: String {
        "log \(log), players \(players), next sequence \(nextSequence), tick \(lastCommittedTick), reservations \(reservations), pending \(pendingSequences), held \(heldResults), work \(inFlightWork), drain \(inputDrainScheduled), jobs \(actionJobs), services \(playerServices), violations \(violations), destroy ticket \(holdsDestroyTicket), failure \(failure.map(\.description) ?? "-")"
    }

    init(_ read: KeeperDifferentialRead<CoreDiffState>) {
        let model = read.model
        log = model.state.log
        players = model.players.reduce(into: [:]) { out, entry in
            out[entry.key.rawValue] = [entry.value.clientID?.rawValue ?? "-", entry.value.lastSessionID?.rawValue ?? "-", "\(entry.value.generation.rawValue)"]
        }
        nextSequence = model.sequence.next
        lastCommittedTick = model.lastCommittedTickId
        reservations = model.rejoinReservations.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value.count }
        pendingSequences = model.pendingItems.map(\.sequence)
        heldResults = model.inputTurnResults.count
        inFlightWork = model.debugInFlightWork
        inputDrainScheduled = model.inputDrainScheduled
        actionJobs = model.actionJobs.count
        playerServices = read.serviceGenerations.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value }
        violations = read.violations
        holdsDestroyTicket = read.holdsDestroyTicket
        failure = read.failure
    }
}

/// One case's pair: the keeper, and the core twin built from a second keeper of the same land.
private struct CoreDiffPair {
    let keeper: LandKeeper<CoreDiffState>
    let harness: KeeperCoreHarness<CoreDiffState>
    let landID: String

    static func make(_ shape: CoreDiffShape, _ name: String) async -> CoreDiffPair {
        let landID = "core-diff:\(name):\(UUID().uuidString)"
        func keeper() -> LandKeeper<CoreDiffState> {
            LandKeeper<CoreDiffState>(definition: coreDiffDefinition(shape), initialState: CoreDiffState(), autoStartLoops: false, landID: landID)
        }
        let direct = keeper(), twinSource = keeper()
        await direct.awaitInitialization()
        await twinSource.awaitInitialization()
        let harness = KeeperCoreHarness(await twinSource.coreTwinForTesting())
        await harness.start()
        return CoreDiffPair(keeper: direct, harness: harness, landID: landID)
    }

    func digests() async -> (keeper: CoreDiffDigest, core: CoreDiffDigest) {
        let keeperDigest = CoreDiffDigest(await keeper.differentialReadForTesting())
        let coreDigest = CoreDiffDigest(await harness.differentialRead())
        return (keeperDigest, coreDigest)
    }

    /// The two paths' digests match, nothing is left on the core's side, and no deferred input
    /// reached the machine.
    func expectSame(_ step: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        let (keeperDigest, coreDigest) = await digests()
        #expect(keeperDigest == coreDigest, "\(step):\n keeper \(keeperDigest)\n core   \(coreDigest)", sourceLocation: sourceLocation)
        #expect(coreDigest.violations.isEmpty, "\(step): \(coreDigest.violations)", sourceLocation: sourceLocation)
        let leftover = await harness.differentialRead().coreWaitsLeft
        #expect(leftover == 0, "\(step): core waits left", sourceLocation: sourceLocation)
        let deferred = await harness.inputsSeen.filter { KeeperInputRoutes.deferred[$0] != nil }
        #expect(deferred.isEmpty, "\(step): deferred inputs sent: \(deferred)", sourceLocation: sourceLocation)
    }
}

// MARK: - The calls, on each path

private func session(_ player: String) -> PlayerSession { PlayerSession(playerID: player) }
private func caller(_ player: String, _ client: String) -> KeeperCaller {
    KeeperCaller(playerID: PlayerID(player), clientID: ClientID(client), sessionID: SessionID(client))
}

/// A join's result on either path, as a comparable value: the decision and admission, or the
/// error's description.
private enum CoreDiffJoinResult: Equatable {
    case joined(allowed: Bool, admitted: Bool)
    case failed(String)
}

private func keeperJoin(_ pair: CoreDiffPair, _ player: String, _ client: String) async -> CoreDiffJoinResult {
    do {
        let outcome = try await pair.keeper.joinReportingAdmission(
            session: session(player), clientID: ClientID(client), sessionID: SessionID(client), services: LandServices(), admitThroughTransport: false
        )
        if case .allow = outcome.decision { return .joined(allowed: true, admitted: outcome.admitted) }
        return .joined(allowed: false, admitted: outcome.admitted)
    } catch {
        return .failed(String(describing: error))
    }
}

private func coreJoin(_ pair: CoreDiffPair, _ player: String, _ client: String) async -> CoreDiffJoinResult {
    let call = KeeperJoinCall(session: session(player), clientID: ClientID(client), sessionID: SessionID(client), services: LandServices(), admitThroughTransport: false)
    do {
        guard case let .join(result) = try await pair.harness.call(.join(call, syncsInTurn: false)) else { return .failed("not a join reply") }
        switch result {
        case let .success(outcome):
            if case .allow = outcome.decision { return .joined(allowed: true, admitted: outcome.admitted) }
            return .joined(allowed: false, admitted: outcome.admitted)
        case let .failure(error):
            return .failed(String(describing: error))
        }
    } catch {
        return .failed("core: \(error)")
    }
}

private func keeperLeave(_ pair: CoreDiffPair, _ player: String, _ client: String) async -> String {
    do {
        try await pair.keeper.leave(playerID: PlayerID(player), clientID: ClientID(client), sessionID: SessionID(client))
        return "done"
    } catch {
        return String(describing: error)
    }
}

private func coreLeave(_ pair: CoreDiffPair, _ player: String, _ client: String) async -> String {
    do {
        guard case .done = try await pair.harness.call(.leave(caller(player, client))) else { return "not a leave reply" }
        return "done"
    } catch {
        return String(describing: error)
    }
}

/// Both paths, in turn: the keeper's, then the core's.
private func bothJoin(_ pair: CoreDiffPair, _ player: String, _ client: String) async -> (CoreDiffJoinResult, CoreDiffJoinResult) {
    (await keeperJoin(pair, player, client), await coreJoin(pair, player, client))
}

private func bothLeave(_ pair: CoreDiffPair, _ player: String, _ client: String) async -> (String, String) {
    (await keeperLeave(pair, player, client), await coreLeave(pair, player, client))
}

private func envelope(_ action: CoreDiffAction) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: CoreDiffAction.self), payload: AnyCodable(action))
}

/// An action's result on either path: the response's value, `.pending`, or the error's value.
private enum CoreDiffActionResult: Equatable {
    case completed(Int?)
    case pending
    case failed(CoreDiffError?, String)

    init(_ result: Result<ActionSubmission, any Error>) {
        switch result {
        case let .success(.completed(outcome)):
            if case let .response(response) = outcome { self = .completed((response as? CoreDiffAck)?.n) } else { self = .completed(nil) }
        case .success(.pending):
            self = .pending
        case let .failure(error):
            self = .failed(error as? CoreDiffError, String(describing: type(of: error)))
        }
    }
}

private func keeperAction(_ pair: CoreDiffPair, _ action: CoreDiffAction, _ player: String, _ client: String) async -> CoreDiffActionResult {
    let result = await Result { try await pair.keeper.submitAction(envelope(action), playerID: PlayerID(player), clientID: ClientID(client), sessionID: SessionID(client)) }
    return CoreDiffActionResult(result)
}

private func coreTicklessAction(_ pair: CoreDiffPair, _ action: CoreDiffAction, _ player: String, _ client: String) async -> CoreDiffActionResult {
    do {
        guard case let .action(result) = try await pair.harness.call(.action(envelope(action), caller(player, client))) else {
            return .failed(nil, "not an action reply")
        }
        return CoreDiffActionResult(result)
    } catch {
        return .failed(nil, "core: \(error)")
    }
}

private func coreTickAction(_ pair: CoreDiffPair, _ action: CoreDiffAction, _ player: String, _ client: String) async -> CoreDiffActionResult {
    guard case let .actionSubmission(result) = await pair.harness.ask(.admitAction(envelope(action), caller(player, client))) else {
        return .failed(nil, "not an action answer")
    }
    return CoreDiffActionResult(result)
}

/// An event's result on either path: done, or the error's value.
private func keeperEvent(_ pair: CoreDiffPair, _ event: CoreDiffEvent, _ player: String, _ client: String) async -> String {
    do {
        try await pair.keeper.handleClientEvent(AnyClientEvent(event), playerID: PlayerID(player), clientID: ClientID(client), sessionID: SessionID(client))
        return "done"
    } catch let error as CoreDiffError {
        return "error \(error.token)"
    } catch {
        return String(describing: error)
    }
}

private func coreEvent(_ pair: CoreDiffPair, _ event: CoreDiffEvent, _ player: String, _ client: String) async -> String {
    do {
        guard case .done = try await pair.harness.call(.clientEvent(AnyClientEvent(event), caller(player, client))) else { return "not an event reply" }
        return "done"
    } catch let error as CoreDiffError {
        return "error \(error.token)"
    } catch {
        return String(describing: error)
    }
}

// MARK: - The cases

private let shapes: [CoreDiffShape] = [
    CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false),
    CoreDiffShape(tick: false, joinResolvers: true, leaveResolver: true),
    CoreDiffShape(tick: true, joinResolvers: false, leaveResolver: false),
    CoreDiffShape(tick: true, joinResolvers: true, leaveResolver: true),
]

@Suite("The keeper's routed flows on a test core match the keeper's own path (#700 K2-1)", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct KeeperCoreDifferentialTests {
    @Test("A join and a leave", arguments: shapes)
    func joinThenLeave(shape: CoreDiffShape) async {
        let pair = await CoreDiffPair.make(shape, "join-leave")
        let joined = await bothJoin(pair, "p1", "c1")
        #expect(joined.0 == joined.1 && joined.0 == .joined(allowed: true, admitted: false), "\(joined)")
        await pair.expectSame("after the join")
        let left = await bothLeave(pair, "p1", "c1")
        #expect(left.0 == left.1 && left.0 == "done", "\(left)")
        await pair.expectSame("after the leave")
    }

    @Test("A duplicate login kicks the old session, then joins", arguments: shapes)
    func kickThenJoin(shape: CoreDiffShape) async {
        let pair = await CoreDiffPair.make(shape, "kick")
        _ = await bothJoin(pair, "p1", "c1")
        let again = await bothJoin(pair, "p1", "c2")
        #expect(again.0 == again.1 && again.0 == .joined(allowed: true, admitted: false), "\(again)")
        await pair.expectSame("after the kick and the join")
    }

    @Test("A kick whose OnLeave resolver throws fails the join with the leave's error, and ends the reservation", arguments: [false, true])
    func kickWithFailingLeave(tick: Bool) async {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: tick, joinResolvers: false, leaveResolver: true), "kick-fails")
        _ = await bothJoin(pair, "p1", "c1")
        CoreDiffLeaveFailures.set(pair.landID, failing: true)
        defer { CoreDiffLeaveFailures.set(pair.landID, failing: false) }
        let again = await bothJoin(pair, "p1", "c2")
        #expect(again.0 == again.1, "\(again)")
        // The leave's own error, as the resolver executor wraps it.
        #expect(again.0 == .failed("Resolver 'CoreDiffLeaveResolver' failed: \(CoreDiffError(token: 77))"), "the leave's own error: \(again.0)")
        await pair.expectSame("after the failed kick")
        let reservations = await pair.digests().core.reservations
        #expect(reservations.values.allSatisfy { $0 == 0 }, "the reservation ended: \(reservations)")
    }

    @Test("A kick whose leave ends in L1 (no OnLeave) joins in the same step", arguments: [false, true])
    func kickWithImmediateLeave(tick: Bool) async {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: tick, joinResolvers: false, leaveResolver: false, noOnLeave: true), "kick-at-once")
        _ = await bothJoin(pair, "p1", "c1")
        let again = await bothJoin(pair, "p1", "c2")
        #expect(again.0 == again.1 && again.0 == .joined(allowed: true, admitted: false), "\(again)")
        await pair.expectSame("after the kick")
    }

    @Test("A kick that empties a one-player land stages the destroy timer, and the join in the same step cancels it before its start (§16 item 10, D14)", arguments: [false, true])
    func kickCancelsStagedDestroyTimer(tick: Bool) async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: tick, joinResolvers: false, leaveResolver: false, noOnLeave: true, destroysWhenEmpty: true), "kick-destroy")
        _ = await bothJoin(pair, "p1", "c1")
        // The join itself cancels no ticket: the land was never empty with a player in it.
        let again = await bothJoin(pair, "p1", "c2")
        #expect(again.0 == again.1 && again.0 == .joined(allowed: true, admitted: false), "\(again)")
        await pair.expectSame("after the kick and the join")
        let keeperRead = await pair.keeper.differentialReadForTesting()
        let coreRead = await pair.harness.differentialRead()
        for (path, read) in [("keeper", keeperRead), ("core", coreRead)] {
            #expect(!read.holdsDestroyTicket, "\(path): the join cleared the slot")
            let ticket = try #require(read.lastDestroyTicket, "\(path): L1 staged the timer")
            // The flush ran the staged start after the cancel: the task is installed and
            // cancelled at once. Its delay is an hour, so a task that wasn't cancelled would hang
            // this await until the suite's time limit.
            let task = try #require(ticket.installedTask, "\(path): the staged start installed its task")
            #expect(task.isCancelled, "\(path): the install saw the cancel")
            await task.value
        }
        #expect(!pair.keeper.isDraining, "the timer ran no destroy")
    }

    @Test("A failure item in a tickless input turn fails the land the same way on both paths, up to the drain's start (§16 item 13's K2-1 part)")
    func failureItemFailsTheLand() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false)
        let landID = "core-diff:failure:\(UUID().uuidString)"
        func keeper() -> LandKeeper<CoreDiffState> {
            LandKeeper<CoreDiffState>(definition: coreDiffDefinition(shape), initialState: CoreDiffState(), autoStartLoops: false, landID: landID)
        }
        let failure = LandFailure(kind: .syncPlan, detail: "the differential's failure", position: LandFailurePosition(stage: .syncPhase))
        let direct = keeper(), twinSource = keeper()
        for k in [direct, twinSource] {
            await k.awaitInitialization()
            _ = try await k.joinReportingAdmission(session: session("p1"), clientID: ClientID("c1"), sessionID: SessionID("c1"), services: LandServices(), admitThroughTransport: false)
            // The join's drain has ended: a drain still running would apply the failure item.
            await k.waitForInFlightWorkForTesting()
            await k.waitForInputDrainIdleForTesting()
        }

        // The twin's source queues the failure item with its kick held, and no drain of its own
        // runs, so the copy carries the pending item and the core's drain applies it.
        let kickHold = WatermarkGate(), sourceDrainHold = WatermarkGate()
        await twinSource.installHolds(HoldRegistry<LandKeeperHoldPoint>()
            .on(.serverInputKick, arrival: 1) { await kickHold.enterAndWait() }
            .on(.inputDrain) { await sourceDrainHold.enterAndWait() }.hook)
        await twinSource.submitLandFailure(failure)
        guard await kickHold.waitUntilEntered() else { return }
        let harness = KeeperCoreHarness(await twinSource.coreTwinForTesting())
        await harness.start()
        await harness.drive(.inputDrainDue)

        // The keeper's path, held at its teardown's first step: what the step did, before the drain.
        let teardownHold = WatermarkGate()
        await direct.installHolds(HoldRegistry<LandKeeperHoldPoint>().on(.landFailedTeardown, arrival: 1) { await teardownHold.enterAndWait() }.hook)
        await direct.submitLandFailure(failure)
        #expect(await direct.waitForFailureForTesting())
        guard await teardownHold.waitUntilEntered() else { return }
        await direct.waitForInFlightWorkForTesting()

        var keeperDigest = CoreDiffDigest(await direct.differentialReadForTesting())
        let coreDigest = CoreDiffDigest(await harness.differentialRead())
        // The twin's source began the kick's work count before its hold; that kick is the
        // source's task, not the core's, so its end never reaches the copy.
        keeperDigest.inFlightWork += 1
        #expect(keeperDigest == coreDigest, "\n keeper \(keeperDigest)\n core   \(coreDigest)")
        #expect(coreDigest.failure?.kind == failure.kind && coreDigest.players.isEmpty && coreDigest.pendingSequences.isEmpty, "\(coreDigest)")
        #expect(coreDigest.violations.isEmpty, "\(coreDigest.violations)")
        #expect(await harness.differentialRead().coreWaitsLeft == 0)
        // The core's flush ran the drain's staged start: with no keeper behind the twin's
        // reference, it starts no teardown (K2-1b's), and only the waiters are resumed.
        #expect(await harness.inputsSeen == ["startLand", "inputDrainDue"])

        teardownHold.release()
        sourceDrainHold.release()
        kickHold.release()
    }

    @Test("A tick that emits two events: the same model on both paths, the events reach the port with their emit-time numbers, and nothing is unlent (§16 item 11)")
    func eventfulTick() async throws {
        let shape = CoreDiffShape(tick: true, joinResolvers: false, leaveResolver: false)
        let landID = "core-diff:tick:\(UUID().uuidString)"
        // An in-turn port on each path, which hears each event with its output sequence.
        let keeperTransport = FoldRecordingTransport(records: false)
        let coreTransport = FoldRecordingTransport(records: false)
        let direct = LandKeeper<CoreDiffState>(definition: coreDiffDefinition(shape), initialState: CoreDiffState(), autoStartLoops: false, landID: landID, transport: keeperTransport)
        let source = LandKeeper<CoreDiffState>(definition: coreDiffDefinition(shape), initialState: CoreDiffState(), autoStartLoops: false, landID: landID)
        await direct.awaitInitialization()
        await source.awaitInitialization()
        let harness = KeeperCoreHarness(await source.coreTwinForTesting(transport: coreTransport))
        await harness.start()
        let pair = CoreDiffPair(keeper: direct, harness: harness, landID: landID)
        let first = await pair.digests().core.nextSequence

        await direct.stepTickOnce()
        await harness.drive(.tickDue(fold: nil, foldStart: nil, syncsInTurn: true))

        await pair.expectSame("after the tick")
        let after = await pair.digests().core
        #expect(after.log.last == "tick", "\(after)")
        #expect(keeperTransport.receivedEventSequences == coreTransport.receivedEventSequences, "keeper \(keeperTransport.receivedEventSequences), core \(coreTransport.receivedEventSequences)")
        #expect(coreTransport.receivedEventSequences == [first, first + 1], "numbered from the lent counter in emit order: \(coreTransport.receivedEventSequences)")
        let keeperRead = await direct.differentialReadForTesting()
        let coreRead = await harness.differentialRead()
        #expect(keeperRead.unlentCount == 0 && coreRead.unlentCount == 0, "unlent: keeper \(keeperRead.unlentCount), core \(coreRead.unlentCount)")
    }

    @Test("A sync folded into the next tick, round trip: the fold comes out of .syncDue's flush, goes back in .tickDue, and the transport's report and the counters match the keeper's (§16 item 12)")
    func foldRoundTrip() async throws {
        // The keeper's path, as `InTurnSyncFoldReportTests` drives it: its loops started, the tick
        // loop asleep, a sync 1 ms before the tick deadline, the tick 20 ms after it (late).
        let keeperTransport = FoldRecordingTransport(records: true)
        let signal = FirstTickSleepSignal()
        let keeper = TickLoopClock.$forNewKeepers.withValue(signal.tickLoopClock) {
            LandKeeper<FoldReportState>(definition: foldReportLandEmitting(), initialState: FoldReportState(), enableLoopPhaseOffset: false, transport: keeperTransport)
        }
        try await keeper.join(playerID: PlayerID("fold-player"), clientID: ClientID("fold-client"), sessionID: SessionID("fold-session"))
        await keeper.awaitInitialization()
        await signal.waitUntilReached()
        let keeperDeadline = ContinuousClock.now
        await keeper.setNextTickDeadlineForTesting(keeperDeadline)
        await keeper.runSyncLoopIterationForTesting(at: keeperDeadline - .milliseconds(1))
        await keeper.stepTickOnceForTesting(at: keeperDeadline + .milliseconds(20))
        let keeperCounters = await keeper.cadenceCountersForTesting()

        // The core's path, from a loop-less twin with its own transport attached.
        let source = LandKeeper<FoldReportState>(definition: foldReportLandEmitting(), initialState: FoldReportState(), autoStartLoops: false, enableLoopPhaseOffset: false)
        try await source.join(playerID: PlayerID("fold-player"), clientID: ClientID("fold-client"), sessionID: SessionID("fold-session"))
        let coreTransport = FoldRecordingTransport(records: true)
        let harness = KeeperCoreHarness(await source.coreTwinForTesting(transport: coreTransport))
        await harness.start()
        let coreDeadline = ContinuousClock.now
        await harness.drive(.syncDue(now: coreDeadline - .milliseconds(1), tickDeadline: coreDeadline, foldPending: false, syncsInTurn: true))
        let folds = await harness.flushedFolds
        try #require(folds.count == 1, "the fold left the sync's step for .land")
        await harness.drive(.tickDue(fold: folds[0], foldStart: coreDeadline + .milliseconds(20), syncsInTurn: true))
        let model = await harness.differentialRead().model

        #expect(keeperTransport.folds.count == 1 && keeperTransport.folds == coreTransport.folds, "keeper \(keeperTransport.folds), core \(coreTransport.folds)")
        #expect(coreTransport.folds.first?.isLate == true)
        #expect(keeperCounters.foldedSyncs == model.foldedSyncs && keeperCounters.overdueFoldedSyncs == model.overdueFoldedSyncs && keeperCounters.lateFoldedSyncs == model.lateFoldedSyncs,
                "keeper \(keeperCounters), core \((model.foldedSyncs, model.overdueFoldedSyncs, model.lateFoldedSyncs))")
        #expect(await harness.droppedOutputs == 0)
        await keeper.forceShutdown()
    }

    @Test("A fold emitted before the owner started .land is dropped and counted by the core; the debug assert is on by default")
    func foldBeforeLandStarted() async throws {
        let source = LandKeeper<FoldReportState>(definition: foldReportLandEmitting(), initialState: FoldReportState(), autoStartLoops: false, enableLoopPhaseOffset: false)
        await source.awaitInitialization()
        let twin = await source.coreTwinForTesting(transport: FoldRecordingTransport(records: true))
        #expect(twin.store.assertsOnUnstartedLandKey, "on by default")
        twin.store.assertsOnUnstartedLandKey = false
        let harness = KeeperCoreHarness(twin)
        await harness.start(startsLand: false)
        let deadline = ContinuousClock.now
        await harness.drive(.syncDue(now: deadline - .milliseconds(1), tickDeadline: deadline, foldPending: false, syncsInTurn: true))
        #expect(await harness.flushedFolds.isEmpty)
        #expect(await harness.droppedOutputs == 1)
    }

    @Test("An action that arrives while the drain waits on its record joins the same drain: one drain end, two records, the same model as two actions in a row")
    func actionJoinsTheRunningDrain() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false)
        let landID = "core-diff:mid-drain:\(UUID().uuidString)"
        func keeper() -> LandKeeper<CoreDiffState> {
            LandKeeper<CoreDiffState>(definition: coreDiffDefinition(shape), initialState: CoreDiffState(), autoStartLoops: false, landID: landID)
        }
        let direct = keeper(), source = keeper()
        for k in [direct, source] {
            await k.awaitInitialization()
            _ = try await k.joinReportingAdmission(session: session("p1"), clientID: ClientID("c1"), sessionID: SessionID("c1"), services: LandServices(), admitThroughTransport: false)
            // The join's work ends when its turn answers it; its drain ends after.
            await k.waitForInFlightWorkForTesting()
            await k.waitForInputDrainIdleForTesting()
        }
        let gate = WatermarkGate()
        let harness = KeeperCoreHarness(await source.coreTwinForTesting(), recordGate: gate)
        // After `start`, which binds the store (the probe is installed through it).
        await harness.start()
        let (drainEnds, drainEndCount) = await harness.drainEnds()

        // A's drain waits on its record; B's intake runs meanwhile and finds the drain scheduled.
        let a = Task { await coreTicklessAction(CoreDiffPair(keeper: direct, harness: harness, landID: landID), CoreDiffAction(n: 1, fails: false), "p1", "c1") }
        guard await gate.waitUntilEntered("A's record") else { return }
        await harness.drive(.action(envelope(CoreDiffAction(n: 2, fails: false)), caller("p1", "c1")))
        gate.release()
        #expect(await a.value == .completed(1))
        var ends = drainEnds.makeAsyncIterator()
        _ = await ends.next()

        // The keeper's path: the same two actions, one after the other.
        let pair = CoreDiffPair(keeper: direct, harness: harness, landID: landID)
        #expect(await keeperAction(pair, CoreDiffAction(n: 1, fails: false), "p1", "c1") == .completed(1))
        #expect(await keeperAction(pair, CoreDiffAction(n: 2, fails: false), "p1", "c1") == .completed(2))
        await direct.waitForInputDrainIdleForTesting()

        await pair.expectSame("after both actions")
        let seen = await harness.inputsSeen
        #expect(drainEndCount.value == 1, "one drain took both actions: \(drainEndCount.value) drain ends")
        #expect(seen.filter { $0 == "recordTaken" }.count == 2, "\(seen)")
        #expect(await harness.differentialRead().model.state.log.suffix(2) == ["action:1", "action:2"])
    }

    @Test("A tickless action answers with its response or its handler's error", arguments: [false, true])
    func ticklessAction(fails: Bool) async {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "action")
        _ = await bothJoin(pair, "p1", "c1")
        let action = CoreDiffAction(n: 5, fails: fails)
        let keeperResult = await keeperAction(pair, action, "p1", "c1")
        let coreResult = await coreTicklessAction(pair, action, "p1", "c1")
        #expect(keeperResult == coreResult, "keeper \(keeperResult), core \(coreResult)")
        #expect(keeperResult == (fails ? .failed(CoreDiffError(token: 5), "CoreDiffError") : .completed(5)), "\(keeperResult)")
        // The work count ended on both paths (the digest compares it).
        await pair.expectSame("after the action")
        // With no recorder the submission is nil, and the drain still takes the record's run and
        // its `.recordTaken` (the empty-record stand-in): the keeper's yield there lets other
        // calls join the same drain, and the core takes the next step meanwhile.
        let seen = await pair.harness.inputsSeen
        #expect(seen.contains("recordTaken"), "\(seen)")
        #expect(await pair.digests().core.inFlightWork == 0)
    }

    @Test("A tick land's action is appended and acknowledged at intake")
    func tickAction() async {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: true, joinResolvers: false, leaveResolver: false), "tick-action")
        _ = await bothJoin(pair, "p1", "c1")
        let action = CoreDiffAction(n: 6, fails: false)
        let keeperResult = await keeperAction(pair, action, "p1", "c1")
        let coreResult = await coreTickAction(pair, action, "p1", "c1")
        #expect(keeperResult == coreResult, "keeper \(keeperResult), core \(coreResult)")
        await pair.expectSame("after the tick land's action")
    }

    @Test("A tickless client event answers done or its handler's error", arguments: [false, true])
    func ticklessClientEvent(fails: Bool) async {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "event")
        _ = await bothJoin(pair, "p1", "c1")
        let event = CoreDiffEvent(n: 8, fails: fails)
        let keeperResult = await keeperEvent(pair, event, "p1", "c1")
        let coreResult = await coreEvent(pair, event, "p1", "c1")
        #expect(keeperResult == coreResult, "keeper \(keeperResult), core \(coreResult)")
        #expect(keeperResult == (fails ? "error 8" : "done"))
        await pair.expectSame("after the event")
        #expect(await pair.digests().core.inFlightWork == 0)
    }

    // MARK: Review round 1 on #938

    @Test("Each core has its own side box: two twins of one source share no store, and a step on one leaves the other's side unchanged")
    func eachCoreHasItsOwnBox() async {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false)
        let source = LandKeeper<CoreDiffState>(definition: coreDiffDefinition(shape), initialState: CoreDiffState(), autoStartLoops: false, landID: "core-diff:box:\(UUID().uuidString)")
        await source.awaitInitialization()
        let a = await source.coreTwinForTesting()
        let b = await source.coreTwinForTesting()
        #expect(a.store !== b.store)
        let first = KeeperCoreHarness(a), second = KeeperCoreHarness(b)
        await first.start()
        await second.start()
        let before = CoreDiffDigest(await second.differentialRead())
        let pair = CoreDiffPair(keeper: source, harness: first, landID: "box")
        #expect(await coreJoin(pair, "p1", "c1") == .joined(allowed: true, admitted: false))
        let stepped = CoreDiffDigest(await first.differentialRead())
        let after = CoreDiffDigest(await second.differentialRead())
        #expect(stepped.players.keys.sorted() == ["p1"], "\(stepped)")
        #expect(after == before, "the other core's side moved:\n before \(before)\n after  \(after)")
    }

    @Test("A join that syncs in the turn is refused on the core with a named refusal, and changes nothing (K2-2 routes it with the binding token)")
    func joinSyncingInTheTurnIsRefused() async {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: true, joinResolvers: false, leaveResolver: false), "refuse-join")
        let before = CoreDiffDigest(await pair.harness.differentialRead())
        let call = KeeperJoinCall(session: session("p1"), clientID: ClientID("c1"), sessionID: SessionID("c1"), services: LandServices(), admitThroughTransport: true)
        let reply: String
        do {
            _ = try await pair.harness.call(.join(call, syncsInTurn: true))
            reply = "replied"
        } catch let refusal as KeeperCoreRefusal {
            reply = refusal.reason
        } catch {
            reply = "\(error)"
        }
        #expect(reply == "a join syncing in the turn needs the binding token (K2-2)")
        let read = await pair.harness.differentialRead()
        #expect(read.violations == ["core side: refused join: a join syncing in the turn needs the binding token (K2-2)"], "\(read.violations)")
        var after = CoreDiffDigest(read)
        after.violations = before.violations
        #expect(after == before, "the refused join changed the core:\n before \(before)\n after  \(after)")
    }

    @Test("Any input of a tickless land with a transport attached is refused on the core (its input turn reads the binding inside the drain)")
    func ticklessLandWithATransportIsRefused() async {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false)
        let source = LandKeeper<CoreDiffState>(definition: coreDiffDefinition(shape), initialState: CoreDiffState(), autoStartLoops: false, landID: "core-diff:refuse-tickless:\(UUID().uuidString)")
        await source.awaitInitialization()
        let harness = KeeperCoreHarness(await source.coreTwinForTesting(transport: FoldRecordingTransport(records: false)))
        await harness.start()
        let reason: String
        do {
            _ = try await harness.call(.action(envelope(CoreDiffAction(n: 1, fails: false)), caller("p1", "c1")))
            reason = "replied"
        } catch let refusal as KeeperCoreRefusal {
            reason = refusal.reason
        } catch {
            reason = "\(error)"
        }
        #expect(reason == "a tickless land with a transport needs the binding token (K2-2)")
        let read = await harness.differentialRead()
        #expect(read.violations == ["core side: refused action: a tickless land with a transport needs the binding token (K2-2)"], "\(read.violations)")
        #expect(read.model.debugInFlightWork == 0 && !read.model.inputDrainScheduled)
    }
}
