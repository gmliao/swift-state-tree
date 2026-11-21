import Foundation
import Logging
import SwiftStateTree

/// Benchmark and test support, not an integration surface: a land's `TransportAdapter` built and
/// driven directly, without a router or a server, for measurements that time the adapter's own
/// sync path (EncodingBenchmark).
///
/// `TransportAdapter` is a package type. This handle forwards only the calls such a measurement
/// makes, each to the same adapter method, so a measured window runs the same adapter code as
/// before. Each async forward is `nonisolated(nonsending)`: it runs on its caller's executor,
/// so the call reaches the adapter with the same hops as a direct call.
/// The diagnostics forwards keep the adapter's `@_spi(Diagnostics)` level. Applications host
/// lands through `NIOLandHost` or `LandRouter`.
public struct TransportAdapterBenchmarkHandle<State: StateNodeProtocol>: Sendable {
    let adapter: TransportAdapter<State>

    /// An adapter on `keeper`, with no router.
    ///
    /// - Precondition: `keeper` is live. A reevaluation keeper runs headless; the adapter traps
    ///   on one (#612).
    public init(
        keeper: LandKeeper<State>,
        transport: any Transport,
        landID: String,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        enableDirtyTracking: Bool = true,
        transportEnvConfig: TransportEnvConfig? = nil,
        encodingConfig: TransportEncodingConfig? = nil,
        pathHashes: [String: UInt32]? = nil,
        suppressMissingPathHashesWarning: Bool = false,
        logger: Logger? = nil
    ) {
        adapter = TransportAdapter<State>(
            keeper: keeper,
            transport: transport,
            landID: landID,
            createGuestSession: createGuestSession,
            enableDirtyTracking: enableDirtyTracking,
            transportEnvConfig: transportEnvConfig,
            encodingConfig: encodingConfig,
            pathHashes: pathHashes,
            suppressMissingPathHashesWarning: suppressMissingPathHashesWarning,
            logger: logger
        )
    }

    /// The adapter of a land instance a `LandManager` built (a router-driven measurement).
    public init(_ container: LandManager<State>.Container) {
        adapter = container.transportAdapter
    }

    /// The adapter as the keeper's transport (`LandKeeper.setTransport`).
    public var keeperTransport: any LandKeeperTransport { adapter }

    /// The adapter as the transport's delegate (`setDelegate`).
    public var transportDelegate: any TransportDelegate { adapter }

    public var syncConfigForRecord: ReevaluationSyncConfig { adapter.syncConfigForRecord }

    @_spi(Diagnostics) public var effectiveStateUpdateFeatures: [String] { adapter.effectiveStateUpdateFeatures }

    nonisolated(nonsending) public func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo? = nil) async {
        await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: authInfo)
    }

    nonisolated(nonsending) public func onDisconnect(sessionID: SessionID, clientID: ClientID) async {
        await adapter.onDisconnect(sessionID: sessionID, clientID: clientID)
    }

    nonisolated(nonsending) public func onMessage(_ message: Data, from sessionID: SessionID) async {
        await adapter.onMessage(message, from: sessionID)
    }

    /// A join the adapter admitted: the adapter's join result.
    public struct Joined: Sendable {
        public let playerID: PlayerID
        public let sessionID: SessionID
        public let playerSlot: Int32
        /// The join completed in a turn: its JoinResponse and firstSync were sent in a sync
        /// phase's commit, so the caller sends neither.
        public let completedInTurn: Bool
    }

    /// `nil` when the join was denied.
    nonisolated(nonsending) public func performJoin(
        playerSession: PlayerSession,
        clientID: ClientID,
        sessionID: SessionID,
        authInfo: AuthenticatedInfo?
    ) async throws -> Joined? {
        guard let result = try await adapter.performJoin(
            playerSession: playerSession, clientID: clientID, sessionID: sessionID, authInfo: authInfo
        ) else { return nil }
        return Joined(
            playerID: result.playerID, sessionID: result.sessionID,
            playerSlot: result.playerSlot, completedInTurn: result.completedInTurn
        )
    }

    nonisolated(nonsending) public func syncStateForNewPlayer(playerID: PlayerID, sessionID: SessionID) async {
        await adapter.syncStateForNewPlayer(playerID: playerID, sessionID: sessionID)
    }

    nonisolated(nonsending) public func syncNow() async {
        await adapter.syncNow()
    }

    nonisolated(nonsending) public func isDirtyTrackingEnabled() async -> Bool {
        await adapter.isDirtyTrackingEnabled()
    }

    @_spi(Diagnostics) nonisolated(nonsending) public func waitForOutboundDrain(timeout: Duration = .seconds(5)) async -> Bool {
        await adapter.waitForOutboundDrain(timeout: timeout)
    }

    @_spi(Diagnostics) nonisolated(nonsending) public func syncSkipCounts() async -> SyncSkipCounts {
        await adapter.syncSkipCounts()
    }

    @_spi(Diagnostics) nonisolated(nonsending) public func syncLagAckDiagnostics() async -> SyncLagAckDiagnostics {
        await adapter.syncLagAckDiagnostics()
    }

    @_spi(Diagnostics) nonisolated(nonsending) public func framePrefixCacheCounts() async -> FramePrefixCacheCounts {
        await adapter.framePrefixCacheCounts()
    }
}
