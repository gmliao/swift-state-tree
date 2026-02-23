import SwiftStateTree
import SwiftStateTreeReevaluationMonitor
import SwiftStateTreeTransport

public struct ReevaluationFeatureConfiguration: Sendable {
    public var enabled: Bool
    public var replayEventPolicy: ReevaluationReplayEventPolicy
    public var replayLandSuffix: String
    public var monitorLandType: String
    public var monitorWebSocketPath: String
    public var replayWebSocketPathResolver: @Sendable (String) -> String
    public var runnerServiceFactory: @Sendable () -> ReevaluationRunnerService

    public init(
        enabled: Bool,
        replayEventPolicy: ReevaluationReplayEventPolicy = .projectedOnly,
        replayLandSuffix: String = "-replay",
        monitorLandType: String = "reevaluation-monitor",
        monitorWebSocketPath: String = "/reevaluation-monitor",
        replayWebSocketPathResolver: @escaping @Sendable (String) -> String = { replayLandType in
            "/game/\(replayLandType)"
        },
        runnerServiceFactory: @escaping @Sendable () -> ReevaluationRunnerService
    ) {
        self.enabled = enabled
        self.replayEventPolicy = replayEventPolicy
        self.replayLandSuffix = replayLandSuffix
        self.monitorLandType = monitorLandType
        self.monitorWebSocketPath = monitorWebSocketPath
        self.replayWebSocketPathResolver = replayWebSocketPathResolver
        self.runnerServiceFactory = runnerServiceFactory
    }
}

public extension NIOLandHost {
    /// Registers a land with reevaluation using the same live land definition for replay.
    /// Replay path uses the same `LandDefinition`; keeper mode is resolved at runtime via instanceId decode.
    ///
    /// - Parameters:
    ///   - landType: Base land type (e.g. "hero-defense"); replay will be "\(landType)\(replayLandSuffix)".
    ///   - liveLand: The land definition used for both live and replay.
    ///   - liveInitialState: Initial state for live sessions.
    ///   - liveWebSocketPath: WebSocket path for live connections.
    ///   - configuration: Server configuration.
    ///   - reevaluation: Reevaluation feature configuration.
    func registerWithReevaluationSameLand<State: StateNodeProtocol>(
        landType: String,
        liveLand: LandDefinition<State>,
        liveInitialState: @autoclosure @escaping @Sendable () -> State,
        liveWebSocketPath: String,
        configuration: NIOLandServerConfiguration,
        reevaluation: ReevaluationFeatureConfiguration
    ) async throws {
        let effectiveConfiguration: NIOLandServerConfiguration
        if reevaluation.enabled {
            effectiveConfiguration = configuration.injectingReevaluationServices(
                runnerServiceFactory: reevaluation.runnerServiceFactory,
                replayEventPolicy: reevaluation.replayEventPolicy
            )
        } else {
            effectiveConfiguration = configuration
        }

        try await register(
            landType: landType,
            land: liveLand,
            initialState: liveInitialState(),
            webSocketPath: liveWebSocketPath,
            configuration: effectiveConfiguration
        )

        guard reevaluation.enabled else {
            return
        }

        let replayLandType = "\(landType)\(reevaluation.replayLandSuffix)"
        let replayWebSocketPath = reevaluation.replayWebSocketPathResolver(replayLandType)
        let recordsDir = NIOEnvConfig.fromEnvironment().reevaluationRecordsDir

        var replayConfig = effectiveConfiguration.injectingReevaluationKeeperModeResolver(
            replayLandType: replayLandType,
            recordsDir: recordsDir
        )
        replayConfig.replayLandSuffix = reevaluation.replayLandSuffix

        replayLandSuffix = reevaluation.replayLandSuffix

        try await register(
            landType: replayLandType,
            land: liveLand,
            initialState: liveInitialState(),
            webSocketPath: replayWebSocketPath,
            configuration: replayConfig
        )

        if await realm.isRegistered(landType: reevaluation.monitorLandType) == false {
            try await register(
                landType: reevaluation.monitorLandType,
                land: ReevaluationMonitor.makeLand(),
                initialState: ReevaluationMonitorState(),
                webSocketPath: reevaluation.monitorWebSocketPath,
                configuration: effectiveConfiguration
            )
        }
    }

    func registerWithReevaluation<LiveState: StateNodeProtocol, ReplayState: StateNodeProtocol>(
        landType: String,
        liveLand: LandDefinition<LiveState>,
        liveInitialState: @autoclosure @escaping @Sendable () -> LiveState,
        liveWebSocketPath: String,
        replayLand: LandDefinition<ReplayState>,
        replayInitialState: @autoclosure @escaping @Sendable () -> ReplayState,
        configuration: NIOLandServerConfiguration,
        reevaluation: ReevaluationFeatureConfiguration
    ) async throws {
        let effectiveConfiguration: NIOLandServerConfiguration
        if reevaluation.enabled {
            effectiveConfiguration = configuration.injectingReevaluationServices(
                runnerServiceFactory: reevaluation.runnerServiceFactory,
                replayEventPolicy: reevaluation.replayEventPolicy
            )
        } else {
            effectiveConfiguration = configuration
        }

        try await register(
            landType: landType,
            land: liveLand,
            initialState: liveInitialState(),
            webSocketPath: liveWebSocketPath,
            configuration: effectiveConfiguration
        )

        guard reevaluation.enabled else {
            return
        }

        let replayLandType = "\(landType)\(reevaluation.replayLandSuffix)"
        let replayWebSocketPath = reevaluation.replayWebSocketPathResolver(replayLandType)

        var replayConfigForDifferentState = effectiveConfiguration
        replayConfigForDifferentState.replayLandSuffix = reevaluation.replayLandSuffix
        replayLandSuffix = reevaluation.replayLandSuffix

        try await register(
            landType: replayLandType,
            land: replayLand,
            initialState: replayInitialState(),
            webSocketPath: replayWebSocketPath,
            configuration: replayConfigForDifferentState
        )

        if await realm.isRegistered(landType: reevaluation.monitorLandType) == false {
            try await register(
                landType: reevaluation.monitorLandType,
                land: ReevaluationMonitor.makeLand(),
                initialState: ReevaluationMonitorState(),
                webSocketPath: reevaluation.monitorWebSocketPath,
                configuration: effectiveConfiguration
            )
        }
    }
}

// MARK: - Generic Replay Registration (additive — does not modify existing functions)

public extension NIOLandHost {
    /// Registers a live land and a corresponding generic replay land.
    ///
    /// Unlike `registerWithReevaluationSameLand`, this variant uses
    /// `GenericReplayLand<State>.makeLand(basedOn:)` to construct the replay land.
    /// The replay land decodes each tick's state from the `ReevaluationRunnerService`
    /// result queue via `State.init(fromBroadcastSnapshot:)` — no manual `Decodable`
    /// conformance is required for game state types.
    ///
    /// The replay land type is `"\(landType)\(reevaluation.replayLandSuffix)"`
    /// (default: `"\(landType)-replay"`).
    ///
    /// - Parameters:
    ///   - landType: Base land type (e.g. "hero-defense"); replay will be
    ///     `"\(landType)\(reevaluation.replayLandSuffix)"`.
    ///   - liveLand: The live land definition.  The same definition is passed to
    ///     `GenericReplayLand.makeLand(basedOn:)` to build the replay land.
    ///   - liveInitialState: Initial state for live sessions.
    ///   - liveWebSocketPath: WebSocket path for live connections.
    ///   - configuration: Server configuration shared by live and replay lands.
    ///   - reevaluation: Reevaluation feature configuration (runner factory, suffix, …).
    func registerWithGenericReplay<State: StateFromSnapshotDecodable>(
        landType: String,
        liveLand: LandDefinition<State>,
        liveInitialState: @autoclosure @escaping @Sendable () -> State,
        liveWebSocketPath: String,
        configuration: NIOLandServerConfiguration,
        reevaluation: ReevaluationFeatureConfiguration
    ) async throws {
        let effectiveConfiguration: NIOLandServerConfiguration
        if reevaluation.enabled {
            effectiveConfiguration = configuration.injectingReevaluationServices(
                runnerServiceFactory: reevaluation.runnerServiceFactory,
                replayEventPolicy: reevaluation.replayEventPolicy
            )
        } else {
            effectiveConfiguration = configuration
        }

        try await register(
            landType: landType,
            land: liveLand,
            initialState: liveInitialState(),
            webSocketPath: liveWebSocketPath,
            configuration: effectiveConfiguration
        )

        guard reevaluation.enabled else {
            return
        }

        let replayLandType = "\(landType)\(reevaluation.replayLandSuffix)"
        let replayWebSocketPath = reevaluation.replayWebSocketPathResolver(replayLandType)
        let recordsDir = NIOEnvConfig.fromEnvironment().reevaluationRecordsDir

        var replayConfig = effectiveConfiguration.injectingReevaluationKeeperModeResolver(
            replayLandType: replayLandType,
            recordsDir: recordsDir
        )
        replayConfig.replayLandSuffix = reevaluation.replayLandSuffix

        replayLandSuffix = reevaluation.replayLandSuffix

        let replayLand = GenericReplayLand<State>.makeLand(basedOn: liveLand)

        try await register(
            landType: replayLandType,
            land: replayLand,
            initialState: liveInitialState(),
            webSocketPath: replayWebSocketPath,
            configuration: replayConfig
        )

        if await realm.isRegistered(landType: reevaluation.monitorLandType) == false {
            try await register(
                landType: reevaluation.monitorLandType,
                land: ReevaluationMonitor.makeLand(),
                initialState: ReevaluationMonitorState(),
                webSocketPath: reevaluation.monitorWebSocketPath,
                configuration: effectiveConfiguration
            )
        }
    }
}

private extension NIOLandServerConfiguration {
    func injectingReevaluationServices(
        runnerServiceFactory: @escaping @Sendable () -> ReevaluationRunnerService,
        replayEventPolicy: ReevaluationReplayEventPolicy
    ) -> NIOLandServerConfiguration {
        var updated = self
        let baseFactory = self.servicesFactory
        updated.servicesFactory = { landID, metadata in
            var services = baseFactory(landID, metadata)
            if services.get(ReevaluationRunnerService.self) == nil {
                services.register(runnerServiceFactory(), as: ReevaluationRunnerService.self)
            }
            if services.get(ReevaluationReplayPolicyService.self) == nil {
                services.register(
                    ReevaluationReplayPolicyService(eventPolicy: replayEventPolicy),
                    as: ReevaluationReplayPolicyService.self
                )
            }
            return services
        }
        return updated
    }

    func injectingReevaluationKeeperModeResolver(
        replayLandType: String,
        recordsDir: String
    ) -> NIOLandServerConfiguration {
        var updated = self
        let previousResolver = self.keeperModeResolver
        let captureReplayLandType = replayLandType
        let captureRecordsDir = recordsDir
        updated.keeperModeResolver = { landID, metadata in
            if let previous = previousResolver, let result = previous(landID, metadata) {
                return result
            }
            guard landID.landType == captureReplayLandType else { return nil }
            guard let descriptor = ReevaluationReplaySessionDescriptor.decode(
                instanceId: landID.instanceId,
                landType: captureReplayLandType,
                recordsDir: captureRecordsDir
            ) else {
                return .invalidReplaySession(message: "Invalid replay session descriptor for instanceId")
            }
            return .reevaluation(recordFilePath: descriptor.recordFilePath)
        }
        return updated
    }
}
