// Tests/SwiftStateTreeNIOTests/Differential/DiffRunner.swift
//
// Runs one scenario in one cell (#555, plan §5): builds the server's assembly with its loops
// off, drives fake connections through the real transport, router, adapter and keeper, and
// captures each connection's frames and close at the live checkpoint, again after the stop,
// and the saved record. Every wait has a bound; a wait that hits it fails the run, naming what
// it waited for. Orders are forced with holds, never with timing.

#if DEBUG
import Foundation
import Logging
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
@testable import SwiftStateTreeNIO
import SwiftStateTreeTestSupport

struct DiffRunFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The bound on each wait of a run. A correct run never reaches it: it is the backstop that
/// turns a hang into a failure naming its step.
let diffWaitBound: Duration = .seconds(30)

/// The record's pinned creation time (the record-identity override).
let diffRecordCreatedAt = Date(timeIntervalSince1970: 1_800_000_000)

/// The land every scenario joins.
let diffLandID = LandID(landType: diffLandType, instanceId: "one")

// MARK: - Holds

/// The run's hold registries, one per component, and a gate per armed or observed hold.
final class DiffHoldTable: @unchecked Sendable {
    let router = HoldRegistry<LandRouterHoldPoint>()
    let adapter = HoldRegistry<TransportAdapterHoldPoint>()
    let keeper = HoldRegistry<LandKeeperHoldPoint>()
    private let lock = NSLock()
    private var gates: [DiffHold: TestGate] = [:]

    /// Closes `hold` on its `arrival`-th arrival (every arrival when nil) until `release`.
    func arm(_ hold: DiffHold, arrival: Int?) {
        register(hold, arrival: arrival, gate: TestGate())
    }

    /// Counts arrivals at `hold` from now on, without blocking them.
    func observe(_ hold: DiffHold) {
        let gate = TestGate()
        gate.open()
        register(hold, arrival: nil, gate: gate)
    }

    func gate(_ hold: DiffHold) -> TestGate? {
        lock.withLock { gates[hold] }
    }

    func openAll() {
        for gate in lock.withLock({ Array(gates.values) }) { gate.open() }
    }

    private func register(_ hold: DiffHold, arrival: Int?, gate: TestGate) {
        lock.withLock { gates[hold] = gate }
        let body: @Sendable () async -> Void = { await gate.arrive() }
        switch hold {
        case .router(let point): router.on(point, arrival: arrival, body)
        case .adapter(let point): adapter.on(point, arrival: arrival, body)
        case .keeper(let point): keeper.on(point, arrival: arrival, body)
        // The server's hook reads the gate itself (`DiffRun.make`).
        case .stopSessionsClosed: break
        }
    }
}

// MARK: - Captures

struct DiffFrame: Codable, Equatable, Sendable {
    let bytes: Data
    let decoded: DiffValue

    init(bytes: Data) throws {
        self.bytes = bytes
        self.decoded = try DiffValue.decodeFrame(bytes)
    }

    /// A frame whose stored view isn't derived from its bytes: the corrupt-golden check's input.
    init(bytes: Data, decodedOverride: DiffValue) throws {
        self.bytes = bytes
        self.decoded = decodedOverride
    }
}

struct DiffClose: Codable, Equatable, Sendable {
    let code: UInt16
    let reason: String
}

struct DiffConnectionCapture: Codable, Equatable, Sendable {
    var frames: [DiffFrame]
    var close: DiffClose?
}

/// Every connection attempt's frames and close, by attempt name.
struct DiffCapture: Codable, Equatable, Sendable {
    var connections: [String: DiffConnectionCapture]
    /// The rows' notes since the previous checkpoint, by name; absent when there are none.
    var notes: [String: DiffValue]?
}

/// The saved record: its file's bytes and its decoded view.
struct DiffRecordCapture: Codable, Equatable, Sendable {
    let bytes: Data
    let decoded: DiffValue
    let complete: Bool
}

struct DiffRunResult: Codable, Equatable, Sendable {
    var live: DiffCapture
    var terminal: DiffCapture
    var record: DiffRecordCapture
    /// What the run went through, for a failure's report: not compared, and not in a golden.
    var diagnostics = DiffRunDiagnostics()

    private enum CodingKeys: String, CodingKey { case live, terminal, record }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.live == rhs.live && lhs.terminal == rhs.terminal && lhs.record == rhs.record
    }
}

/// Where the harness waits for the writer's sync-cycle drain.
enum DiffDrainSite: Hashable, Sendable {
    /// `sync()`, before its `syncNow`.
    case beforeSync
    /// `sync()`, after its background syncs.
    case afterSync
    /// A tick the harness steps, before it.
    case tick
    /// The start of a keeper leave (a disconnect, a kick, the stop's leaves), before its turn.
    case keeperLeave
    /// A join's sync request, before the keeper's join sync turn.
    case joinSyncRequest
}

/// A run's counters that depend on timing, reported beside a cell's differences (#908).
struct DiffRunDiagnostics: Equatable, Sendable {
    /// In-turn sync phases the writer's back-pressure deferred (`syncSkipCounts().outboundBacklog`).
    /// A deferred phase builds no output; the writer-drain retry's sync-only turn does instead.
    /// One deferral turns a tick output into a sync-only one; two in a row share one retry, so
    /// the record has one output fewer and every later stream index and sync sequence is one
    /// lower (#908, #917). The harness drains the writer around its syncs, so only a scenario
    /// that forces the back-pressure sees one.
    var syncPhasesDeferredByBackPressure = 0

    /// Empty when nothing timing-dependent happened.
    var summary: String {
        syncPhasesDeferredByBackPressure == 0 ? ""
            : "sync phases deferred by the writer's back-pressure: \(syncPhasesDeferredByBackPressure)"
    }
}

// MARK: - The run

/// One connection attempt of a scenario.
struct DiffAttempt: Sendable {
    let session: SessionID
    let connection: RecordingConnection
    /// The transport's generation for this connection, read when it was accepted: a barrier
    /// finds the attempt a close was for by it, not by what the transport holds now (#909).
    let generation: UInt64?
}

/// A run of one scenario in one cell. Steps run in order on one task; the hold table and the
/// resolver gates are the only state other tasks touch, and they lock.
final class DiffRun: @unchecked Sendable {
    let scenario: DiffScenario
    let cell: DiffCell
    let server: NIOLandServer<DiffState>
    let container: LandContainer<DiffState>
    let recorder: ReevaluationRecorder
    let holds = DiffHoldTable()
    private(set) var attempts: [String: DiffAttempt] = [:]
    private(set) var attemptOrder: [String] = []
    private var ingress: [String: Task<Void, Never>] = [:]
    private var spawned: [Task<Void, Never>] = []
    /// Answers of actions whose job outlived their turn (`held`): the barrier waits for them.
    private(set) var pendingAnswers = 0
    /// Notes taken since the last capture.
    private var notes: [String: DiffValue] = [:]
    private(set) var live: DiffCapture?
    private(set) var stopped = false
    private var stopTask: Task<StopLandResult, Never>?
    /// Attempts whose client disconnected: no longer live, though their connection isn't closed.
    private(set) var disconnected: Set<String> = []
    /// Failures of the harness's own hold bodies, which can't throw: the step they ran in fails.
    private let holdBodyFailureLock = NSLock()
    private var holdBodyFailures: [String] = []

    func recordHoldBodyFailure(_ failure: String) {
        holdBodyFailureLock.withLock { holdBodyFailures.append(failure) }
    }

    private func throwHoldBodyFailures() throws {
        let failures = holdBodyFailureLock.withLock { holdBodyFailures }
        if !failures.isEmpty { throw DiffRunFailure("a harness hold body failed: \(failures.joined(separator: "; "))") }
    }

    var transport: WebSocketTransport { server.transport }
    var router: LandRouter<DiffState> { server.landRouter }
    var adapter: TransportAdapter<DiffState> { container.transportAdapter }
    var keeper: LandKeeper<DiffState> { container.keeper }

    private init(scenario: DiffScenario, cell: DiffCell, server: NIOLandServer<DiffState>, container: LandContainer<DiffState>, recorder: ReevaluationRecorder) {
        self.scenario = scenario
        self.cell = cell
        self.server = server
        self.container = container
        self.recorder = recorder
    }

    /// The assembly for `cell`, with every timer and clock-driven decision off, and the land
    /// created before any join so its holds are installed first.
    static func make(_ scenario: DiffScenario, cell: DiffCell) async throws -> DiffRun {
        DiffGates.reset()
        let definition = makeDiffLand(cell.land)
        var configuration = NIOLandServerConfiguration(
            logger: Logger(label: "differential") { _ in SwiftLogNoOpLogHandler() },
            allowAutoCreateOnJoin: false,
            transportEncoding: cell.encoding.config,
            enableLiveStateHashRecording: true,
            enableLoopPhaseOffset: false,
            syncLag: .off,
            maxHandshakeFrameBytes: HandshakeFrameLimit.defaultMaxBytes,
            maxRefusedHandshakeFrames: HandshakeFrameLimit.defaultMaxRefusedFrames
        )
        // Past any correct run: a stop that reaches it fails the run.
        configuration.landStopTimeout = diffWaitBound
        let transport = WebSocketTransport()
        let server = try NIOLandServer<DiffState>(
            landType: diffLandType,
            landFactory: { _ in definition },
            initialStateFactory: { _ in DiffState() },
            configuration: configuration,
            transport: transport,
            autoStartLoops: false
        )
        await server.attach()
        await transport.setClientIDSupplierForTesting { ClientID("c\($0)") }
        await server.landManager.setRecordIdentityForTesting(.init(createdAt: diffRecordCreatedAt, hardwareInfo: nil))
        // The join budget off (`.zero` is none).
        await server.landRouter.setJoinTimeoutForTesting(.zero)
        let container = try await server.landManager.getOrCreateLand(
            landID: diffLandID, definition: definition, initialState: DiffState(), metadata: [:]
        )
        guard let recorder = await container.keeper.getReevaluationRecorder() else {
            throw DiffRunFailure("the land has no recorder")
        }
        let run = DiffRun(scenario: scenario, cell: cell, server: server, container: container, recorder: recorder)
        // The flip timeout off (`.zero` is none), and the join commits captured.
        await container.transportAdapter.setJoinFlipLimitsForTesting(timeout: .zero, budget: nil)
        await container.transportAdapter.captureJoinCommitsForTesting()
        await server.landRouter.installHolds(run.holds.router.hook)
        await container.transportAdapter.installHolds(run.holds.adapter.hook)
        await container.transportAdapter.trackDetachedClosesForTesting()
        // On a tickless land with in-turn sync, a join's OnJoin turn and its registration race:
        // the turn can run before the registration (the join then flips in a sync-only turn of
        // its own) or after it (and flips in the OnJoin turn), and the record names the turn
        // kind. So every join waits at `keeperJoinReturned` until the keeper's input drain is
        // idle: its OnJoin turn runs before its registration, in every process. A tick land's
        // OnJoin waits for the tick. Registered first, so it runs before a scenario's own hold
        // there.
        if cell.land == .tickless {
            run.holds.adapter.on(.keeperJoinReturned) { [weak keeper = container.keeper] in
                await keeper?.waitForInputDrainIdleForTesting()
            }
        }
        // The phases the keeper starts on its own inside a step (a leave's turn, a kick's, the
        // stop's leaves, a join's sync turn) don't go through the harness's `sync()`, so they
        // wait here instead: the input turns before them are applied (tickless), then the writer
        // drains, so none finds an earlier phase's element still queued (#917). Registered
        // first, so a scenario's own hold at these points comes after.
        let landIsTickless = cell.land == .tickless
        let writer = await container.transportAdapter.outboundWriter
        // Bounded like every harness wait: a hold body can't throw, so a wait that runs out is
        // recorded on the run, the hold goes on, and the step fails with its name.
        // The keeper holds this closure (its hold hook): a strong capture would keep the keeper,
        // its recorder and its spool file alive after the run (#910).
        let settle: @Sendable (DiffDrainSite) async -> Void = { [weak run, weak keeper = container.keeper] site in
            guard let keeper else { return }
            do {
                if landIsTickless {
                    try await bounded("the keeper's input drain before \(site)") { await keeper.waitForInputDrainIdleForTesting() }
                }
                if let run, let observer = run.drainObserverForTesting { await observer(run, site) }
                try await bounded("the writer's sync-cycle drain before \(site)") { await writer.waitForSyncCycleDrain() }
            } catch {
                run?.recordHoldBodyFailure("\(error)")
            }
        }
        run.holds.keeper.on(.leave) { await settle(.keeperLeave) }
        run.holds.adapter.on(.joinSyncRequested) { await settle(.joinSyncRequest) }
        await container.keeper.installHolds(run.holds.keeper.hook)
        server.stopFlightsForTesting.onAfterSessionsClosedForTesting { [holds = run.holds] _ in
            await holds.gate(.stopSessionsClosed)?.arrive()
        }
        return run
    }

    /// Called by every writer drain the harness waits for, before it waits, with where the
    /// drain is (a self-check's seam: it sees what ran before the drain).
    var drainObserverForTesting: (@Sendable (DiffRun, DiffDrainSite) async -> Void)?

    /// Runs the scenario: its steps, then the stop (unless a step stopped the land), the
    /// terminal capture and the record. Cleans up whatever happens.
    func execute() async throws -> DiffRunResult {
        do {
            for (index, step) in scenario.steps.enumerated() {
                do {
                    try await run(step)
                    try throwHoldBodyFailures()
                } catch let failure as DiffRunFailure {
                    throw DiffRunFailure("step \(index + 1) (\(Self.name(of: step))): \(failure)")
                }
            }
            guard let live else { throw DiffRunFailure("no live checkpoint: a scenario must have one") }
            if !stopped { try await stop() }
            try await barrier()
            try throwHoldBodyFailures()
            let terminal = try await capture()
            let record = try await saveRecord()
            let deferred = await adapter.syncSkipCounts().outboundBacklog
            await cleanUp()
            var result = DiffRunResult(live: live, terminal: terminal, record: record)
            result.diagnostics.syncPhasesDeferredByBackPressure = deferred
            return result
        } catch {
            // A run that fails names the deferrals it went through too, whatever failed, so a
            // red cell shows them without a rerun (#908).
            let diagnostics = DiffRunDiagnostics(syncPhasesDeferredByBackPressure: await adapter.syncSkipCounts().outboundBacklog)
            await cleanUp()
            if diagnostics.summary.isEmpty { throw error }
            throw DiffRunFailure("\(error) (\(diagnostics.summary))")
        }
    }

    // MARK: Steps

    private func run(_ step: DiffStep) async throws {
        switch step {
        case .connect(let name, let session):
            guard attempts[name] == nil else { throw DiffRunFailure("attempt \(name) connected twice") }
            let connection = RecordingConnection(hangBound: diffWaitBound)
            let id = SessionID(session)
            let acceptance = await transport.handleConnection(sessionID: id, connection: connection, authInfo: nil)
            guard acceptance == .accepted else { throw DiffRunFailure("\(name)'s connection was \(acceptance)") }
            let generation = await transport.connectionGeneration(for: id)
            attempts[name] = DiffAttempt(session: id, connection: connection, generation: generation)
            attemptOrder.append(name)

        case .join(let name, let player):
            try startJoin(name, player: player)
            try await settleJoin(name)

        case .refusedJoin(let name, let player):
            try startJoin(name, player: player)
            try await awaitIngress(name)
            // The handshake's refusal is JSON in every encoding: an error or a failed join reply.
            let requestID = "join-\(name)"
            let refused = try await bounded("the refusal frame of \(name)") { [attempt = try self.attempt(name)] in
                await attempt.connection.waitUntilFrames { messages in
                    messages.contains { message in
                        switch message.payload {
                        case .error: return true
                        case .joinResponse(let reply): return reply.requestID == requestID && !reply.success
                        default: return false
                        }
                    }
                }
            }
            guard refused else { throw DiffRunFailure("\(name)'s join got no refusal") }

        case .startJoin(let name, let player):
            try startJoin(name, player: player)

        case .awaitJoin(let name):
            try await settleJoin(name)

        case .awaitIngress(let name):
            try await awaitIngress(name)

        case .bump(let name, let requestID, let amount):
            try send(name, try action(requestID: requestID, DiffBumpAction(amount: amount)))
            try await awaitIngress(name)
            try await applyInputs()

        case .bumpUnsynced(let name, let requestID, let amount):
            try send(name, try action(requestID: requestID, DiffBumpAction(amount: amount)))
            try await awaitIngress(name)
            if cell.land == .tick {
                await keeper.stepTickOnce()
            } else {
                try await bounded("the keeper's input drain") { [keeper] in await keeper.waitForInputDrainIdleForTesting() }
            }

        case .held(let name, let requestID, let key):
            try send(name, try action(requestID: requestID, DiffHeldAction(key: key)))
            try await awaitIngress(name)
            pendingAnswers += 1
            // The gate's own bound (`testHangBound`) ends this wait with false.
            let arrived = await DiffGates.gate(key).waitForArrivals(1)
            if !arrived {
                let frames = await (try attempt(name)).connection.frames.map { String(decoding: $0.prefix(200), as: UTF8.self) }
                throw DiffRunFailure("resolver \(key) never ran; \(name) received \(frames)")
            }

        case .openGate(let key):
            DiffGates.gate(key).open()

        case .settleJobsBeforeAnswers(let hold):
            try await bounded("the action jobs") { [keeper] in await keeper.waitForActionJobsForTesting() }
            guard let gate = holds.gate(hold) else { throw DiffRunFailure("\(hold) was never armed") }
            let reached = try await bounded("\(hold)") { await gate.waitForArrivals(1) }
            guard reached else { throw DiffRunFailure("\(hold) wasn't reached before the sync") }
            try await applyInputs()

        case .settleJobs:
            try await bounded("the action jobs") { [keeper] in await keeper.waitForActionJobsForTesting() }
            if pendingAnswers > 0 {
                let count = pendingAnswers
                try await bounded("\(count) pending answer(s)") { [adapter] in
                    await adapter.waitForActionResponsesFinishedForTesting(count)
                }
            }
            try await applyInputs()

        case .settleSpawned:
            for task in spawned {
                try await bounded("a spawned task") { await task.value }
            }
            try await bounded("the background syncs") { [adapter] in await adapter.waitForBackgroundSyncsForTesting() }
            try await applyInputs()

        case .tick:
            if cell.land == .tick { try await stepTick() }

        case .flushOutbound:
            try await flushOutbound()

        case .only(_, let selects, let steps):
            guard selects(cell) else { break }
            for inner in steps { try await run(inner) }

        case .awaitSpawned:
            for task in spawned {
                try await bounded("a spawned task") { await task.value }
            }

        case .tickUnsynced:
            if cell.land == .tick { await keeper.stepTickOnce() }

        case .disconnect(let name):
            let attempt = try attempt(name)
            disconnected.insert(name)
            // The frames queued before the disconnect reach their connections first: the
            // disconnect cancels the session's drain and drops its queue, so otherwise whether
            // they're delivered depends on the scheduler. A row about undelivered frames needs a
            // step of its own (a disconnect without this flush): with the writer held, this
            // flush would wait out its bound.
            try await flushOutbound()
            try await bounded("\(name)'s disconnect") { [transport] in
                await transport.handleDisconnection(sessionID: attempt.session)
            }
            // The router forwards the disconnect to the adapter in a task of its own: wait
            // until every forward has returned from the adapter (its leave is submitted by
            // then). Not a count of `disconnectForwarded`: a supersede's server close forwards
            // one too, at a time of its own.
            try await bounded("\(name)'s disconnect forward") { [router] in
                await router.waitForDisconnectForwardsForTesting()
            }
            // The leave is an input: applied before the next step, so the next step's inputs
            // never share its pass.
            try await applyInputs()

        case .startDisconnect(let name):
            let attempt = try attempt(name)
            disconnected.insert(name)
            try await flushOutbound()
            try await bounded("\(name)'s disconnect") { [transport] in
                await transport.handleDisconnection(sessionID: attempt.session)
            }

        case .settleDisconnects:
            try await bounded("the disconnect forwards") { [router] in await router.waitForDisconnectForwardsForTesting() }
            try await applyInputs()

        case .awaitDisconnectForwards:
            try await bounded("the disconnect forwards") { [router] in await router.waitForDisconnectForwardsForTesting() }

        case .startStop:
            guard stopTask == nil, !stopped else { throw DiffRunFailure("the land was stopped twice") }
            stopped = true
            let server = self.server
            stopTask = Task { await server.stopLand(landID: diffLandID) }

        case .awaitStop:
            guard let stopTask else { throw DiffRunFailure("no stop was started") }
            let result = try await bounded("the stop") { await stopTask.value }
            try await checkStop(result)

        case .spawn(let label, let body):
            spawned.append(Task { [self] in await body(self) })
            _ = label

        case .arm(let hold, let arrival):
            holds.arm(hold, arrival: arrival)

        case .observe(let hold):
            holds.observe(hold)

        case .reach(let hold, let count):
            guard let gate = holds.gate(hold) else { throw DiffRunFailure("\(hold) is neither armed nor observed") }
            let reached = try await bounded("\(hold)") { await gate.waitForArrivals(count) }
            guard reached else { throw DiffRunFailure("\(hold) wasn't reached \(count) time(s) (the reach rule)") }

        case .release(let hold):
            guard let gate = holds.gate(hold) else { throw DiffRunFailure("\(hold) was never armed") }
            gate.open()

        case .liveCheckpoint:
            guard live == nil else { throw DiffRunFailure("a second live checkpoint") }
            try await barrier()
            let captured = try await capture()
            try await DiffOracle.convergence(self, captured)
            live = captured

        case .stop:
            try await stop()

        case .check(let name, let body):
            do {
                try await body(self)
            } catch let failure as DiffRunFailure {
                throw DiffRunFailure("check \"\(name)\": \(failure)")
            }

        case .note(let name, let body):
            guard notes[name] == nil else { throw DiffRunFailure("note \"\(name)\" taken twice before a checkpoint") }
            do {
                notes[name] = try await body(self)
            } catch let failure as DiffRunFailure {
                throw DiffRunFailure("note \"\(name)\": \(failure)")
            }
        }
    }

    static func name(of step: DiffStep) -> String {
        switch step {
        case .connect(let name, _): return "connect \(name)"
        case .join(let name, _): return "join \(name)"
        case .refusedJoin(let name, _): return "refused join \(name)"
        case .startJoin(let name, _): return "start join \(name)"
        case .awaitJoin(let name): return "await join \(name)"
        case .awaitIngress(let name): return "await ingress \(name)"
        case .bump(let name, let requestID, _): return "bump \(name) \(requestID)"
        case .bumpUnsynced(let name, let requestID, _): return "bump unsynced \(name) \(requestID)"
        case .held(let name, let requestID, _): return "held action \(name) \(requestID)"
        case .openGate(let key): return "open gate \(key)"
        case .settleJobs: return "settle jobs"
        case .settleJobsBeforeAnswers(let hold): return "settle jobs before answers (\(hold) held)"
        case .settleSpawned: return "settle spawned"
        case .awaitSpawned: return "await spawned"
        case .flushOutbound: return "flush outbound"
        case .only(let label, _, let steps): return "only \(label): \(steps.map(name(of:)).joined(separator: ", "))"
        case .tick: return "tick"
        case .tickUnsynced: return "tick unsynced"
        case .disconnect(let name): return "disconnect \(name)"
        case .startDisconnect(let name): return "start disconnect \(name)"
        case .settleDisconnects: return "settle disconnects"
        case .awaitDisconnectForwards: return "await disconnect forwards"
        case .startStop: return "start stop"
        case .awaitStop: return "await stop"
        case .spawn(let label, _): return "spawn \(label)"
        case .arm(let hold, _): return "arm \(hold)"
        case .observe(let hold): return "observe \(hold)"
        case .reach(let hold, _): return "reach \(hold)"
        case .release(let hold): return "release \(hold)"
        case .liveCheckpoint: return "live checkpoint"
        case .stop: return "stop"
        case .check(let name, _): return "check \(name)"
        case .note(let name, _): return "note \(name)"
        }
    }

    func attempt(_ name: String) throws -> DiffAttempt {
        guard let attempt = attempts[name] else { throw DiffRunFailure("no attempt \(name)") }
        return attempt
    }

    /// The handshake join, always JSON.
    private func startJoin(_ name: String, player: String) throws {
        let frame = try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-\(name)", landType: diffLandType, landInstanceId: diffLandID.instanceId,
            playerID: player, deviceID: nil, metadata: StateUpdateFeature.joinMetadata
        ))
        try send(name, frame)
    }

    /// A frame from `name`'s client, delivered through the transport in a task of its own (the
    /// NIO session handler awaits each frame before the next, and so does the runner).
    private func send(_ name: String, _ frame: Data) throws {
        let attempt = try attempt(name)
        if let previous = ingress[name] {
            spawned.append(previous)
        }
        let transport = self.transport
        ingress[name] = Task { await transport.handleIncomingMessage(sessionID: attempt.session, data: frame) }
    }

    private func action<A: ActionPayload>(requestID: String, _ payload: A) throws -> Data {
        let envelope = ActionEnvelope(typeIdentifier: String(describing: A.self), payload: AnyCodable(payload))
        return try cell.encoding.config.makeCodec().encode(TransportMessage.action(requestID: requestID, action: envelope))
    }

    private func awaitIngress(_ name: String) async throws {
        guard let task = ingress[name] else { return }
        try await bounded("\(name)'s frame") { await task.value }
    }

    /// A join's ingress has returned (the router spawns the in-turn flip wait and returns), the
    /// inputs it submitted are applied, and its flip has settled.
    private func settleJoin(_ name: String) async throws {
        try await awaitIngress(name)
        try await applyInputs()
        try await bounded("no pending flip after \(name)'s join") { [router] in
            await router.waitForNoPendingFlipForTesting()
        }
    }

    /// Applies what the last step submitted, as the loops would (they are off): on a tick land
    /// one tick, then the sync cycle; on a tickless land the input's own drain (the ingress
    /// returns once the input is submitted), then the sync cycle. The sync loop is off too, so
    /// in either sync mode an applied change reaches the clients only through this cycle.
    private func applyInputs() async throws {
        if cell.land == .tick {
            try await stepTick()
            return
        }
        try await bounded("the keeper's input drain") { [keeper] in await keeper.waitForInputDrainIdleForTesting() }
        try await sync()
    }

    /// One tick and the sync cycle after it: the tick loop and the sync loop, once each.
    private func stepTick() async throws {
        try await drainWriter(.tick)
        await keeper.stepTickOnce()
        try await sync()
    }

    /// One sync cycle, and the retry a skipped one schedules in the background (a cycle in
    /// flight, or the writer's backlog): with the loops off nothing else would order it.
    private func sync() async throws {
        try await drainWriter(.beforeSync)
        await adapter.syncNow()
        try await bounded("the background syncs") { [adapter] in await adapter.waitForBackgroundSyncsForTesting() }
        try await drainWriter(.afterSync)
    }

    /// The writer holds no sync cycle element: a sync phase run next can't find it busy, so no
    /// run's phases depend on how fast the connections took the frames (#908, #917).
    private func drainWriter(_ site: DiffDrainSite) async throws {
        if let observer = drainObserverForTesting { await observer(self, site) }
        try await bounded("the writer's sync cycle drain") { [writer = adapter.outboundWriter] in
            await writer.waitForSyncCycleDrain()
        }
    }

    // MARK: Checkpoints

    /// The capture barrier (plan §5.3), in dependency order.
    func barrier() async throws {
        // 1. The scenario's own work: its frames' tasks, and every flip settled.
        for (name, task) in ingress {
            try await bounded("\(name)'s frame") { await task.value }
        }
        for task in spawned {
            try await bounded("a spawned task") { await task.value }
        }
        try await bounded("no pending flip") { [router] in await router.waitForNoPendingFlipForTesting() }
        // A supersede closes the old connection behind the frames queued for it (#909): the
        // writer hands the close to the transport, whose drain closes the connection at its
        // marker, after telling the router of the disconnect. A zero forward count can precede
        // that, so the closes come first: each superseded connection is waited for until it has
        // its 4017. A writer-idle wait alone isn't enough: the transport's queue may not have
        // sent the frames ahead of the marker yet. The connection is found by the session and
        // the generation recorded when it was accepted, never by what the transport holds now:
        // while the marker's close runs, the transport has already removed the session's queue
        // (its leave runs before the close frame goes out). Only an attempt the scenario
        // disconnected is skipped: its queue was retired, so its marker is never read. A close
        // the writer refused went out from a task (`waitForDetachedClosesForTesting`).
        try await bounded("the supersedes' fallback closes") { [adapter] in await adapter.waitForDetachedClosesForTesting() }
        try await bounded("outbound idle") { [adapter] in await adapter.waitForOutboundIdleForTesting() }
        for (session, generation) in await adapter.queuedClosesForTesting() {
            guard let name = attemptOrder.last(where: {
                attempts[$0]?.session == session && (generation == nil || attempts[$0]?.generation == generation)
            }), !disconnected.contains(name), let connection = attempts[name]?.connection else { continue }
            guard try await bounded("\(name)'s 4017 close", { await connection.waitUntilClosed() }) else {
                throw DiffRunFailure("\(name)'s superseded connection wasn't closed")
            }
            // A stopped land's 4014 can close it first.
            let code = await connection.closeCode
            guard stopped || code == SessionClose.Code.superseded else {
                throw DiffRunFailure("\(name)'s superseded connection closed with \(String(describing: code))")
            }
        }
        try await bounded("the disconnect forwards") { [router] in await router.waitForDisconnectForwardsForTesting() }
        guard !stopped else {
            try await bounded("the transport's queues") { [transport] in await transport.flushSessionQueues() }
            return
        }
        // 2. The adapter settles, twice: a drain can start a sync after the first pass.
        for _ in 0..<2 {
            for attempt in attempts.values {
                try await bounded("\(attempt.session)'s inbound drain") { [adapter] in
                    await adapter.waitForInboundDrainForTesting(attempt.session)
                }
            }
            if pendingAnswers > 0 {
                let count = pendingAnswers
                try await bounded("\(count) pending answer(s)") { [adapter] in
                    await adapter.waitForActionResponsesFinishedForTesting(count)
                }
            }
            let quiet = try await bounded("sync quiescence") { [adapter] in await adapter.waitForSyncQuiescenceForTesting() }
            guard quiet else { throw DiffRunFailure("the adapter's sync work didn't settle") }
        }
        // 3. The outbound writer is idle; 4. every queued frame reached its connection.
        try await bounded("outbound idle") { [adapter] in await adapter.waitForOutboundIdleForTesting() }
        try await bounded("the transport's queues") { [transport] in await transport.flushSessionQueues() }
    }

    /// The outbound writer is idle and every queued frame reached its connection.
    private func flushOutbound() async throws {
        try await bounded("outbound idle") { [adapter] in await adapter.waitForOutboundIdleForTesting() }
        try await bounded("the transport's queues") { [transport] in await transport.flushSessionQueues() }
    }

    private func capture() async throws -> DiffCapture {
        var connections: [String: DiffConnectionCapture] = [:]
        for (name, attempt) in attempts {
            let connection = attempt.connection
            let frames = try await connection.frames.map { try DiffFrame(bytes: $0) }
            let close: DiffClose? = await connection.closed
                ? DiffClose(code: await connection.closeCode ?? 0, reason: await connection.closeReason ?? "")
                : nil
            connections[name] = DiffConnectionCapture(frames: frames, close: close)
        }
        let taken = notes
        notes = [:]
        return DiffCapture(connections: connections, notes: taken.isEmpty ? nil : taken)
    }

    /// Stops the land and waits for its stop to finish; one that passes its bound fails the run.
    private func stop() async throws {
        guard !stopped else { throw DiffRunFailure("the land was stopped twice") }
        stopped = true
        try await checkStop(await server.stopLand(landID: diffLandID))
    }

    private func checkStop(_ result: StopLandResult) async throws {
        guard result == .stopped(timedOut: false) else { throw DiffRunFailure("the stop ended \(result)") }
        let atBound = await transport.finalFrameClosesAtBound
        guard atBound == 0 else { throw DiffRunFailure("\(atBound) final-frame close(s) ended at their bound") }
    }

    private func saveRecord() async throws -> DiffRecordCapture {
        await keeper.waitForRecorderSubmissionsForTesting()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("differential-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("record.sstr").path
        try await recorder.saveCopyForTesting(to: path)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let contents = try ReevaluationRecordLog.decodeForTesting(Array(bytes))
        return DiffRecordCapture(bytes: bytes, decoded: try Self.decodedView(contents), complete: contents.completeness == .complete)
    }

    /// The record's decoded view: its metadata and frames as JSON, its completeness and flag.
    static func decodedView(_ contents: ReevaluationRecordLogContents) throws -> DiffValue {
        struct View: Encodable {
            let metadata: ReevaluationRecordMetadata
            let frames: [ReevaluationTickFrame]
            let completeness: String
            let holdsNonNFCText: Bool
        }
        let completeness: String
        switch contents.completeness {
        case .complete: completeness = "complete"
        case .incomplete(let reason, let tick): completeness = "incomplete: \(reason) \(tick.map(String.init) ?? "-")"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(View(
            metadata: contents.metadata, frames: contents.frames,
            completeness: completeness, holdsNonNFCText: contents.holdsNonNFCText
        ))
        return try payloadsAsTrees(DiffValue.fromJSON(data))
    }

    /// Rule `recordPayloadAsTree` (#700 K1a, plan §3.11): each action's and client event's 3.7
    /// payload in the view is its tree (the bytes decoded with their encoding), in the form a 3.6
    /// record's tree has, and the entry's `payloadEncoding` is left out. Canonical JSON bytes are
    /// the same within one toolchain only, so off the pinned image the view must not hold a
    /// payload's spelling; the byte comparison on the pinned image still sees the bytes.
    ///
    /// Leaving `payloadEncoding` out is on purpose: the view compares what a payload holds, so a
    /// JSON and a MessagePack payload holding the same value compare equal in decoded-only mode.
    /// The header's `payloadEncoding` is still compared, and the bytes are, on the pinned image.
    static func payloadsAsTrees(_ view: DiffValue) throws -> DiffValue {
        guard case .object(var root) = view, case .array(let frames)? = root["frames"] else { return view }
        root["frames"] = .array(try frames.map { frame in
            guard case .object(var fields) = frame else { return frame }
            for key in ["actions", "clientEvents", "serverInputs"] {
                guard case .array(let entries)? = fields[key] else { continue }
                // A server input's bytes are canonical MessagePack whatever the header says (K1-Q4 (a)).
                fields[key] = .array(try entries.map { try payloadAsTree($0, isServerInput: key == "serverInputs") })
            }
            return .object(fields)
        })
        return .object(root)
    }

    private static func payloadAsTree(_ entry: DiffValue, isServerInput: Bool) throws -> DiffValue {
        guard case .object(var fields) = entry, case .string(let base64)? = fields["payload"] else { return entry }
        // A 3.7 payload is base64 in the view; anything else is a record this rule can't show.
        guard let bytes = Data(base64Encoded: base64) else {
            throw DiffRunFailure("a recorded payload in the record view isn't base64: \(base64.prefix(40))")
        }
        var encoding: RecordPayloadEncoding?
        if case .string(let name)? = fields["payloadEncoding"] { encoding = RecordPayloadEncoding(rawValue: name) }
        // A server input reads with the record codec, as live and replay do, at its own depth.
        let tree = isServerInput
            ? try RecordedPayloadTree.serverInputTree(bytes)
            : try RecordedPayloadTree.tree(bytes, encoding: encoding)
        fields["payload"] = try DiffValue.fromJSON(JSONEncoder().encode(tree))
        fields["payloadEncoding"] = nil
        return .object(fields)
    }

    /// Opens every gate, stops the land if it still runs, closes the connections and awaits
    /// the run's tasks, each under its own bound. Work left past the bounds touches only this
    /// run's instances.
    private func cleanUp() async {
        // A forcing row's back-pressure goes first: with it in place, a writer-drain retry the
        // opened holds let run would wait on it forever.
        await adapter.setWriterBackPressureOverrideForTesting(nil)
        holds.openAll()
        DiffGates.openAll()
        if !stopped {
            stopped = true
            _ = try? await bounded("the cleanup stop") { [server] in await server.stopLand(landID: diffLandID) }
        }
        for attempt in attempts.values {
            _ = try? await bounded("the cleanup disconnect") { [transport] in
                await transport.handleDisconnection(sessionID: attempt.session)
            }
        }
        if let stopTask { _ = try? await bounded("the started stop at cleanup") { await stopTask.value } }
        for task in Array(ingress.values) + spawned {
            _ = try? await bounded("a task at cleanup") { await task.value }
        }
    }
}

/// `work`, or a failure naming `what` once `diffWaitBound` passes.
func bounded<T: Sendable>(_ what: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    switch await raceDeadline(diffWaitBound, work) {
    case .finished(let result): return try result.get()
    case .timedOut: throw DiffRunFailure("\(what) didn't finish within \(diffWaitBound)")
    }
}
#endif
