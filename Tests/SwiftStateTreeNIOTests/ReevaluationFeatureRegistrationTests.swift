import Foundation
import Testing
import SwiftStateTree
import SwiftStateTreeTransport
import SwiftStateTreeReevaluationMonitor
@testable import SwiftStateTreeNIO

@StateNodeBuilder
private struct FeatureLiveState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0
    init() {}
}

@StateNodeBuilder
private struct FeatureReplayState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0
    init() {}
}

private enum FeatureLiveLand {
    static func makeLand() -> LandDefinition<FeatureLiveState> {
        Land("feature-live", using: FeatureLiveState.self) { Rules {} }
    }
}

private enum FeatureReplayLand {
    static func makeLand() -> LandDefinition<FeatureReplayState> {
        Land("feature-live-replay", using: FeatureReplayState.self) { Rules {} }
    }
}

@Suite("NIO Reevaluation Feature Registration Tests")
struct ReevaluationFeatureRegistrationTests {
    @Test("ReevaluationFeatureConfiguration defaults to projectedOnly replay policy")
    func reevaluationFeatureDefaultsToProjectedOnlyPolicy() {
        let feature = ReevaluationFeatureConfiguration(
            enabled: true,
            runnerServiceFactory: {
                ReevaluationRunnerService(factory: MockReevaluationTargetFactory())
            }
        )

        #expect(feature.replayEventPolicy == .projectedOnly)
    }

    @Test("registerWithReevaluation registers live, replay, and monitor lands when enabled")
    func registerWithReevaluationEnabled() async throws {
        let host = NIOLandHost(configuration: NIOLandHostConfiguration(
            host: "localhost",
            port: 8080,
            adminAPIKey: "test-admin-key"
        ))

        let feature = ReevaluationFeatureConfiguration(
            enabled: true,
            replayEventPolicy: .projectedWithFallback,
            runnerServiceFactory: {
                ReevaluationRunnerService(factory: MockReevaluationTargetFactory())
            }
        )

        try await host.registerWithReevaluation(
            landType: "feature-live",
            liveLand: FeatureLiveLand.makeLand(),
            liveInitialState: FeatureLiveState(),
            liveWebSocketPath: "/game/feature-live",
            replayLand: FeatureReplayLand.makeLand(),
            replayInitialState: FeatureReplayState(),
            configuration: NIOLandServerConfiguration(transportEncoding: .json),
            reevaluation: feature
        )

        let realm = await host.realm
        #expect(await realm.isRegistered(landType: "feature-live"))
        #expect(await realm.isRegistered(landType: "feature-live-replay"))
        #expect(await realm.isRegistered(landType: "reevaluation-monitor"))
    }

    @Test("registerWithReevaluation registers only live land when disabled")
    func registerWithReevaluationDisabled() async throws {
        let host = NIOLandHost(configuration: NIOLandHostConfiguration(
            host: "localhost",
            port: 8080,
            adminAPIKey: "test-admin-key"
        ))

        let feature = ReevaluationFeatureConfiguration(
            enabled: false,
            runnerServiceFactory: {
                ReevaluationRunnerService(factory: MockReevaluationTargetFactory())
            }
        )

        try await host.registerWithReevaluation(
            landType: "feature-live",
            liveLand: FeatureLiveLand.makeLand(),
            liveInitialState: FeatureLiveState(),
            liveWebSocketPath: "/game/feature-live",
            replayLand: FeatureReplayLand.makeLand(),
            replayInitialState: FeatureReplayState(),
            configuration: NIOLandServerConfiguration(transportEncoding: .json),
            reevaluation: feature
        )

        let realm = await host.realm
        #expect(await realm.isRegistered(landType: "feature-live"))
        #expect(await realm.isRegistered(landType: "feature-live-replay") == false)
        #expect(await realm.isRegistered(landType: "reevaluation-monitor") == false)
    }
}

private struct MockReevaluationTargetFactory: ReevaluationTargetFactory {
    func createRunner(landType _: String, recordFilePath _: String) async throws -> any ReevaluationRunnerProtocol {
        MockReevaluationRunner()
    }
}

private actor MockReevaluationRunner: ReevaluationRunnerProtocol {
    let maxTickId: Int64 = -1

    func prepare() async throws {}

    func step() async throws -> ReevaluationStepResult? {
        nil
    }
}
