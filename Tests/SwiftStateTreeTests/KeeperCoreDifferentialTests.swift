// Tests/SwiftStateTreeTests/KeeperCoreDifferentialTests.swift
//
// #700 K2-1's differential: each routed flow is driven twice on the same inputs, through the
// keeper's own path and through a test `TurnCore` running `KeeperModel`, and the replies, the
// model and the side are compared (plan §6). The core isn't wired into the keeper: the harness
// below is the core's only adopter, and it starts `.land` itself (`.startLand`).
//
// Out of scope here (plan §16 items 16–18): the input drain's hold and its idle waiters, the
// action jobs, the initialization and the destroy drain. No core-driven case holds
// `.inputDrain` or waits on the drain's idle waiters (two cases hold it on the keeper's or the
// twin source's side), and none starts a job or sends a deferred input; the harness checks the
// last two.

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

@Payload
struct CoreDiffServerInput: ServerInputPayload {
    let n: Int
}

/// The core's clock in the freeze cases: `now` moves only by `advance`, and a sleep returns once
/// `now` reaches its instant, so a freeze's timeout fires when the case says (the keeper's path
/// keeps its own clock: its timeouts are a short one against a held work, or one that can't fire).
final class CoreDiffClock: TurnClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = TurnInstant(nanoseconds: 0)
    private var sleepers: [(instant: TurnInstant, resume: CheckedContinuation<Void, Never>)] = []

    var now: TurnInstant { lock.withLock { current } }

    func sleep(until instant: TurnInstant) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready: Bool = lock.withLock {
                    if current >= instant || Task.isCancelled { return true }
                    sleepers.append((instant, continuation))
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let woken: [CheckedContinuation<Void, Never>] = lock.withLock {
                defer { sleepers.removeAll() }
                return sleepers.map(\.resume)
            }
            // A superseded sleep's return does nothing (`TurnClock`), so waking every sleeper is safe.
            woken.forEach { $0.resume() }
        }
    }

    func advance(by duration: Duration) {
        let woken: [CheckedContinuation<Void, Never>] = lock.withLock {
            current = current + duration
            let due = sleepers.filter { $0.instant <= current }
            sleepers.removeAll { $0.instant <= current }
            return due.map(\.resume)
        }
        woken.forEach { $0.resume() }
    }
}

/// A gate armed after the setup, so the setup's own records pass: the next record (or the next
/// `.turnRecord` hold of the keeper's path) enters it.
final class CoreDiffArmedGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed: WatermarkGate?
    func arm(_ gate: WatermarkGate) { lock.withLock { armed = gate } }
    func take() -> WatermarkGate? { lock.withLock { defer { armed = nil }; return armed } }
}

/// The latest value set, read from any task.
final class CoreDiffLatest<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Value?
    func set(_ value: Value) { lock.withLock { latest = value } }
    var value: Value? { lock.withLock { latest } }
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

/// An action whose resolver runs in a job (K2-2 plan, commit 0): it throws
/// `CoreDiffError(token: n)` when `fails`, and waits on its land's gate when one is set.
@Payload
struct CoreDiffJobAction: ActionPayload {
    typealias Response = CoreDiffAck
    let n: Int
    let fails: Bool
}

@PlainData
struct CoreDiffJobResolver: Resolver {
    typealias Dependencies = NoServices
    typealias Output = CoreDiffOutput
    let n: Int
    let fails: Bool
    let landID: String
    func resolve(_ deps: NoServices) async throws -> CoreDiffOutput {
        await CoreDiffJobGates.gate(landID)?.enterAndWait()
        if fails { throw CoreDiffError(token: n) }
        return CoreDiffOutput(value: n)
    }
}

/// OnInitialize's resolver: it waits at its land's gate when one is set, then throws when the
/// land is marked failing (Review on #966, MF2: the core twins of the keeper's T-cases).
@PlainData
struct CoreDiffInitResolver: Resolver {
    typealias Dependencies = NoServices
    typealias Output = CoreDiffOutput
    let landID: String
    func resolve(_ deps: NoServices) async throws -> CoreDiffOutput {
        await CoreDiffInitGates.gate(landID)?.enterAndWait()
        if CoreDiffInitGates.fails(landID) { throw CoreDiffError(token: -1) }
        return CoreDiffOutput(value: 1)
    }
}

/// OnInitialize's gate and failure mark, by land ID (both paths share the pair's land ID).
enum CoreDiffInitGates {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gates: [String: WatermarkGate] = [:]
    nonisolated(unsafe) private static var failing: Set<String> = []
    static func set(_ landID: String, _ gate: WatermarkGate?) { lock.withLock { gates[landID] = gate } }
    static func gate(_ landID: String) -> WatermarkGate? { lock.withLock { gates[landID] } }
    static func setFails(_ landID: String, _ fails: Bool) { lock.withLock { if fails { failing.insert(landID) } else { failing.remove(landID) } } }
    static func fails(_ landID: String) -> Bool { lock.withLock { failing.contains(landID) } }
}

/// OnLeave's resolver gate, by land ID: taken by the next OnLeave resolver that runs, so a
/// case holds one leave on one path at a time.
enum CoreDiffLeaveGates {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gates: [String: WatermarkGate] = [:]
    static func arm(_ landID: String, _ gate: WatermarkGate) { lock.withLock { gates[landID] = gate } }
    static func take(_ landID: String) -> WatermarkGate? { lock.withLock { gates.removeValue(forKey: landID) } }
}

/// A job's resolver gate, by land ID: a case that holds the job sets it on both lands.
enum CoreDiffJobGates {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gates: [String: WatermarkGate] = [:]
    static func set(_ landID: String, _ gate: WatermarkGate?) { lock.withLock { gates[landID] = gate } }
    static func gate(_ landID: String) -> WatermarkGate? { lock.withLock { gates[landID] } }
}

struct CoreDiffJoinResolver: ContextResolver {
    typealias Output = CoreDiffOutput
    static func resolve(ctx: ResolverContext) async throws -> CoreDiffOutput { CoreDiffOutput(value: 1) }
}

struct CoreDiffLeaveResolver: ContextResolver {
    typealias Output = CoreDiffOutput
    static func resolve(ctx: ResolverContext) async throws -> CoreDiffOutput {
        await CoreDiffLeaveGates.take(ctx.landID)?.enterAndWait()
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
    /// `DestroyWhenEmpty(after: 50 ms)`: an emptied land stages the timer's start, and a timer
    /// nobody cancels reaches `.destroyTimerFired` soon.
    var destroysWhenEmpty = false
    /// The destroy timer's delay: 50 ms where a case waits for it to fire, 1 h where it must not.
    var destroyDelay: Duration = .milliseconds(50)
    /// OnInitialize with a resolver (tickless, no destroy timer): it logs "init:<value>", then
    /// fires the land's `CoreDiffHandlerReentry` hook (the keeper's T11 shape, when registered).
    var onInitialize = false
    /// OnInitialize in two stages whose `validate` throws (Review on #966, MF2 (b)), after it
    /// fires the land's `CoreDiffHandlerReentry` hook (when registered).
    var initializeRefuses = false

    var description: String {
        "\(tick ? "tick" : "tickless"), join resolvers \(joinResolvers), leave resolver \(leaveResolver)\(noOnLeave ? ", no OnLeave" : "")\(destroysWhenEmpty ? ", destroys when empty" : "")"
    }
}

@Sendable private func coreDiffTick(_ state: inout CoreDiffState, _ ctx: LandContext) {
    state.log.append("tick")
    // The tokenless step's re-entry (a handler reaching a guarded entry, not through `callOut`).
    CoreDiffHandlerReentry.fire(ctx.landID)
    ctx.emitEvent(CoreDiffServerEvent(n: 1), to: .all)
    ctx.emitEvent(CoreDiffServerEvent(n: 2), to: .all)
}

private func coreDiffDefinition(_ shape: CoreDiffShape) -> LandDefinition<CoreDiffState> {
    Land("core-diff", using: CoreDiffState.self) {
        AccessControl { MaxPlayers(4) }
        ClientEvents { Register(CoreDiffEvent.self) }
        ServerEvents { Register(CoreDiffServerEvent.self) }
        Rules {
            HandleServerInput(CoreDiffServerInput.self) { state, input, _ in state.log.append("input:\(input.n)") }
            if shape.joinResolvers {
                CanJoin(resolvers: CoreDiffJoinResolver.self) { _, session, _, _ in .allow(playerID: PlayerID(session.playerID)) }
                OnJoin(resolvers: CoreDiffJoinResolver.self) { state, _, ctx in state.log.append("join:\(ctx.playerID.rawValue)") }
            } else {
                CanJoin { _, session, _ in .allow(playerID: PlayerID(session.playerID)) }
                OnJoin { state, ctx in
                    state.log.append("join:\(ctx.playerID.rawValue)")
                    // The freeze cases' land failure: a join isn't held by the freeze.
                    CoreDiffHandlerReentry.fire(ctx.landID)
                }
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
            HandleAction(CoreDiffJobAction.self, resolvers: { _, action, ctx in
                CoreDiffJobResolver(n: action.n, fails: action.fails, landID: ctx.landID)
            }, validate: { _, _, _, _ in }, apply: { state, action, output, _ in
                state.log.append("job:\(action.n):\(output?.value ?? -1)")
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
        if shape.initializeRefuses {
            Lifetime {
                // `validate` fires the land's re-entry hook first, when a case registered one.
                OnInitialize(validate: { _, ctx in
                    CoreDiffHandlerReentry.fire(ctx.landID)
                    throw CoreDiffError(token: -2)
                }, apply: { state, _ in state.log.append("init:applied") })
                // Destroy handlers a failed initialization's drain must skip (#104), so a case
                // can see that they didn't run (Review r2 on #969).
                DestroyWhenEmpty(after: .seconds(3600)) { state, _ in state.log.append("destroyWhenEmpty") }
                OnFinalize { state, _ in state.log.append("finalize") }
                AfterFinalize { _, _ in }
            }
        } else if shape.onInitialize {
            Lifetime {
                OnInitialize(resolvers: { _, ctx in CoreDiffInitResolver(landID: ctx.landID) }) { state, output, ctx in
                    state.log.append("init:\(output?.value ?? -1)")
                    CoreDiffHandlerReentry.fire(ctx.landID)
                }
            }
        } else if shape.tick && shape.destroysWhenEmpty {
            Lifetime {
                Tick(every: .seconds(3600)) { state, ctx in coreDiffTick(&state, ctx) }
                DestroyWhenEmpty(after: shape.destroyDelay)
            }
        } else if shape.tick {
            Lifetime {
                Tick(every: .seconds(3600)) { state, ctx in coreDiffTick(&state, ctx) }
            }
        } else if shape.destroysWhenEmpty {
            Lifetime {
                DestroyWhenEmpty(after: shape.destroyDelay)
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
    /// The next `.awaitRecordTaken` effect after `arm` waits here (the freeze cases' held work).
    nonisolated let armedRecordGate = CoreDiffArmedGate()
    /// The owner's `.drainStart` hold (the keeper's `holds.at(.drainStart)`, M7): when armed, the
    /// next drain start waits at it before `.drainStart` is sent (P1b-1).
    nonisolated let armedDrainStartGate = CoreDiffArmedGate()
    /// The owner's `.landFailedTeardown` hold (the keeper's `runFailureTeardown`): when armed,
    /// the next failure teardown waits at it before the port hears of the failure.
    nonisolated let armedFailureTeardownGate = CoreDiffArmedGate()
    /// "drain finished" once per flushed `.detachTransport`: the event after `.drainFinished`'s
    /// step, so a case waits for that step itself, not for the port's `onLandDestroyed`, which
    /// the notify effect calls before the step (Review r1 on #969).
    nonisolated let drainFinishes = EventLog()
    /// The last `.initializeResolvers` effect's request, kept as it starts (a stale resolution's
    /// case builds its input from it).
    nonisolated let initializeResolvingSeen = CoreDiffLatest<LandKeeper<State>.InitializeResolving>()
    /// Each `.initializeRecord` effect, as it starts its wait for the recorder: "awaiting the
    /// hand-off", or "no submission" when the step gave it none (966 mutant at the record's
    /// staging).
    nonisolated let recordHandOffs = EventLog()
    /// The twin's source keeper, whose executor this actor shares (as the facade will share the
    /// core's, plan §3): a callback that re-enters the keeper with `assumeIsolated` then runs.
    nonisolated let owner: LandKeeper<State>
    nonisolated var unownedExecutor: UnownedSerialExecutor { owner.unownedExecutor }
    /// §16 item 5: an input and a query the next flush makes, in that order, and what it saw.
    private var armedFlush: (input: KeeperInput<State>, query: KeeperQuery)?
    private(set) var flushQueryAnswers: [(answer: KeeperAnswer<State>, pendingAtQuery: [Int64], tickAtQuery: Int64)] = []

    init(_ twin: (model: KeeperModel<State>, behavior: KeeperBehavior<State>, store: KeeperSideStore, owner: LandKeeper<State>), recordGate: WatermarkGate? = nil,
         clock: CoreDiffClock? = nil) {
        self.recordGate = recordGate
        owner = twin.owner
        if let clock {
            core = TurnCore(machine: twin.model, behavior: twin.behavior, queueLimit: 1024, maxReleasesPerBatch: 64, clock: clock)
        } else {
            core = TurnCore(machine: twin.model, behavior: twin.behavior, queueLimit: 1024, maxReleasesPerBatch: 64, clock: SystemTurnClock())
        }
        store = twin.store
        definition = twin.behavior.definition
    }

    /// Binds the side store to this actor and starts `.land` (as the owner's initialization
    /// will, K2-2), unless `startsLand` is false.
    func start(startsLand: Bool = true) {
        store.bind(to: self)
        let stepped = steppedEvents
        store.withSide { side in side.onInputSteppedForTesting = { stepped.append($0) } }
        guard startsLand else { return }
        note(.startLand)
        send(.startLand)
    }

    var droppedOutputs: Int { core.stats.droppedOutputs }

    /// Yields once per input drain's end (the side's `input-drain-end` probe), and counts them.
    /// Install after `start` (the store must be bound) and before the drain.
    /// Installs the side's probe (the keeper's `setInTurnProbeForTesting`).
    func setProbe(_ probe: (@Sendable (String) -> Void)?) {
        store.withSide { side in side.probe = probe }
    }

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

    /// A call whose task's cancel withdraws it (`.cancelsCall`): the facade's joins from commit 4.
    /// A barrier wait it is in ends `.withdrawn` (#953), and the caller gets `CancellationError`.
    func callCancellable(_ input: KeeperInput<State>) async throws -> KeeperReply<State> {
        note(input)
        return try await sendAndWait(input, cancellation: .cancelsCall)
    }

    /// The box of the job `sequence` (the side's job table): a waiting caller cancels the job
    /// through it, as the keeper's `awaitActionResult` handler does.
    func jobBox(_ sequence: Int64) -> KeeperActionJobTask? {
        store.withSide { $0.actions.jobTask(sequence) }
    }

    /// The sync entries, as the keeper's: each query names the owner, and its arm asks the
    /// port's witness at the keeper entry's point (K2-2 plan §9, #948 round 2). `query` answers
    /// in place (`TurnActor.query` steps synchronously).
    func syncTurnNow(via port: any LandKeeperTransport, reason: SyncTurnReason, ticket: SyncTurnTicket? = nil) -> InTurnSyncResult {
        guard case let .syncTurn(result) = ask(.syncTurnNow(port: port, owner: owner, reason: reason, ticket: ticket)) else {
            preconditionFailure("syncTurnNow's answer")
        }
        return result
    }

    func syncTurnTicket(via port: any LandKeeperTransport) -> SyncTurnTicket? {
        guard case let .syncTurnTicket(ticket) = ask(.syncTurnTicket(port: port, owner: owner)) else {
            preconditionFailure("syncTurnTicket's answer")
        }
        return ticket
    }

    func ask(_ question: KeeperQuery) -> KeeperAnswer<State> {
        query(question)
    }

    func differentialRead() -> KeeperDifferentialRead<State> {
        let model = core.read { copy $0 }
        return store.withSide { KeeperDifferentialRead(model: model, side: $0) }
    }

    private func note(_ input: KeeperInput<State>) { noteSeen(input.routeName) }
    private func noteResult(_ name: String) { noteSeen(name) }
    /// The names of the inputs whose step has ended (`onInputSteppedForTesting`, at `handle`'s
    /// end), so `waitForInputs` waits for the step itself. A name in `inputsSeen` is noted before
    /// the step: `call` notes before it sends, and `perform` before it returns the effect's input
    /// (Review r2 on #969, MF2). Bounded: a lost input fails at the hang bound.
    private nonisolated let steppedEvents = EventLog()
    private func noteSeen(_ name: String) {
        inputsSeen.append(name)
    }

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
        case let .awaitRecordTaken(submission, applied, results, endsTickWork):
            await recordGate?.enterAndWait()
            await armedRecordGate.take()?.enterAndWait()
            await submission?.taken()
            result = .recordTaken(applied: applied, results: results, endsTickWork: endsTickWork)
        case let .actionJob(start):
            // As the keeper's staged start: the task goes into the box (a cancel that came first
            // cancels it), runs the resolvers under the job's own abandonment, and its result
            // comes back as `.actionResolved`.
            let resolved = CoreDiffResolved()
            let task = Task<Void, Never> {
                do {
                    let ctx = try await ResolverExecutor.executeResolvers(
                        executors: start.executors, resolverContext: start.resolverContext,
                        landContext: start.landContext, abandonment: start.box.abandonment)
                    resolved.set(.success(ctx.getAllResolverOutputs()))
                } catch {
                    resolved.set(.failure(error))
                }
            }
            start.box.install(task)
            await task.value
            result = .actionResolved(sequence: start.sequence, resolved.value)
        case let .actionJobRelease(sequence, abandonment):
            await abandonment.waitUntilEnded()
            result = .actionJobReleased(sequence: sequence)
        case let .initializeResolvers(resolving):
            initializeResolvingSeen.set(resolving)
            // As the keeper's driver: the resolvers, then this task's cancellation, read here
            // (Notes/solutions/2026-11-27-a-core-step-reads-the-drivers-task-not-the-callers.md).
            let resolved: Result<LandContext, any Error>
            do {
                resolved = .success(try await ResolverExecutor.executeInitializeResolvers(
                    executors: resolving.executors,
                    resolverContext: resolving.resolverContext,
                    landContext: resolving.ctx,
                    abandonment: ResolverAbandonment(kind: .onInitialize, counter: LandAbandonmentCounter(), metrics: ResolverDeadline.metrics)
                ))
            } catch {
                resolved = .failure(error)
            }
            result = .initializeResolved(resolving, resolved, initializationTaskCancelled: Task.isCancelled)
        case let .initializeRecord(submission):
            await armedRecordGate.take()?.enterAndWait()
            recordHandOffs.append(submission == nil ? "no submission" : "awaiting the hand-off")
            await submission?.taken()
            result = .initializeRecorded
        case let .destroyResolvers(destroyStep):
            // As the keeper's drain: no deadline, a failure skips the handler in the next step.
            let resolved: Result<LandContext, any Error>
            do {
                resolved = .success(try await ResolverExecutor.executeResolversWithoutDeadline(
                    executors: destroyStep.resolvers, resolverContext: destroyStep.resolverContext, landContext: destroyStep.ctx))
            } catch {
                resolved = .failure(error)
            }
            result = .destroyHandlerResolved(destroyStep, resolved)
        case let .afterFinalize(finalizeStep, scoped, scope):
            await finalizeStep.handler(finalizeStep.snapshot, scoped)
            scope.close()
            result = .afterFinalizeReturned
        case let .notifyTransport(port):
            await port?.onLandDestroyed()
            result = .drainFinished
        case let .awaitTickRecord(submission, tickId):
            await recordGate?.enterAndWait()
            await armedRecordGate.take()?.enterAndWait()
            await submission?.taken()
            result = .tickRecordTaken(tickId: tickId)
        case let .shutdownRecord(submission):
            await submission?.taken()
            result = .shutdownRecorded
        }
        if let result { await noteResult(result.routeName) }
        return result
    }

    func flush(_ outputs: consuming [KeeperOutput]) {
        let outputs = Array(outputs)
        flushed.append(contentsOf: outputs)
        for case .detachTransport in outputs { drainFinishes.append("drain finished") }
        // The owner's `.startLoops` (K2-2 commit 1a): the twin has no loops to configure, so it
        // answers `.initializeDone` at once, behind this flush (Review on #966, MF2 (c)). It
        // stands in for loops configured, so a tick land's finish check holds; the case drives
        // `.tickDue` itself.
        if outputs.contains(where: { if case .startLoops = $0 { true } else { false } }) {
            let done = KeeperInput<State>.initializeDone(tickLoopConfigured: true, syncLoopConfigured: true)
            note(done)
            send(done)
        }
        // The owner's drain start (M7): the twin has no loops to cancel. Unheld, it sends
        // `.drainStart` behind this flush; held, from a task once the gate opens, as the
        // keeper's `drainAfterIdleCheck` awaits its hold before `drainBegin`. The facade's hold
        // is commit 4's.
        for case let .failureTeardown(failure, port) in outputs {
            // The keeper's `runFailureTeardown`: the port hears of the failure, then the drain.
            let gate = armedFailureTeardownGate.take()
            Task {
                await gate?.enterAndWait()
                await port?.landDidFail(failure)
                await self.drive(.drainStart)
            }
        }
        if outputs.contains(where: { if case .drainStarting = $0 { true } else { false } }) {
            if let gate = armedDrainStartGate.take() {
                Task {
                    await gate.enterAndWait()
                    await self.drive(.drainStart)
                }
            } else {
                note(.drainStart)
                send(.drainStart)
            }
        }
        guard let (input, question) = armedFlush else { return }
        armedFlush = nil
        // The core's flush: a send is queued behind this flush, and a query is answered in place,
        // as its own step (TurnActor.swift's flush rules).
        note(input)
        send(input)
        let answer = query(question)
        let model = core.read { copy $0 }
        flushQueryAnswers.append((answer, model.pendingItems.map(\.sequence), model.lastCommittedTickId))
    }

    /// §16 item 5: the next flush sends `input`, then asks `query`.
    func armFlush(send input: KeeperInput<State>, thenAsk query: KeeperQuery) {
        armedFlush = (input, query)
    }

    /// Waits until `count` inputs named `name` have stepped. False, with an issue, at the hang
    /// bound: a case that needs the step guards on it and stops.
    func waitForInputs(named name: String, count: Int, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        let reached = await steppedEvents.waitFor { $0.filter { $0 == name }.count >= count }
        if !reached { Issue.record("\(count) × \(name) never stepped: seen \(inputsSeen), stepped \(steppedEvents.events)", sourceLocation: sourceLocation) }
        return reached
    }

    /// The twin's own recorder queue (tests that hold a submission ahead of the core's record).
    func recorderSubmissions() -> ReevaluationSubmissionTracker {
        store.withSide { side in side.submissionsForTesting }
    }

    /// Waits for the record submissions the core's flushes made (the twin's own tracker).
    func waitForSubmissions() async {
        let tracker = store.withSide { side in side.submissionsForTesting }
        await tracker.waitForAll()
    }

    /// Whether the twin's side holds a bound sync requester (`bindSyncRequester`, T8b's port).
    func hasBoundRequester() -> Bool {
        store.withSide { side in side.sharedBoundRequester.port != nil }
    }

    /// The twin's own drop counter for the destroy handlers' outputs (`openStepScope`'s
    /// `droppingInto:`, #893), read from its side.
    func destroyHandlerOutputsDropped() -> Int {
        store.withSide { side in side.sharedDestroyHandlerOutputsDropped.count }
    }

    /// The core's armed deadlines (its one timer's live entries), so a case checks that a
    /// timer it expects gone is gone, not only that its waiter is.
    var liveDeadlines: Int { core.liveDeadlinesForTesting }

    /// The drain flag only, on the twin: unlike the keeper's `markDrainingForTesting`, it clears
    /// no players, services or reservations (its cases join no player) and starts no drain
    /// (Review on #966, MF2 (e); r2's nit).
    func markDraining(cause: LandDestructionCause) {
        store.withSide { side in side.sharedDrainFlag.set(cause: cause) }
    }

    func keepLastDestroyTicket() {
        store.withSide { side in side.keepsLastDestroyTicketForTesting = true }
    }

    /// Installs the side's flush trace.
    func setFlushTrace(_ trace: @escaping @Sendable (String) -> Void) {
        store.withSide { side in side.flushTraceForTesting = trace }
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

/// A tick handler's re-entry, by land ID: the case registers what its land's handler calls
/// (parallel cases have their own land IDs).
enum CoreDiffHandlerReentry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hooks: [String: @Sendable () -> Void] = [:]
    static func register(_ landID: String, _ hook: @escaping @Sendable () -> Void) { lock.withLock { hooks[landID] = hook } }
    static func clear(_ landID: String) { _ = lock.withLock { hooks.removeValue(forKey: landID) } }
    static func fire(_ landID: String) {
        // One-shot.
        let hook = lock.withLock { hooks.removeValue(forKey: landID) }
        hook?()
    }
}

/// One path's ordered trace (§6, MF3's fix): every port call with its contents, and every effect
/// a flush runs (the staged actions and the recorder hand-offs, by label), in the order they
/// happen. `runsSyncPhaseInTurn` is left out: the keeper's path asks the port, the core's step
/// carries its input's read (K2-1, until K2-2's binding token), a stated asymmetry. The same holds
/// for a requested sync-only turn (`.syncTurnNow`): its arm asks the witness once, and the body's
/// second ask inside `callOut` is short-circuited on the core (K2-2 plan §10).
final class CoreDiffTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    /// The same entries as events, so a case can wait for one (bounded, never by timing).
    private let events = EventLog()
    func append(_ entry: String) {
        lock.withLock { entries.append(entry) }
        events.append(entry)
    }
    func clear() { lock.withLock { entries.removeAll() } }
    var all: [String] { lock.withLock { entries } }
    /// Waits until `entry` was appended; false after `testHangBound`.
    func waitFor(_ entry: String) async -> Bool { await events.waitFor(entry) }
}

/// The port that writes the trace. When armed, its `runSyncPhaseInTurn` re-enters `keeper` once
/// with a guarded entry (`submitSyncStream`), which the sentinel refuses mid-step.
final class CoreDiffTraceTransport: LandKeeperSettlePort, @unchecked Sendable {
    /// Which sync follow-up a committed or deferred phase asks for (Review round 2 on #938).
    enum FollowUp: Sendable, CaseIterable { case none, joinsAwaiting, keptEvents, deferred }
    let trace: CoreDiffTrace
    var followUp: FollowUp = .none
    private let lock = NSLock()
    private weak var reentryKeeper: LandKeeper<CoreDiffState>?
    init(_ trace: CoreDiffTrace) { self.trace = trace }

    func armReentry(_ keeper: LandKeeper<CoreDiffState>) { lock.withLock { reentryKeeper = keeper } }

    private weak var witnessReentryKeeper: LandKeeper<CoreDiffState>?
    private var witnessCalls = 0
    /// The next in-turn witness re-enters `keeper` (the settle's `.settleCheck`, #948 round 2).
    func armWitnessReentry(_ keeper: LandKeeper<CoreDiffState>) { lock.withLock { witnessReentryKeeper = keeper } }
    /// How many times the in-turn witness was asked. Not traced: the ordered traces leave the
    /// witness out (#938 round 1).
    var witnessCount: Int { lock.withLock { witnessCalls } }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async { trace.append("sendEvent \(event) to \(target)") }
    func syncNowFromTransport() async { trace.append("syncNow") }
    func syncBroadcastOnlyFromTransport() async { trace.append("syncBroadcastOnly") }
    /// Holds the port's `onLandDestroyed` once armed (a case reads the land mid-notify).
    let destroyedHold = CoreDiffArmedGate()
    func onLandDestroyed() async {
        await destroyedHold.take()?.enterAndWait()
        trace.append("onLandDestroyed")
    }
    func landDidFail(_ failure: LandFailure) async { trace.append("landDidFail \(failure.kind) \(failure.detail)") }
    func closeOutputs(for failure: LandFailure) { trace.append("closeOutputs \(failure.kind) \(failure.detail)") }
    /// What the in-turn witness answers (a refusing port answers false for every owner).
    var witnessAnswer = true
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool {
        if let reentry = lock.withLock({ () -> LandKeeper<CoreDiffState>? in
            witnessCalls += 1
            defer { witnessReentryKeeper = nil }
            return witnessReentryKeeper
        }) {
            trace.append("re-enter submitSyncStream from the witness")
            reentry.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: the witness's re-entry the sentinel refuses
        }
        return lock.withLock { witnessAnswer }
    }
    func runSettlePhaseInTurn<S: StateNodeProtocol>(state: S, settle: InTurnSettle, recording: InTurnSyncRecording?) -> InTurnSyncOutput {
        trace.append("runSettlePhaseInTurn \(settle.generation)")
        return InTurnSyncOutput(.notRequested, syncStream: [], settle: .empty(membershipEpoch: 0))
    }
    func admitJoiningSession(playerID: PlayerID, clientID: ClientID, sessionID: SessionID, joinSequence: Int64?) -> JoinAdmission {
        trace.append("admitJoiningSession \(playerID) \(clientID) \(sessionID) \(joinSequence.map(String.init) ?? "-")")
        return .notAdmitted
    }
    func refusesResolvedJoin(playerID: PlayerID, sessionID: SessionID) -> Bool { trace.append("refusesResolvedJoin \(playerID) \(sessionID)"); return false }
    private weak var reportReentryKeeper: LandKeeper<CoreDiffState>?
    /// The next join report re-enters `keeper`: `reportJoinsInTurn`'s `callOut` refuses it and
    /// fails the land in the batch (Review r1 on #969, MF3).
    func armReportReentry(_ keeper: LandKeeper<CoreDiffState>) { lock.withLock { reportReentryKeeper = keeper } }
    func noteJoinInputsConsumed(_ results: [JoinInputResult]) {
        trace.append("noteJoinInputsConsumed \(results)")
        if let keeper = lock.withLock({ () -> LandKeeper<CoreDiffState>? in defer { reportReentryKeeper = nil }; return reportReentryKeeper }) {
            trace.append("re-enter submitSyncStream from the report")
            keeper.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: the report's re-entry the sentinel refuses
        }
    }
    var hasJoinsAwaitingSync: Bool { trace.append("hasJoinsAwaitingSync"); return followUp == .joinsAwaiting }
    func waitForWriterDrainForInTurnSync() async { trace.append("waitForWriterDrain") }
    var recordsInTurnSyncFolds: Bool { false }
    func noteInTurnSyncFold(_ fold: InTurnSyncFold) { trace.append("noteInTurnSyncFold \(fold)") }
    func noteInTurnJoinSyncTick() { trace.append("noteInTurnJoinSyncTick") }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(state: S, events: [InTurnServerEvent], includeSync: Bool, recording: InTurnSyncRecording?) -> InTurnSyncOutput {
        let described = events.map { "#\($0.sequence.map(String.init) ?? "-") \($0.event) to \($0.target)" }
        trace.append("runSyncPhaseInTurn includeSync=\(includeSync) recording=\(recording.map { "\($0)" } ?? "-") events=\(described)")
        if let keeper = lock.withLock({ () -> LandKeeper<CoreDiffState>? in defer { reentryKeeper = nil }; return reentryKeeper }) {
            trace.append("re-enter submitSyncStream")
            keeper.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: the synchronous callback the sentinel refuses
        }
        guard includeSync else { return InTurnSyncOutput(.notRequested) }
        switch followUp {
        case .deferred: return InTurnSyncOutput(.deferredBackPressure)
        case .keptEvents: return InTurnSyncOutput(.committed(clearDirtyFlags: true), syncStream: [], keepsEvents: true)
        case .none, .joinsAwaiting: return InTurnSyncOutput(.committed(clearDirtyFlags: true))
        }
    }
}

/// A job task's result, set once by the task and read after it ends.
final class CoreDiffResolved: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<[String: HeldResolverOutput], any Error> = .failure(CancellationError())
    func set(_ value: Result<[String: HeldResolverOutput], any Error>) { lock.withLock { stored = value } }
    var value: Result<[String: HeldResolverOutput], any Error> { lock.withLock { stored } }
}

final class CoreDiffCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

// MARK: - What the two paths are compared on

/// A value as text with every dictionary's and set's entries sorted, at any depth, so two equal
/// values render alike whatever their hash order (Review round 2 on #938).
func coreDiffCanonical(_ value: Any) -> String {
    // Strings quoted and escaped, so a value's text can't read as a separator or as `nil`.
    if let string = value as? String { return string.debugDescription }
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
    case .dictionary:
        let entries = mirror.children.map { entry -> String in
            let pair = Mirror(reflecting: entry.value).children.map { coreDiffCanonical($0.value) }
            return pair.joined(separator: ": ")
        }
        return "[" + entries.sorted().joined(separator: ", ") + "]"
    case .set:
        return "{" + mirror.children.map { coreDiffCanonical($0.value) }.sorted().joined(separator: ", ") + "}"
    case .collection, .tuple:
        return "(" + mirror.children.map { ($0.label.map { "\($0): " } ?? "") + coreDiffCanonical($0.value) }.joined(separator: ", ") + ")"
    case .optional:
        return mirror.children.first.map { coreDiffCanonical($0.value) } ?? "nil"
    case .struct:
        let fields = mirror.children.map { ($0.label.map { "\($0): " } ?? "") + coreDiffCanonical($0.value) }
        return "\(mirror.subjectType)(" + fields.joined(separator: ", ") + ")"
    case .enum:
        // The case's name, then its payload rendered the same way.
        let name = String(describing: value).prefix { $0 != "(" }
        guard !mirror.children.isEmpty else { return String(name) }
        return name + "(" + mirror.children.map { coreDiffCanonical($0.value) }.joined(separator: ", ") + ")"
    default:
        // A class or a leaf: its own description (the model is plain; a class here is a box).
        return String(describing: value)
    }
}

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
    /// Every other model field, by label, as text (Review round 1 on #938: the model as a whole
    /// value), less `statedAsymmetries`.
    var otherModelFields: [String: String]
    var collectedEventSequences: [Int64]
    var failureIDs: [String]
    var isDraining: Bool
    var mailboxFailure: LandFailure?
    var pendingSyncTurnAfterTurn: String

    /// The model fields the two paths set apart by construction, each with its reason; the
    /// fields named in the digest above are compared there.
    static let statedAsymmetries: [String: String] = [
        "hasHeldTransport": "the twin's copy sets it from the twin's own transport (`coreTwinForTesting`)",
        "transportRecordsFolds": "the same",
        // K22-Q6: the keeper's path holds a batch's results here until its record is in; the
        // core's results ride the record effect. Checked per path in `expectSame`.
        "inputTurnResults": "the core carries a batch's results on its record effect (K2-2 item 15)",
        // K2-2 commit 1b: the core's flows keep their phase in the model; the keeper's path keeps
        // its tasks and continuations instead and leaves these at their start values.
        "drainPhase": "the core's drain phase (plan §13.2); the keeper's drain is its `drainTask`",
        "stopPhase": "the core's stop phase (plan §13.3); the keeper's is `forceShutdownFlight`",
        "stopAwaitsInitialization": "the core's stop before the initialization's end; the keeper's awaits `ensureInitialized`",
        "loopEpoch": "the core's loop epoch (M5); the keeper's loops are its own Tasks",
        "drainRequested": "the core's drain request; the keeper's is its `drainTask`",
    ]
    /// Fields the projections above compare. `players`, `rejoinReservations` and `pendingItems`
    /// are compared whole too, in `otherModelFields` (metadata, guest and device identity,
    /// reservation epochs, the items' kinds and payloads: Review round 2 on #938).
    static let digestedFields: Set<String> = [
        "state", "sequence", "lastCommittedTickId", "debugInFlightWork", "inputDrainScheduled", "actionJobs",
    ]

    /// The fields that differ from `other`, by name, for the failure message.
    func differingFields(from other: CoreDiffDigest) -> [String] {
        var names: [String] = []
        for (mine, theirs) in zip(Mirror(reflecting: self).children, Mirror(reflecting: other).children) where mine.label != "otherModelFields" {
            if coreDiffCanonical(mine.value) != coreDiffCanonical(theirs.value) { names.append(mine.label ?? "?") }
        }
        for key in Set(otherModelFields.keys).union(other.otherModelFields.keys).sorted() where otherModelFields[key] != other.otherModelFields[key] {
            names.append("model.\(key)")
        }
        return names
    }

    var description: String {
        "other model fields \(otherModelFields.count), collected \(collectedEventSequences), failure IDs \(failureIDs), draining \(isDraining), mailbox \(mailboxFailure.map(\.description) ?? "-"), follow-up \(pendingSyncTurnAfterTurn), " +
        "log \(log), players \(players), next sequence \(nextSequence), tick \(lastCommittedTick), reservations \(reservations), pending \(pendingSequences), held \(heldResults), work \(inFlightWork), drain \(inputDrainScheduled), jobs \(actionJobs), services \(playerServices), violations \(violations), destroy ticket \(holdsDestroyTicket), failure \(failure.map(\.description) ?? "-")"
    }

    init(_ read: KeeperDifferentialRead<CoreDiffState>) {
        let model = read.model
        var others: [String: String] = [:]
        for child in Mirror(reflecting: model).children {
            guard let label = child.label, !Self.digestedFields.contains(label), Self.statedAsymmetries[label] == nil else { continue }
            others[label] = coreDiffCanonical(child.value)
        }
        otherModelFields = others
        collectedEventSequences = read.collectedEventSequences
        failureIDs = read.failureIDs
        isDraining = read.isDraining
        mailboxFailure = read.mailboxFailure
        pendingSyncTurnAfterTurn = read.pendingSyncTurnAfterTurn
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
    /// The twin's source, whose sentinel and mailbox the core shares (nil for a pair built by hand).
    var source: LandKeeper<CoreDiffState>? = nil
    /// Each path has a transport (a pair built by hand with ports): the stated asymmetries'
    /// fixture.
    var transports = false

    static func make(_ shape: CoreDiffShape, _ name: String, holds: (@Sendable (LandKeeperHoldPoint) async -> Void)? = nil,
                     pathHolds: (@Sendable (String, LandKeeperHoldPoint) async -> Void)? = nil,
                     keeperRecordGate: CoreDiffArmedGate? = nil, clock: CoreDiffClock? = nil,
                     initializes: Bool = true, records: Bool = false, autoStartLoops: Bool = false,
                     before: (@Sendable (String) -> Void)? = nil, coreTransport: CoreDiffTraceTransport? = nil) async -> CoreDiffPair {
        let landID = "core-diff:\(name):\(UUID().uuidString)"
        // Set before either keeper exists: a gate or failure mark the initialization reads.
        before?(landID)
        func keeper() -> LandKeeper<CoreDiffState> {
            LandKeeperTesting.$defersInitialization.withValue(!initializes) {
                LandKeeper<CoreDiffState>(definition: coreDiffDefinition(shape), initialState: CoreDiffState(),
                                          enableLiveStateHashRecording: records, autoStartLoops: autoStartLoops, landID: landID)
            }
        }
        let direct = keeper(), twinSource = keeper()
        if let holds {
            // On both keepers, before the twin copies the source's side.
            await direct.installHolds(holds)
            await twinSource.installHolds(holds)
        }
        if let pathHolds {
            // Labelled by path, so a case can tell the keeper's hold from the core's.
            await direct.installHolds { await pathHolds("keeper", $0) }
            await twinSource.installHolds { await pathHolds("core", $0) }
        }
        if let keeperRecordGate {
            // The keeper's held work: its next record after `arm` waits at `.turnRecord`.
            await direct.installHolds { point in
                if point == .turnRecord, let gate = keeperRecordGate.take() { await gate.enterAndWait() }
            }
        }
        if initializes {
            await direct.awaitInitialization()
            await twinSource.awaitInitialization()
        }
        // The action tables' mid-step audit, on both paths (the twin copies the source's flag).
        await direct.setActionTableAuditForTesting(true)
        await twinSource.setActionTableAuditForTesting(true)
        // `initializes` false: neither keeper has initialized; the case runs the keeper's
        // (`awaitInitialization`) and the core's (`.initialize`) itself (K2-2 commit 1a).
        let harness = KeeperCoreHarness(await twinSource.coreTwinForTesting(transport: coreTransport, initialized: initializes), clock: clock)
        await harness.start()
        // The destroy-timer cases read the last ticket after a cancel, on both paths.
        await direct.keepLastDestroyTicketForTesting()
        await harness.keepLastDestroyTicket()
        return CoreDiffPair(keeper: direct, harness: harness, landID: landID, source: twinSource)
    }

    func digests() async -> (keeper: CoreDiffDigest, core: CoreDiffDigest) {
        let keeperDigest = CoreDiffDigest(await keeper.differentialReadForTesting())
        let coreDigest = CoreDiffDigest(await harness.differentialRead())
        return (keeperDigest, coreDigest)
    }

    /// The two paths' digests match, nothing is left on the core's side, and no deferred input
    /// reached the machine.
    /// `logOrderFree`: the state's log is compared as a multiset, for a case whose keeper order
    /// is the scheduler's (the case asserts the core's order itself).
    func expectSame(_ step: String, logOrderFree: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) async {
        // The keeper's drain yields before it ends (`runInputDrain`), after the call that
        // started it returned: read it once its work and its drain are done.
        await keeper.waitForInFlightWorkForTesting()
        await keeper.waitForInputDrainIdleForTesting()
        var (keeperDigest, coreDigest) = await digests()
        if logOrderFree {
            keeperDigest.log.sort()
            coreDigest.log.sort()
        }
        // The whole-model comparison compares something: the model has dozens of other fields.
        #expect(coreDigest.otherModelFields.count > 20, "\(step): \(coreDigest.otherModelFields.keys.sorted())", sourceLocation: sourceLocation)
        #expect(keeperDigest == coreDigest, "\(step): differ in \(keeperDigest.differingFields(from: coreDigest))\n keeper \(keeperDigest)\n core   \(coreDigest)", sourceLocation: sourceLocation)
        // The stated asymmetries, each checked against its path's fixture: each path holds a
        // transport exactly when the pair gave it one, and none records folds.
        let keeperModel = await keeper.differentialReadForTesting().model, coreModel = await harness.differentialRead().model
        #expect(keeperModel.hasHeldTransport == transports && coreModel.hasHeldTransport == transports, "\(step): held transport", sourceLocation: sourceLocation)
        #expect(!keeperModel.transportRecordsFolds && !coreModel.transportRecordsFolds, "\(step): no fold recording", sourceLocation: sourceLocation)
        // K22-Q6, per path: with the work waited for, neither holds a result, and the core never
        // keeps one in the table between steps.
        #expect(keeperModel.inputTurnResults.isEmpty && coreModel.inputTurnResults.isEmpty, "\(step): results left: keeper \(keeperModel.inputTurnResults.keys.sorted()), core \(coreModel.inputTurnResults.keys.sorted())", sourceLocation: sourceLocation)
        #expect(coreDigest.violations.isEmpty, "\(step): \(coreDigest.violations)", sourceLocation: sourceLocation)
        let leftover = await harness.differentialRead().coreWaitsLeft
        #expect(leftover == 0, "\(step): core waits left", sourceLocation: sourceLocation)
        let deferredNames = await harness.inputsSeen.filter { KeeperInputRoute(rawValue: $0).flatMap { KeeperInputRoutes.deferred[$0] } != nil }
        #expect(deferredNames.isEmpty, "\(step): deferred inputs sent: \(deferredNames)", sourceLocation: sourceLocation)
    }

    /// A kick happened: p1's entry is c2's, with a new generation, on both paths (the digest
    /// compares the two).
    func expectKicked(sourceLocation: SourceLocation = #_sourceLocation) async {
        let core = await digests().core
        #expect(core.players["p1"]?.first == "c2", "the second login holds the entry: \(core.players)", sourceLocation: sourceLocation)
        #expect(core.players["p1"]?.last != "1", "a new generation: \(core.players)", sourceLocation: sourceLocation)
    }
}

// MARK: - The calls, on each path

private func session(_ player: String) -> PlayerSession { PlayerSession(playerID: player) }

/// Whether `task` ends within `seconds`, so a task that never ends fails an expectation instead
/// of hanging the suite.
/// Whether `signal` yields within `seconds`. Both children end on cancellation (a stream's
/// iteration and the sleep do), so the group never waits on uncancellable work. The sleep is
/// only the bound: it orders nothing, and on correct code the signal comes first however slow
/// the scheduler is. A false means the awaited event never happened, so the case's recovery
/// (advancing its clock) runs before it joins the work it was waiting on.
private func firstSignal(_ signal: AsyncStream<Void>, withinSeconds seconds: Int) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { for await _ in signal { return true }; return false }
        group.addTask { try? await safeTaskSleep(for: .seconds(seconds)); return false }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

private func boundedEnd(_ task: Task<Void, Never>, seconds: Int) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await task.value; return true }
        group.addTask { try? await safeTaskSleep(for: .seconds(seconds)); return false }
        let first = await group.next() ?? false
        // Cancelling the waiter doesn't cancel the unstructured task it waits on, so a timeout
        // cancels the task itself, or the group would wait for it (Review round 3 on #938).
        if !first { task.cancel() }
        group.cancelAll()
        return first
    }
}
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
    guard case let .actionSubmission(result) = await pair.harness.ask(.admitAction(envelope(action), caller(player, client), enforcingLimits: true)) else {
        return .failed(nil, "not an action answer")
    }
    return CoreDiffActionResult(result)
}

// MARK: - Action jobs (K2-2 plan, commit 0)

private func jobEnvelope(_ action: CoreDiffJobAction) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: CoreDiffJobAction.self), payload: AnyCodable(action))
}

/// A job's outcome on either path, as text both can match.
/// An intake's answer, exactly: `.pending` keeps its sequence (Review on #966).
private func describeSubmission(_ result: Result<ActionSubmission, any Error>) -> String {
    switch result {
    case let .success(.pending(sequence)): "pending \(sequence)"
    case let .success(.completed(outcome)): "completed \(describeJob(.success(outcome)))"
    case let .failure(error): describeJob(.failure(error))
    }
}

private func describeJob(_ result: Result<InputOutcome, any Error>) -> String {
    switch result {
    case let .success(.response(response)): "ack \((response as? CoreDiffAck)?.n ?? -1)"
    case .success(.none): "none"
    case let .failure(error as CoreDiffError): "error \(error.token)"
    case .failure(is CancellationError): "cancelled"
    case let .failure(error): "\(type(of: error)): \(String(describing: error))"
    }
}

/// The intake on either path, answered `.pending(sequence:)`.
private func keeperJobIntake(_ pair: CoreDiffPair, _ action: CoreDiffJobAction) async -> Int64? {
    let submission = try? await pair.keeper.submitAction(jobEnvelope(action), playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("c1"))
    guard case let .pending(sequence)? = submission else { Issue.record("keeper: not pending: \(String(describing: submission))"); return nil }
    return sequence
}

private func coreJobIntake(_ pair: CoreDiffPair, _ action: CoreDiffJobAction, tick: Bool) async -> Int64? {
    let submission: Result<ActionSubmission, any Error>
    if tick {
        guard case let .actionSubmission(result) = await pair.harness.ask(.admitAction(jobEnvelope(action), caller("p1", "c1"), enforcingLimits: true)) else { return nil }
        submission = result
    } else {
        guard case let .action(result)? = try? await pair.harness.call(.action(jobEnvelope(action), caller("p1", "c1"))) else { return nil }
        submission = result
    }
    guard case let .pending(sequence)? = try? submission.get() else { Issue.record("core: not pending: \(submission)"); return nil }
    return sequence
}

private func coreJobResult(_ pair: CoreDiffPair, _ sequence: Int64) async -> String {
    do {
        guard case let .input(result) = try await pair.harness.call(.awaitActionResult(sequence: sequence)) else { return "not an input reply" }
        return describeJob(result)
    } catch {
        return "core: \(error)"
    }
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
        await pair.expectKicked()
    }

    @Test("A rejoin while the player's leave is in its OnLeave resolvers waits for the leave's end, then joins (#943), the same on both paths; on the core it waits in the barrier (#953, its first adopter)", arguments: [false, true])
    func rejoinWaitsForTheLeaveInFlight(tick: Bool) async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: tick, joinResolvers: false, leaveResolver: true), "rejoin-waits")
        _ = await bothJoin(pair, "p1", "c1")
        // Each path in turn: the leave held in its resolver, the rejoin parked behind it.
        let keeperGate = WatermarkGate()
        defer { keeperGate.release() }
        CoreDiffLeaveGates.arm(pair.landID, keeperGate)
        let keeperLeft = Task { await keeperLeave(pair, "p1", "c1") }
        guard await keeperGate.waitUntilEntered("the keeper's OnLeave resolver") else { return }
        let keeperJoined = Task { await keeperJoin(pair, "p1", "c2") }
        guard await valueWithinHangBound(Task { await pair.keeper.waitForLeaveEndWaitersForTesting(PlayerID("p1"), count: 1) }) != nil else {
            Issue.record("the keeper's rejoin never waited"); return
        }

        let coreGate = WatermarkGate()
        defer { coreGate.release() }
        CoreDiffLeaveGates.arm(pair.landID, coreGate)
        let coreLeft = Task { await coreLeave(pair, "p1", "c1") }
        guard await coreGate.waitUntilEntered("the core's OnLeave resolver") else { return }
        let (waits, probe) = probeEvents("join-awaits-leave")
        await pair.harness.setProbe(probe)
        let coreJoined = Task { await coreJoin(pair, "p1", "c2") }
        guard await firstWithinHangBound(waits) else { Issue.record("the core's rejoin never waited in the barrier"); return }
        await pair.harness.setProbe(nil)
        let held = await pair.harness.differentialRead().model
        #expect(held.leavesInFlight[PlayerID("p1")] != nil && held.players[PlayerID("p1")] == nil, "the leave is in flight, the rejoin not inserted")

        keeperGate.release()
        coreGate.release()
        guard let kl = await valueWithinHangBound(keeperLeft), let cl = await valueWithinHangBound(coreLeft),
              let kj = await valueWithinHangBound(keeperJoined), let cj = await valueWithinHangBound(coreJoined) else {
            Issue.record("a leave or a rejoin never returned"); return
        }
        #expect(kl == "done" && cl == "done", "keeper \(kl), core \(cl)")
        #expect(kj == cj && cj == .joined(allowed: true, admitted: false), "keeper \(kj), core \(cj)")
        await pair.expectSame("after the leave and the rejoin")
    }

    @Test("W6 on the core: a rejoin cancelled while it waits in the barrier for the player's leave is withdrawn with CancellationError, and its reservation and arrival token end; the leave then ends and resumes nobody (#943, #953)")
    func rejoinCancelledWhileItWaits() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: true), "rejoin-cancel")
        _ = await bothJoin(pair, "p1", "c1")
        let gate = WatermarkGate()
        defer { gate.release() }
        CoreDiffLeaveGates.arm(pair.landID, gate)
        let left = Task { await coreLeave(pair, "p1", "c1") }
        guard await gate.waitUntilEntered("the core's OnLeave resolver") else { return }
        let (waits, probe) = probeEvents("join-awaits-leave")
        await pair.harness.setProbe(probe)
        let call = KeeperJoinCall(session: session("p1"), clientID: ClientID("c2"), sessionID: SessionID("c2"), services: LandServices(), admitThroughTransport: false)
        let joined = Task { try await pair.harness.callCancellable(.join(call, syncsInTurn: false)) }
        guard await firstWithinHangBound(waits) else { Issue.record("the core's rejoin never waited in the barrier"); return }
        await pair.harness.setProbe(nil)
        #expect(await pair.harness.differentialRead().model.rejoinReservations[PlayerID("p1")]?.isEmpty == false, "the waiting rejoin holds its reservation")

        joined.cancel()
        guard let answer = await resultWithinHangBound(joined) else { Issue.record("the cancelled rejoin never ended"); return }
        guard case let .failure(error) = answer, error is CancellationError else { Issue.record("the cancelled rejoin: \(answer)"); return }
        let after = await pair.harness.differentialRead().model
        #expect(after.latestJoinArrivals.isEmpty, "the rejoin's token outlived its join: \(after.latestJoinArrivals)")
        #expect(after.rejoinReservations[PlayerID("p1")]?.isEmpty ?? true, "the rejoin's reservation outlived its join: \(after.rejoinReservations)")

        gate.release()
        guard let leave = await valueWithinHangBound(left) else { Issue.record("the leave never returned"); return }
        #expect(leave == "done")
        let done = await pair.harness.differentialRead().model
        #expect(done.players.isEmpty && done.leavesInFlight.isEmpty, "the leave resumed nobody: players \(done.players.keys), in flight \(done.leavesInFlight)")
    }

    @Test("A stop while a rejoin waits for the player's leave in flight: the drain's start ends the leave's window and the rejoin gets landShuttingDown, the same on both paths (#943, W6d)")
    func stopWhileTheRejoinWaits() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: true), "rejoin-stop")
        _ = await bothJoin(pair, "p1", "c1")
        let keeperGate = WatermarkGate()
        defer { keeperGate.release() }
        CoreDiffLeaveGates.arm(pair.landID, keeperGate)
        let keeperLeft = Task { await keeperLeave(pair, "p1", "c1") }
        guard await keeperGate.waitUntilEntered("the keeper's OnLeave resolver") else { return }
        let keeperJoined = Task { await keeperJoin(pair, "p1", "c2") }
        guard await valueWithinHangBound(Task { await pair.keeper.waitForLeaveEndWaitersForTesting(PlayerID("p1"), count: 1) }) != nil else {
            Issue.record("the keeper's rejoin never waited"); return
        }
        let keeperStop = Task { await pair.keeper.forceShutdown() }
        guard let kj = await valueWithinHangBound(keeperJoined) else { Issue.record("the keeper's rejoin never returned"); return }

        let coreGate = WatermarkGate()
        defer { coreGate.release() }
        CoreDiffLeaveGates.arm(pair.landID, coreGate)
        let coreLeft = Task { await coreLeave(pair, "p1", "c1") }
        guard await coreGate.waitUntilEntered("the core's OnLeave resolver") else { return }
        let (waits, probe) = probeEvents("join-awaits-leave")
        await pair.harness.setProbe(probe)
        let coreJoined = Task { await coreJoin(pair, "p1", "c2") }
        guard await firstWithinHangBound(waits) else { Issue.record("the core's rejoin never waited in the barrier"); return }
        await pair.harness.setProbe(nil)
        let coreStop = Task { try await pair.harness.call(.shutdown) }
        guard let cj = await valueWithinHangBound(coreJoined) else { Issue.record("the core's rejoin never returned"); return }
        #expect(kj == cj && cj == .failed(String(describing: JoinError.landShuttingDown)), "keeper \(kj), core \(cj)")

        keeperGate.release()
        coreGate.release()
        guard await valueWithinHangBound(keeperLeft) != nil, await valueWithinHangBound(coreLeft) != nil,
              await valueWithinHangBound(keeperStop) != nil else { Issue.record("a leave or the keeper's stop never returned"); return }
        guard case .success(.done)? = await resultWithinHangBound(coreStop) else { Issue.record("the core's stop wasn't answered .done"); return }
        await pair.expectSame("after the stop")
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
        await pair.expectKicked()
    }

    @Test("A kick on a one-player land: L1 installs the destroy timer and J3 cancels it, on both paths, and the timer never fires (§16 item 10)", arguments: [false, true])
    func kickInstallsThenCancelsTheDestroyTimer(tick: Bool) async throws {
        // Each step flushes at its end, on both paths: L1's staged start installs the timer before
        // J3's `joinInsert` cancels it. So this pins install-then-cancel, not D14's cancel before
        // install (a stage and a cancel in one frame), which #860's D2 shape or K1b-5's own test
        // covers. The order is each path's probes; the timer is 1 h, so no window lets it fire.
        let fires = CoreDiffCounter()
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: tick, joinResolvers: false, leaveResolver: false, noOnLeave: true, destroysWhenEmpty: true, destroyDelay: .seconds(3600)), "kick-destroy",
                                           holds: { point in if point == .destroyTimerFired { fires.increment() } })
        _ = await bothJoin(pair, "p1", "c1")
        let keeperOrder = CoreDiffTrace(), coreOrder = CoreDiffTrace()
        await pair.keeper.setInTurnProbeForTesting { if $0.hasPrefix("destroy-timer-") { keeperOrder.append($0) } }
        await pair.harness.setProbe { if $0.hasPrefix("destroy-timer-") { coreOrder.append($0) } }
        let again = await bothJoin(pair, "p1", "c2")
        for (path, order) in [("keeper", keeperOrder.all), ("core", coreOrder.all)] {
            #expect(order == ["destroy-timer-installed", "destroy-timer-cancelled"], "\(path): \(order)")
        }
        #expect(again.0 == again.1 && again.0 == .joined(allowed: true, admitted: false), "\(again)")
        await pair.expectSame("after the kick and the join")
        let keeperRead = await pair.keeper.differentialReadForTesting()
        let coreRead = await pair.harness.differentialRead()
        for (path, read) in [("keeper", keeperRead), ("core", coreRead)] {
            #expect(!read.holdsDestroyTicket, "\(path): the join cleared the slot")
            let ticket = try #require(read.lastDestroyTicket, "\(path): L1 staged the timer")
            let task = try #require(ticket.installedTask, "\(path): the staged start installed its task")
            #expect(task.isCancelled, "\(path): J3 cancelled it")
            // A cancelled 1 h timer ends at once; a live one wouldn't end within the bound.
            let ended = await boundedEnd(task, seconds: 5)
            #expect(ended, "\(path): the timer's task ended")
        }
        #expect(fires.value == 0, "a cancelled timer reached .destroyTimerFired \(fires.value) time(s)")
        #expect(!pair.keeper.isDraining, "the timer ran no destroy")
    }

    @Test("The control: the last player's leave installs the destroy timer, and with no rejoin it fires on both paths", arguments: [false, true])
    func uncancelledDestroyTimerFires(tick: Bool) async throws {
        // Each path's fire is observed by its hold, not by time (Review round 2): the keeper's own
        // drain cancels a timer that fired, so its task's end says nothing.
        let keeperFires = CoreDiffCounter(), coreFires = CoreDiffCounter()
        let (fired, firedContinuation) = AsyncStream<Void>.makeStream()
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: tick, joinResolvers: false, leaveResolver: false, noOnLeave: true, destroysWhenEmpty: true), "destroy-fires",
                                           pathHolds: { path, point in
                                               guard point == .destroyTimerFired else { return }
                                               (path == "keeper" ? keeperFires : coreFires).increment()
                                               firedContinuation.yield()
                                           })
        _ = await bothJoin(pair, "p1", "c1")
        #expect(await keeperLeave(pair, "p1", "c1") == "done")
        #expect(await coreLeave(pair, "p1", "c1") == "done")
        for (path, read) in [("keeper", await pair.keeper.differentialReadForTesting()), ("core", await pair.harness.differentialRead())] {
            let ticket = try #require(read.lastDestroyTicket, "\(path): the leave staged the timer")
            #expect(ticket.installedTask != nil, "\(path): installed")
        }
        // One fire per path: the keeper's (which then drains) and the core's (whose staged hop
        // finds no keeper, K2-1).
        var fireEvents = fired.makeAsyncIterator()
        _ = await fireEvents.next()
        _ = await fireEvents.next()
        #expect(keeperFires.value == 1 && coreFires.value == 1, "fires: keeper \(keeperFires.value), core \(coreFires.value)")
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
        let kickHold = WatermarkGate(), sourceDrainHold = WatermarkGate(), teardownHold = WatermarkGate(), coreTeardownHold = WatermarkGate()
        // Released on every exit, a failed expectation's early return included.
        defer {
            coreTeardownHold.release()
            teardownHold.release()
            sourceDrainHold.release()
            kickHold.release()
        }
        await twinSource.installHolds(HoldRegistry<LandKeeperHoldPoint>()
            .on(.serverInputKick, arrival: 1) { await kickHold.enterAndWait() }
            .on(.inputDrain) { await sourceDrainHold.enterAndWait() }.hook)
        await twinSource.submitLandFailure(failure)
        guard await kickHold.waitUntilEntered() else { return }
        let harness = KeeperCoreHarness(await twinSource.coreTwinForTesting())
        await harness.start()
        // The core's teardown is held where the keeper's is (`.landFailedTeardown`), before the
        // port hears of the failure and the drain starts (K2-2 commit 1b runs it on the core).
        harness.armedFailureTeardownGate.arm(coreTeardownHold)
        await harness.drive(.inputDrainDue)
        guard await coreTeardownHold.waitUntilEntered("the core's failure teardown") else { return }

        // The keeper's path, held at its teardown's first step: what the step did, before the drain.
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
        #expect(keeperDigest == coreDigest, "differ in \(keeperDigest.differingFields(from: coreDigest))\n keeper \(keeperDigest)\n core   \(coreDigest)")
        #expect(coreDigest.failure?.kind == failure.kind && coreDigest.players.isEmpty && coreDigest.pendingSequences.isEmpty, "\(coreDigest)")
        #expect(coreDigest.violations.isEmpty, "\(coreDigest.violations)")
        #expect(await harness.differentialRead().coreWaitsLeft == 0)
        // The core's teardown is held before its `.drainStart`, as the keeper's before its drain.
        #expect(await harness.inputsSeen == ["startLand", "inputDrainDue"])
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
        let pair = CoreDiffPair(keeper: direct, harness: harness, landID: landID, transports: true)
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
        defer { gate.release() }
        let harness = KeeperCoreHarness(await source.coreTwinForTesting(), recordGate: gate)
        // After `start`, which binds the store (the probe is installed through it).
        await harness.start()
        let (drainEnds, drainEndCount) = await harness.drainEnds()

        // A's drain waits on its record; B's intake runs meanwhile and finds the drain scheduled.
        let a = Task { await coreTicklessAction(CoreDiffPair(keeper: direct, harness: harness, landID: landID), CoreDiffAction(n: 1, fails: false), "p1", "c1") }
        guard await gate.waitUntilEntered("A's record") else { return }
        // B is a call too, so its reply is compared: its intake steps before the gate opens.
        let b = Task { await coreTicklessAction(CoreDiffPair(keeper: direct, harness: harness, landID: landID), CoreDiffAction(n: 2, fails: false), "p1", "c1") }
        guard await harness.waitForInputs(named: "action", count: 2) else { return }
        gate.release()
        #expect(await a.value == .completed(1))
        #expect(await b.value == .completed(2))
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

    @Test("A tickless action's failure rides the record effect: while its record is in flight the model's in-flight table owns it, with no violation, and the caller gets the error after the record (K2-2 plan, item 15, K22-Q5)")
    func failedResultOwnedInFlight() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false)
        let landID = "core-diff:in-flight:\(UUID().uuidString)"
        let source = LandKeeper<CoreDiffState>(definition: coreDiffDefinition(shape), initialState: CoreDiffState(), autoStartLoops: false, landID: landID)
        await source.awaitInitialization()
        _ = try await source.joinReportingAdmission(session: session("p1"), clientID: ClientID("c1"), sessionID: SessionID("c1"), services: LandServices(), admitThroughTransport: false)
        await source.waitForInFlightWorkForTesting()
        await source.waitForInputDrainIdleForTesting()
        let gate = WatermarkGate()
        defer { gate.release() }
        let harness = KeeperCoreHarness(await source.coreTwinForTesting(), recordGate: gate)
        await harness.start()
        let pair = CoreDiffPair(keeper: source, harness: harness, landID: landID)
        let call = Task { await coreTicklessAction(pair, CoreDiffAction(n: 7, fails: true), "p1", "c1") }
        guard await gate.waitUntilEntered("the failing action's record") else { return }
        let held = await harness.differentialRead()
        #expect(held.model.inFlightRecordResults.count == 1, "the in-flight table owns the failure: \(held.model.inFlightRecordResults)")
        #expect(held.model.inputTurnResults.isEmpty, "the result left the table with the effect")
        #expect(held.violations.isEmpty, "no owner violation while in flight: \(held.violations)")
        gate.release()
        let answer = await call.value
        // The exact error: a lost failure (`FailureTableMiss`) must not pass.
        #expect(answer == .failed(CoreDiffError(token: 7), "CoreDiffError"), "the caller got the handler's error: \(answer)")
        #expect(await keeperAction(pair, CoreDiffAction(n: 7, fails: true), "p1", "c1") == answer, "the keeper's caller gets the same")
        let after = await harness.differentialRead()
        #expect(after.model.inFlightRecordResults.isEmpty && after.model.inputTurnResults.isEmpty)
        #expect(after.violations.isEmpty, "\(after.violations)")
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
        let pendingBefore = await pair.digests().core.pendingSequences.count
        let action = CoreDiffAction(n: 6, fails: false)
        let keeperResult = await keeperAction(pair, action, "p1", "c1")
        let coreResult = await coreTickAction(pair, action, "p1", "c1")
        #expect(keeperResult == coreResult, "keeper \(keeperResult), core \(coreResult)")
        // Not the same failure on both: acknowledged and appended.
        if case .failed = keeperResult { Issue.record("the tick land's action failed: \(keeperResult)") }
        await pair.expectSame("after the tick land's action")
        #expect(await pair.digests().core.pendingSequences.count == pendingBefore + 1, "appended for the next tick")
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

    @Test("An action job: the intake answers pending, the resolvers run as the core's effect, and the result comes back through the slot, on both paths (K2-2 plan, commit 0)",
          arguments: [(false, false), (false, true), (true, false), (true, true)])
    func actionJob(tick: Bool, fails: Bool) async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: tick, joinResolvers: false, leaveResolver: false), "job")
        _ = await bothJoin(pair, "p1", "c1")
        let action = CoreDiffJobAction(n: 9, fails: fails)
        let keeperSequence = try #require(await keeperJobIntake(pair, action))
        let keeperResult = describeJob(await Result { try await pair.keeper.awaitActionResult(sequence: keeperSequence) })
        await pair.keeper.waitForActionJobsForTesting()
        let coreSequence = try #require(await coreJobIntake(pair, action, tick: tick))
        #expect(coreSequence == keeperSequence, "the same sequence on both paths")
        let coreResult = await coreJobResult(pair, coreSequence)
        #expect(keeperResult == coreResult, "keeper \(keeperResult), core \(coreResult)")
        // A tick land acknowledges at delivery; a tickless one answers with the handler's response;
        // a failing resolver's error comes back wrapped by the executor, the same on both.
        if fails {
            #expect(keeperResult != "none" && keeperResult != "ack 9", "\(keeperResult)")
        } else {
            #expect(keeperResult == (tick ? "none" : "ack 9"), "\(keeperResult)")
        }
        await pair.expectSame("after the job")
        let seen = await pair.harness.inputsSeen
        #expect(seen.contains("actionResolved"), "\(seen)")
    }

    @Test("An action job whose caller cancels while its resolver runs is not applied, and its caller gets CancellationError, on both paths (K2-2 plan, commit 0: the box rides the effect)",
          arguments: [false, true])
    func actionJobCallerCancel(tick: Bool) async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: tick, joinResolvers: false, leaveResolver: false), "job-cancel")
        _ = await bothJoin(pair, "p1", "c1")
        let action = CoreDiffJobAction(n: 4, fails: false)
        defer { CoreDiffJobGates.set(pair.landID, nil) }

        // The keeper's path: the caller waits on the slot, is cancelled, then the resolver returns.
        let keeperGate = WatermarkGate()
        defer { keeperGate.release() }
        CoreDiffJobGates.set(pair.landID, keeperGate)
        let keeperSequence = try #require(await keeperJobIntake(pair, action))
        var waiting = await pair.keeper.watchActionSlotForTesting(keeperSequence, waiter: true).makeAsyncIterator()
        let keeperWait = Task { describeJob(await Result { try await pair.keeper.awaitActionResult(sequence: keeperSequence) }) }
        _ = await waiting.next()
        // The resolver runs (it waits at the gate) before the cancel, so the cancel meets a job
        // in flight on both paths (Review r4 on #948).
        guard await keeperGate.waitUntilEntered("the keeper's resolver") else { return }
        keeperWait.cancel()
        keeperGate.release()
        let keeperResult = await keeperWait.value
        await pair.keeper.waitForActionJobsForTesting()

        // The core's path: the caller's own cancel handler cancels the box (K2-2b's wait does the same).
        let coreGate = WatermarkGate()
        defer { coreGate.release() }
        CoreDiffJobGates.set(pair.landID, coreGate)
        let coreSequence = try #require(await coreJobIntake(pair, action, tick: tick))
        let box = await pair.harness.jobBox(coreSequence)
        #expect(box != nil, "the core's side holds the job's box")
        let coreWait = Task {
            await withTaskCancellationHandler {
                await coreJobResult(pair, coreSequence)
            } onCancel: {
                box?.callerCancelled.set()
                box?.cancel()
            }
        }
        guard await pair.harness.waitForInputs(named: "awaitActionResult", count: 1) else { return }
        guard await coreGate.waitUntilEntered("the core's resolver") else { return }
        coreWait.cancel()
        coreGate.release()
        let coreResult = await coreWait.value

        #expect(keeperResult == "cancelled" && coreResult == "cancelled", "keeper \(keeperResult), core \(coreResult)")
        await pair.expectSame("after the cancelled job")
        #expect(!(await pair.digests().core.log.contains { $0.hasPrefix("job:") }), "not applied")
    }

    @Test("A freeze with no work in flight answers true at once, and its resume thaws the land, on both paths (K2-2 plan, commit 2)", arguments: [false])
    func freezeAndResume(tick: Bool) async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: tick, joinResolvers: false, leaveResolver: false), "freeze")
        _ = await bothJoin(pair, "p1", "c1")
        let keeperFroze = await pair.keeper.debugFreeze(generation: 1, timeout: .seconds(5))
        guard case let .frozen(coreFroze) = try await pair.harness.call(.freeze(generation: 1, timeout: .seconds(5))) else {
            Issue.record("not a freeze reply"); return
        }
        #expect(keeperFroze && coreFroze, "keeper \(keeperFroze), core \(coreFroze)")
        await pair.expectSame("frozen")
        #expect(await pair.digests().core.otherModelFields["debugFrozen"] == "true")
        await pair.keeper.debugResume(generation: 1)
        await pair.harness.drive(.resume(generation: 1))
        await pair.expectSame("resumed")
        #expect(await pair.digests().core.otherModelFields["debugFrozen"] == "false")
        #expect(await pair.harness.flushed.contains { if case .dropFold = $0 { true } else { false } }, "the freeze dropped the driver's fold")
    }

    @Test("A released generation doesn't freeze again: a late freeze answers false and changes nothing, on both paths (K2-2 plan, commit 2)")
    func releasedGenerationDoesNotFreeze() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "freeze-late")
        await pair.keeper.debugResume(generation: 2)
        await pair.harness.drive(.resume(generation: 2))
        let keeperFroze = await pair.keeper.debugFreeze(generation: 2, timeout: .seconds(5))
        guard case let .frozen(coreFroze) = try await pair.harness.call(.freeze(generation: 2, timeout: .seconds(5))) else {
            Issue.record("not a freeze reply"); return
        }
        #expect(!keeperFroze && !coreFroze, "keeper \(keeperFroze), core \(coreFroze)")
        await pair.expectSame("after the late freeze")
    }

    @Test("A tick land's client event is queued for its next tick, with no value, on both paths (K2-2 plan, commit 2: .admitClientEvent)")
    func tickLandClientEvent() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: true, joinResolvers: false, leaveResolver: false), "tick-event")
        _ = await bothJoin(pair, "p1", "c1")
        let event = CoreDiffEvent(n: 3, fails: false)
        let keeperResult = await keeperEvent(pair, event, "p1", "c1")
        guard case let .clientEventQueued(coreResult) = await pair.harness.ask(.admitClientEvent(AnyClientEvent(event), caller("p1", "c1"))) else {
            Issue.record("not an event answer"); return
        }
        #expect(keeperResult == "done")
        #expect((try? coreResult.get()) != nil, "\(coreResult)")
        await pair.expectSame("after the queued event")
    }

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

    @Test("The core's refusals are named: one reason per refused shape, each with its own message and the K2-2 commit that lifts it (commit 4 requires none left)")
    func refusalReasonsAreNamed() {
        let reasons = KeeperCoreRefusalReason.allCases
        #expect(Set(reasons.map(\.rawValue)) == ["joinSyncingInTurn", "ticklessLandWithTransport"], "a refusal was added or lifted: update this list and the K2-2 plan's §3.2 table")
        #expect(Set(reasons.map(\.message)).count == reasons.count, "two refusals share a message")
        for reason in reasons {
            #expect(reason.liftedIn.hasPrefix("K2-2 commit "), "\(reason) names no lifting commit")
        }
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

    // MARK: The ordered trace and the tokenless step (§6, §4.2 point 3, §16 items 5 and 12)

    /// A keeper on each path with a recorder and a tracing port, for the trace cases: the direct
    /// keeper, and the core twin of a second keeper. Distinct land IDs (one recorder spool each);
    /// the land reads no RNG and no land ID, so the records don't depend on it.
    private struct TracePair {
        let keeper: LandKeeper<CoreDiffState>
        let source: LandKeeper<CoreDiffState>
        let harness: KeeperCoreHarness<CoreDiffState>
        let keeperLandID: String
        let coreLandID: String
        let keeperTrace: CoreDiffTrace
        let coreTrace: CoreDiffTrace
        let keeperTransport: CoreDiffTraceTransport
        let coreTransport: CoreDiffTraceTransport

        static func make(_ name: String) async throws -> TracePair {
            let shape = CoreDiffShape(tick: true, joinResolvers: false, leaveResolver: false)
            let keeperTrace = CoreDiffTrace(), coreTrace = CoreDiffTrace()
            let keeperTransport = CoreDiffTraceTransport(keeperTrace), coreTransport = CoreDiffTraceTransport(coreTrace)
            let keeperLandID = "core-diff:\(name):keeper:\(UUID().uuidString)", coreLandID = "core-diff:\(name):core:\(UUID().uuidString)"
            func keeper(_ id: String, _ transport: CoreDiffTraceTransport?) -> LandKeeper<CoreDiffState> {
                LandKeeper<CoreDiffState>(definition: coreDiffDefinition(shape), initialState: CoreDiffState(), enableLiveStateHashRecording: true,
                                          autoStartLoops: false, landID: id, transport: transport)
            }
            let direct = keeper(keeperLandID, keeperTransport), source = keeper(coreLandID, nil)
            await direct.awaitInitialization()
            await source.awaitInitialization()
            for k in [direct, source] {
                let recorder = try #require(await k.getReevaluationRecorder())
                await recorder.setMetadata(ReevaluationRecordMetadata(landID: "core-diff", landType: "core-diff", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                                      metadata: [:], landDefinitionID: "core-diff", rngSeed: 1, version: ReevaluationRecordVersion.current))
            }
            let harness = KeeperCoreHarness(await source.coreTwinForTesting(transport: coreTransport))
            await harness.start()
            await direct.setFlushTraceForTesting { keeperTrace.append("flush: \($0)") }
            await harness.setFlushTrace { coreTrace.append("flush: \($0)") }
            await direct.waitForRecorderSubmissionsForTesting()
            keeperTrace.clear()
            coreTrace.clear()
            return TracePair(keeper: direct, source: source, harness: harness, keeperLandID: keeperLandID, coreLandID: coreLandID,
                             keeperTrace: keeperTrace, coreTrace: coreTrace, keeperTransport: keeperTransport, coreTransport: coreTransport)
        }

        /// A tick on each path, with its record handed to the recorder and taken.
        func tick() async {
            await keeper.stepTickOnce()
            await keeper.waitForRecorderSubmissionsForTesting()
            await harness.drive(.tickDue(fold: nil, foldStart: nil, syncsInTurn: true))
            await harness.waitForSubmissions()
        }

        /// Each path's recorder frames, as JSON, entry by entry.
        func frames() async throws -> (keeper: [String], core: [String]) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            func encoded(_ k: LandKeeper<CoreDiffState>) async throws -> [String] {
                let recorder = try #require(await k.getReevaluationRecorder())
                return try await recorder.getAllFrames().map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            }
            return (try await encoded(keeper), try await encoded(source))
        }

        /// The two traces, entry by entry, and the two records.
        /// `failed`: the land failed in the step. Each path's teardown then runs: the keeper's
        /// from the staged start, the core's from its `.failureTeardown` output (K2-2 commit 1b):
        /// `landDidFail`, then the drain's `onLandDestroyed`, last, on both paths.
        func expectSameTrace(_ step: String, failed: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            var k = keeperTrace.all
            var c = coreTrace.all
            if failed {
                await keeper.waitUntilDrainStartedForTesting()
                await keeper.waitUntilDrained()
                guard await coreTrace.waitFor("onLandDestroyed") else {
                    Issue.record("\(step): the core's teardown never told the port the land was destroyed: \(coreTrace.all)", sourceLocation: sourceLocation)
                    return
                }
                k = keeperTrace.all
                c = coreTrace.all
                for (path, entries) in [("keeper", k), ("core", c)] {
                    let teardown = entries.filter { $0.hasPrefix("landDidFail") || $0 == "onLandDestroyed" }
                    #expect(teardown.count == 2 && teardown.last == "onLandDestroyed", "\(step): the \(path)'s teardown \(teardown)", sourceLocation: sourceLocation)
                    #expect(Array(entries.suffix(2)) == teardown, "\(step): the \(path)'s teardown comes last \(entries)", sourceLocation: sourceLocation)
                }
            }
            #expect(k.count == c.count, "\(step): \(k.count) vs \(c.count) entries\n keeper \(k)\n core   \(c)", sourceLocation: sourceLocation)
            for (index, pair) in zip(k, c).enumerated() where pair.0 != pair.1 {
                Issue.record("\(step): entry \(index) differs:\n keeper \(pair.0)\n core   \(pair.1)", sourceLocation: sourceLocation)
            }
            let (kf, cf) = try await frames()
            #expect(kf == cf, "\(step): the records differ\n keeper \(kf)\n core   \(cf)", sourceLocation: sourceLocation)
        }
    }

    @Test("The sync entries on the core: a ticket, a requested sync-only turn with and without it, and a stale ticket, the same answers, port calls and records on both paths (K2-2 plan, commit 3, §9)")
    func syncEntries() async throws {
        let pair = try await TracePair.make("sync-entries")
        let keeperTicket = await pair.keeper.syncTurnTicket(via: pair.keeperTransport)
        let coreTicket = await pair.harness.syncTurnTicket(via: pair.coreTransport)
        #expect(keeperTicket != nil && coreTicket != nil, "the attached port gets a ticket on both paths")
        let keeperNow = await pair.keeper.syncTurnNow(via: pair.keeperTransport, reason: .syncNow)
        let coreNow = await pair.harness.syncTurnNow(via: pair.coreTransport, reason: .syncNow)
        #expect("\(keeperNow)" == "\(coreNow)", "keeper \(keeperNow), core \(coreNow)")
        let keeperTicketed = await pair.keeper.syncTurnNow(via: pair.keeperTransport, reason: .syncNow, ticket: keeperTicket)
        let coreTicketed = await pair.harness.syncTurnNow(via: pair.coreTransport, reason: .syncNow, ticket: coreTicket)
        #expect("\(keeperTicketed)" == "\(coreTicketed)", "keeper \(keeperTicketed), core \(coreTicketed)")
        // A port that isn't the attached transport: refused, nothing bound, no phase.
        let stranger = CoreDiffTraceTransport(CoreDiffTrace())
        let keeperStranger = await pair.keeper.syncTurnNow(via: stranger, reason: .syncNow)
        let coreStranger = await pair.harness.syncTurnNow(via: stranger, reason: .syncNow)
        #expect("\(keeperStranger)" == "\(coreStranger)" && "\(coreStranger)" == "\(InTurnSyncResult.skipped)", "keeper \(keeperStranger), core \(coreStranger)")
        await pair.harness.waitForSubmissions()
        await pair.keeper.waitForRecorderSubmissionsForTesting()
        try await pair.expectSameTrace("after the sync entries")
        let keeperRequested = await pair.keeper.requestedSyncTurnsForTesting
        let coreRequested = await pair.harness.differentialRead().model.requestedSyncTurnsForTesting
        #expect(keeperRequested == coreRequested, "keeper \(keeperRequested), core \(coreRequested)")
        #expect(await pair.harness.differentialRead().violations.isEmpty)
    }

    @Test("A ticket made stale by a rebind, and a port whose witness refuses the owner, are skipped and bind nothing, on both paths (Review r2 on #948)")
    func syncStaleTicketAndRefusingWitness() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "sync-stale")
        _ = await bothJoin(pair, "p1", "c1")
        // A refusing witness first: skipped, and nothing bound, so a later port still binds.
        let keeperRefusing = CoreDiffTraceTransport(CoreDiffTrace()), coreRefusing = CoreDiffTraceTransport(CoreDiffTrace())
        keeperRefusing.witnessAnswer = false
        coreRefusing.witnessAnswer = false
        let keeperRefused = await pair.keeper.syncTurnNow(via: keeperRefusing, reason: .syncNow)
        let coreRefused = await pair.harness.syncTurnNow(via: coreRefusing, reason: .syncNow)
        #expect("\(keeperRefused)" == "\(InTurnSyncResult.skipped)" && "\(coreRefused)" == "\(InTurnSyncResult.skipped)", "keeper \(keeperRefused), core \(coreRefused)")
        let keeperRefusedTicket = await pair.keeper.syncTurnTicket(via: keeperRefusing)
        let coreRefusedTicket = await pair.harness.syncTurnTicket(via: coreRefusing)
        #expect(keeperRefusedTicket == nil && coreRefusedTicket == nil)

        // Port A binds and gets a ticket; it goes away (the binding is weak), port B binds, and
        // the binding's generation moves: A's ticket is stale.
        var keeperA: CoreDiffTraceTransport? = CoreDiffTraceTransport(CoreDiffTrace())
        var coreA: CoreDiffTraceTransport? = CoreDiffTraceTransport(CoreDiffTrace())
        let keeperTicket = try #require(await pair.keeper.syncTurnTicket(via: keeperA!))
        let coreTicket = try #require(await pair.harness.syncTurnTicket(via: coreA!))
        keeperA = nil
        coreA = nil
        let keeperB = CoreDiffTraceTransport(CoreDiffTrace()), coreB = CoreDiffTraceTransport(CoreDiffTrace())
        let keeperStale = await pair.keeper.syncTurnNow(via: keeperB, reason: .syncNow, ticket: keeperTicket)
        let coreStale = await pair.harness.syncTurnNow(via: coreB, reason: .syncNow, ticket: coreTicket)
        #expect("\(keeperStale)" == "\(InTurnSyncResult.skipped)" && "\(coreStale)" == "\(InTurnSyncResult.skipped)", "keeper \(keeperStale), core \(coreStale)")
        // B is now bound: its current ticket runs a turn on both paths.
        let keeperCurrent = await pair.keeper.syncTurnTicket(via: keeperB)
        let coreCurrent = await pair.harness.syncTurnTicket(via: coreB)
        #expect(keeperCurrent != nil && coreCurrent != nil && keeperCurrent != keeperTicket && coreCurrent != coreTicket)
        let keeperRequested = await pair.keeper.requestedSyncTurnsForTesting
        let coreRequested = await pair.harness.differentialRead().model.requestedSyncTurnsForTesting
        #expect(keeperRequested == coreRequested, "keeper \(keeperRequested), core \(coreRequested)")
        await pair.expectSame("after the stale ticket")
    }

    @Test("The ordered trace on an eventful tick: the same port calls with the same events, the same flush effects and the same record, entry by entry (§6)")
    func orderedTraceOnAnEventfulTick() async throws {
        let pair = try await TracePair.make("trace")
        await pair.tick()
        try await pair.expectSameTrace("after the tick")
        #expect(pair.coreTrace.all.contains { $0.hasPrefix("runSyncPhaseInTurn") && $0.contains("CoreDiffServerEvent") }, "\(pair.coreTrace.all)")
        #expect(pair.coreTrace.all.contains { $0.hasPrefix("flush: submission") }, "the record's hand-off is traced: \(pair.coreTrace.all)")
        let (frames, _) = try await pair.frames()
        #expect(frames.count >= 1)
    }

    @Test("The ordered trace on a refusal path: a port callback re-enters mid-step, is refused, and the land ends in that step the same way on both paths (§6)")
    func orderedTraceOnARefusedCallback() async throws {
        let pair = try await TracePair.make("trace-refusal")
        pair.keeperTransport.armReentry(pair.keeper)
        pair.coreTransport.armReentry(pair.source)
        // The refused answer is not used on either path (Review round 2): the failure applies in
        // the call (one refusal, no late application), not after the frame read the answer.
        let keeperViolationsBefore = await pair.keeper.reentryViolationsForTesting
        let coreViolationsBefore = await pair.source.reentryViolationsForTesting
        let keeperLateBefore = await pair.keeper.lateReentriesAppliedForTesting
        let coreLateBefore = await pair.source.lateReentriesAppliedForTesting
        await pair.tick()
        try await pair.expectSameTrace("after the refused callback", failed: true)
        #expect(pair.coreTrace.all.contains("re-enter submitSyncStream"))
        let keeperFailure = await pair.keeper.differentialReadForTesting().failure
        let coreFailure = await pair.harness.differentialRead().failure
        #expect(keeperFailure != nil && keeperFailure == coreFailure, "keeper \(String(describing: keeperFailure)), core \(String(describing: coreFailure))")
        #expect(keeperFailure?.kind == .keeperReentry)
        #expect(await pair.keeper.reentryViolationsForTesting - keeperViolationsBefore == 1)
        #expect(await pair.source.reentryViolationsForTesting - coreViolationsBefore == 1)
        #expect(await pair.keeper.lateReentriesAppliedForTesting == keeperLateBefore)
        #expect(await pair.source.lateReentriesAppliedForTesting == coreLateBefore)
    }

    @Test("The tokenless step: a .tickDue carries no binding token, its handler reaches a guarded entry outside callOut, and the land ends in that same step by the keeper's route (§4.2 point 3)")
    func tokenlessStepBackstop() async throws {
        let pair = try await TracePair.make("tokenless")
        CoreDiffHandlerReentry.register(pair.keeperLandID) { [keeper = pair.keeper] in
            keeper.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: the handler's re-entry the sentinel refuses
        }
        CoreDiffHandlerReentry.register(pair.coreLandID) { [source = pair.source] in
            source.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: the handler's re-entry the sentinel refuses
        }
        let keeperLateBefore = await pair.keeper.lateReentriesAppliedForTesting
        let coreLateBefore = await pair.source.lateReentriesAppliedForTesting
        await pair.tick()
        try await pair.expectSameTrace("after the handler's re-entry", failed: true)
        let keeperFailure = await pair.keeper.differentialReadForTesting().failure
        let coreFailure = await pair.harness.differentialRead().failure
        #expect(coreFailure != nil && keeperFailure == coreFailure, "keeper \(String(describing: keeperFailure)), core \(String(describing: coreFailure))")
        // The same route on both paths: the refusal noted the failure in the mailbox the step
        // reads (the core's is the source's, as the facade's will be the core's), and the tick's
        // body applied it in that step, before its sync phase (the trace has none). The backstop
        // count moves alike on both.
        let keeperLate = await pair.keeper.lateReentriesAppliedForTesting - keeperLateBefore
        let coreLate = await pair.source.lateReentriesAppliedForTesting - coreLateBefore
        #expect(keeperLate == coreLate, "backstop: keeper \(keeperLate), core \(coreLate)")
        #expect(!pair.coreTrace.all.contains { $0.hasPrefix("runSyncPhaseInTurn") }, "no sync phase after the trip: \(pair.coreTrace.all)")
    }

    @Test("A sync follow-up a tick's phase asks for, on a land without periodic sync, is refused on the core by name, with no work count or pending turn left (Review round 2 on #938: K2-2 routes them)",
          arguments: [CoreDiffTraceTransport.FollowUp.joinsAwaiting, .keptEvents, .deferred], [false, true])
    func syncFollowUpsAreRefusedOnTheCore(followUp: CoreDiffTraceTransport.FollowUp, syncOnly: Bool) async throws {
        let pair = try await TracePair.make("follow-up")
        pair.coreTransport.followUp = followUp
        if syncOnly {
            // A sync that doesn't fold (no tick due): `syncOnlyTurnBody`'s own path to the helpers.
            await pair.harness.drive(.syncDue(now: ContinuousClock.now, tickDeadline: nil, foldPending: false, syncsInTurn: true))
            await pair.harness.waitForSubmissions()
        } else {
            await harnessTick(pair)
        }
        let read = await pair.harness.differentialRead()
        let site = switch followUp {
        case .joinsAwaiting: "scheduleJoinSyncTurn"
        case .keptEvents: "requestSyncTurnAfterThisTurn"
        case .deferred, .none: "retrySyncOnlyTurnAfterWriterDrain"
        }
        #expect(read.violations.contains { $0.contains("refused \(site)") }, "\(read.violations)")
        #expect(!read.violations.contains { $0.contains("requested sync work") }, "no work count began: \(read.violations)")
        #expect(read.model.requestedSyncWork == 0)
        #expect(read.model.joinSyncTurnBinding == nil && read.model.inTurnDrainRetryBinding == nil, "no binding was written")
        #expect(read.pendingSyncTurnAfterTurn == "-", "no pending follow-up: \(read.pendingSyncTurnAfterTurn)")
        #expect(read.model.requestedSyncTurnsForTesting.isEmpty && read.model.joinSyncTurnsScheduledForTesting == 0, "no test counter moved")
        #expect(!pair.coreTrace.all.contains("flush: staged action"), "no staged start: \(pair.coreTrace.all)")
        #expect(pair.coreTrace.all.contains { $0.hasPrefix("runSyncPhaseInTurn") && $0.contains("includeSync=true") }, "the phase ran: \(pair.coreTrace.all)")
    }

    /// The core's tick only (the keeper's path runs its follow-up, which this case doesn't compare).
    /// A sync due before the tick folds into it (as the fold round trip drives it), so the
    /// tick's phase includes the sync and reaches `applyInTurnSyncResult`'s branches.
    private func harnessTick(_ pair: TracePair) async {
        let deadline = ContinuousClock.now
        await pair.harness.drive(.syncDue(now: deadline - .milliseconds(1), tickDeadline: deadline, foldPending: false, syncsInTurn: true))
        let fold = await pair.harness.flushedFolds.last
        await pair.harness.drive(.tickDue(fold: fold, foldStart: fold.map { _ in deadline + .milliseconds(20) }, syncsInTurn: true))
        await pair.harness.waitForSubmissions()
    }

    @Test("The late re-entry backstop: with no transport, a handler's re-entry is applied by the frame's backstop after the body, once on each path (Review round 2 on #938)")
    func lateReentryBackstop() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: true, joinResolvers: false, leaveResolver: false), "backstop")
        let source = try #require(pair.source)
        let keeperLateBefore = await pair.keeper.lateReentriesAppliedForTesting
        let coreLateBefore = await source.lateReentriesAppliedForTesting
        // One path at a time: the hook is one-shot and keyed by the land ID both share.
        CoreDiffHandlerReentry.register(pair.landID) { [keeper = pair.keeper] in
            keeper.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: the handler's re-entry the sentinel refuses
        }
        await pair.keeper.stepTickOnce()
        CoreDiffHandlerReentry.register(pair.landID) { [source] in
            source.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: the handler's re-entry the sentinel refuses
        }
        await pair.harness.drive(.tickDue(fold: nil, foldStart: nil, syncsInTurn: false))
        defer { CoreDiffHandlerReentry.clear(pair.landID) }
        let keeperLate = await pair.keeper.lateReentriesAppliedForTesting - keeperLateBefore
        let coreLate = await source.lateReentriesAppliedForTesting - coreLateBefore
        #expect(keeperLate == 1 && coreLate == 1, "backstop: keeper \(keeperLate), core \(coreLate)")
        let keeperFailure = await pair.keeper.differentialReadForTesting().failure
        let coreFailure = await pair.harness.differentialRead().failure
        #expect(coreFailure != nil && keeperFailure == coreFailure, "keeper \(String(describing: keeperFailure)), core \(String(describing: coreFailure))")
    }

    @Test("The core's flush sends an input and then asks a query: the query is answered in place, before the queued input steps (§16 item 5)")
    func flushSendsThenQueries() async throws {
        let shape = CoreDiffShape(tick: true, joinResolvers: false, leaveResolver: false)
        let source = LandKeeper<CoreDiffState>(definition: coreDiffDefinition(shape), initialState: CoreDiffState(), autoStartLoops: false, landID: "core-diff:flush-query:\(UUID().uuidString)")
        await source.awaitInitialization()
        let harness = KeeperCoreHarness(await source.coreTwinForTesting(transport: FoldRecordingTransport(records: true)))
        await harness.start()
        let before = await harness.differentialRead().model
        // The only K2-1 output is a fold, so the armed flush is `.syncDue`'s: it sends a tick and
        // asks for a tick land's action intake.
        await harness.armFlush(send: .tickDue(fold: nil, foldStart: nil, syncsInTurn: true),
                               thenAsk: .admitAction(envelope(CoreDiffAction(n: 3, fails: false)), caller("p1", "c1"), enforcingLimits: true))
        let deadline = ContinuousClock.now
        await harness.drive(.syncDue(now: deadline - .milliseconds(1), tickDeadline: deadline, foldPending: false, syncsInTurn: true))
        let answers = await harness.flushQueryAnswers
        try #require(answers.count == 1, "the fold's flush ran the armed calls")
        guard case let .actionSubmission(submission) = answers[0].answer, (try? submission.get()) != nil else {
            Issue.record("the query's answer: \(answers[0].answer)")
            return
        }
        #expect(answers[0].pendingAtQuery.count == 1, "the intake appended at the query: \(answers[0].pendingAtQuery)")
        // Answered in place, as its own step: the sent tick hadn't stepped yet.
        #expect(answers[0].tickAtQuery == before.lastCommittedTickId, "\(answers[0].tickAtQuery)")
        let after = await harness.differentialRead().model
        #expect(after.lastCommittedTickId == before.lastCommittedTickId + 1, "the sent tick stepped after the flush")
        #expect(after.state.log.contains("action:3"), "the queued tick applied the query's action: \(after.state.log)")
        #expect(await harness.inputsSeen.suffix(2) == ["syncDue", "tickDue"])
    }

}

// MARK: - K2-2a round 2: the freeze, the barrier, the sync draft, the caller's cancellation

private func coreFreeze(_ pair: CoreDiffPair, _ generation: UInt64, _ timeout: Duration) async -> Bool? {
    guard case let .frozen(frozen)? = try? await pair.harness.call(.freeze(generation: generation, timeout: timeout)) else { return nil }
    return frozen
}

/// A probe's name as an event: yields once each time the probe opens it.
private func probeEvents(_ name: String) -> (stream: AsyncStream<Void>, probe: @Sendable (String) -> Void) {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    return (stream, { if $0 == name { continuation.yield() } })
}

/// A task's result, or nil after `testHangBound` (Review r2 on #966): the harness calls with
/// `.ignoresCancel`, so a lost reply can't be freed by a cancel; the bound is an event the
/// task's end appends, and the caller fails the case instead of hanging it.
private func resultWithinHangBound<T: Sendable>(_ task: Task<T, any Error>) async -> Result<T, any Error>? {
    let ended = EventLog()
    Task {
        _ = await task.result
        ended.append("ended")
    }
    guard await ended.waitFor("ended") else { return nil }
    return await task.result
}

/// `task.value`, bounded as `resultWithinHangBound` is; nil when it doesn't end.
private func valueWithinHangBound<T: Sendable>(_ task: Task<T, Never>) async -> T? {
    let ended = EventLog()
    Task {
        _ = await task.value
        ended.append("ended")
    }
    guard await ended.waitFor("ended") else { return nil }
    return await task.value
}

/// A harness call's reply, bounded as `resultWithinHangBound` is.
private func replyWithinHangBound(_ pair: CoreDiffPair, _ input: KeeperInput<CoreDiffState>) async -> Result<KeeperReply<CoreDiffState>, any Error>? {
    await resultWithinHangBound(Task { try await pair.harness.call(input) })
}

/// Whether `stream` yields within `testHangBound`. It consumes the stream: one read per stream.
private func firstWithinHangBound(_ stream: AsyncStream<Void>) async -> Bool {
    let seen = EventLog()
    Task {
        for await _ in stream {
            seen.append("next")
            return
        }
    }
    return await seen.waitFor("next")
}

/// The cause inside an initialization's failure, as both paths can compare it: the resolver
/// group's error unwrapped from `resolverFailed`, a refusal's own error, or the land's closing
/// rejection.
private func initializationCause(_ error: any Error) -> String {
    guard let failure = error as? LandInitializationError else { return "not a LandInitializationError: \(error)" }
    var cause = failure.underlying
    if case let ResolverExecutionError.resolverFailed(_, underlying) = cause { cause = underlying }
    return String(describing: cause)
}

/// The keeper's initialization failure, as a late caller sees it: a leave awaits the
/// initialization first, and throws its failure.
private func keeperInitializationCause(_ keeper: LandKeeper<CoreDiffState>) async -> String {
    do {
        try await keeper.leave(playerID: PlayerID("late"), clientID: ClientID("late"), sessionID: SessionID("late"))
        return "the late leave returned"
    } catch {
        return initializationCause(error)
    }
}

/// Every caller's cause is `expected`: the core's early and late `.awaitInitialized` and the
/// keeper's late leave (Review r2 on #966: the wrapper type alone lets another failure pass).
private func expectInitializationCauses(
    _ pair: CoreDiffPair,
    early: Result<KeeperReply<CoreDiffState>, any Error>?,
    _ expected: String,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let late = await replyWithinHangBound(pair, .awaitInitialized)
    for (name, answer) in [("early", early), ("late", late)] {
        guard case let .failure(error)? = answer else {
            Issue.record("the core's \(name) waiter: \(String(describing: answer))", sourceLocation: sourceLocation)
            continue
        }
        #expect(initializationCause(error) == expected, "the core's \(name) waiter: \(error)", sourceLocation: sourceLocation)
    }
    let keeperCause = await keeperInitializationCause(pair.keeper)
    #expect(keeperCause == expected, "the keeper's late caller: \(keeperCause)", sourceLocation: sourceLocation)
}

private func outputDraft(_ tag: UInt64, reentering keeper: LandKeeper<CoreDiffState>? = nil) -> SyncStreamDraft {
    SyncStreamDraft(.output(observedTickId: 0, make: { streamIndex, index in
        keeper?.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: a draft factory that calls back into its keeper
        return ReevaluationRecordedSyncOutput(index: index, turnKind: .syncOnly, observedTickId: 0,
                                              streamIndex: streamIndex, sequence: Int64(streamIndex), broadcastHash: 0xbeef_0000 + tag)
    }))
}

private func markerDraft() -> SyncStreamDraft {
    SyncStreamDraft(.marker(make: { streamIndex, position in
        ReevaluationRecordedSyncMarker(kind: .clear, playerID: "p1", streamIndex: streamIndex, sequence: position.sequence)
    }))
}

extension KeeperCoreDifferentialTests {
    @Test("The freeze watcher counts a registration that has already ended: a caller that registered and timed out before the watcher was installed still counts (#948 cloud mutant b, forced by awaiting the caller's end first)")
    func freezeWatcherCountsEndedRegistration() async throws {
        let keeperGate = CoreDiffArmedGate()
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "freeze-watcher-ended",
                                           keeperRecordGate: keeperGate)
        _ = await bothJoin(pair, "p1", "c1")
        let kg = WatermarkGate()
        defer { kg.release() }
        keeperGate.arm(kg)
        let keeperAct = Task { await keeperAction(pair, CoreDiffAction(n: 1, fails: false), "p1", "c1") }
        guard await kg.waitUntilEntered("the keeper's record") else { return }
        // The caller registers (the work is in flight) and times out; its end is awaited before
        // the watcher exists, so no caller waits when the watcher is installed. A watcher that
        // read the current waiters would see 0 and wait out its bound.
        let short = await pair.keeper.debugFreeze(generation: 1, timeout: .milliseconds(50))
        #expect(short == false, "the short caller timed out with the work in flight")
        #expect(await pair.keeper.waitUntilFreezeRegistrationsForTesting(1, within: .seconds(2)), "the ended registration counts")
        kg.release()
        _ = await keeperAct.value
        await pair.keeper.debugResume(generation: 1)
    }

    @Test("Each freeze caller has its own deadline: with work in flight, the first caller's short budget ends false while the second's long one answers true at the work's end, on both paths (Review on #948, MF1)")
    func freezeDeadlinePerCaller() async throws {
        let keeperGate = CoreDiffArmedGate(), clock = CoreDiffClock()
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "freeze-per-caller",
                                           keeperRecordGate: keeperGate, clock: clock)
        _ = await bothJoin(pair, "p1", "c1")

        let kg = WatermarkGate()
        defer { kg.release() }
        keeperGate.arm(kg)
        let keeperAct = Task { await keeperAction(pair, CoreDiffAction(n: 1, fails: false), "p1", "c1") }
        guard await kg.waitUntilEntered("the keeper's record") else { return }
        // The keeper's clock is real: a short budget against a held work, and one that can't fire.
        // The long caller registers first, and the short one's registration is the event the
        // case waits for: its timer can't fire before the segment that registers it ends, so
        // both wait when the short one times out (Review r2 on #948, MF3).
        let keeperLong = Task { await pair.keeper.debugFreeze(generation: 1, timeout: .seconds(3600)) }
        #expect(await pair.keeper.waitUntilFreezeRegistrationsForTesting(1), "a freeze caller registered")
        let keeperShort = Task { await pair.keeper.debugFreeze(generation: 1, timeout: .milliseconds(50)) }
        #expect(await pair.keeper.waitUntilFreezeRegistrationsForTesting(2), "a freeze caller registered")
        let keeperShortFroze = await keeperShort.value
        kg.release()
        let keeperLongFroze = await keeperLong.value
        await pair.keeper.debugResume(generation: 1)
        _ = await keeperAct.value

        let cg = WatermarkGate()
        defer { cg.release() }
        pair.harness.armedRecordGate.arm(cg)
        let coreAct = Task { await coreTicklessAction(pair, CoreDiffAction(n: 1, fails: false), "p1", "c1") }
        guard await cg.waitUntilEntered("the core's record") else { return }
        let coreShort = Task { await coreFreeze(pair, 1, .seconds(1)) }
        guard await pair.harness.waitForInputs(named: "freeze", count: 1) else { return }
        let coreLong = Task { await coreFreeze(pair, 1, .seconds(3600)) }
        guard await pair.harness.waitForInputs(named: "freeze", count: 2) else { return }
        clock.advance(by: .seconds(2))
        let coreShortFroze = await coreShort.value
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.freeze[1]?.count == 1, "the long caller still waits")
        cg.release()
        let coreLongFroze = await coreLong.value
        await pair.harness.drive(.resume(generation: 1))
        _ = await coreAct.value

        #expect(keeperShortFroze == false && keeperLongFroze == true, "keeper \(keeperShortFroze), \(keeperLongFroze)")
        #expect(coreShortFroze == false && coreLongFroze == true, "core \(String(describing: coreShortFroze)), \(String(describing: coreLongFroze))")
        await pair.expectSame("after both freezes")
    }

    @Test("A superseded generation's caller is answered false when the work ends, not at its timeout, on both paths (Review on #948, MF1)")
    func supersededGenerationAnsweredAtWorkEnd() async throws {
        let keeperGate = CoreDiffArmedGate(), clock = CoreDiffClock()
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "freeze-superseded",
                                           keeperRecordGate: keeperGate, clock: clock)
        _ = await bothJoin(pair, "p1", "c1")

        let kg = WatermarkGate()
        defer { kg.release() }
        keeperGate.arm(kg)
        let keeperAct = Task { await keeperAction(pair, CoreDiffAction(n: 1, fails: false), "p1", "c1") }
        guard await kg.waitUntilEntered("the keeper's record") else { return }
        let keeperFirst = Task { await pair.keeper.debugFreeze(generation: 1, timeout: .seconds(3600)) }
        #expect(await pair.keeper.waitUntilFreezeWaitsForTesting(), "a freeze caller registered")
        let keeperSecond = Task { await pair.keeper.debugFreeze(generation: 2, timeout: .seconds(3600)) }
        // Both callers wait before the work ends (Review r2 on #948, MF3).
        #expect(await pair.keeper.waitUntilFreezeRegistrationsForTesting(2), "a freeze caller registered")
        kg.release()
        let keeperAnswers = (await keeperFirst.value, await keeperSecond.value)
        await pair.keeper.debugResume(generation: 2)
        _ = await keeperAct.value

        let cg = WatermarkGate()
        defer { cg.release() }
        pair.harness.armedRecordGate.arm(cg)
        let coreAct = Task { await coreTicklessAction(pair, CoreDiffAction(n: 1, fails: false), "p1", "c1") }
        guard await cg.waitUntilEntered("the core's record") else { return }
        let coreFirst = Task { await coreFreeze(pair, 1, .seconds(3600)) }
        guard await pair.harness.waitForInputs(named: "freeze", count: 1) else { return }
        let coreSecond = Task { await coreFreeze(pair, 2, .seconds(3600)) }
        guard await pair.harness.waitForInputs(named: "freeze", count: 2) else { return }
        cg.release()
        // The answers are the events (Review r2 on #948, MF3): the clock is manual and isn't
        // advanced, so a caller answered only at its timeout never returns, and the hang bound
        // fails the case. A count of results noted in `perform` would run before their steps.
        // The bound waits on a signal, never on the calls themselves (`.ignoresCancel`, so a
        // cancelled wait wouldn't end them; #940's R13): on a timeout the clock is advanced
        // first, which answers both, and only then are they joined (Review r3 on #948).
        let (answered, signal) = AsyncStream<Void>.makeStream()
        let watcher = Task { _ = await coreFirst.value; _ = await coreSecond.value; signal.yield() }
        let answeredAtWorkEnd = await firstSignal(answered, withinSeconds: 30)
        #expect(answeredAtWorkEnd, "every generation's callers answered at the work's end")
        if !answeredAtWorkEnd { clock.advance(by: .seconds(3601)) }
        await watcher.value
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.freeze.isEmpty)
        let coreAnswers = (await coreFirst.value, await coreSecond.value)
        await pair.harness.drive(.resume(generation: 2))
        _ = await coreAct.value

        #expect(keeperAnswers == (false, true), "keeper \(keeperAnswers)")
        #expect(coreAnswers == (false, true), "core \(coreAnswers)")
        await pair.expectSame("after the superseded freeze")
    }

    @Test("An expired budget with work in flight answers false at once, with no wait armed, on both paths (Review on #948, MF1)")
    func expiredFreezeBudget() async throws {
        let keeperGate = CoreDiffArmedGate()
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "freeze-expired",
                                           keeperRecordGate: keeperGate, clock: CoreDiffClock())
        _ = await bothJoin(pair, "p1", "c1")
        let kg = WatermarkGate()
        defer { kg.release() }
        keeperGate.arm(kg)
        let keeperAct = Task { await keeperAction(pair, CoreDiffAction(n: 1, fails: false), "p1", "c1") }
        guard await kg.waitUntilEntered("the keeper's record") else { return }
        let keeperFroze = await pair.keeper.debugFreeze(generation: 1, timeout: .zero)
        kg.release()
        await pair.keeper.debugResume(generation: 1)
        _ = await keeperAct.value

        let cg = WatermarkGate()
        defer { cg.release() }
        pair.harness.armedRecordGate.arm(cg)
        let coreAct = Task { await coreTicklessAction(pair, CoreDiffAction(n: 1, fails: false), "p1", "c1") }
        guard await cg.waitUntilEntered("the core's record") else { return }
        let coreFroze = await coreFreeze(pair, 1, .zero)
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.isEmpty, "no wait armed")
        cg.release()
        await pair.harness.drive(.resume(generation: 1))
        _ = await coreAct.value

        #expect(keeperFroze == false && coreFroze == false, "keeper \(keeperFroze), core \(String(describing: coreFroze))")
        await pair.expectSame("after the expired freeze")
    }

    @Test("A freeze's deadline saturates: a timeout past Int64 nanoseconds, or past the range from now, is the range's end (Review on #948, MF1)")
    func freezeDeadlineSaturates() {
        typealias Model = KeeperModel<CoreDiffState>
        #expect(Model.freezeDeadline(TurnInstant(nanoseconds: 5), .seconds(1)) == TurnInstant(nanoseconds: 1_000_000_005))
        #expect(Model.freezeDeadline(TurnInstant(nanoseconds: 0), .seconds(Int64.max)) == TurnInstant(nanoseconds: .max))
        #expect(Model.freezeDeadline(TurnInstant(nanoseconds: .max - 10), .seconds(1)) == TurnInstant(nanoseconds: .max))
    }

    @Test("A stop on an idle land, tick and tickless: the same model, the drain finished, and the caller answered after it, on both paths (K2-2 commit 1b)", arguments: [true, false])
    func stopOnIdleLand(tick: Bool) async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: tick, joinResolvers: false, leaveResolver: false), "stop-idle-\(tick)")
        guard await valueWithinHangBound(Task { await pair.keeper.forceShutdown() }) != nil else { Issue.record("the keeper\'s stop never returned"); return }
        guard case .success(.done)? = await resultWithinHangBound(Task { try await pair.harness.call(.shutdown) }) else {
            Issue.record("the core's stop wasn't answered .done"); return
        }
        // One detach at `.drainFinished`, before the stop's reply (the owner's M10 calls).
        let detaches = await pair.harness.flushed.filter { if case .detachTransport = $0 { true } else { false } }.count
        #expect(detaches == 1, "detaches: \(detaches)")
        let core = await pair.harness.differentialRead().model
        #expect(core.drainPhase == .finished)
        #expect(core.stopPhase == .ended, "the stop's flight returned")
        #expect(core.destructionFinished)
        #expect(await pair.keeper.differentialReadForTesting().model.destructionFinished)
        await pair.expectSame("after the stop")
    }

    @Test("A freeze and a drain both waiting on one held tick record: the tick's end answers the freeze true at the work count's zero, then the drain goes on and finishes, in that one step (plan §13.1; Review r1 on #969). The order inside the step can't be seen from outside on the core: the reply goes out after the step")
    func freezeAndDrainWaitOnOneTick() async throws {
        let pair = try await TracePair.make("freeze-drain-tick")
        let coreHold = WatermarkGate()
        defer { coreHold.release() }
        pair.harness.armedRecordGate.arm(coreHold)
        await pair.harness.drive(.tickDue(fold: nil, foldStart: nil, syncsInTurn: true))
        guard await coreHold.waitUntilEntered("the core's tick record") else { return }
        let freeze = Task { try await pair.harness.call(.freeze(generation: 1, timeout: .seconds(3600))) }
        guard await pair.harness.waitForInputs(named: "freeze", count: 1) else { return }
        await pair.harness.markDraining(cause: .forceShutdown)
        await pair.harness.drive(.drainStart)
        let waiting = await pair.harness.differentialRead().model
        #expect(waiting.drainPhase == .waitingForTick && waiting.coreBarrierWaits.freeze[1]?.count == 1, "\(waiting.drainPhase), \(waiting.coreBarrierWaits)")
        coreHold.release()
        guard case .success(.frozen(true))? = await resultWithinHangBound(freeze) else { Issue.record("the freeze wasn't answered true"); return }
        guard await pair.harness.drainFinishes.waitFor("drain finished") else { Issue.record("the drain never finished"); return }
        let after = await pair.harness.differentialRead().model
        #expect(after.coreBarrierWaits.freeze.isEmpty && after.ticksInFlight == 0 && after.drainPhase == .finished)
    }

    @Test("A tick or sync from before the drain's epoch bump is a no-op on the core, delivered mid-drain (the drain waits for a tick held at its record, the port still attached): no step, no call to the port, the model unchanged (M5, plan §13.1)")
    func staleTickDueAfterDrainStart() async throws {
        let pair = try await TracePair.make("stale-epoch")
        let coreHold = WatermarkGate()
        defer { coreHold.release() }
        pair.harness.armedRecordGate.arm(coreHold)
        await pair.harness.drive(.tickDue(fold: nil, foldStart: nil, syncsInTurn: true))
        guard await coreHold.waitUntilEntered("the core's tick record") else { return }
        let epochBefore = await pair.harness.differentialRead().model.loopEpoch
        // A drain that starts with a tick in flight: the flag first, then the owner's
        // `.drainStart`, as a land failure's teardown sends it (the failure itself would also
        // mute the sync, so only the flag is set here; no player is joined).
        await pair.harness.markDraining(cause: .forceShutdown)
        await pair.harness.drive(.drainStart)
        let draining = await pair.harness.differentialRead().model
        #expect(draining.loopEpoch == epochBefore &+ 1, "the drain start bumps the epoch")
        #expect(draining.drainPhase == .waitingForTick, "the drain waits for the held tick: \(draining.drainPhase)")
        let before = CoreDiffDigest(await pair.harness.differentialRead())
        pair.coreTrace.clear()

        // A sync and a tick that the replaced loops sent before the bump. A sync step doesn't
        // read the drain flag, so only the epoch keeps this one from reaching the port; the
        // tick's step would also stop at `tickStart`'s drain check.
        await pair.harness.drive(.syncDue(now: ContinuousClock.now, tickDeadline: nil, foldPending: false, syncsInTurn: true, epoch: epochBefore))
        await pair.harness.drive(.tickDue(fold: nil, foldStart: nil, syncsInTurn: true, epoch: epochBefore))
        #expect(pair.coreTrace.all.isEmpty, "a stale loop input reached the port: \(pair.coreTrace.all)")
        let after = CoreDiffDigest(await pair.harness.differentialRead())
        #expect(after == before, "differ in \(after.differingFields(from: before))")

        coreHold.release()
        // `.drainFinished`'s step itself, not the port's call before it (Review r1 on #969).
        guard await pair.harness.drainFinishes.waitFor("drain finished") else { Issue.record("the core's drain never ended: \(pair.coreTrace.all)"); return }
        #expect(await pair.harness.differentialRead().model.drainPhase == .finished)
    }

    /// A tickless pair with a recorder, `p1` joined on the core only, and an action whose batch is
    /// held at its record: work in flight, and the input drain busy, so a `.shutdown` queues its
    /// item behind it.
    private func heldTicklessBatch(_ name: String, coreTransport: CoreDiffTraceTransport? = nil) async -> (CoreDiffPair, WatermarkGate, Task<CoreDiffActionResult, Never>)? {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), name, records: true, coreTransport: coreTransport)
        guard let first = await valueWithinHangBound(Task { await coreJoin(pair, "p1", "c1") }) else { Issue.record("the core's join never returned"); return nil }
        guard case .joined(allowed: true, _) = first else { Issue.record("the core's join: \(first)"); return nil }
        let hold = WatermarkGate()
        pair.harness.armedRecordGate.arm(hold)
        let action = Task { await coreTicklessAction(pair, CoreDiffAction(n: 2, fails: false), "p1", "c1") }
        guard await hold.waitUntilEntered("the action's batch record") else { hold.release(); return nil }
        return (pair, hold, action)
    }

    @Test("A land failure in a query step tears the land down on the core (Review r1 on #969, MF2): a .syncTurnNow whose sync phase re-enters fails the land, the port hears landDidFail, then onLandDestroyed, and the drain finishes; a first stop after it is answered at once (MF1 (b)), the same on both paths")
    func queryStepFailureTearsDown() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "query-fail")
        let source = try #require(pair.source)
        let keeperTrace = CoreDiffTrace(), coreTrace = CoreDiffTrace()
        let keeperPort = CoreDiffTraceTransport(keeperTrace), corePort = CoreDiffTraceTransport(coreTrace)
        keeperPort.armReentry(pair.keeper)
        corePort.armReentry(source)
        _ = await pair.keeper.syncTurnNow(via: keeperPort, reason: .syncNow)
        _ = await pair.harness.syncTurnNow(via: corePort, reason: .syncNow)
        guard await keeperTrace.waitFor("onLandDestroyed") else { Issue.record("the keeper's teardown never ended: \(keeperTrace.all)"); return }
        guard await coreTrace.waitFor("onLandDestroyed") else { Issue.record("the core's teardown never reached the port: \(coreTrace.all)"); return }
        guard await pair.harness.drainFinishes.waitFor("drain finished") else { Issue.record("the core's drain never finished"); return }
        let teardown: (String) -> Bool = { $0.hasPrefix("landDidFail") || $0 == "onLandDestroyed" }
        #expect(keeperTrace.all.filter(teardown) == coreTrace.all.filter(teardown), "keeper \(keeperTrace.all), core \(coreTrace.all)")
        #expect(coreTrace.all.filter(teardown).count == 2, "\(coreTrace.all)")

        // MF1 (b): the failure's drain has finished; a first stop joins it and returns at once.
        guard await valueWithinHangBound(Task { await pair.keeper.forceShutdown() }) != nil else { Issue.record("the keeper\'s stop never returned"); return }
        guard case .success(.done)? = await resultWithinHangBound(Task { try await pair.harness.call(.shutdown) }) else {
            Issue.record("the stop after the failure's drain wasn't answered"); return
        }
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.drained.isEmpty)
    }

    @Test("A tickless [join, shutdown] batch whose join report is refused emits the failure's teardown, not an ordinary drain start (Review r1 on #969, MF3): the teardown runs before the stop goes on, which then joins it",
          .disabled("unreachable until K2-2 commit 3: the core refuses a tickless land with a transport (ticklessLandWithTransport), and without one the batch's join report calls no port"))
    func shutdownBatchThatFailsTheLand() async throws {
        let trace = CoreDiffTrace()
        let port = CoreDiffTraceTransport(trace)
        guard let (pair, hold, action) = await heldTicklessBatch("batch-fails", coreTransport: port) else { return }
        defer { hold.release() }
        let source = try #require(pair.source)
        // The batch's join report re-enters: `failLand` runs in the batch, before its
        // `completeShutdownTurn`.
        port.armReportReentry(source)
        let joined = Task { await coreJoin(pair, "p2", "c2") }
        guard await pair.harness.waitForInputs(named: "join", count: 2) else { return }
        let stop = Task { try await pair.harness.call(.shutdown) }
        guard await pair.harness.waitForInputs(named: "shutdown", count: 1) else { return }
        #expect(await pair.harness.differentialRead().model.pendingItems.count == 2, "the join and the shutdown wait for one batch")
        hold.release()
        guard await valueWithinHangBound(action) != nil, await valueWithinHangBound(joined) != nil else { Issue.record("the action or the join never returned"); return }
        guard case .success(.done)? = await resultWithinHangBound(stop) else { Issue.record("the stop wasn't answered .done"); return }
        #expect(trace.all.contains("re-enter submitSyncStream from the report"), "\(trace.all)")
        let flushed = await pair.harness.flushed
        let teardowns = flushed.filter { if case .failureTeardown = $0 { true } else { false } }.count
        let starts = flushed.filter { if case .drainStarting = $0 { true } else { false } }.count
        #expect(teardowns == 1 && starts == 0, "the failure's teardown, not a stop's drain start: teardowns \(teardowns), starts \(starts)")
        // As the keeper's `runFailureTeardown`: the port hears of the failure, then of the end, once.
        let teardown = trace.all.filter { $0.hasPrefix("landDidFail") || $0 == "onLandDestroyed" }
        #expect(teardown.count == 2 && teardown.first?.hasPrefix("landDidFail") == true && teardown.last == "onLandDestroyed", "\(trace.all)")
        #expect(await pair.harness.differentialRead().failure?.kind == .keeperReentry)
    }

    @Test("A drain that overtakes a queued tickless shutdown moves the stop on (Review r1 on #969, MF5, m8): the shutdown item is dropped, never applied, and the stop drains with the failure's drain and returns")
    func drainOvertakesQueuedShutdown() async throws {
        guard let (pair, hold, action) = await heldTicklessBatch("overtake") else { return }
        defer { hold.release() }
        let source = try #require(pair.source)
        let stop = Task { try await pair.harness.call(.shutdown) }
        guard await pair.harness.waitForInputs(named: "shutdown", count: 1) else { return }
        let queued = await pair.harness.differentialRead().model
        #expect(queued.stopPhase == .awaitingShutdownTurn && queued.pendingItems.count == 1, "\(queued.stopPhase), \(queued.pendingItems.count)")
        // A failure outside the batch: a sync-only turn whose sync phase re-enters. Its port is
        // the bound requester, so the drain's notify (T8b) reaches it and is held there.
        let trace = CoreDiffTrace()
        let port = CoreDiffTraceTransport(trace)
        let notifyHold = WatermarkGate()
        defer { notifyHold.release() }
        port.destroyedHold.arm(notifyHold)
        port.armReentry(source)
        _ = await pair.harness.syncTurnNow(via: port, reason: .syncNow)
        guard await notifyHold.waitUntilEntered("the drain's onLandDestroyed") else { return }
        let mid = await pair.harness.differentialRead().model
        #expect(!mid.shutdownTurnApplied, "the drain dropped the shutdown item before its turn")
        #expect(mid.stopPhase == .draining, "the stop moved on with the drain before its end: \(mid.stopPhase)")
        #expect(mid.pendingItems.isEmpty && mid.coreBarrierWaits.drained.count == 1, "\(mid.pendingItems.count), \(mid.coreBarrierWaits)")
        notifyHold.release()
        guard case .success(.done)? = await resultWithinHangBound(stop) else { Issue.record("the stop wasn't answered .done"); return }
        let after = await pair.harness.differentialRead().model
        #expect(after.stopPhase == .ended && after.drainPhase == .finished && !after.shutdownTurnApplied, "\(after.stopPhase), \(after.drainPhase)")
        // The earlier batch's caller gets its result once its record is released.
        hold.release()
        guard let result = await valueWithinHangBound(action) else { Issue.record("the held batch's action wasn't answered"); return }
        // Applied before its record was held: the failure came after, so it keeps its result.
        #expect(result == .completed(2), "\(result)")
    }

    @Test("A freeze still waiting for held work when the stop arrives is answered false by the stop's end of the freeze, and its table and timer are emptied (Review r1 on #969: endDebugFreezeForShutdown's waiters)")
    func stopAnswersAWaitingFreeze() async throws {
        guard let (pair, hold, action) = await heldTicklessBatch("stop-freeze") else { return }
        defer { hold.release() }
        let freeze = Task { try await pair.harness.call(.freeze(generation: 1, timeout: .seconds(3600))) }
        guard await pair.harness.waitForInputs(named: "freeze", count: 1) else { return }
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.freeze[1]?.count == 1, "the freeze waits for the held batch")
        let stop = Task { try await pair.harness.call(.shutdown) }
        guard case .success(.frozen(false))? = await resultWithinHangBound(freeze) else { Issue.record("the waiting freeze wasn't answered false"); return }
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.freeze.isEmpty)
        hold.release()
        guard await valueWithinHangBound(action) != nil else { Issue.record("the action never returned"); return }
        guard case .success(.done)? = await resultWithinHangBound(stop) else { Issue.record("the stop wasn't answered .done"); return }
        #expect(await pair.harness.differentialRead().coreWaitsLeft == 0, "no core wait is left")
        #expect(await pair.harness.liveDeadlines == 0, "the freeze's timer was ended with its wait")
    }

    /// `doneStartingLoops`: `.done` through the owner's `.initializeDone` (autoStartLoops), the
    /// other call site of `beginStopAfterInitialization` (Review r2 on #969).
    enum InitializationEnd: String, CaseIterable, Sendable { case done, doneStartingLoops, failed, abandonedByDrain }

    @Test("A stop that arrives during the initialization waits for its end, however it ends (Review r1 on #969, MF4, m11): parked apart from the drain's callers, so a drain that finishes first doesn't answer it, and answered once the initialization ended", arguments: InitializationEnd.allCases)
    func stopDuringTheInitializationWaitsForIt(_ end: InitializationEnd) async throws {
        let shape = end == .failed
            ? CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false, initializeRefuses: true)
            : CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false, onInitialize: true)
        let pair = await CoreDiffPair.make(shape, "stop-init-\(end.rawValue)", initializes: false, autoStartLoops: end == .doneStartingLoops)
        let gate = WatermarkGate()
        defer { gate.release() }
        defer { CoreDiffInitGates.set(pair.landID, nil) }
        // A failing initialization has no resolver to hold: the stop comes before `.initialize`.
        if end != .failed {
            CoreDiffInitGates.set(pair.landID, gate)
            await pair.harness.drive(.initialize)
            guard await gate.waitUntilEntered("OnInitialize's resolver") else { return }
        }
        let stop = Task { try await pair.harness.call(.shutdown) }
        guard await pair.harness.waitForInputs(named: "shutdown", count: 1) else { return }
        let parked = await pair.harness.differentialRead().model
        #expect(parked.coreBarrierWaits.stopsAwaitingInitialization.count == 1 && parked.coreBarrierWaits.drained.isEmpty, "\(parked.coreBarrierWaits)")
        switch end {
        case .done, .doneStartingLoops:
            gate.release()
        case .failed:
            await pair.harness.drive(.initialize)
        case .abandonedByDrain:
            // A drain started and finished during the resolvers, as a land failure's teardown
            // sends it; the initializer is still held after it.
            await pair.harness.markDraining(cause: .forceShutdown)
            await pair.harness.drive(.drainStart)
            guard await pair.harness.drainFinishes.waitFor("drain finished") else { Issue.record("the drain never finished"); return }
            let held = await pair.harness.differentialRead().model
            #expect(held.coreBarrierWaits.stopsAwaitingInitialization.count == 1 && held.coreBarrierWaits.drained.isEmpty,
                    "the stop waits for the initialization, not the drain: \(held.coreBarrierWaits)")
            #expect(!held.didInitialize, "the initializer is still held")
            gate.release()
        }
        // The initialization's last step begins the parked stop: read right after it, so a stop
        // left parked fails here, not at the hang bound (m11's never-begins reading).
        let lastStep = switch end {
        case .failed: "initialize"
        case .doneStartingLoops: "initializeDone"
        case .done, .abandonedByDrain: "initializeResolved"
        }
        guard await pair.harness.waitForInputs(named: lastStep, count: 1) else { return }
        let begun = await pair.harness.differentialRead().model
        // Every end begins the stop (`admitStop`); after a finished drain its arm 1 joins that
        // drain and is answered in the same step.
        #expect(begun.coreBarrierWaits.stopsAwaitingInitialization.isEmpty, "the stop is still parked: \(begun.coreBarrierWaits)")
        #expect(begun.stopPhase != .notStarted, "the stop wasn't begun: \(begun.stopPhase)")
        guard case .success(.done)? = await resultWithinHangBound(stop) else { Issue.record("the stop wasn't answered after the initialization"); return }
        let after = await pair.harness.differentialRead().model
        let expectedPhase: InitializationPhase = switch end {
        case .done, .doneStartingLoops: .done
        case .failed: .failed
        case .abandonedByDrain: .abandonedByDrain
        }
        #expect(after.initializationPhase == expectedPhase, "\(after.initializationPhase)")
        #expect(after.coreBarrierWaits.isEmpty && after.drainPhase == .finished, "\(after.coreBarrierWaits), \(after.drainPhase)")
    }

    @Test("A failed initialization's drain runs to its end on the core: no destroy handler, the drain finished, and a stop after it answered at once (Review r1 on #969)")
    func failedInitializationDrainFinishes() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false, initializeRefuses: true)
        let pair = await CoreDiffPair.make(shape, "init-fail-drain", initializes: false)
        await pair.harness.drive(.initialize)
        guard await pair.harness.drainFinishes.waitFor("drain finished") else { Issue.record("the failed initialization's drain never finished"); return }
        let model = await pair.harness.differentialRead().model
        #expect(model.drainPhase == .finished && model.destructionFinished, "\(model.drainPhase)")
        // `drainAfterTicks` skips the handlers on a failed initialization (#104): no destroy
        // resolver or AfterFinalize effect came back.
        let seen = await pair.harness.inputsSeen
        #expect(!seen.contains("destroyHandlerResolved") && !seen.contains("afterFinalizeReturned"), "\(seen)")
        #expect(!model.state.log.contains("destroyWhenEmpty") && !model.state.log.contains("finalize"), "a destroy handler ran: \(model.state.log)")
        #expect(await pair.harness.destroyHandlerOutputsDropped() == 0)
        guard case .success(.done)? = await resultWithinHangBound(Task { try await pair.harness.call(.shutdown) }) else {
            Issue.record("the stop after the drain wasn't answered"); return
        }
    }

    @Test("A failed initialization that also failed the land (OnInitialize's validate re-enters, then throws) tears down by the failure: one .failureTeardown, no ordinary drain start, no destroy handler, the same failure on both paths (Review r3 on #969, MF)")
    func failedInitializationThatFailedTheLand() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false, initializeRefuses: true)
        let pair = await CoreDiffPair.make(shape, "init-fail-reentry", initializes: false)
        let source = try #require(pair.source)
        defer { CoreDiffHandlerReentry.clear(pair.landID) }
        // One path at a time: the hook is one-shot and keyed by the land ID both share.
        CoreDiffHandlerReentry.register(pair.landID) { [keeper = pair.keeper] in
            keeper.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: validate's re-entry the sentinel refuses
        }
        guard await valueWithinHangBound(Task { await pair.keeper.awaitInitialization() }) != nil,
              await valueWithinHangBound(Task { await pair.keeper.forceShutdown() }) != nil else {
            Issue.record("the keeper's initialization or stop never returned"); return
        }
        CoreDiffHandlerReentry.register(pair.landID) { [source] in
            source.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: validate's re-entry the sentinel refuses
        }
        await pair.harness.drive(.initialize)
        guard await pair.harness.drainFinishes.waitFor("drain finished") else { Issue.record("the core's drain never finished"); return }
        let flushed = await pair.harness.flushed
        let teardowns = flushed.filter { if case .failureTeardown = $0 { true } else { false } }.count
        let starts = flushed.filter { if case .drainStarting = $0 { true } else { false } }.count
        #expect(teardowns == 1 && starts == 0, "the failed initialization claimed an ordinary drain: teardowns \(teardowns), starts \(starts)")
        let model = await pair.harness.differentialRead().model
        #expect(model.initializationPhase == .failed && model.drainPhase == .finished, "\(model.initializationPhase), \(model.drainPhase)")
        #expect(!model.state.log.contains("destroyWhenEmpty") && !model.state.log.contains("finalize"), "a destroy handler ran: \(model.state.log)")
        let keeperFailure = await pair.keeper.differentialReadForTesting().failure
        let coreFailure = await pair.harness.differentialRead().failure
        #expect(coreFailure?.kind == .keeperReentry && keeperFailure == coreFailure, "keeper \(String(describing: keeperFailure)), core \(String(describing: coreFailure))")
    }

    @Test("T8b on the core: a land with no transport tells its bound requester that it was destroyed, and the requester is cleared after (Review r1 on #969)")
    func boundRequesterHearsTheDestruction() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "t8b")
        let trace = CoreDiffTrace()
        let port = CoreDiffTraceTransport(trace)
        _ = await pair.harness.syncTurnNow(via: port, reason: .syncNow)
        #expect(await pair.harness.hasBoundRequester(), "the sync-only turn bound its port")
        guard case .success(.done)? = await resultWithinHangBound(Task { try await pair.harness.call(.shutdown) }) else {
            Issue.record("the stop wasn't answered"); return
        }
        #expect(trace.all.filter { $0 == "onLandDestroyed" }.count == 1, "\(trace.all)")
        #expect(await !pair.harness.hasBoundRequester(), "cleared at the drain's end")
    }

    @Test("A stale-epoch .tickDue on an open tick land after the initialization's .startLoops is a no-op; the current epoch's runs (Review r1 on #969, m2)")
    func staleTickDueOnAnOpenLand() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: true, joinResolvers: false, leaveResolver: false), "stale-open", initializes: false, autoStartLoops: true)
        await pair.harness.drive(.initialize)
        guard await pair.harness.waitForInputs(named: "initializeDone", count: 1) else { return }
        let current = await pair.harness.differentialRead().model.loopEpoch
        #expect(current > 0, "the initialization's finish bumped the epoch")
        let before = await pair.harness.differentialRead().model.state.log
        await pair.harness.drive(.tickDue(fold: nil, foldStart: nil, syncsInTurn: true, epoch: current &- 1))
        #expect(await pair.harness.differentialRead().model.state.log == before, "a stale tick ran")
        await pair.harness.drive(.tickDue(fold: nil, foldStart: nil, syncsInTurn: true, epoch: current))
        #expect(await pair.harness.differentialRead().model.state.log == before + ["tick"])
    }

    @Test("A second stop joins the first and is answered with it (the keeper's SingleFlight), and a third after the drain finished is answered at once, on the core (K2-2 commit 1b; Review r1 on #969, MF1 (a))")
    func secondStopJoins() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "stop-twice")
        let hold = WatermarkGate()
        defer { hold.release() }
        pair.harness.armedDrainStartGate.arm(hold)
        let first = Task { try await pair.harness.call(.shutdown) }
        guard await hold.waitUntilEntered("the drain's start") else { return }
        let second = Task { try await pair.harness.call(.shutdown) }
        guard await pair.harness.waitForInputs(named: "shutdown", count: 2) else { return }
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.drained.count == 2, "both stops wait for the one drain")
        hold.release()
        // `.drainFinished`'s step answers both: read right after it, so a lost answer fails
        // here, not at the hang bound (mutant m6 at db097c23).
        guard await pair.harness.drainFinishes.waitFor("drain finished") else { Issue.record("the drain never finished"); return }
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.drained.isEmpty, "the drain's end left its callers waiting")
        for (name, stop) in [("first", first), ("second", second)] {
            guard case .success(.done)? = await resultWithinHangBound(stop) else { Issue.record("the \(name) stop wasn't answered .done"); return }
        }
        #expect(await pair.harness.differentialRead().model.drainPhase == .finished)
        // A late stop: the flight has returned, so it is answered at once, not parked. Read
        // right after its step, so a parked stop fails here, not at the hang bound.
        let third = Task { try await pair.harness.call(.shutdown) }
        guard await pair.harness.waitForInputs(named: "shutdown", count: 3) else { return }
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.drained.isEmpty, "the late stop was parked")
        guard case .success(.done)? = await resultWithinHangBound(third) else {
            Issue.record("the stop after the drain wasn't answered"); return
        }
        let after = await pair.harness.differentialRead().model
        #expect(after.coreBarrierWaits.drained.isEmpty && after.stopPhase == .ended, "\(after.coreBarrierWaits), \(after.stopPhase)")
        #expect(await pair.harness.flushed.filter { if case .drainStarting = $0 { true } else { false } }.count == 1, "one drain")
    }

    @Test("The shutdown turn, held before the drain starts: the players cleared, nothing queued, the drain flag set and no destroy handler run, the same on both paths; then both drains end (the keeper's .shutdownTurnApplied, the core's drain-start gate, K2-2 commit 1b)")
    func shutdownTurnHeldBeforeTheDrain() async throws {
        let keeperHold = WatermarkGate(), coreHold = WatermarkGate()
        defer {
            keeperHold.release()
            coreHold.release()
        }
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "stop-turn-held", pathHolds: { path, point in
            if path == "keeper", point == .shutdownTurnApplied { await keeperHold.enterAndWait() }
        })
        _ = await bothJoin(pair, "p1", "c1")
        await pair.expectSame("after the join")

        let keeperStop = Task { await pair.keeper.forceShutdown() }
        guard await keeperHold.waitUntilEntered("the keeper's shutdown turn") else { return }
        // The core's stop runs the shutdown turn and asks the owner for the drain's start in one
        // step: the owner's start, held, is the core's side of the keeper's hold.
        pair.harness.armedDrainStartGate.arm(coreHold)
        let coreStop = Task { try await pair.harness.call(.shutdown) }
        guard await coreHold.waitUntilEntered("the core's drain start") else { return }
        var (keeperHeld, coreHeld) = await pair.digests()
        // The stop's caller waits on the core in `coreBarrierWaits.drained`, answered by
        // `.drainFinished`; the keeper's waits in its SingleFlight, off the model. Checked here,
        // then compared apart.
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.drained.count == 1, "the core's stop caller waits for the drain")
        keeperHeld.otherModelFields["coreBarrierWaits"] = nil
        coreHeld.otherModelFields["coreBarrierWaits"] = nil
        #expect(keeperHeld == coreHeld, "differ in \(keeperHeld.differingFields(from: coreHeld))\n keeper \(keeperHeld)\n core   \(coreHeld)")
        #expect(coreHeld.players.isEmpty && coreHeld.pendingSequences.isEmpty && coreHeld.isDraining, "\(coreHeld)")
        let heldLog = coreHeld.log
        #expect(!(await pair.harness.differentialRead().model.destroyHandlersStarted), "the destroy runs after the turn")

        keeperHold.release()
        coreHold.release()
        guard await valueWithinHangBound(keeperStop) != nil else { Issue.record("the keeper's stop never returned"); return }
        guard case .success(.done)? = await resultWithinHangBound(coreStop) else { Issue.record("the core's stop wasn't answered .done"); return }
        let (keeperDone, coreDone) = await pair.digests()
        #expect(keeperDone.log == coreDone.log, "keeper \(keeperDone.log), core \(coreDone.log)")
        #expect(coreDone.log.count >= heldLog.count, "\(heldLog) → \(coreDone.log)")
        #expect(await pair.harness.differentialRead().model.drainPhase == .finished)
        #expect(await pair.harness.differentialRead().model.destructionFinished)
    }

    @Test("#512 as today (P11-1): on a tick land, a leave queued while the stop waits for the tick held at its record is dropped by the shutdown turn: no OnLeave, its caller returns, and the shutdown frame holds only \"shutdown\", on both paths (#512's fix flips this)")
    func shutdownDropsQueuedLeave512() async throws {
        let keeperRecord = CoreDiffArmedGate()
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: true, joinResolvers: false, leaveResolver: false), "stop-512", keeperRecordGate: keeperRecord, records: true)
        let source = try #require(pair.source)
        _ = await bothJoin(pair, "p1", "c1")
        _ = await bothJoin(pair, "p2", "c2")
        await pair.expectSame("after the joins")
        let keeperHold = WatermarkGate(), coreHold = WatermarkGate()
        defer {
            keeperHold.release()
            coreHold.release()
        }

        // The keeper: a tick held at its record, the stop at its gate, then the leave, appended.
        keeperRecord.arm(keeperHold)
        let keeperTick = Task { await pair.keeper.stepTickOnce() }
        guard await keeperHold.waitUntilEntered("the keeper's tick record") else { return }
        let (keeperGate, keeperProbe) = probeEvents("shutdown-stop-gate")
        await pair.keeper.setInTurnProbeForTesting(keeperProbe)
        let keeperStop = Task { await pair.keeper.forceShutdown() }
        guard await firstWithinHangBound(keeperGate) else { Issue.record("the keeper's stop never reached its gate"); return }
        await pair.keeper.setInTurnProbeForTesting(nil)
        // The leave's append is the segment that resumes after its `.leave` hold; the resumed
        // hook's task runs once that segment ends, at the leave's wait for its turn.
        let appended = EventLog()
        await pair.keeper.installResumedHoldsForTesting { point, actor in
            guard point == .leave else { return }
            Task {
                actor?.assertIsolated("the event's task runs on the keeper")
                appended.append("leave appended")
            }
        }
        let keeperLeaveTask = Task { await keeperLeave(pair, "p1", "c1") }
        guard await appended.waitFor("leave appended") else { Issue.record("the keeper's leave never appended"); return }
        await pair.keeper.installResumedHoldsForTesting(nil)
        #expect(await pair.keeper.pendingItemSequencesForTesting().count == 1, "the leave is queued behind the stop")

        // The core: the same, the leave stepped while its stop waits for the held tick.
        pair.harness.armedRecordGate.arm(coreHold)
        await pair.harness.drive(.tickDue(fold: nil, foldStart: nil, syncsInTurn: true))
        guard await coreHold.waitUntilEntered("the core's tick record") else { return }
        let coreStop = Task { try await pair.harness.call(.shutdown) }
        guard await pair.harness.waitForInputs(named: "shutdown", count: 1) else { return }
        let coreLeaveTask = Task { await coreLeave(pair, "p1", "c1") }
        guard await pair.harness.waitForInputs(named: "leave", count: 1) else { return }
        #expect(await pair.harness.differentialRead().model.pendingItems.count == 1, "the leave is queued behind the stop")

        keeperHold.release()
        coreHold.release()
        // The tick's end moves the stop on in its own step: read right after it, so a stop left
        // waiting fails here, not at the hang bound (mutant m5 at db097c23).
        guard await pair.harness.waitForInputs(named: "tickRecordTaken", count: 1) else { return }
        #expect(await pair.harness.differentialRead().model.stopPhase != .waitingForTick, "the tick's end didn't move the stop on")
        guard let keeperLeft = await valueWithinHangBound(keeperLeaveTask), let coreLeft = await valueWithinHangBound(coreLeaveTask) else {
            Issue.record("a leave never returned"); return
        }
        #expect(keeperLeft == "done" && coreLeft == "done", "keeper \(keeperLeft), core \(coreLeft)")
        guard await valueWithinHangBound(keeperStop) != nil, await valueWithinHangBound(keeperTick) != nil else { Issue.record("the keeper's stop or tick never ended"); return }
        guard case .success(.done)? = await resultWithinHangBound(coreStop) else { Issue.record("the core's stop wasn't answered .done"); return }

        let (keeperDone, coreDone) = await pair.digests()
        #expect(keeperDone.log == coreDone.log, "keeper \(keeperDone.log), core \(coreDone.log)")
        #expect(!coreDone.log.contains { $0.hasPrefix("leave:") }, "#512 as today: no OnLeave for the dropped leave: \(coreDone.log)")
        func lastLifecycle(_ keeper: LandKeeper<CoreDiffState>) async throws -> [String] {
            let recorder = try #require(await keeper.getReevaluationRecorder())
            return await recorder.getAllFrames().last?.lifecycleEvents.map(\.kind) ?? []
        }
        let (keeperLast, coreLast) = (try await lastLifecycle(pair.keeper), try await lastLifecycle(source))
        #expect(keeperLast == ["shutdown"] && coreLast == ["shutdown"], "the shutdown frame: keeper \(keeperLast), core \(coreLast)")
    }

    @Test("A tickless batch's record in flight when the stop arrives (plan §13.2.1): the batch counts in no tick, so nothing waits for it; once the record is taken its caller gets its result, then the shutdown turn and the drain run, the same on both paths")
    func ticklessRecordInFlightAtDrainStart() async throws {
        let keeperRecord = CoreDiffArmedGate()
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "stop-record-tickless", keeperRecordGate: keeperRecord, records: true)
        let keeperHold = WatermarkGate(), coreHold = WatermarkGate()
        defer {
            keeperHold.release()
            coreHold.release()
        }
        // A join's batch, held at its record on each path.
        keeperRecord.arm(keeperHold)
        pair.harness.armedRecordGate.arm(coreHold)
        let keeperJoined = Task { await keeperJoin(pair, "p1", "c1") }
        guard await keeperHold.waitUntilEntered("the keeper's batch record") else { return }
        let coreJoined = Task { await coreJoin(pair, "p1", "c1") }
        guard await coreHold.waitUntilEntered("the core's batch record") else { return }
        #expect(await pair.keeper.differentialReadForTesting().model.ticksInFlight == 0, "a tickless batch counts in no tick")
        #expect(await pair.harness.differentialRead().model.ticksInFlight == 0, "a tickless batch counts in no tick")

        // The stop, queued behind the held batch on each path.
        let (queued, probe) = probeEvents("shutdown-queued")
        await pair.keeper.setInTurnProbeForTesting(probe)
        let keeperStop = Task { await pair.keeper.forceShutdown() }
        guard await firstWithinHangBound(queued) else { Issue.record("the keeper's stop never queued"); return }
        await pair.keeper.setInTurnProbeForTesting(nil)
        let coreStop = Task { try await pair.harness.call(.shutdown) }
        guard await pair.harness.waitForInputs(named: "shutdown", count: 1) else { return }
        #expect(await pair.harness.differentialRead().model.drainPhase == .notStarted, "the core's drain waits for the shutdown turn")

        keeperHold.release()
        coreHold.release()
        guard let keeperJoin = await valueWithinHangBound(keeperJoined), let coreJoin = await valueWithinHangBound(coreJoined) else {
            Issue.record("a join never returned"); return
        }
        #expect(keeperJoin == coreJoin, "keeper \(keeperJoin), core \(coreJoin)")
        guard case .joined(allowed: true, _) = coreJoin else { Issue.record("the held batch's caller: \(coreJoin)"); return }
        // The shutdown turn sets the drain flag before any drain runs; the stop must still ask
        // for one. Read right after the turn's record (the second `.recordTaken`), so a stop that took the flag for a drain
        // fails here, not at the hang bound (mutant m7 at db097c23).
        guard await pair.harness.waitForInputs(named: "recordTaken", count: 2) else { return }
        #expect(await pair.harness.differentialRead().model.drainRequested, "the shutdown turn's flag was taken for a drain in progress")
        guard await valueWithinHangBound(keeperStop) != nil else { Issue.record("the keeper's stop never returned"); return }
        guard case .success(.done)? = await resultWithinHangBound(coreStop) else { Issue.record("the core's stop wasn't answered .done"); return }
        #expect(await pair.harness.differentialRead().model.drainPhase == .finished)
        #expect(await pair.keeper.differentialReadForTesting().model.destructionFinished)
        await pair.expectSame("after the stop")
    }

    @Test("A shutdown while frozen (P11-2): the freeze ends first, so the held action re-enters behind the shutdown item and gets .landClosed, and the held server input is never applied, the same on both paths")
    func shutdownWhileFrozenDropsHeldIntakes() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false)
        let landID = "core-diff:stop-frozen:\(UUID().uuidString)"
        func keeper() -> LandKeeper<CoreDiffState> {
            LandKeeper<CoreDiffState>(definition: coreDiffDefinition(shape), initialState: CoreDiffState(), autoStartLoops: false, landID: landID)
        }
        let direct = keeper(), source = keeper()
        // Joined, frozen, and a server input held by the freeze, on both keepers before the twin
        // copies the source (the core has no server-input entry of its own yet).
        for k in [direct, source] {
            await k.awaitInitialization()
            _ = try await k.joinReportingAdmission(session: session("p1"), clientID: ClientID("c1"), sessionID: SessionID("c1"), services: LandServices(), admitThroughTransport: false)
            // The join's work ends when its turn answers it; its drain ends after, and the twin
            // copies only an idle keeper.
            await k.waitForInFlightWorkForTesting()
            await k.waitForInputDrainIdleForTesting()
            #expect(await k.debugFreeze(generation: 1, timeout: .seconds(5)))
            guard case .accepted = await k.submitServerInput(CoreDiffServerInput(n: 9)) else { Issue.record("not accepted"); return }
        }
        let harness = KeeperCoreHarness(await source.coreTwinForTesting(), clock: CoreDiffClock())
        await harness.start()
        let pair = CoreDiffPair(keeper: direct, harness: harness, landID: landID, source: source)
        // The held item is each keeper's own value, so the two are compared by count here.
        #expect(await direct.differentialReadForTesting().model.serverInputsHeldWhileFrozen.count == 1)
        #expect(await harness.differentialRead().model.serverInputsHeldWhileFrozen.count == 1)

        // An action held at the freeze, on each path.
        let (keeperHeld, keeperProbe) = probeEvents("input-held-frozen")
        await direct.setInTurnProbeForTesting(keeperProbe)
        let keeperAct = Task { await keeperAction(pair, CoreDiffAction(n: 2, fails: false), "p1", "c1") }
        guard await firstWithinHangBound(keeperHeld) else { Issue.record("the keeper's action was never held"); return }
        await direct.setInTurnProbeForTesting(nil)
        let (coreHeld, coreProbe) = probeEvents("input-held-frozen")
        await harness.setProbe(coreProbe)
        let coreAct = Task { await coreTicklessAction(pair, CoreDiffAction(n: 2, fails: false), "p1", "c1") }
        guard await firstWithinHangBound(coreHeld) else { Issue.record("the core's action was never held"); return }
        await harness.setProbe(nil)

        await direct.forceShutdown()
        guard case .success(.done)? = await resultWithinHangBound(Task { try await harness.call(.shutdown) }) else {
            Issue.record("the core's stop wasn't answered .done"); return
        }
        guard let keeperResult = await valueWithinHangBound(keeperAct), let coreResult = await valueWithinHangBound(coreAct) else {
            Issue.record("a held action never returned"); return
        }
        #expect(keeperResult == coreResult, "keeper \(keeperResult), core \(coreResult)")
        // The result keeps the error's type only: the keeper's `.landClosed`, the same on both.
        #expect(coreResult == .failed(nil, "LandInputRejection"), "the held action re-enters behind the shutdown: \(coreResult)")
        let core = await harness.differentialRead().model
        #expect(!core.state.log.contains("input:9") && !core.state.log.contains("action:2"), "\(core.state.log)")
        #expect(core.serverInputsHeldWhileFrozen.isEmpty && !core.debugFrozen && core.debugInFlightWork == 0)
        #expect(core.drainPhase == .finished)
        await pair.expectSame("after the stop")
    }

    @Test("A tick land's freeze steps on the core since the tick-record hold (K2-2 commit 1b): an idle land freezes at once")
    func tickLandFreezeSteps() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: true, joinResolvers: false, leaveResolver: false), "freeze-tick")
        guard case let .success(answer)? = await resultWithinHangBound(Task { try await pair.harness.call(.freeze(generation: 1, timeout: .seconds(5))) }) else {
            Issue.record("the freeze wasn't answered"); return
        }
        #expect("\(answer)".contains("true"), "\(answer)")
        #expect(await pair.harness.differentialRead().model.debugFrozen == true)
    }

    @Test("A tick land's freeze waits for the tick held at its record, and is answered true once the record is taken, on both paths (the tick-record hold, plan §13.1)")
    func tickLandFreezeWaitsForTheRecord() async throws {
        let keeperGate = CoreDiffArmedGate()
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: true, joinResolvers: false, leaveResolver: false), "freeze-record",
                                           keeperRecordGate: keeperGate, records: true)
        let keeperHold = WatermarkGate(), coreHold = WatermarkGate()
        keeperGate.arm(keeperHold)
        pair.harness.armedRecordGate.arm(coreHold)
        let keeperTick = Task { await pair.keeper.stepTickOnce() }
        guard await keeperHold.waitUntilEntered() else { Issue.record("the keeper's tick never reached its record"); return }
        await pair.harness.drive(.tickDue(fold: nil, foldStart: nil, syncsInTurn: true))
        guard await coreHold.waitUntilEntered() else { Issue.record("the core's tick never reached its record"); return }
        // Both ticks are in flight, held at the record: each path counts the work.
        #expect(await pair.keeper.differentialReadForTesting().model.ticksInFlight == 1)
        #expect(await pair.harness.differentialRead().model.ticksInFlight == 1)
        let keeperFreeze = Task { await pair.keeper.debugFreeze(generation: 1, timeout: .seconds(30)) }
        let coreFreeze = Task { try await pair.harness.call(.freeze(generation: 1, timeout: .seconds(30))) }
        // Not answered before the release, by events, not a read race: the keeper's caller
        // registered as waiting for the work, and the core's `.freeze` stepped and left its
        // caller parked behind the held tick.
        #expect(await pair.keeper.waitUntilFreezeWaitsForTesting(), "the keeper's freeze answered without waiting for the held tick")
        guard await pair.harness.waitForInputs(named: "freeze", count: 1) else { return }
        let parked = await pair.harness.differentialRead().model.coreBarrierWaits.freeze[1]?.count
        #expect(parked == 1, "the core's freeze answered without waiting for the held tick: \(String(describing: parked))")
        keeperHold.release()
        coreHold.release()
        #expect(await valueWithinHangBound(keeperFreeze) == true)
        guard case .success(.frozen(true))? = await resultWithinHangBound(coreFreeze) else { Issue.record("the core's freeze wasn't answered true"); return }
        guard await valueWithinHangBound(keeperTick) != nil else { Issue.record("the keeper's tick never ended"); return }
        await pair.expectSame("after the record")
    }

    @Test("The resume's kick counts as work: a freeze right after a resume that released a held server input waits for that input's turn, on both paths (Review on #948, MF2)")
    func freezeAfterResumeWaitsForTheKick() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false)
        let landID = "core-diff:resume-kick:\(UUID().uuidString)"
        func keeper() -> LandKeeper<CoreDiffState> {
            LandKeeper<CoreDiffState>(definition: coreDiffDefinition(shape), initialState: CoreDiffState(), autoStartLoops: false, landID: landID)
        }
        let direct = keeper(), source = keeper()
        let keeperGate = CoreDiffArmedGate()
        await direct.installHolds { point in
            if point == .turnRecord, let gate = keeperGate.take() { await gate.enterAndWait() }
        }
        for k in [direct, source] {
            await k.awaitInitialization()
            #expect(await k.debugFreeze(generation: 1, timeout: .seconds(5)))
            guard case .accepted = await k.submitServerInput(CoreDiffServerInput(n: 9)) else { Issue.record("not accepted"); return }
        }
        let harness = KeeperCoreHarness(await source.coreTwinForTesting(), clock: CoreDiffClock())
        await harness.start()
        let pair = CoreDiffPair(keeper: direct, harness: harness, landID: landID, source: source)

        let kg = WatermarkGate()
        defer { kg.release() }
        keeperGate.arm(kg)
        await direct.debugResume(generation: 1)
        guard await kg.waitUntilEntered("the kicked input's record") else { return }
        let keeperFreeze = Task { await direct.debugFreeze(generation: 2, timeout: .seconds(3600)) }
        #expect(await direct.waitUntilFreezeWaitsForTesting(), "a freeze caller registered")
        kg.release()
        let keeperFroze = await keeperFreeze.value

        let cg = WatermarkGate()
        defer { cg.release() }
        harness.armedRecordGate.arm(cg)
        await harness.drive(.resume(generation: 1))
        guard await cg.waitUntilEntered("the core's kicked record") else { return }
        let coreFreezeTask = Task { await coreFreeze(pair, 2, .seconds(3600)) }
        guard await harness.waitForInputs(named: "freeze", count: 1) else { return }
        #expect(await harness.differentialRead().model.coreBarrierWaits.freeze[2]?.count == 1, "the freeze waits for the kick's work")
        cg.release()
        let coreFroze = await coreFreezeTask.value

        #expect(keeperFroze && coreFroze == true, "keeper \(keeperFroze), core \(String(describing: coreFroze))")
        await direct.debugResume(generation: 2)
        await harness.drive(.resume(generation: 2))
        await pair.expectSame("after the kick")
        #expect(await harness.differentialRead().model.state.log.contains("input:9"))
    }

    @Test("The intake is its own barrier: while frozen a tickless action is held in its step, a second freeze answers true with nothing applied, and the resume runs it, on both paths (Review on #948, MF3)")
    func intakeHeldAtTheBarrier() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "barrier")
        _ = await bothJoin(pair, "p1", "c1")
        #expect(await pair.keeper.debugFreeze(generation: 1, timeout: .seconds(5)))
        #expect(await coreFreeze(pair, 1, .seconds(5)) == true)

        let (keeperHeld, keeperProbe) = probeEvents("input-held-frozen")
        await pair.keeper.setInTurnProbeForTesting(keeperProbe)
        let keeperAct = Task { await keeperAction(pair, CoreDiffAction(n: 2, fails: false), "p1", "c1") }
        var keeperHolds = keeperHeld.makeAsyncIterator()
        _ = await keeperHolds.next()
        let coreAct = Task { await coreTicklessAction(pair, CoreDiffAction(n: 2, fails: false), "p1", "c1") }
        guard await pair.harness.waitForInputs(named: "action", count: 1) else { return }

        // A freeze between the barrier and the intake finds no work and nothing applied.
        let keeperAgain = await pair.keeper.debugFreeze(generation: 1, timeout: .seconds(5))
        let coreAgain = await coreFreeze(pair, 1, .seconds(5))
        #expect(keeperAgain && coreAgain == true, "keeper \(keeperAgain), core \(String(describing: coreAgain))")
        let (keeperLog, coreLog) = (await pair.digests().keeper.log, await pair.digests().core.log)
        #expect(!keeperLog.contains("action:2") && !coreLog.contains("action:2"), "keeper \(keeperLog), core \(coreLog)")

        await pair.keeper.debugResume(generation: 1)
        await pair.harness.drive(.resume(generation: 1))
        let (keeperResult, coreResult) = (await keeperAct.value, await coreAct.value)
        #expect(keeperResult == .completed(2) && coreResult == .completed(2), "keeper \(keeperResult), core \(coreResult)")
        await pair.expectSame("after the held action")
    }

    @Test("Two held intakes, an action and a client event, are released by the resume on both paths; the core runs both in arrival order in the resume's step, while the keeper's order is the scheduler's (each resumed caller re-enters on its own), so only the core's order is asserted (Review r2 on #948, a stated choice; r3)")
    func twoHeldIntakesReleasedInOrder() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "barrier-two")
        _ = await bothJoin(pair, "p1", "c1")
        #expect(await pair.keeper.debugFreeze(generation: 1, timeout: .seconds(5)))
        #expect(await coreFreeze(pair, 1, .seconds(5)) == true)

        let (keeperHeld, keeperProbe) = probeEvents("input-held-frozen")
        await pair.keeper.setInTurnProbeForTesting(keeperProbe)
        var keeperHolds = keeperHeld.makeAsyncIterator()
        let keeperAct = Task { await keeperAction(pair, CoreDiffAction(n: 2, fails: false), "p1", "c1") }
        _ = await keeperHolds.next()
        let keeperEv = Task { await keeperEvent(pair, CoreDiffEvent(n: 9, fails: false), "p1", "c1") }
        _ = await keeperHolds.next()
        await pair.keeper.setInTurnProbeForTesting(nil)
        await pair.keeper.debugResume(generation: 1)
        let keeperResults = (await keeperAct.value, await keeperEv.value)

        let (coreHeld, coreProbe) = probeEvents("input-held-frozen")
        await pair.harness.setProbe(coreProbe)
        var coreHolds = coreHeld.makeAsyncIterator()
        let coreAct = Task { await coreTicklessAction(pair, CoreDiffAction(n: 2, fails: false), "p1", "c1") }
        _ = await coreHolds.next()
        let coreEv = Task { await coreEvent(pair, CoreDiffEvent(n: 9, fails: false), "p1", "c1") }
        _ = await coreHolds.next()
        await pair.harness.setProbe(nil)
        await pair.harness.drive(.resume(generation: 1))
        let coreResults = (await coreAct.value, await coreEv.value)

        #expect(keeperResults.0 == .completed(2) && coreResults.0 == .completed(2), "keeper \(keeperResults.0), core \(coreResults.0)")
        #expect(keeperResults.1 == "done" && coreResults.1 == "done", "keeper \(keeperResults.1), core \(coreResults.1)")
        let (keeperLog, coreLog) = (await pair.digests().keeper.log, await pair.digests().core.log)
        let applied = coreLog.filter { $0 == "action:2" || $0 == "event:9" }
        #expect(applied == ["action:2", "event:9"], "the core's arrival order: \(applied)")
        // The keeper's two re-entries are enqueued in either order: compare as multisets.
        #expect(keeperLog.sorted() == coreLog.sorted(), "keeper \(keeperLog), core \(coreLog)")
        await pair.expectSame("after two held intakes", logOrderFree: true)
    }

    @Test("A held intake goes on when the land fails while frozen, and gets the same answer on both paths: no caller waits for a resume that never comes (Review on #948, MF3)")
    func heldIntakeReleasedOnFailure() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "barrier-fail")
        let source = try #require(pair.source)
        _ = await bothJoin(pair, "p1", "c1")
        #expect(await pair.keeper.debugFreeze(generation: 1, timeout: .seconds(5)))
        #expect(await coreFreeze(pair, 1, .seconds(5)) == true)
        defer { CoreDiffHandlerReentry.clear(pair.landID) }

        let (keeperHeld, keeperProbe) = probeEvents("input-held-frozen")
        await pair.keeper.setInTurnProbeForTesting(keeperProbe)
        let keeperAct = Task { await keeperAction(pair, CoreDiffAction(n: 2, fails: false), "p1", "c1") }
        var keeperHolds = keeperHeld.makeAsyncIterator()
        _ = await keeperHolds.next()
        // A join isn't held: its OnJoin re-enters, and the land fails in that step.
        CoreDiffHandlerReentry.register(pair.landID) { [keeper = pair.keeper] in
            keeper.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: the handler's re-entry the sentinel refuses
        }
        _ = await keeperJoin(pair, "p2", "c2")
        let keeperResult = await keeperAct.value

        let coreAct = Task { await coreTicklessAction(pair, CoreDiffAction(n: 2, fails: false), "p1", "c1") }
        guard await pair.harness.waitForInputs(named: "action", count: 1) else { return }
        CoreDiffHandlerReentry.register(pair.landID) { [source] in
            source.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: the handler's re-entry the sentinel refuses
        }
        _ = await coreJoin(pair, "p2", "c2")
        let coreResult = await coreAct.value

        #expect(keeperResult == coreResult, "keeper \(keeperResult), core \(coreResult)")
        #expect(await pair.harness.differentialRead().failure != nil, "the core's land failed")
        let (keeperLog, coreLog) = (await pair.digests().keeper.log, await pair.digests().core.log)
        #expect(keeperLog == coreLog, "keeper \(keeperLog), core \(coreLog)")
    }

    @Test("A sync stream's drafts: an output and a marker, in turn and outside, record the same frames on both paths (Review on #948, MF6)", arguments: [false, true])
    func syncStreamDraft(outsideTurn: Bool) async throws {
        let pair = try await TracePair.make("sync-draft")
        await pair.keeper.submitSyncStream([outputDraft(1), markerDraft()], outsideTurn: outsideTurn)
        await pair.harness.drive(.syncStreamDraft([outputDraft(1), markerDraft()], outsideTurn: outsideTurn))
        await pair.keeper.waitForRecorderSubmissionsForTesting()
        await pair.harness.waitForSubmissions()
        try await pair.expectSameTrace("after the drafts")
        let (keeperFrames, coreFrames) = try await pair.frames()
        #expect(keeperFrames == coreFrames)
    }

    @Test("A re-entering draft factory ends the land in the body on both paths: one violation, no late backstop (Review on #948, MF4)")
    func syncStreamDraftFactoryReentry() async throws {
        let pair = try await TracePair.make("sync-draft-reentry")
        let keeperBefore = (await pair.keeper.reentryViolationsForTesting, await pair.keeper.lateReentriesAppliedForTesting)
        let coreBefore = (await pair.source.reentryViolationsForTesting, await pair.source.lateReentriesAppliedForTesting)
        await pair.keeper.submitSyncStream([outputDraft(7, reentering: pair.keeper)])
        await pair.harness.drive(.syncStreamDraft([outputDraft(7, reentering: pair.source)], outsideTurn: false))
        let keeperDelta = (await pair.keeper.reentryViolationsForTesting - keeperBefore.0, await pair.keeper.lateReentriesAppliedForTesting - keeperBefore.1)
        let coreDelta = (await pair.source.reentryViolationsForTesting - coreBefore.0, await pair.source.lateReentriesAppliedForTesting - coreBefore.1)
        #expect(keeperDelta == (1, 0) && coreDelta == (1, 0), "keeper \(keeperDelta), core \(coreDelta)")
        let keeperFailure = await pair.keeper.differentialReadForTesting().failure
        let coreFailure = await pair.harness.differentialRead().failure
        #expect(coreFailure != nil && keeperFailure == coreFailure, "keeper \(String(describing: keeperFailure)), core \(String(describing: coreFailure))")
        await pair.harness.waitForSubmissions()
        try await pair.expectSameTrace("after the re-entry", failed: true)
    }

    @Test("A cancelled caller's job is never started: the cancellation rides the input, read in the caller's task, not the core's (Review on #948, MF5)", arguments: [false, true])
    func cancelledCallerJobNotStarted(tick: Bool) async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: tick, joinResolvers: false, leaveResolver: false), "job-cancelled-caller")
        _ = await bothJoin(pair, "p1", "c1")
        let action = CoreDiffJobAction(n: 6, fails: false)
        let keeperResult = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return describeJob(await Result { try await pair.keeper.submitAction(jobEnvelope(action), playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("c1")) }.map { _ in InputOutcome.none })
        }.value
        let coreSubmission: Result<ActionSubmission, any Error>
        if tick {
            guard case let .actionSubmission(result) = await pair.harness.ask(.admitAction(jobEnvelope(action), caller("p1", "c1"), enforcingLimits: true, cancelled: true)) else {
                Issue.record("not an action answer"); return
            }
            coreSubmission = result
        } else {
            guard case let .action(result) = try await pair.harness.call(.action(jobEnvelope(action), caller("p1", "c1"), cancelled: true)) else {
                Issue.record("not an action reply"); return
            }
            coreSubmission = result
        }
        let coreResult = describeJob(coreSubmission.map { _ in InputOutcome.none })
        #expect(keeperResult == "cancelled" && coreResult == "cancelled", "keeper \(keeperResult), core \(coreResult)")
        let seen = await pair.harness.inputsSeen
        #expect(!seen.contains("actionResolved"), "no job ran: \(seen)")
        await pair.expectSame("after the cancelled caller")
    }

    /// The other order, a caller cancelled after the resume released its intake and its job
    /// started, is `actionJobCallerCancel`'s: that cancel rides the job's box.
    @Test("A caller held at the freeze's barrier and cancelled before the resume gets CancellationError and starts no job, on both paths, with the resume sent right after cancel() returns (Review r3 on #948, MF1)")
    func parkedCallerCancelledBeforeResume() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "parked-cancelled")
        _ = await bothJoin(pair, "p1", "c1")
        let action = CoreDiffJobAction(n: 8, fails: false)
        #expect(await pair.keeper.debugFreeze(generation: 1, timeout: .seconds(5)))
        #expect(await coreFreeze(pair, 1, .seconds(5)) == true)

        // The keeper: held in `debugWaitWhileFrozen`. `cancel()` sets the task's flag
        // synchronously, and the resume's re-check reads it.
        let (keeperHeld, keeperProbe) = probeEvents("input-held-frozen")
        await pair.keeper.setInTurnProbeForTesting(keeperProbe)
        let keeperAct = Task {
            describeJob(await Result { try await pair.keeper.submitAction(jobEnvelope(action), playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("c1")) }.map { _ in InputOutcome.none })
        }
        var keeperHolds = keeperHeld.makeAsyncIterator()
        _ = await keeperHolds.next()
        await pair.keeper.setInTurnProbeForTesting(nil)
        keeperAct.cancel()
        await pair.keeper.debugResume(generation: 1)
        let keeperResult = await keeperAct.value

        // The core: held at the barrier in its step. The caller's `onCancel` sets the flag the
        // input carries, synchronously, inside `cancel()`, so a `.resume` sent right after it,
        // with no await between, finds it set: no hop can lose to the thaw.
        let flag = ActionJobCallerCancellation()
        let (coreHeld, coreProbe) = probeEvents("input-held-frozen")
        await pair.harness.setProbe(coreProbe)
        let coreAct = Task { () -> String in
            do {
                let reply = try await withTaskCancellationHandler {
                    try await pair.harness.call(.action(jobEnvelope(action), caller("p1", "c1"), cancellation: flag))
                } onCancel: {
                    flag.set()
                }
                guard case let .action(result) = reply else { return "not an action reply" }
                return describeJob(result.map { _ in InputOutcome.none })
            } catch {
                return "core: \(error)"
            }
        }
        var coreHolds = coreHeld.makeAsyncIterator()
        _ = await coreHolds.next()
        await pair.harness.setProbe(nil)
        coreAct.cancel()
        await pair.harness.drive(.resume(generation: 1))
        let coreResult = await coreAct.value

        #expect(keeperResult == "cancelled" && coreResult == "cancelled", "keeper \(keeperResult), core \(coreResult)")
        let seen = await pair.harness.inputsSeen
        #expect(!seen.contains("actionResolved"), "no job ran on the core: \(seen)")
        #expect(await pair.harness.differentialRead().model.actionJobs.isEmpty, "no job on the core")
        await pair.expectSame("after the cancelled held caller")
    }

    /// The resume-first order, forced (Review on #966, MF1): the resume releases the held
    /// intake, its job starts and is held at its resolver's gate, the caller is cancelled there,
    /// then the gate opens. The cancel-first order is `parkedCallerCancelledBeforeResume`.
    @Test("A held caller resumed first, then cancelled while its job is held at the resolver, is answered .pending with its job run, on both paths, compared once the core's input drain ended (Review on #966, MF1)")
    func parkedCallerResumedThenCancelled() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "parked-resumed-cancelled")
        _ = await bothJoin(pair, "p1", "c1")
        let action = CoreDiffJobAction(n: 8, fails: false)
        defer { CoreDiffJobGates.set(pair.landID, nil) }
        #expect(await pair.keeper.debugFreeze(generation: 1, timeout: .seconds(5)))
        #expect(await coreFreeze(pair, 1, .seconds(5)) == true)

        // The keeper.
        let keeperGate = WatermarkGate()
        defer { keeperGate.release() }
        CoreDiffJobGates.set(pair.landID, keeperGate)
        let (keeperHeld, keeperProbe) = probeEvents("input-held-frozen")
        await pair.keeper.setInTurnProbeForTesting(keeperProbe)
        let keeperAct = Task {
            describeSubmission(await Result { try await pair.keeper.submitAction(jobEnvelope(action), playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("c1")) })
        }
        guard await firstWithinHangBound(keeperHeld) else { Issue.record("the keeper never held the intake"); return }
        await pair.keeper.setInTurnProbeForTesting(nil)
        await pair.keeper.debugResume(generation: 1)
        guard await keeperGate.waitUntilEntered("the keeper's resolver") else { return }
        keeperAct.cancel()
        keeperGate.release()
        guard let keeperResult = await valueWithinHangBound(keeperAct) else { Issue.record("the keeper's cancelled caller never ended"); return }
        await pair.keeper.waitForActionJobsForTesting()

        // The core.
        let coreGate = WatermarkGate()
        defer { coreGate.release() }
        CoreDiffJobGates.set(pair.landID, coreGate)
        let flag = ActionJobCallerCancellation()
        let (coreHeld, coreProbe) = probeEvents("input-held-frozen")
        await pair.harness.setProbe(coreProbe)
        let coreAct = Task { () -> String in
            do {
                let reply = try await withTaskCancellationHandler {
                    try await pair.harness.call(.action(jobEnvelope(action), caller("p1", "c1"), cancellation: flag))
                } onCancel: {
                    flag.set()
                }
                guard case let .action(result) = reply else { return "not an action reply" }
                return describeSubmission(result)
            } catch {
                return "core: \(error)"
            }
        }
        guard await firstWithinHangBound(coreHeld) else { Issue.record("the core never held the intake"); return }
        await pair.harness.setProbe(nil)
        await pair.harness.drive(.resume(generation: 1))
        guard await coreGate.waitUntilEntered("the core's resolver") else { return }
        // From here the only input drain is the job's delivery: wait for its end, so the core
        // is compared after `.recordTaken`, not mid-job.
        let ends = await pair.harness.drainEnds().stream
        coreAct.cancel()
        coreGate.release()
        guard let coreResult = await valueWithinHangBound(coreAct) else { Issue.record("the core's cancelled caller never ended"); return }
        guard await firstWithinHangBound(ends) else { Issue.record("the core's input drain never ended"); return }
        await pair.harness.setProbe(nil)

        #expect(keeperResult.hasPrefix("pending ") && coreResult == keeperResult, "keeper \(keeperResult), core \(coreResult)")
        #expect(await pair.harness.inputsSeen.contains("actionResolved"), "the job ran on the core")
        #expect(await pair.harness.differentialRead().coreWaitsLeft == 0, "nothing left waiting on the core")
        await pair.expectSame("after the resumed, then cancelled, caller")
    }

    /// The settle's cases (#948 round 2, MF1): the body checks the land, the deadline and the
    /// generation before it asks the port's witness, through `callOut`, on both paths.
    enum SettleCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// The fence's generation isn't the frozen one: `.released`, and the witness isn't asked.
        case released
        /// The fence's deadline has passed: `.timedOut`, and the witness isn't asked.
        case timedOut
        /// The fence holds: the witness, then the settle phase.
        case settled
        /// The witness re-enters the keeper: the land ends in the settle's step.
        case settleCheck
        var testDescription: String { rawValue }
    }

    @Test("The settle asks the port's witness after its fence, through callOut, on both paths; a re-entry from it ends the land in the settle (Review r2 on #948, MF1)", arguments: SettleCase.allCases)
    func settleWitnessAfterTheFence(_ settleCase: SettleCase) async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "settle-\(settleCase.rawValue)")
        let source = try #require(pair.source)
        _ = await bothJoin(pair, "p1", "c1")
        #expect(await pair.keeper.debugFreeze(generation: 1, timeout: .seconds(5)))
        #expect(await coreFreeze(pair, 1, .seconds(5)) == true)
        let generation: UInt64 = settleCase == .released ? 2 : 1
        let deadline = settleCase == .timedOut ? ContinuousClock.now - .seconds(1) : ContinuousClock.now + .seconds(3600)
        let keeperTrace = CoreDiffTrace(), coreTrace = CoreDiffTrace()
        let keeperPort = CoreDiffTraceTransport(keeperTrace), corePort = CoreDiffTraceTransport(coreTrace)
        if settleCase == .settleCheck {
            keeperPort.armWitnessReentry(pair.keeper)
            corePort.armWitnessReentry(source)
        }
        func describe(_ outcome: LandKeeper<CoreDiffState>.SettleTurnOutcome) -> String {
            switch outcome {
            case .settled(_, _, _, let planned): "settled planned=\(planned)"
            case .timedOut: "timedOut"
            case .released: "released"
            case .closed(let failure): "closed \(failure.map { "\($0.kind)" } ?? "-")"
            case .refused(let refusal): "refused \(refusal)"
            case .failed(let failure): "failed \(failure.kind)"
            }
        }
        let keeperOutcome = describe(await pair.keeper.settleTurn(via: keeperPort, fence: .init(generation: generation, deadline: deadline)))
        guard case let .settle(coreAnswer) = await pair.harness.ask(.settle(port: corePort, owner: pair.harness.owner, generation: generation, deadline: deadline)) else {
            Issue.record("not a settle answer"); return
        }
        let coreOutcome = describe(coreAnswer)
        #expect(keeperOutcome == coreOutcome, "keeper \(keeperOutcome), core \(coreOutcome)")
        let expectedOutcome: String = switch settleCase {
        case .released: "released"
        case .timedOut: "timedOut"
        // The test port's settle plans nothing (`.empty`).
        case .settled: "settled planned=false"
        case .settleCheck: "failed keeperReentry"
        }
        #expect(keeperOutcome == expectedOutcome, "keeper \(keeperOutcome)")
        // The fence's refusals ask no witness; a held fence asks it once.
        let expectedWitness = settleCase == .released || settleCase == .timedOut ? 0 : 1
        #expect(keeperPort.witnessCount == expectedWitness && corePort.witnessCount == expectedWitness,
                "witness: keeper \(keeperPort.witnessCount), core \(corePort.witnessCount)")
        // The failed land's teardown (`landDidFail`, `onLandDestroyed`) runs after the settle's
        // step on both paths, each in its own task, so the settle's own calls are compared apart
        // from it.
        let teardown: (String) -> Bool = { $0.hasPrefix("landDidFail") || $0 == "onLandDestroyed" }
        #expect(keeperTrace.all.filter { !teardown($0) } == coreTrace.all.filter { !teardown($0) }, "keeper \(keeperTrace.all), core \(coreTrace.all)")
        guard settleCase == .settleCheck else {
            await pair.expectSame("after the settle (\(settleCase.rawValue))")
            return
        }
        let keeperFailure = await pair.keeper.differentialReadForTesting().failure
        let coreFailure = await pair.harness.differentialRead().failure
        #expect(keeperFailure != nil && keeperFailure == coreFailure, "keeper \(String(describing: keeperFailure)), core \(String(describing: coreFailure))")
        let (keeperLog, coreLog) = (await pair.digests().keeper.log, await pair.digests().core.log)
        #expect(keeperLog == coreLog, "keeper \(keeperLog), core \(coreLog)")
    }

    @Test("The initialization on the core: OnInitialize's resolvers as an effect, the record's hand-off or the finish's own step, and a waiter that came first answered when it ends, on both paths (K2-2 commit 1a)", arguments: [false, true])
    func initializationOnTheCore(records: Bool) async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false, onInitialize: true)
        let pair = await CoreDiffPair.make(shape, "init-\(records ? "recorded" : "unrecorded")", initializes: false, records: records)
        #expect(await pair.harness.differentialRead().model.didInitialize == false)
        // A waiter before the initialization: it waits at the barrier, an event the case reads.
        let coreWaiter = Task { try await pair.harness.call(.awaitInitialized) }
        guard await pair.harness.waitForInputs(named: "awaitInitialized", count: 1) else { return }
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.initialized.count == 1)

        await pair.keeper.awaitInitialization()
        await pair.harness.drive(.initialize)
        guard case .success(.done)? = await resultWithinHangBound(coreWaiter) else { Issue.record("the waiter wasn't answered .done"); return }
        let seen = await pair.harness.inputsSeen
        #expect(seen.contains("initializeResolved"), "the resolvers ran as an effect: \(seen)")
        // The record's hand-off comes back as an input; without a record the finish is a second
        // step in OnInitialize's handler, with no input of its own, so the phase's end is checked
        // instead.
        #expect(seen.contains("initializeRecorded") == records, "\(seen)")
        #expect(await pair.harness.differentialRead().model.initializationPhase == .done)
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.initialized.isEmpty)
        let (keeperLog, coreLog) = (await pair.digests().keeper.log, await pair.digests().core.log)
        #expect(keeperLog == ["init:1"] && coreLog == ["init:1"], "keeper \(keeperLog), core \(coreLog)")
        await pair.expectSame("after the initialization")
        // The land is open: a join goes through on both paths.
        _ = await bothJoin(pair, "p1", "c1")
        await pair.expectSame("after a join")
    }

    @Test("A held initialize record: two waiters that came first stay parked until the record is taken, then both get .done, on both paths (Review on #966, MF2 (a))")
    func initializationHeldRecordTwoWaiters() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false, onInitialize: true)
        let pair = await CoreDiffPair.make(shape, "init-held-record", initializes: false, records: true)
        let hold = WatermarkGate()
        defer { hold.release() }
        pair.harness.armedRecordGate.arm(hold)
        let first = Task { try await pair.harness.call(.awaitInitialized) }
        let second = Task { try await pair.harness.call(.awaitInitialized) }
        guard await pair.harness.waitForInputs(named: "awaitInitialized", count: 2) else { return }
        await pair.harness.drive(.initialize)
        guard await hold.waitUntilEntered("the core's initialize record") else { return }
        // Held at the record: OnInitialize applied, the waiters still parked.
        let held = await pair.harness.differentialRead().model
        guard case .recording = held.initializationPhase else { Issue.record("phase \(held.initializationPhase)"); return }
        // In `.recording` (as in `.finishing` and `.startingLoops`) `applied` is true and
        // `didInitialize` false (Review r2 on #966, MF): the drain's `stateIsSetUp` reads
        // `applied`.
        #expect(held.initializationApplied && !held.didInitialize, "held at the record: applied \(held.initializationApplied), didInitialize \(held.didInitialize)")
        #expect(held.coreBarrierWaits.initialized.count == 2)
        hold.release()
        for waiter in [first, second] {
            guard case .success(.done)? = await resultWithinHangBound(waiter) else { Issue.record("a waiter wasn't answered .done"); return }
        }
        #expect(await pair.harness.differentialRead().model.initializationPhase == .done)
        await pair.keeper.awaitInitialization()
        await pair.expectSame("after the held record")
    }

    @Test("The core's initialization waits for the recorder to take its record: with a submission held ahead of it in the twin's recorder queue, the record effect carries the submission and waits on it, the phase stays .recording, and the waiter is answered only after the queue moves (966 mutant (a), Review r3 should 1)")
    func initializationWaitsForTheRecorderOnTheCore() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false, onInitialize: true)
        let pair = await CoreDiffPair.make(shape, "init-recorder-queue", initializes: false, records: true)
        // The recorder's queue applies in submit order (a FIFO): a held submission ahead of the
        // record keeps the record from being taken.
        let queueHold = WatermarkGate()
        defer { queueHold.release() }
        let log = EventLog()
        await pair.harness.recorderSubmissions().submit(label: "held") {
            await queueHold.enterAndWait()
            log.append("queue moved")
        }
        let waiter = Task { try await pair.harness.call(.awaitInitialized) }
        guard await pair.harness.waitForInputs(named: "awaitInitialized", count: 1) else { return }
        await pair.harness.drive(.initialize)
        // The effect's own event, before it waits: the step staged the record and handed the
        // effect its submission. A step that hands it none lets the core finish at once.
        guard await pair.harness.recordHandOffs.waitFor({ !$0.isEmpty }) else { Issue.record("the record effect never ran"); return }
        #expect(pair.harness.recordHandOffs.events == ["awaiting the hand-off"], "\(pair.harness.recordHandOffs.events)")
        let held = await pair.harness.differentialRead().model
        guard case .recording = held.initializationPhase else { Issue.record("phase \(held.initializationPhase) while the record waits"); return }
        #expect(held.initializationApplied && !held.didInitialize)
        #expect(held.coreBarrierWaits.initialized.count == 1, "the waiter is still parked")

        queueHold.release()
        guard case .success(.done)? = await resultWithinHangBound(waiter) else { Issue.record("the waiter wasn't answered .done"); return }
        #expect(log.events == ["queue moved"])
        #expect(await pair.harness.differentialRead().model.initializationPhase == .done)
    }

    @Test("A failed initialization (OnInitialize's resolver throws): an early and a late waiter both get the failure, the phase is .failed, on both paths (Review on #966, MF2 (b), and the should on §3.3.1)")
    func initializationFailureAnswersTheWaiters() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false, onInitialize: true)
        let pair = await CoreDiffPair.make(shape, "init-fails", initializes: false, before: { CoreDiffInitGates.setFails($0, true) })
        defer { CoreDiffInitGates.setFails(pair.landID, false) }
        let early = Task { try await pair.harness.call(.awaitInitialized) }
        guard await pair.harness.waitForInputs(named: "awaitInitialized", count: 1) else { return }
        await pair.keeper.awaitInitialization()
        await pair.harness.drive(.initialize)
        await expectInitializationCauses(pair, early: await resultWithinHangBound(early), "\(CoreDiffError(token: -1))")
        #expect(await pair.harness.differentialRead().model.initializationPhase == .failed)
        #expect(await pair.keeper.differentialReadForTesting().model.initializationPhase == .failed)
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.initialized.isEmpty)
        // The keeper's teardown then drains; the core's is K2-2 commit 1b's, so the paths are
        // compared on the initialization's outcome only.
    }

    @Test("A drain flag set while OnInitialize's resolver is held: the initialization ends .abandonedByDrain, applies nothing, and the waiter gets the closed land, on both paths (Review on #966, MF2 (e), the keeper's T12)")
    func initializationDrainDuringResolvers() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false, onInitialize: true)
        let pair = await CoreDiffPair.make(shape, "init-drain-resolvers", initializes: false, autoStartLoops: true)
        defer { CoreDiffInitGates.set(pair.landID, nil) }

        let keeperGate = WatermarkGate()
        defer { keeperGate.release() }
        CoreDiffInitGates.set(pair.landID, keeperGate)
        let keeperInit = Task { await pair.keeper.awaitInitialization() }
        guard await keeperGate.waitUntilEntered("the keeper's OnInitialize resolver") else { return }
        await pair.keeper.markDrainingForTesting(cause: .forceShutdown)
        keeperGate.release()
        guard await valueWithinHangBound(keeperInit) != nil else { Issue.record("the keeper's initialization never ended"); return }

        let coreGate = WatermarkGate()
        defer { coreGate.release() }
        CoreDiffInitGates.set(pair.landID, coreGate)
        let waiter = Task { try await pair.harness.call(.awaitInitialized) }
        guard await pair.harness.waitForInputs(named: "awaitInitialized", count: 1) else { return }
        await pair.harness.drive(.initialize)
        guard await coreGate.waitUntilEntered("the core's OnInitialize resolver") else { return }
        await pair.harness.markDraining(cause: .forceShutdown)
        coreGate.release()
        let answer = await resultWithinHangBound(waiter)

        let keeperPhase = await pair.keeper.differentialReadForTesting().model.initializationPhase
        let corePhase = await pair.harness.differentialRead().model.initializationPhase
        #expect(keeperPhase == .abandonedByDrain && corePhase == .abandonedByDrain, "keeper \(keeperPhase), core \(corePhase)")
        // An abandoned initialization is a failed one to its waiters (K2 §3.3.1), as the keeper's
        // `ensureInitialized` throws: the land closed under it, with no failure of its own. A
        // late caller after `.abandonedByDrain` gets the same (the phase is over).
        await expectInitializationCauses(pair, early: answer, "\(LandInputRejection.landClosed)")
        #expect(!(await pair.harness.flushed.contains { if case .startLoops = $0 { true } else { false } }), "no loop on a draining land")
        let (keeperLog, coreLog) = (await pair.digests().keeper.log, await pair.digests().core.log)
        #expect(keeperLog.isEmpty && coreLog.isEmpty, "keeper \(keeperLog), core \(coreLog)")
        await pair.expectSame("after the drain during the resolvers")
    }

    @Test("A drain flag set while the initialize record is held: OnInitialize still applied, the phase ends without starting loops, and the waiter is answered, on both paths (Review on #966, MF2 (e), the keeper's T2b)")
    func initializationDrainDuringRecord() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false, onInitialize: true)
        let keeperRecord = CoreDiffArmedGate()
        let pair = await CoreDiffPair.make(shape, "init-drain-record", keeperRecordGate: keeperRecord, initializes: false, records: true, autoStartLoops: true)

        let keeperHold = WatermarkGate()
        defer { keeperHold.release() }
        keeperRecord.arm(keeperHold)
        let keeperInit = Task { await pair.keeper.awaitInitialization() }
        guard await keeperHold.waitUntilEntered("the keeper's initialize record") else { return }
        await pair.keeper.markDrainingForTesting(cause: .forceShutdown)
        keeperHold.release()
        guard await valueWithinHangBound(keeperInit) != nil else { Issue.record("the keeper's initialization never ended"); return }

        let coreHold = WatermarkGate()
        defer { coreHold.release() }
        pair.harness.armedRecordGate.arm(coreHold)
        let waiter = Task { try await pair.harness.call(.awaitInitialized) }
        guard await pair.harness.waitForInputs(named: "awaitInitialized", count: 1) else { return }
        await pair.harness.drive(.initialize)
        guard await coreHold.waitUntilEntered("the core's initialize record") else { return }
        await pair.harness.markDraining(cause: .forceShutdown)
        coreHold.release()
        let answer = await resultWithinHangBound(waiter)

        let keeperPhase = await pair.keeper.differentialReadForTesting().model.initializationPhase
        let corePhase = await pair.harness.differentialRead().model.initializationPhase
        #expect(keeperPhase == .done && corePhase == .done, "keeper \(keeperPhase), core \(corePhase)")
        guard case .success(.done)? = answer else { Issue.record("the core's waiter: \(String(describing: answer))"); return }
        #expect(!(await pair.harness.flushed.contains { if case .startLoops = $0 { true } else { false } }), "no loop on a draining land")
        let (keeperLog, coreLog) = (await pair.digests().keeper.log, await pair.digests().core.log)
        #expect(keeperLog == ["init:1"] && coreLog == ["init:1"], "still applied: keeper \(keeperLog), core \(coreLog)")
        await pair.expectSame("after the drain during the record")
    }

    @Test("OnInitialize's validate refuses: the phase is .failed, nothing applies, no loop starts, and an early and a late waiter both get the failure, on both paths (Review on #966, MF2 (b))")
    func initializationValidateRefuses() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false, initializeRefuses: true)
        let pair = await CoreDiffPair.make(shape, "init-refuses", initializes: false, autoStartLoops: true)
        let early = Task { try await pair.harness.call(.awaitInitialized) }
        guard await pair.harness.waitForInputs(named: "awaitInitialized", count: 1) else { return }
        await pair.keeper.awaitInitialization()
        await pair.harness.drive(.initialize)
        await expectInitializationCauses(pair, early: await resultWithinHangBound(early), "\(CoreDiffError(token: -2))")
        let keeperPhase = await pair.keeper.differentialReadForTesting().model.initializationPhase
        let corePhase = await pair.harness.differentialRead().model.initializationPhase
        #expect(keeperPhase == .failed && corePhase == .failed, "keeper \(keeperPhase), core \(corePhase)")
        #expect(!(await pair.harness.flushed.contains { if case .startLoops = $0 { true } else { false } }), "no loop after a refusal")
        let (keeperLog, coreLog) = (await pair.digests().keeper.log, await pair.digests().core.log)
        #expect(keeperLog.isEmpty && coreLog.isEmpty, "keeper \(keeperLog), core \(coreLog)")
    }

    @Test("A stop parked during the initialization, whose OnInitialize fails the land by its late re-entry, joins the failure's teardown: one .failureTeardown, no ordinary drain start, the same failure on both paths (Review r2 on #969, MF1: the failure takes precedence wherever a drain is claimed)")
    func parkedStopJoinsTheInitializationsFailure() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false, onInitialize: true)
        let pair = await CoreDiffPair.make(shape, "init-reentry-stop", initializes: false)
        let source = try #require(pair.source)
        defer { CoreDiffHandlerReentry.clear(pair.landID) }
        defer { CoreDiffInitGates.set(pair.landID, nil) }
        // The keeper first (the hook is one-shot, keyed by the land ID both share): its stop
        // waits in `ensureInitialized`, then joins the drain `failLand` staged.
        CoreDiffHandlerReentry.register(pair.landID) { [keeper = pair.keeper] in
            keeper.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: OnInitialize's re-entry the sentinel refuses
        }
        let keeperGate = WatermarkGate()
        defer { keeperGate.release() }
        CoreDiffInitGates.set(pair.landID, keeperGate)
        let keeperInit = Task { await pair.keeper.awaitInitialization() }
        guard await keeperGate.waitUntilEntered("the keeper's OnInitialize resolver") else { return }
        // The stop must wait in `ensureInitialized` before the resolver ends (Review r3).
        let waitsBefore = await pair.keeper.initializationWaitsForTesting()
        let keeperStop = Task { await pair.keeper.forceShutdown() }
        guard await valueWithinHangBound(Task { await pair.keeper.waitForInitializationWaitersForTesting(waitsBefore + 1) }) == true else {
            Issue.record("the keeper's stop never waited for the initialization"); return
        }
        keeperGate.release()
        guard await valueWithinHangBound(keeperInit) != nil, await valueWithinHangBound(keeperStop) != nil else { Issue.record("the keeper's stop never returned"); return }

        let coreGate = WatermarkGate()
        defer { coreGate.release() }
        CoreDiffInitGates.set(pair.landID, coreGate)
        await pair.harness.drive(.initialize)
        guard await coreGate.waitUntilEntered("the core's OnInitialize resolver") else { return }
        let stop = Task { try await pair.harness.call(.shutdown) }
        guard await pair.harness.waitForInputs(named: "shutdown", count: 1) else { return }
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.stopsAwaitingInitialization.count == 1)
        CoreDiffHandlerReentry.register(pair.landID) { [source] in
            source.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: OnInitialize's re-entry the sentinel refuses
        }
        coreGate.release()
        guard case .success(.done)? = await resultWithinHangBound(stop) else { Issue.record("the core's stop wasn't answered .done"); return }
        let flushed = await pair.harness.flushed
        let teardowns = flushed.filter { if case .failureTeardown = $0 { true } else { false } }.count
        let starts = flushed.filter { if case .drainStarting = $0 { true } else { false } }.count
        #expect(teardowns == 1 && starts == 0, "the stop claimed an ordinary drain: teardowns \(teardowns), starts \(starts)")
        // No port on this tickless shape (a tickless land with a transport is refused until
        // commit 3), so `landDidFail` is read as the teardown's output before the drain's end.
        let teardownAt = flushed.firstIndex { if case .failureTeardown = $0 { true } else { false } }
        let detachAt = flushed.firstIndex { if case .detachTransport = $0 { true } else { false } }
        #expect(teardownAt != nil && detachAt != nil && teardownAt! < detachAt!, "\(flushed.map { "\($0)".prefix(30) })")
        let keeperFailure = await pair.keeper.differentialReadForTesting().failure
        let coreFailure = await pair.harness.differentialRead().failure
        #expect(coreFailure?.kind == .keeperReentry && keeperFailure == coreFailure, "keeper \(String(describing: keeperFailure)), core \(String(describing: coreFailure))")
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.isEmpty)
    }

    @Test("OnInitialize's late re-entry (the keeper's T11): the backstop fails the land in OnInitialize's step, so the finish starts no loop; the initialization itself ended .done, on both paths (Review on #966, MF2 (d))")
    func initializationLateReentry() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false, onInitialize: true)
        let pair = await CoreDiffPair.make(shape, "init-reentry", initializes: false, autoStartLoops: true)
        let source = try #require(pair.source)
        defer { CoreDiffHandlerReentry.clear(pair.landID) }
        // One path at a time: the hook is one-shot and keyed by the land ID both share.
        CoreDiffHandlerReentry.register(pair.landID) { [keeper = pair.keeper] in
            keeper.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: OnInitialize's re-entry the sentinel refuses
        }
        await pair.keeper.awaitInitialization()
        CoreDiffHandlerReentry.register(pair.landID) { [source] in
            source.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: OnInitialize's re-entry the sentinel refuses
        }
        let waiter = Task { try await pair.harness.call(.awaitInitialized) }
        guard await pair.harness.waitForInputs(named: "awaitInitialized", count: 1) else { return }
        await pair.harness.drive(.initialize)
        let answer = await resultWithinHangBound(waiter)

        #expect(await pair.keeper.lateReentriesAppliedForTesting == 1)
        #expect(await source.lateReentriesAppliedForTesting == 1)
        let keeperFailure = await pair.keeper.differentialReadForTesting().failure
        let coreFailure = await pair.harness.differentialRead().failure
        #expect(coreFailure?.kind == .keeperReentry && keeperFailure == coreFailure, "keeper \(String(describing: keeperFailure)), core \(String(describing: coreFailure))")
        #expect(!(await pair.harness.flushed.contains { if case .startLoops = $0 { true } else { false } }), "no loop after the backstop failed the land")
        let keeperPhase = await pair.keeper.differentialReadForTesting().model.initializationPhase
        let corePhase = await pair.harness.differentialRead().model.initializationPhase
        // The initialization itself succeeded (OnInitialize applied); the land failed after it,
        // in that step's backstop. So the phase ends `.done` with no loop on both paths, and the
        // waiter is answered `.done`, as the keeper's `awaitInitialization` returns: the land's
        // failure, not the initialization's, ends what comes next.
        #expect(keeperPhase == .done && corePhase == .done, "keeper \(keeperPhase), core \(corePhase)")
        guard case .success(.done)? = answer else { Issue.record("the core's waiter: \(String(describing: answer))"); return }
    }

    @Test("autoStartLoops: the core's .startLoops is answered by the owner's .initializeDone, which ends the phase and answers the waiter, on both paths (Review on #966, MF2 (c))")
    func initializationStartsLoops() async throws {
        let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false, onInitialize: true)
        let pair = await CoreDiffPair.make(shape, "init-loops", initializes: false, autoStartLoops: true)
        let waiter = Task { try await pair.harness.call(.awaitInitialized) }
        guard await pair.harness.waitForInputs(named: "awaitInitialized", count: 1) else { return }
        await pair.harness.drive(.initialize)
        guard case .success(.done)? = await resultWithinHangBound(waiter) else { Issue.record("the waiter wasn't answered .done"); return }
        #expect(await pair.harness.inputsSeen.contains("initializeDone"), "the owner's answer to .startLoops")
        #expect(await pair.harness.differentialRead().model.initializationPhase == .done)
        await pair.keeper.awaitInitialization()
        await pair.expectSame("after the loops' start")
    }

    @Test("A resolution of another sequence, while the core's initialization is in .resolving, stops the process: the result step checks the sequence its request left, not only the phase (966 mutant (f))")
    func staleInitializeResolutionStops() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let shape = CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false, onInitialize: true)
            let gate = WatermarkGate()
            let pair = await CoreDiffPair.make(shape, "init-stale-resolution", initializes: false, before: { CoreDiffInitGates.set($0, gate) })
            await pair.harness.drive(.initialize)
            // The core's resolvers are held, so its phase is `.resolving(sequence:)` of this
            // request; a resolution carrying another sequence is a broken flow.
            guard await gate.waitUntilEntered("the core's OnInitialize resolver"),
                  let resolving = pair.harness.initializeResolvingSeen.value else { return }
            let stale = LandKeeper<CoreDiffState>.InitializeResolving(
                handler: resolving.handler,
                ctx: resolving.ctx,
                sequence: resolving.sequence + 1,
                sequenceAfterTake: resolving.sequenceAfterTake,
                executors: resolving.executors,
                resolverContext: resolving.resolverContext
            )
            await pair.harness.drive(.initializeResolved(stale, .success(resolving.ctx), initializationTaskCancelled: false))
            // A waiter queued behind it: answered only if the stale resolution was applied, so
            // the body doesn't end (and the process exit 0) before the stale input steps. The
            // harness calls with `.ignoresCancel`: bounded, a lost reply ends the body (exit 0,
            // the case fails) instead of hanging the child.
            _ = await replyWithinHangBound(pair, .awaitInitialized)
        }
        #if DEBUG
        // An optimized build's `preconditionFailure` traps without its message: the message is
        // checked only where it is printed.
        let standardError = result.map { String(decoding: $0.standardErrorContent, as: UTF8.self) } ?? ""
        #expect(standardError.contains("OnInitialize's resolvers ended in phase"), "\(standardError)")
        #else
        _ = result
        #endif
    }

    @Test("The initialization's barrier is open after OnInitialize, on both paths (Review on #948, MF6: the open case until commit 1)")
    func awaitInitializedOpen() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "await-initialized")
        await pair.keeper.awaitInitialization()
        guard case .done = try await pair.harness.call(.awaitInitialized) else { Issue.record("not a done reply"); return }
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.isEmpty)
        await pair.expectSame("after the initialization's barrier")
    }
}
