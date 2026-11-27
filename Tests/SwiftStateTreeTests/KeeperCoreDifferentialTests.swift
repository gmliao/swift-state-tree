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
        if shape.tick && shape.destroysWhenEmpty {
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
    /// Holds an action job's result before it steps, as the keeper's `.actionComplete` hold does.
    nonisolated let jobGate: WatermarkGate?
    /// The twin's source keeper, whose executor this actor shares (as the facade will share the
    /// core's, plan §3): a callback that re-enters the keeper with `assumeIsolated` then runs.
    nonisolated let owner: LandKeeper<State>
    nonisolated var unownedExecutor: UnownedSerialExecutor { owner.unownedExecutor }
    /// §16 item 5: an input and a query the next flush makes, in that order, and what it saw.
    private var armedFlush: (input: KeeperInput<State>, query: KeeperQuery)?
    private(set) var flushQueryAnswers: [(answer: KeeperAnswer<State>, pendingAtQuery: [Int64], tickAtQuery: Int64)] = []

    init(_ twin: (model: KeeperModel<State>, behavior: KeeperBehavior<State>, store: KeeperSideStore, owner: LandKeeper<State>), recordGate: WatermarkGate? = nil, jobGate: WatermarkGate? = nil,
         clock: CoreDiffClock? = nil) {
        self.recordGate = recordGate
        self.jobGate = jobGate
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

    /// The box of the job `sequence` (the side's job table): a waiting caller cancels the job
    /// through it, as the keeper's `awaitActionResult` handler does.
    func jobBox(_ sequence: Int64) -> KeeperActionJobTask? {
        store.withSide { $0.actions.jobTask(sequence) }
    }

    /// The sync entries, as the keeper's: the port's in-turn read for the owner and the query in
    /// one segment, with no await between (K2-2 plan §9). `query` answers in place
    /// (`TurnActor.query` steps synchronously), so no other step runs between the read and the
    /// query's step.
    func syncTurnNow(via port: any LandKeeperTransport, reason: SyncTurnReason, ticket: SyncTurnTicket? = nil) -> InTurnSyncResult {
        guard case let .syncTurn(result) = ask(.syncTurnNow(port: port, inTurnForOwner: port.runsSyncPhaseInTurn(of: owner), reason: reason, ticket: ticket)) else {
            preconditionFailure("syncTurnNow's answer")
        }
        return result
    }

    func syncTurnTicket(via port: any LandKeeperTransport) -> SyncTurnTicket? {
        guard case let .syncTurnTicket(ticket) = ask(.syncTurnTicket(port: port, inTurnForOwner: port.runsSyncPhaseInTurn(of: owner))) else {
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
    private var inputWaiters: [(name: String, count: Int, resume: CheckedContinuation<Void, Never>)] = []
    private func noteSeen(_ name: String) {
        inputsSeen.append(name)
        let seen = inputsSeen.filter { $0 == name }.count
        let ready = inputWaiters.filter { $0.name == name && $0.count <= seen }
        inputWaiters.removeAll { $0.name == name && $0.count <= seen }
        for waiter in ready { waiter.resume.resume() }
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
            await jobGate?.enterAndWait()
            result = .actionResolved(sequence: start.sequence, resolved.value)
        case let .actionJobRelease(sequence, abandonment):
            await abandonment.waitUntilEnded()
            result = .actionJobReleased(sequence: sequence)
        case .initialize, .destroyHandler:
            Issue.record("K2-2a commit 0 routes no \(effect) effect")
            result = nil
        }
        if let result { await noteResult(result.routeName) }
        return result
    }

    func flush(_ outputs: consuming [KeeperOutput]) {
        flushed.append(contentsOf: outputs)
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

    /// Returns once `count` inputs named `name` were sent: an event, resumed by the note (a call
    /// notes its input, then steps it, in one segment of this actor).
    func waitForInputs(named name: String, count: Int) async {
        guard inputsSeen.filter({ $0 == name }).count < count else { return }
        await withCheckedContinuation { inputWaiters.append((name, count, $0)) }
    }

    /// Waits for the record submissions the core's flushes made (the twin's own tracker).
    func waitForSubmissions() async {
        let tracker = store.withSide { side in side.submissionsForTesting }
        await tracker.waitForAll()
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
/// carries its input's read (K2-1, until K2-2's binding token), a stated asymmetry.
final class CoreDiffTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    func clear() { lock.withLock { entries.removeAll() } }
    var all: [String] { lock.withLock { entries } }
}

/// The port that writes the trace. When armed, its `runSyncPhaseInTurn` re-enters `keeper` once
/// with a guarded entry (`submitSyncStream`), which the sentinel refuses mid-step.
final class CoreDiffTraceTransport: LandKeeperTransport, @unchecked Sendable {
    /// Which sync follow-up a committed or deferred phase asks for (Review round 2 on #938).
    enum FollowUp: Sendable, CaseIterable { case none, joinsAwaiting, keptEvents, deferred }
    let trace: CoreDiffTrace
    var followUp: FollowUp = .none
    private let lock = NSLock()
    private weak var reentryKeeper: LandKeeper<CoreDiffState>?
    init(_ trace: CoreDiffTrace) { self.trace = trace }

    func armReentry(_ keeper: LandKeeper<CoreDiffState>) { lock.withLock { reentryKeeper = keeper } }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async { trace.append("sendEvent \(event) to \(target)") }
    func syncNowFromTransport() async { trace.append("syncNow") }
    func syncBroadcastOnlyFromTransport() async { trace.append("syncBroadcastOnly") }
    func onLandDestroyed() async { trace.append("onLandDestroyed") }
    func landDidFail(_ failure: LandFailure) async { trace.append("landDidFail \(failure.kind) \(failure.detail)") }
    func closeOutputs(for failure: LandFailure) { trace.append("closeOutputs \(failure.kind) \(failure.detail)") }
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func admitJoiningSession(playerID: PlayerID, clientID: ClientID, sessionID: SessionID, joinSequence: Int64?) -> JoinAdmission {
        trace.append("admitJoiningSession \(playerID) \(clientID) \(sessionID) \(joinSequence.map(String.init) ?? "-")")
        return .notAdmitted
    }
    func refusesResolvedJoin(playerID: PlayerID, sessionID: SessionID) -> Bool { trace.append("refusesResolvedJoin \(playerID) \(sessionID)"); return false }
    func noteJoinInputsConsumed(_ results: [JoinInputResult]) { trace.append("noteJoinInputsConsumed \(results)") }
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
                     keeperRecordGate: CoreDiffArmedGate? = nil, clock: CoreDiffClock? = nil) async -> CoreDiffPair {
        let landID = "core-diff:\(name):\(UUID().uuidString)"
        func keeper() -> LandKeeper<CoreDiffState> {
            LandKeeper<CoreDiffState>(definition: coreDiffDefinition(shape), initialState: CoreDiffState(), autoStartLoops: false, landID: landID)
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
        await direct.awaitInitialization()
        await twinSource.awaitInitialization()
        let harness = KeeperCoreHarness(await twinSource.coreTwinForTesting(), clock: clock)
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
    func expectSame(_ step: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        // The keeper's drain yields before it ends (`runInputDrain`), after the call that
        // started it returned: read it once its work and its drain are done.
        await keeper.waitForInFlightWorkForTesting()
        await keeper.waitForInputDrainIdleForTesting()
        let (keeperDigest, coreDigest) = await digests()
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
private func describeJob(_ result: Result<InputOutcome, any Error>) -> String {
    switch result {
    case let .success(.response(response)): "ack \((response as? CoreDiffAck)?.n ?? -1)"
    case .success(.none): "none"
    case let .failure(error as CoreDiffError): "error \(error.token)"
    case .failure(is CancellationError): "cancelled"
    case let .failure(error): "\(type(of: error))"
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
        let kickHold = WatermarkGate(), sourceDrainHold = WatermarkGate(), teardownHold = WatermarkGate()
        // Released on every exit, a failed expectation's early return included.
        defer {
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
        await harness.drive(.inputDrainDue)

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
        #expect(keeperDigest == coreDigest, "\n keeper \(keeperDigest)\n core   \(coreDigest)")
        #expect(coreDigest.failure?.kind == failure.kind && coreDigest.players.isEmpty && coreDigest.pendingSequences.isEmpty, "\(coreDigest)")
        #expect(coreDigest.violations.isEmpty, "\(coreDigest.violations)")
        #expect(await harness.differentialRead().coreWaitsLeft == 0)
        // The core's flush ran the drain's staged start: with no keeper behind the twin's
        // reference, it starts no teardown (K2-1b's), and only the waiters are resumed.
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
        await harness.waitForInputs(named: "action", count: 2)
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
        #expect(answer != .completed(7), "the caller got the handler's error: \(answer)")
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
        await pair.harness.waitForInputs(named: "awaitActionResult", count: 1)
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
        /// `failed`: the land failed in the step. The keeper's teardown then runs from the staged
        /// start (`landDidFail`, then the destroy's `onLandDestroyed`); the core's finds no keeper
        /// (K2-1b routes the teardown, plan §16 item 13), so those two are compared apart.
        func expectSameTrace(_ step: String, failed: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            var k = keeperTrace.all
            let c = coreTrace.all
            if failed {
                await keeper.waitUntilDrainStartedForTesting()
                await keeper.waitUntilDrained()
                k = keeperTrace.all
                let teardown = k.filter { $0.hasPrefix("landDidFail") || $0 == "onLandDestroyed" }
                #expect(teardown.count == 2 && teardown.last == "onLandDestroyed", "\(step): the keeper's teardown \(teardown)", sourceLocation: sourceLocation)
                #expect(Array(k.suffix(2)) == teardown, "\(step): the teardown comes last \(k)", sourceLocation: sourceLocation)
                k.removeLast(2)
                #expect(!c.contains { $0.hasPrefix("landDidFail") || $0 == "onLandDestroyed" }, "\(step): \(c)", sourceLocation: sourceLocation)
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
        let keeperShort = Task { await pair.keeper.debugFreeze(generation: 1, timeout: .milliseconds(50)) }
        let keeperLong = Task { await pair.keeper.debugFreeze(generation: 1, timeout: .seconds(3600)) }
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
        await pair.harness.waitForInputs(named: "freeze", count: 1)
        let coreLong = Task { await coreFreeze(pair, 1, .seconds(3600)) }
        await pair.harness.waitForInputs(named: "freeze", count: 2)
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
        await pair.keeper.waitUntilFreezeWaitsForTesting()
        let keeperSecond = Task { await pair.keeper.debugFreeze(generation: 2, timeout: .seconds(3600)) }
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
        await pair.harness.waitForInputs(named: "freeze", count: 1)
        let coreSecond = Task { await coreFreeze(pair, 2, .seconds(3600)) }
        await pair.harness.waitForInputs(named: "freeze", count: 2)
        cg.release()
        await pair.harness.waitForInputs(named: "recordTaken", count: 2)
        let left = await pair.harness.differentialRead().model.coreBarrierWaits.freeze
        #expect(left.isEmpty, "every generation's callers answered at the work's end: \(left)")
        // Unsticks a caller the expectation above found (it would otherwise wait an hour).
        clock.advance(by: .seconds(3601))
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

    @Test("A tick land's freeze is refused on the core until commit 1 holds the tick's count across its record (Review on #948, MF2)")
    func tickLandFreezeRefused() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: true, joinResolvers: false, leaveResolver: false), "freeze-tick")
        do {
            _ = try await pair.harness.call(.freeze(generation: 1, timeout: .seconds(5)))
            Issue.record("the tick land's freeze stepped")
        } catch let refusal as KeeperCoreRefusal {
            #expect(refusal.reason.contains("commit 1"), "\(refusal.reason)")
        }
        #expect(await pair.harness.differentialRead().model.debugFrozen == false)
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
        await direct.waitUntilFreezeWaitsForTesting()
        kg.release()
        let keeperFroze = await keeperFreeze.value

        let cg = WatermarkGate()
        defer { cg.release() }
        harness.armedRecordGate.arm(cg)
        await harness.drive(.resume(generation: 1))
        guard await cg.waitUntilEntered("the core's kicked record") else { return }
        let coreFreezeTask = Task { await coreFreeze(pair, 2, .seconds(3600)) }
        await harness.waitForInputs(named: "freeze", count: 1)
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
        await pair.harness.waitForInputs(named: "action", count: 1)

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
        await pair.harness.waitForInputs(named: "action", count: 1)
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

    @Test("The initialization's barrier is open after OnInitialize, on both paths (Review on #948, MF6: the open case until commit 1)")
    func awaitInitializedOpen() async throws {
        let pair = await CoreDiffPair.make(CoreDiffShape(tick: false, joinResolvers: false, leaveResolver: false), "await-initialized")
        await pair.keeper.awaitInitialization()
        guard case .done = try await pair.harness.call(.awaitInitialized) else { Issue.record("not a done reply"); return }
        #expect(await pair.harness.differentialRead().model.coreBarrierWaits.isEmpty)
        await pair.expectSame("after the initialization's barrier")
    }
}
