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
    
    public func removeLand(landID: LandID) async {
        await landManager.removeLand(landID: landID)
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
    /// Ends the session tickets of lands whose destroy was abandoned, so their sync and
    /// outbound writer stop issuing frames. Returns how many it reached.
    func endSessions(ofAbandoned landIDs: Set<LandID>) async -> Int
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

    func endSessions(ofAbandoned landIDs: Set<LandID>) async -> Int {
        var reached = 0
        for landID in landIDs {
            guard let container = await landManager.getLand(landID: landID) else { continue }
            await container.transportAdapter.endSessionTicketsForTeardown()
            reached += 1
        }
        return reached
    }

    func stopTransport() async {
        // 1001, as every session closed by the shutdown (decision A1).
        await transport.stop(closingWith: .goingAway)
    }
}
