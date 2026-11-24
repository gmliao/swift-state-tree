// Tests/SwiftStateTreeNIOTests/RecordSchemaFingerprintRegistrationTests.swift
//
// A land that records must have a record schema fingerprint (#521 D15, U3): the host refuses one
// whose payload has fields the fingerprint can't list, and registers nothing, so no record that
// can never replay is made. With recording off, the same land registers.

import Foundation
import Logging
import Testing
import SwiftStateTree
import SwiftStateTreeTransport
@testable import SwiftStateTreeNIO
import SwiftStateTreeReevaluationMonitor

@StateNodeBuilder
struct FingerprintHostState: StateNodeProtocol, StateFromSnapshotDecodable {
    @Sync(.broadcast) var hp: Int = 0
    init() {}
}

/// A nested value with required fields and no `@SnapshotConvertible`: no sample of it can be built.
@PlainData
struct FingerprintHostInner: Codable, Sendable {
    let x: Int
}

@Payload
struct FingerprintHostEvent: ServerEventPayload {
    let inner: FingerprintHostInner
}

/// Registered through `ServerEventNode(type:)`, not `Register`: a server event type with no
/// decoder, which a replay can't decode (EV8). Fieldless, so the fingerprint can list it.
struct FingerprintHostNotAPayload: Codable, Sendable {}

@Suite("NIOLandHost record schema fingerprint")
struct RecordSchemaFingerprintRegistrationTests {
    @Test("register refuses a recording land whose fingerprint can't be computed, naming the type, and registers nothing")
    func refusesUnlistableWhenRecording() async throws {
        let logger = Logger(label: "test")
        let host = NIOLandHost(configuration: NIOLandHostConfiguration(host: "localhost", port: 8080, logger: logger, adminAPIKey: nil))
        let land = Land("fingerprint-host", using: FingerprintHostState.self) {
            ServerEvents { Register(FingerprintHostEvent.self) }
            Rules {}
        }
        var recording = NIOLandServerConfiguration(logger: logger, allowAutoCreateOnJoin: false, transportEncoding: .messagepack)
        recording.enableLiveStateHashRecording = true
        let error = try await #require(throws: LandRegistrationError.self) {
            try await host.register(
                landType: "fingerprint-host",
                land: land,
                initialState: FingerprintHostState(),
                webSocketPath: "/game/fingerprint-host",
                configuration: recording
            )
        }
        #expect(error.schemaFingerprint == .unbuildableType("FingerprintHostInner"))
        #expect(error.description.contains("fingerprint-host"))
        #expect(await host.realm.isRegistered(landType: "fingerprint-host") == false)

        // Without recording, nothing will be replayed: the land registers.
        try await host.register(
            landType: "fingerprint-host",
            land: land,
            initialState: FingerprintHostState(),
            webSocketPath: "/game/fingerprint-host",
            configuration: NIOLandServerConfiguration(logger: logger, allowAutoCreateOnJoin: false, transportEncoding: .messagepack)
        )
        #expect(await host.realm.isRegistered(landType: "fingerprint-host"))
        // The realm reports no fingerprint for it: computing one throws.
        await #expect(throws: SchemaFingerprintError.unbuildableType("FingerprintHostInner")) {
            _ = try await host.realm.recordSchemaFingerprint(for: "fingerprint-host")
        }
    }

    @Test("Registering a land for reevaluation refuses one whose fingerprint can't be computed, even without recording")
    func reevaluationRefusesUnlistable() async throws {
        let host = NIOLandHost(configuration: NIOLandHostConfiguration(host: "localhost", port: 8080, adminAPIKey: "test-admin-key"))
        let land = Land("fingerprint-reeval", using: FingerprintHostState.self) {
            ServerEvents { Register(FingerprintHostEvent.self) }
            Rules {}
        }
        let feature = ReevaluationFeatureConfiguration(
            enabled: true,
            replayEventPolicy: .projectedOnly,
            runnerServiceFactory: { ReevaluationRunnerService(factory: UnusedFingerprintTargetFactory()) }
        )
        let configuration = NIOLandServerConfiguration(transportEncoding: .json)
        let error = try await #require(throws: LandRegistrationError.self) {
            try await host.registerWithGenericReplay(
                landType: "fingerprint-reeval",
                liveLand: land,
                liveInitialState: FingerprintHostState(),
                liveWebSocketPath: "/game/fingerprint-reeval",
                configuration: configuration,
                reevaluation: feature
            )
        }
        #expect(error.schemaFingerprint == .unbuildableType("FingerprintHostInner"))
        #expect(await host.realm.isRegistered(landType: "fingerprint-reeval") == false)
        #expect(await host.realm.isRegistered(landType: "fingerprint-reeval-replay") == false)
    }

    @Test("Registering a land for reevaluation refuses a server event a replay can't decode, even without recording (EV8)")
    func reevaluationRefusesUndecodable() async throws {
        let host = NIOLandHost(configuration: NIOLandHostConfiguration(host: "localhost", port: 8080, adminAPIKey: "test-admin-key"))
        let land = Land("fingerprint-ev8", using: FingerprintHostState.self) {
            Rules {}
            ServerEventNode(type: FingerprintHostNotAPayload.self)
        }
        // Recording off: `register` alone wouldn't run EV8, so this pins the helpers' forced flag.
        let configuration = NIOLandServerConfiguration(transportEncoding: .json)
        let probe = NIOLandHost(configuration: NIOLandHostConfiguration(host: "localhost", port: 8080, adminAPIKey: "test-admin-key"))
        try await probe.register(
            landType: "fingerprint-ev8", land: land, initialState: FingerprintHostState(),
            webSocketPath: "/game/fingerprint-ev8", configuration: configuration
        )
        let feature = ReevaluationFeatureConfiguration(
            enabled: true,
            replayEventPolicy: .projectedOnly,
            runnerServiceFactory: { ReevaluationRunnerService(factory: UnusedFingerprintTargetFactory()) }
        )
        let error = try await #require(throws: LandRegistrationError.self) {
            try await host.registerWithGenericReplay(
                landType: "fingerprint-ev8", liveLand: land, liveInitialState: FingerprintHostState(),
                liveWebSocketPath: "/game/fingerprint-ev8", configuration: configuration, reevaluation: feature
            )
        }
        #expect(error.serverEventsWithoutDecoder.count == 1, "\(error)")
        #expect(error.schemaFingerprint == nil, "\(error)")
        #expect(await host.realm.isRegistered(landType: "fingerprint-ev8") == false)
        #expect(await host.transportForTesting(webSocketPath: "/game/fingerprint-ev8") == nil)
    }

    @Test("A registered land type reports its definition's fingerprint to the admin replay start")
    func realmReportsFingerprint() async throws {
        let logger = Logger(label: "test")
        let host = NIOLandHost(configuration: NIOLandHostConfiguration(host: "localhost", port: 8080, logger: logger, adminAPIKey: nil))
        let land = Land("fingerprint-ok", using: FingerprintHostState.self) { Rules {} }
        var recording = NIOLandServerConfiguration(logger: logger, allowAutoCreateOnJoin: false, transportEncoding: .messagepack)
        recording.enableLiveStateHashRecording = true
        try await host.register(
            landType: "fingerprint-ok",
            land: land,
            initialState: FingerprintHostState(),
            webSocketPath: "/game/fingerprint-ok",
            configuration: recording
        )
        #expect(try await host.realm.recordSchemaFingerprint(for: "fingerprint-ok") == (try ReevaluationSchemaFingerprint.compute(for: land)))
        #expect(try await host.realm.recordSchemaFingerprint(for: "not-registered") == nil)
    }
}

/// The registration is refused before any replay runs.
private struct UnusedFingerprintTargetFactory: ReevaluationTargetFactory {
    func createRunner(landType: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        throw CancellationError()
    }
}
