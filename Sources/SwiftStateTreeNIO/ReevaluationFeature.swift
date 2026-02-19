import SwiftStateTree
import SwiftStateTreeReevaluationMonitor

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

        try await register(
            landType: replayLandType,
            land: replayLand,
            initialState: replayInitialState(),
            webSocketPath: replayWebSocketPath,
            configuration: effectiveConfiguration
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
