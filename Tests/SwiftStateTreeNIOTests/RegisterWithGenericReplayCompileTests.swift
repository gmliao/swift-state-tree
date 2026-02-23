// RegisterWithGenericReplayCompileTests.swift
// Compile-only test — verifies the registerWithGenericReplay API signature compiles.
// Actual replay behaviour is verified via E2E (verify-replay-record.ts).

import Foundation
import Testing
import SwiftStateTree
import SwiftStateTreeTransport
import SwiftStateTreeReevaluationMonitor
@testable import SwiftStateTreeNIO

// Minimal state type satisfying StateFromSnapshotDecodable for compile tests.
@StateNodeBuilder
private struct GenericReplayRegisterState: StateNodeProtocol {
    @Sync(.broadcast) var score: Int = 0
    init() {}
}

extension GenericReplayRegisterState: StateFromSnapshotDecodable {
    public init(fromBroadcastSnapshot snapshot: StateSnapshot) throws {
        self.init()
        if let v = snapshot.values["score"] { self._score.wrappedValue = try _snapshotDecode(v) }
    }
}

private func makeGenericReplayRegisterLand() -> LandDefinition<GenericReplayRegisterState> {
    Land("generic-replay-register-test", using: GenericReplayRegisterState.self) {
        AccessControl { AllowPublic(true) }
        Lifetime {
            Tick(every: .milliseconds(50)) { (_: inout GenericReplayRegisterState, _: LandContext) in }
        }
    }
}

@Suite("registerWithGenericReplay compile check")
struct RegisterWithGenericReplayCompileTests {

    @Test("registerWithGenericReplay function exists on NIOLandHost")
    func functionExistsOnNIOLandHost() async throws {
        let host = NIOLandHost(configuration: NIOLandHostConfiguration(
            host: "localhost",
            port: 8080,
            adminAPIKey: "test-admin-key"
        ))

        let feature = ReevaluationFeatureConfiguration(
            enabled: true,
            runnerServiceFactory: {
                ReevaluationRunnerService(factory: MockGenericReplayTargetFactory())
            }
        )

        // This call verifies that registerWithGenericReplay exists with the expected signature.
        // It actually calls the function to confirm it registers lands correctly.
        try await host.registerWithGenericReplay(
            landType: "generic-replay-register-test",
            liveLand: makeGenericReplayRegisterLand(),
            liveInitialState: GenericReplayRegisterState(),
            liveWebSocketPath: "/game/generic-replay-register-test",
            configuration: NIOLandServerConfiguration(transportEncoding: .json),
            reevaluation: feature
        )

        let realm = await host.realm
        #expect(await realm.isRegistered(landType: "generic-replay-register-test"))
        #expect(await realm.isRegistered(landType: "generic-replay-register-test-replay"))
        #expect(await realm.isRegistered(landType: "reevaluation-monitor"))
    }

    @Test("registerWithGenericReplay registers only live land when disabled")
    func registerWithGenericReplayDisabled() async throws {
        let host = NIOLandHost(configuration: NIOLandHostConfiguration(
            host: "localhost",
            port: 8080,
            adminAPIKey: "test-admin-key"
        ))

        let feature = ReevaluationFeatureConfiguration(
            enabled: false,
            runnerServiceFactory: {
                ReevaluationRunnerService(factory: MockGenericReplayTargetFactory())
            }
        )

        try await host.registerWithGenericReplay(
            landType: "generic-replay-register-test-disabled",
            liveLand: makeGenericReplayRegisterLand(),
            liveInitialState: GenericReplayRegisterState(),
            liveWebSocketPath: "/game/generic-replay-register-test-disabled",
            configuration: NIOLandServerConfiguration(transportEncoding: .json),
            reevaluation: feature
        )

        let realm = await host.realm
        #expect(await realm.isRegistered(landType: "generic-replay-register-test-disabled"))
        #expect(await realm.isRegistered(landType: "generic-replay-register-test-disabled-replay") == false)
    }
}

private struct MockGenericReplayTargetFactory: ReevaluationTargetFactory {
    func createRunner(landType _: String, recordFilePath _: String) async throws -> any ReevaluationRunnerProtocol {
        MockGenericReplayRunner()
    }
}

private actor MockGenericReplayRunner: ReevaluationRunnerProtocol {
    let maxTickId: Int64 = -1

    func prepare() async throws {}

    func step() async throws -> ReevaluationStepResult? {
        nil
    }
}
