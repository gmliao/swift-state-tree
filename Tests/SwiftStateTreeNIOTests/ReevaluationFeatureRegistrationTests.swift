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

    @Test("replay landType can be registered without dedicated replay gameplay land (same-land mode)")
    func replayRegisteredWithoutDedicatedReplayLand() async throws {
        let host = NIOLandHost(configuration: NIOLandHostConfiguration(
            host: "localhost",
            port: 8080,
            adminAPIKey: "test-admin-key"
        ))

        let feature = ReevaluationFeatureConfiguration(
            enabled: true,
            replayEventPolicy: .projectedOnly,
            runnerServiceFactory: {
                ReevaluationRunnerService(factory: MockReevaluationTargetFactory())
            }
        )

        try await host.registerWithReevaluationSameLand(
            landType: "feature-live",
            liveLand: FeatureLiveLand.makeLand(),
            liveInitialState: FeatureLiveState(),
            liveWebSocketPath: "/game/feature-live",
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

    @Test("Replay resolver returns invalidReplaySession when ReevaluationReplaySessionDescriptor.decode fails")
    func replayResolverFailsClosedForInvalidInstanceId() async throws {
        let recordsDir = FileManager.default.temporaryDirectory.path
        let replayLandType = "feature-live-replay"

        let landFactory: @Sendable (LandID) -> LandDefinition<FeatureReplayState> = { landID in
            Land(landID.stringValue, using: FeatureReplayState.self) { Rules {} }
        }
        let initialStateFactory: @Sendable (LandID) -> FeatureReplayState = { _ in FeatureReplayState() }

        let manager = LandManager<FeatureReplayState>(
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            keeperModeResolver: { landID, _ in
                guard landID.landType == replayLandType else { return nil }
                guard let descriptor = ReevaluationReplaySessionDescriptor.decode(
                    instanceId: landID.instanceId,
                    landType: replayLandType,
                    recordsDir: recordsDir
                ) else {
                    return .invalidReplaySession(message: "Invalid replay session descriptor for instanceId")
                }
                return .reevaluation(recordFilePath: descriptor.recordFilePath)
            }
        )

        let landID = LandID(landType: replayLandType, instanceId: "invalid-no-dot-format")
        let definition = landFactory(landID)
        let initialState = initialStateFactory(landID)

        do {
            _ = try await manager.getOrCreateLand(
                landID: landID,
                definition: definition,
                initialState: initialState,
                metadata: [:]
            )
            Issue.record("Expected ReevaluationReplayError to be thrown for invalid instanceId")
        } catch let error as ReevaluationReplayError {
            if case .invalidSessionDescriptor = error {
                // Expected: fail-closed when decode returns nil
            } else {
                Issue.record("Expected invalidSessionDescriptor case")
            }
        } catch {
            Issue.record("Expected ReevaluationReplayError, got \(type(of: error)): \(error)")
        }
    }

    @Test("ReplayTickEvent has correct fields")
    func replayTickEventHasCorrectFields() {
        let event = ReplayTickEvent(
            tickId: 42,
            isMatch: true,
            expectedHash: "abc",
            actualHash: "abc"
        )
        #expect(event.tickId == 42)
        #expect(event.isMatch == true)
        #expect(event.expectedHash == "abc")
        #expect(event.actualHash == "abc")
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

extension ReevaluationFeatureRegistrationTests {
    @Test("GenericReplayLand.makeLand produces a LandDefinition with the correct land ID")
    func genericReplayLandMakeLandProducesValidDefinition() {
        let definition = GenericReplayLand.makeLand(
            landType: "hero-defense",
            stateType: FeatureLiveState.self
        )
        #expect(definition.id == "hero-defense-replay")
    }

    @Test("StandardReplayLifetime returns a LifetimeNode")
    func standardReplayLifetimeIsLandNode() {
        let _: LifetimeNode<FeatureLiveState> = StandardReplayLifetime(landType: "test")
        // Compilation itself proves it returns the right type
    }

    @Test("StandardReplayServerEvents returns a ServerEventsNode")
    func standardReplayServerEventsIsLandNode() {
        let _: ServerEventsNode = StandardReplayServerEvents()
        // Compilation itself proves it returns the right type
    }
}
