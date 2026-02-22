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

        var replayConfig = effectiveConfiguration
        replayConfig.replayLandSuffix = reevaluation.replayLandSuffix

        replayLandSuffix = reevaluation.replayLandSuffix

        try await register(
            landType: replayLandType,
            land: GenericReplayLand.makeLand(landType: landType, stateType: State.self),
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
}
