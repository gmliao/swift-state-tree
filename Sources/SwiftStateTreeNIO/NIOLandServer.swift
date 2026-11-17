// Sources/SwiftStateTreeNIO/NIOLandServer.swift
//
// NIO-based LandServer implementation conforming to LandServerProtocol.

import Foundation
import Logging
import NIOCore
import SwiftStateTree
import SwiftStateTreeTransport

/// NIO-based LandServer that conforms to LandServerProtocol.
///
/// This provides the same interface as the Hummingbird LandServer,
/// allowing it to be registered with LandRealm for multi-land management.
public struct NIOLandServer<State: StateNodeProtocol>: LandServerProtocol, Sendable {
    public let landManager: LandManager<State>
    public let transport: WebSocketTransport
    public let landRouter: LandRouter<State>
    public let landType: String
    
    private let logger: Logger
    /// The bound on one land stop (#102): the host's `shutdownTimeout`.
    private let stopTimeout: Duration
    /// One stop per land ID at a time, shared by the requests that arrive during it.
    private let stops = LandStopFlights()
    
    /// Create a NIOLandServer.
    ///
    /// - Parameters:
    ///   - landType: Unique identifier for this land type.
    ///   - landFactory: Factory for creating LandDefinition instances.
    ///   - initialStateFactory: Factory for creating initial state.
    ///   - configuration: Server configuration.
    ///   - transport: Shared WebSocketTransport instance.
    /// - Throws: `SyncValueSemanticsError` (#464) or `SyncPolicyNestingError` (#179) from
    ///   `LandTypeRegistry.init`.
    public init(
        landType: String,
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        configuration: NIOLandServerConfiguration,
        transport: WebSocketTransport
    ) throws {
        self.landType = landType
        self.transport = transport
        self.logger = configuration.logger ?? Logger(label: "com.swiftstatetree.nio.server.\(landType)")
        self.stopTimeout = configuration.landStopTimeout
        
        // Create LandManager
        self.landManager = LandManager<State>(
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            servicesFactory: configuration.servicesFactory,
            transport: transport,
            createGuestSession: configuration.createGuestSession,
            authenticatesPlayers: configuration.authenticatesPlayers,
            transportEncoding: configuration.effectiveTransportEncoding.effective(pathHashes: configuration.pathHashes),
            enableLiveStateHashRecording: configuration.enableLiveStateHashRecording,
            pathHashes: configuration.pathHashes,
            eventHashes: configuration.eventHashes,
            clientEventHashes: configuration.clientEventHashes,
            keeperModeResolver: configuration.keeperModeResolver,
            enableLoopPhaseOffset: configuration.enableLoopPhaseOffset,
            inTurnSync: configuration.inTurnSync,
            syncLagPolicy: configuration.syncLag,
            logger: configuration.logger
        )
        
        // Create LandTypeRegistry
        let registry = try LandTypeRegistry<State>(
            landFactory: { (_: String, landID: LandID) in landFactory(landID) },
            initialStateFactory: { (_: String, landID: LandID) in initialStateFactory(landID) },
            replayLandSuffix: configuration.replayLandSuffix
        )
        
        // Create LandRouter
        self.landRouter = LandRouter<State>(
            landManager: landManager,
            landTypeRegistry: registry,
            transport: transport,
            createGuestSession: configuration.createGuestSession,
            authenticatesPlayers: configuration.authenticatesPlayers,
            allowAutoCreateOnJoin: configuration.allowAutoCreateOnJoin,
            transportEncoding: configuration.effectiveTransportEncoding.effective(pathHashes: configuration.pathHashes),
            logger: configuration.logger
        )

        // A failed land is stopped by this server (#535 B2): its sessions close with 4016 and
        // it detaches, as an admin stop does. Set before any land exists.
        let landManager = self.landManager
        let landRouter = self.landRouter
        let stops = self.stops
        let logger = self.logger
        let stopTimeout = self.stopTimeout
        // Weak: the manager holds the slot, and the slot this closure (no cycle). A land's
        // failure after its server is gone has no host to stop it: its adapter closes its
        // sessions itself (`landDidFail`'s fallback).
        landManager.landFailureStop.set { [weak landManager, weak landRouter] landID, epoch in
            guard let landManager, let landRouter else { return false }
            await Self.stopForFailure(
                landID: landID, epoch: epoch, landManager: landManager, landRouter: landRouter,
                stops: stops, timeout: stopTimeout, logger: logger
            )
            return true
        }
    }
    
    // MARK: - LandServerProtocol
    
    /// Shuts this land type down without a time bound: stops accepting, closes every session
    /// with 1001 after its leave ran (OnLeave included), then destroys every land through the
    /// normal path (destroy handlers, the save on destroy, `onLandDestroyed`). `NIOLandHost`
    /// runs the same steps itself, each bounded (#351).
    public func shutdown() async throws {
        logger.info("Shutting down NIOLandServer", metadata: ["landType": .string(landType)])
        await stopAccepting()
        await closeSessionsForShutdown(progress: ShutdownLeaveProgress())
        await destroyLandsForShutdown(progress: ShutdownLandProgress())
    }
    
    public func healthCheck() async -> Bool {
        // Basic health check - server is running
        return true
    }
    
    public func listLands() async -> [LandID] {
        await landManager.listLands()
    }
    
    public func getLandStats(landID: LandID) async -> LandStats? {
        await landManager.getLandStats(landID: landID)
    }
    
    /// Stops the land with this ID (the admin API's `DELETE /admin/lands/:landID`, #102):
    /// 1. detaches its instance, marked stopping, so a join for the ID waits for its destroy and
    ///    then gets a fresh instance (with auto-create), or finds nothing (without);
    /// 2. closes the sessions bound to that instance with 4014 (`SessionClose.Code.landStopped`)
    ///    after each one's leave ran (OnLeave included), as a shutdown does; a session still
    ///    joining is refused. A session whose close request is issued after the land failed
    ///    gets 4016 (`landFailed`) instead, and its leave runs no OnLeave (#535);
    /// 3. destroys it through the normal path (destroy handlers, the save, `onLandDestroyed`).
    ///
    /// The steps run in the stop's own task: a caller that is cancelled or gives up stops only
    /// its wait, and the land is always destroyed. Concurrent calls for one ID share that stop
    /// and its result. The wait is bounded by the host's `shutdownTimeout`, counted from the
    /// stop's start; past it the result is `.stopped(timedOut: true)` and the stop goes on in
    /// the background, as an abandoned shutdown destroy does. A cancelled caller gets the same
    /// result at once: it stopped waiting, and the stop goes on.
    public func stopLand(landID: LandID) async -> StopLandResult {
        let landManager = self.landManager
        let landRouter = self.landRouter
        let logger = self.logger
        let flight = stops.flight(for: landID, epoch: nil, timeout: stopTimeout) { [stops] detached in
            await Self.runStop(
                landID: landID, epoch: nil, landManager: landManager, landRouter: landRouter,
                stops: stops, detached: detached, logger: logger
            )
        }
        let wait = StopWait()
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<StopWait.Outcome, Never>) in
                wait.install(continuation)
                Task { wait.settle(.finished(await flight.task.value)) }
                wait.setTimer(Task {
                    // A cancelled sleep: the stop or a cancellation settled first.
                    guard (try? await safeTaskSleep(for: flight.deadline - .now)) != nil else { return }
                    wait.settle(.timedOut)
                })
            }
        } onCancel: {
            wait.settle(.cancelled)
        }
        switch outcome {
        case .finished(let result):
            return result
        case .timedOut:
            logger.warning("Land stop passed its bound; it goes on in the background", metadata: [
                "landID": .string(landID.stringValue),
                "timeout": .stringConvertible(stopTimeout),
            ])
            return .stopped(timedOut: true)
        case .cancelled:
            return .stopped(timedOut: true)
        }
    }

    /// The stop flights (tests).
    var stopFlightsForTesting: LandStopFlights { stops }

    /// The stop's steps, in its own task. Holds the instance (keeper and adapter) until its
    /// destroy has run, so the manager's weak entry can't be released before its drop. Nothing
    /// here throws: the destroy always runs once the instance is detached.
    ///
    /// With `epoch` (a failed land's stop), it detaches only the instance with that epoch. The
    /// detach creates the epoch's sessions-closed latch in its own segment, and `detached` is
    /// set once the detach step ended, whatever it found; the latch is set once the sessions are
    /// closed, before the destroy, and removed (by epoch) after it.
    private static func runStop(
        landID: LandID,
        epoch: Epoch?,
        landManager: LandManager<State>,
        landRouter: LandRouter<State>,
        stops: LandStopFlights,
        detached: StopDetach,
        logger: Logger
    ) async -> StopLandResult {
        let instance = await landManager.detachForStop(landID: landID, epoch: epoch) { detachedEpoch in
            stops.createLatch(for: detachedEpoch)
        }
        detached.set(instance?.epoch)
        guard let instance else { return .notFound }
        logger.info("Stopping land", metadata: [
            "landID": .string(landID.stringValue),
            "epoch": .stringConvertible(instance.epoch),
        ])
        let latch = stops.latch(for: instance.epoch)
        let keeper = instance.keeper
        // The code is the land's cause as of each session's close request (#535 D10).
        await landRouter.closeSessions(boundTo: instance.epoch) {
            keeper.destructionCause == .failed ? .landFailed : .landStopped
        }
        latch?.set()
        await stops.afterSessionsClosedForTesting(instance.epoch)
        await instance.keeper.forceShutdown()
        await landRouter.endClosing(epoch: instance.epoch)
        if let latch { stops.removeLatch(for: instance.epoch, ifIdenticalTo: latch) }
        await stops.afterDestroyForTesting(instance.epoch)
        withExtendedLifetime(instance.adapter) {}
        logger.info("Stopped land", metadata: ["landID": .string(landID.stringValue)])
        return .stopped(timedOut: false)
    }

    /// A failed land's stop (#535 B2), from its adapter's `landDidFail`: returns once the
    /// instance with `epoch` has its sessions closed, never after its destroy (the stop's
    /// `forceShutdown` joins the failed land's teardown, which waits for this call).
    ///
    /// - A stop that already detached the epoch (an admin `DELETE`) has its latch: wait for it,
    ///   set at once if that stop is past its sessions.
    /// - Otherwise it starts the stop for the epoch, or shares the one in flight for the ID, and
    ///   waits for its detach step. If that stop detached this epoch, it waits for the latch.
    /// - A shared stop that detached another instance of the ID (or none) isn't this epoch's. If
    ///   this epoch is no longer stored and has no latch, no stop will close its sessions, and
    ///   it returns at once; otherwise it waits for that stop's end, which doesn't depend on
    ///   this land, then runs its own.
    /// - Its own stop finding no instance: nothing will close this epoch's sessions (the
    ///   instance isn't stored any more), and it returns at once.
    ///
    /// None of these waits depend on this land's destroy, so the teardown can't wait on itself.
    ///
    /// Once a host shutdown's `closeSessionsForShutdown` has taken the sessions for its own
    /// close (1001), this stop finds none bound, and they close with 1001, not 4016: the
    /// shutdown's code.
    private static func stopForFailure(
        landID: LandID,
        epoch: Epoch,
        landManager: LandManager<State>,
        landRouter: LandRouter<State>,
        stops: LandStopFlights,
        timeout: Duration,
        logger: Logger
    ) async {
        if let latch = stops.latch(for: epoch) {
            await latch.wait()
            return
        }
        logger.error("Stopping a failed land", metadata: [
            "landID": .string(landID.stringValue),
            "epoch": .stringConvertible(epoch),
        ])
        while true {
            let flight = stops.flight(for: landID, epoch: epoch, timeout: timeout) { [stops] detached in
                await Self.runStop(
                    landID: landID, epoch: epoch, landManager: landManager, landRouter: landRouter,
                    stops: stops, detached: detached, logger: logger
                )
            }
            let detachedEpoch = await flight.detached.wait()
            // This epoch's latch: the shared stop, or another one meanwhile, detached it.
            if let latch = stops.latch(for: epoch) {
                await latch.wait()
                return
            }
            if detachedEpoch == epoch || flight.epoch == epoch { return }
            // Another instance's stop. This epoch no longer stored: no stop will detach it, so
            // none will raise its latch (checked after, since only a detach creates one).
            if !(await landManager.isStored(landID: landID, epoch: epoch)), stops.latch(for: epoch) == nil {
                return
            }
            // Its end doesn't wait on this land.
            _ = await flight.task.value
        }
    }
    
    public func getReevaluationRecord(landID: LandID) async throws -> Data? {
        guard let container = await landManager.getLand(landID: landID) else { return nil }
        guard let recorder = await container.keeper.getReevaluationRecorder() else { return nil }
        return try await recorder.encode()
    }

    public func debugFreeze(landID: LandID) async throws -> DebugFreezeResponse? {
        guard let container = await landManager.getLand(landID: landID) else { return nil }
        return try await container.transportAdapter.debugFreeze()
    }

    public func debugProjection(landID: LandID, playerID: PlayerID?) async throws -> DebugProjectionResponse? {
        guard let container = await landManager.getLand(landID: landID) else { return nil }
        return try await container.transportAdapter.debugProjection(playerID: playerID)
    }

    public func debugResume(landID: LandID, freezeToken: String) async -> DebugResumeResponse? {
        guard let container = await landManager.getLand(landID: landID) else { return nil }
        return await container.transportAdapter.debugResume(freezeToken: freezeToken)
    }
}

// MARK: - Host shutdown steps (#351)

/// One registered land type's part in a host shutdown, step by step; the host bounds each step.
protocol HostShutdownParticipant: Sendable {
    var landType: String { get }
    /// Joins and new connections are refused, and creations rejected, from here on.
    func stopAccepting() async
    /// Every session closed with 1001, each joined one after its leave ran.
    func closeSessionsForShutdown(progress: ShutdownLeaveProgress) async
    /// Every land destroyed through the normal path; `progress` names the unfinished ones.
    func destroyLandsForShutdown(progress: ShutdownLandProgress) async
    /// Creations still in progress: their land, if they publish one, got no destroy.
    func creationsUnfinished() async -> Int
    /// Ends the session tickets of land instances whose destroy was abandoned, so their sync and
    /// outbound writer stop issuing frames. Each instance by its epoch, a detached one included
    /// (#390). Returns how many it reached.
    func endSessions(ofAbandoned instances: Set<ShutdownLandProgress.Key>) async -> Int
    /// Closes whatever the transport still holds.
    func stopTransport() async
}

extension NIOLandServer: HostShutdownParticipant {
    func stopAccepting() async {
        await landRouter.stopAccepting()
        await landManager.stopCreations()
    }

    func closeSessionsForShutdown(progress: ShutdownLeaveProgress) async {
        await landRouter.closeSessionsForShutdown(progress: progress)
    }

    func destroyLandsForShutdown(progress: ShutdownLandProgress) async {
        // Each land on its own, as soon as it is known: the stored and detached lands now, each
        // creation's land when that creation ends. One hung destroy or creation holds no other
        // land; the host's deadline cuts the step, and what didn't finish is counted then.
        let listing = await landManager.beginShutdown()
        let late = await landManager.creationLandsForShutdown()
        await withTaskGroup(of: Void.self) { group in
            for land in listing.all {
                destroy(land, in: &group, progress: progress)
            }
            for await land in late {
                destroy(land, in: &group, progress: progress)
            }
        }
    }

    private func destroy(_ land: LandManager<State>.ShutdownLand, in group: inout TaskGroup<Void>, progress: ShutdownLandProgress) {
        progress.started(land.landID, epoch: land.epoch)
        group.addTask {
            // Joins a destruction already in progress (an empty-room timer that fired).
            await land.keeper.forceShutdown()
            progress.finished(land.landID, epoch: land.epoch)
        }
    }

    func creationsUnfinished() async -> Int {
        await landManager.creationsInFlight()
    }

    func endSessions(ofAbandoned instances: Set<ShutdownLandProgress.Key>) async -> Int {
        var reached = 0
        for instance in instances {
            guard let adapter = await landManager.adapter(landID: instance.landID, epoch: instance.epoch) else { continue }
            await adapter.endSessionTicketsForTeardown()
            reached += 1
        }
        return reached
    }

    func stopTransport() async {
        // 1001, as every session closed by the shutdown (decision A1).
        await transport.stop(closingWith: .goingAway)
    }
}

/// One land stop per land ID at a time (#102). A request that arrives during a stop shares it:
/// the same task and the same deadline, so the same result. The entry goes when its task ends;
/// a later request starts a new stop (which finds the instance still stopping, a new one, or
/// nothing).
///
/// Beside the flights, each stopped instance's **sessions-closed latch**, by epoch (#535 B2):
/// lasting state, not an event. It is created in the detach's segment, set once the stop closed
/// the instance's sessions, and removed by the stop that created it, by epoch, after the
/// destroy; a waiter holding it is unaffected. A failed land's teardown waits on it.
final class LandStopFlights: @unchecked Sendable {
    struct Flight: Sendable {
        let task: Task<StopLandResult, Never>
        /// The stop's bound, counted from its start.
        let deadline: ContinuousClock.Instant
        /// The epoch this stop was started for (a failed land's), or nil (an admin stop).
        let epoch: Epoch?
        /// Set once the stop's detach step ended, with the epoch it detached (nil: none).
        let detached: StopDetach
    }

    private let lock = NSLock()
    private var flights: [LandID: (id: UInt64, flight: Flight)] = [:]
    private var latches: [Epoch: StopLatch] = [:]
    private var nextID: UInt64 = 0
    private var onSharedHook: (@Sendable (LandID) -> Void)?
    private var afterSessionsClosedHook: (@Sendable (Epoch) async -> Void)?
    private var afterDestroyHook: (@Sendable (Epoch) async -> Void)?

    /// Called by a stop after its destroy, before its flight ends (tests).
    func onAfterDestroyForTesting(_ hook: (@Sendable (Epoch) async -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        afterDestroyHook = hook
    }

    func afterDestroyForTesting(_ epoch: Epoch) async {
        let hook: (@Sendable (Epoch) async -> Void)? = {
            lock.lock(); defer { lock.unlock() }
            return afterDestroyHook
        }()
        await hook?(epoch)
    }

    /// Creates the epoch's sessions-closed latch (in the detach's segment), or returns it.
    @discardableResult
    func createLatch(for epoch: Epoch) -> StopLatch {
        lock.lock(); defer { lock.unlock() }
        if let existing = latches[epoch] { return existing }
        let latch = StopLatch()
        latches[epoch] = latch
        return latch
    }

    /// The epoch's sessions-closed latch, while its stop runs.
    func latch(for epoch: Epoch) -> StopLatch? {
        lock.lock(); defer { lock.unlock() }
        return latches[epoch]
    }

    /// Removes the epoch's latch if it is still `latch` (its stop's own).
    func removeLatch(for epoch: Epoch, ifIdenticalTo latch: StopLatch) {
        lock.lock(); defer { lock.unlock() }
        if latches[epoch] === latch { latches[epoch] = nil }
    }

    /// Latches held (tests).
    var latchCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return latches.count
    }

    /// Called by a stop after it set its latch, before its destroy (tests).
    func onAfterSessionsClosedForTesting(_ hook: (@Sendable (Epoch) async -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        afterSessionsClosedHook = hook
    }

    func afterSessionsClosedForTesting(_ epoch: Epoch) async {
        let hook: (@Sendable (Epoch) async -> Void)? = {
            lock.lock(); defer { lock.unlock() }
            return afterSessionsClosedHook
        }()
        await hook?(epoch)
    }

    /// Called when a request shares a stop already in flight (tests).
    func onSharedForTesting(_ hook: (@Sendable (LandID) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        onSharedHook = hook
    }

    /// The stop in flight for `landID`, or a new one running `body`.
    func flight(
        for landID: LandID,
        epoch: Epoch?,
        timeout: Duration,
        _ body: @escaping @Sendable (StopDetach) async -> StopLandResult
    ) -> Flight {
        lock.lock()
        if let existing = flights[landID] {
            let hook = onSharedHook
            lock.unlock()
            hook?(landID)
            return existing.flight
        }
        defer { lock.unlock() }
        nextID += 1
        let id = nextID
        // The task's end takes the lock, so it removes the entry only after it is stored.
        let detached = StopDetach()
        let task = Task {
            let result = await body(detached)
            // A body that returned early still ends its detach step.
            detached.set(nil)
            self.finish(landID, id: id)
            return result
        }
        let flight = Flight(task: task, deadline: .now + timeout, epoch: epoch, detached: detached)
        flights[landID] = (id, flight)
        return flight
    }

    private func finish(_ landID: LandID, id: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if flights[landID]?.id == id { flights[landID] = nil }
    }
}

/// A caller's wait on a stop: the stop's result, its deadline, or the caller's cancellation,
/// whichever comes first. The first settles; a cancellation before the continuation is installed
/// is kept and resumes it at install.
private final class StopWait: @unchecked Sendable {
    enum Outcome: Sendable {
        case finished(StopLandResult)
        case timedOut
        case cancelled
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var settled: Outcome?
    private var resumed = false
    private var timer: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Outcome, Never>) {
        lock.lock()
        if let settled {
            resumed = true
            lock.unlock()
            continuation.resume(returning: settled)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setTimer(_ task: Task<Void, Never>) {
        lock.lock()
        let cancelNow = resumed
        if !cancelNow { timer = task }
        lock.unlock()
        if cancelNow { task.cancel() }
    }

    func settle(_ outcome: Outcome) {
        lock.lock()
        guard settled == nil else { lock.unlock(); return }
        settled = outcome
        let continuation = self.continuation
        self.continuation = nil
        if continuation != nil { resumed = true }
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(returning: outcome)
    }
}

/// A set-once completion that callers await (#535 B2): `wait` returns at once once it is set.
final class StopLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func set() {
        lock.lock()
        guard !isSet else { lock.unlock(); return }
        isSet = true
        let waiting = waiters
        waiters.removeAll()
        lock.unlock()
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isSet {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    var isSetForTesting: Bool {
        lock.lock(); defer { lock.unlock() }
        return isSet
    }
}

/// A stop's detach step (#535 B2): set once, with the epoch it detached (nil: none); `wait`
/// returns that epoch once it is set.
final class StopDetach: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Epoch??
    private var waiters: [CheckedContinuation<Epoch?, Never>] = []

    func set(_ epoch: Epoch?) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = .some(epoch)
        let waiting = waiters
        waiters.removeAll()
        lock.unlock()
        waiting.forEach { $0.resume(returning: epoch) }
    }

    func wait() async -> Epoch? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Epoch?, Never>) in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}
