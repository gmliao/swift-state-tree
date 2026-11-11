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
    /// - Throws: `SyncPolicyNestingError` from `LandTypeRegistry.init` (#179).
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
    ///    joining is refused;
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
        let flight = stops.flight(for: landID, timeout: stopTimeout) {
            await Self.runStop(landID: landID, landManager: landManager, landRouter: landRouter, logger: logger)
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
    private static func runStop(
        landID: LandID,
        landManager: LandManager<State>,
        landRouter: LandRouter<State>,
        logger: Logger
    ) async -> StopLandResult {
        guard let instance = await landManager.detachForStop(landID: landID) else { return .notFound }
        logger.info("Stopping land", metadata: [
            "landID": .string(landID.stringValue),
            "epoch": .stringConvertible(instance.epoch),
        ])
        await landRouter.closeSessions(boundTo: instance.epoch, close: .landStopped)
        await instance.keeper.forceShutdown()
        withExtendedLifetime(instance.adapter) {}
        logger.info("Stopped land", metadata: ["landID": .string(landID.stringValue)])
        return .stopped(timedOut: false)
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
final class LandStopFlights: @unchecked Sendable {
    struct Flight: Sendable {
        let task: Task<StopLandResult, Never>
        /// The stop's bound, counted from its start.
        let deadline: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var flights: [LandID: (id: UInt64, flight: Flight)] = [:]
    private var nextID: UInt64 = 0
    private var onSharedHook: (@Sendable (LandID) -> Void)?

    /// Called when a request shares a stop already in flight (tests).
    func onSharedForTesting(_ hook: (@Sendable (LandID) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        onSharedHook = hook
    }

    /// The stop in flight for `landID`, or a new one running `body`.
    func flight(
        for landID: LandID,
        timeout: Duration,
        _ body: @escaping @Sendable () async -> StopLandResult
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
        let task = Task {
            let result = await body()
            self.finish(landID, id: id)
            return result
        }
        let flight = Flight(task: task, deadline: .now + timeout)
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
