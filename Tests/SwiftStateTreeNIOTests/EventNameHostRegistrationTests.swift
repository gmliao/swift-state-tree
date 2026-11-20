// #521 PR 1b-2b at the host: `register` runs EV2 and EV3 with the configuration's
// `eventHashes`, and the reevaluation helpers check the replay definition before the live land
// registers, so a refusal publishes no route.

import Foundation
import Logging
import Testing
import SwiftStateTree
import SwiftStateTreeTransport
@testable import SwiftStateTreeNIO
import SwiftStateTreeReevaluationMonitor

@StateNodeBuilder
struct EventNameHostState: StateNodeProtocol, StateFromSnapshotDecodable {
    @Sync(.broadcast) var n: Int = 0
    init() {}
}

@Payload
struct EHLiveEvent: ServerEventPayload {
    let n: Int
}

/// Renamed from `EHOldBell`; the hand-written wire name keeps the old one.
struct EHBellEvent: ServerEventPayload {
    static var _payloadWireName: String { "EHOldBell" }
}

/// `a` is keyed `"b"`, and `b` (defaulted) is left out of `CodingKeys`: one wire key, two fields,
/// which the record fingerprint refuses.
@Payload
struct EHCollidingKeys: ServerEventPayload {
    let a: Int
    var b: Int = 0

    enum CodingKeys: String, CodingKey {
        case a = "b"
    }
}

enum EHInputs {
    /// A server input with the colliding event's short type name. Its schema used to replace the
    /// event's in the base's fingerprint walk, hiding the event's wire-key collision there, while
    /// the generic alias, which drops the server inputs, found it. Since #602 the walk refuses
    /// the two types under one name.
    @Payload
    struct EHCollidingKeys: ServerInputPayload {}
}

private let logger = Logger(label: "event-name-host")

private func makeHost() -> NIOLandHost {
    NIOLandHost(configuration: NIOLandHostConfiguration(host: "localhost", port: 8080, logger: logger, adminAPIKey: "test-admin-key"))
}

private func liveLand(_ id: String) -> LandDefinition<EventNameHostState> {
    Land(id, using: EventNameHostState.self) {
        ServerEvents { Register(EHLiveEvent.self) }
        Rules {}
    }
}

/// The live land's schema table.
private func liveTable(_ id: String) throws -> [String: Int] {
    try #require(try SchemaExtractor.extract(from: liveLand(id)).lands[id]?.eventHashes)
}

private func configuration(eventHashes: [String: Int]?) -> NIOLandServerConfiguration {
    var configuration = NIOLandServerConfiguration(logger: logger, allowAutoCreateOnJoin: false, transportEncoding: .opcode)
    configuration.eventHashes = eventHashes
    return configuration
}

private func feature() -> ReevaluationFeatureConfiguration {
    ReevaluationFeatureConfiguration(
        enabled: true,
        replayEventPolicy: .projectedOnly,
        runnerServiceFactory: { ReevaluationRunnerService(factory: UnusedEventNameTargetFactory()) }
    )
}

@Suite("NIOLandHost: event names at registration (#521 PR 1b-2b)")
struct EventNameHostRegistrationTests {
    @Test("register refuses a land with a registered event missing from the configuration's eventHashes, and maps nothing")
    func registerRefusesMissingHash() async throws {
        let host = makeHost()
        let error = try await #require(throws: LandRegistrationError.self) {
            try await host.register(
                landType: "eh-host", land: liveLand("eh-host"), initialState: EventNameHostState(),
                webSocketPath: "/game/eh-host", configuration: configuration(eventHashes: ["Other": 1])
            )
        }
        #expect(error.serverEventsWithoutHash.map { $0.hasPrefix("EHLive (") } == [true], "\(error)")
        #expect(await host.realm.isRegistered(landType: "eh-host") == false)
        #expect(await host.transportForTesting(webSocketPath: "/game/eh-host") == nil)
    }

    @Test("register refuses a land whose server event's wire name isn't the schema's (EV2), and maps nothing")
    func registerRefusesWireNameMismatch() async throws {
        let host = makeHost()
        let land = Land("eh-renamed", using: EventNameHostState.self) {
            ServerEvents { Register(EHBellEvent.self) }
            Rules {}
        }
        let error = try await #require(throws: LandRegistrationError.self) {
            try await host.register(
                landType: "eh-renamed", land: land, initialState: EventNameHostState(),
                webSocketPath: "/game/eh-renamed",
                configuration: NIOLandServerConfiguration(logger: logger, allowAutoCreateOnJoin: false, transportEncoding: .json)
            )
        }
        #expect(error.wireNameMismatches.count == 1 && error.wireNameMismatches[0].contains("wire name EHOldBell"), "\(error)")
        #expect(await host.transportForTesting(webSocketPath: "/game/eh-renamed") == nil)
    }

    @Test("register passes with the schema's own table given explicitly")
    func registerPassesWithSchemaTable() async throws {
        let host = makeHost()
        try await host.register(
            landType: "eh-ok", land: liveLand("eh-ok"), initialState: EventNameHostState(),
            webSocketPath: "/game/eh-ok", configuration: configuration(eventHashes: try liveTable("eh-ok"))
        )
        #expect(await host.realm.isRegistered(landType: "eh-ok"))
    }

    @Test("A valid generic replay alias registers with a non-empty table")
    func genericAliasRegisters() async throws {
        let host = makeHost()
        try await host.registerWithGenericReplay(
            landType: "eh-generic",
            liveLand: liveLand("eh-generic"),
            liveInitialState: EventNameHostState(),
            liveWebSocketPath: "/game/eh-generic",
            configuration: configuration(eventHashes: try liveTable("eh-generic")),
            reevaluation: feature()
        )
        #expect(await host.realm.isRegistered(landType: "eh-generic"))
        #expect(await host.realm.isRegistered(landType: "eh-generic-replay"))
    }

    @Test("The helper's live check reports EV2 and EV3 in one throw, and maps nothing")
    func liveCheckReportsEveryRow() async throws {
        let host = makeHost()
        let landType = "eh-both-generic-replay"
        let land = Land(landType, using: EventNameHostState.self) {
            ServerEvents {
                Register(EHBellEvent.self)
                Register(EHLiveEvent.self)
            }
            Rules {}
        }
        var configuration = NIOLandServerConfiguration(logger: logger, allowAutoCreateOnJoin: false, transportEncoding: .json)
        configuration.eventHashes = ["EHBell": 1]
        let error = try await #require(throws: LandRegistrationError.self) {
            try await host.registerWithGenericReplay(
                landType: landType, liveLand: land, liveInitialState: EventNameHostState(),
                liveWebSocketPath: "/game/\(landType)", configuration: configuration, reevaluation: feature()
            )
        }
        // The throw names the live land type: the generic alias keeps the live ID.
        #expect(error.landType == landType, "the error names the live land type")
        #expect(error.wireNameMismatches.count == 1, "\(error)")
        #expect(error.serverEventsWithoutHash.map { $0.hasPrefix("EHLive (") } == [true], "\(error)")
        #expect(await host.transportForTesting(webSocketPath: "/game/\(landType)") == nil)
    }

    @Test("A server input named like a server event is refused with the base's fingerprint (#602); the live route stays unpublished")
    func genericAliasFingerprintRefusedUpFront() async throws {
        let host = makeHost()
        let land = Land("eh-hidden", using: EventNameHostState.self) {
            ServerEvents { Register(EHCollidingKeys.self) }
            Rules {
                HandleServerInput(EHInputs.EHCollidingKeys.self) { (_: inout EventNameHostState, _: EHInputs.EHCollidingKeys, _: LandContext) in }
            }
        }
        // The input no longer hides the event's wire-key collision: the base's own fingerprint
        // walk refuses the two types under one name, before either is hashed.
        func names(_ found: [SchemaTypeNameCollision]) -> [String] {
            found.map { "\($0.name): \($0.types.joined(separator: ", "))" }
        }
        let collisions = [
            "EHCollidingKeys: SwiftStateTreeNIOTests.EHCollidingKeys, SwiftStateTreeNIOTests.EHInputs.EHCollidingKeys"
        ]
        let baseError = try #require(throws: LandRegistrationError.self) {
            try land.validateForRegistration(context: LandRegistrationContext(recordsForReplay: true))
        }
        #expect(names(baseError.typeNameCollisions) == collisions, "\(baseError)")
        #expect(baseError.schemaFingerprint == nil, "\(baseError)")
        // The live land records, so its registration computes the fingerprint.
        var configuration = NIOLandServerConfiguration(logger: logger, allowAutoCreateOnJoin: false, transportEncoding: .json)
        configuration.enableLiveStateHashRecording = true
        let error = try await #require(throws: LandRegistrationError.self) {
            try await host.registerWithGenericReplay(
                landType: "eh-hidden", liveLand: land, liveInitialState: EventNameHostState(),
                liveWebSocketPath: "/game/eh-hidden", configuration: configuration, reevaluation: feature()
            )
        }
        #expect(names(error.typeNameCollisions) == collisions, "\(error)")
        #expect(await host.realm.isRegistered(landType: "eh-hidden") == false)
        #expect(await host.transportForTesting(webSocketPath: "/game/eh-hidden") == nil, "the live path isn't mapped")
    }

    @Test("The generic alias runs EV3 itself: registered directly with a table missing its event, it is refused")
    func genericAliasRunsTheRow() async throws {
        let host = makeHost()
        let alias = GenericReplayLand<EventNameHostState>.makeLand(basedOn: liveLand("eh-alias"))
        let error = try await #require(throws: LandRegistrationError.self) {
            try await host.register(
                landType: "eh-alias-replay", land: alias, initialState: EventNameHostState(),
                webSocketPath: "/game/eh-alias-replay", configuration: configuration(eventHashes: ["Other": 1])
            )
        }
        #expect(error.serverEventsWithoutHash.map { $0.hasPrefix("EHLive (") } == [true], "\(error)")
        #expect(await host.realm.isRegistered(landType: "eh-alias-replay") == false)
    }
}

private struct UnusedEventNameTargetFactory: ReevaluationTargetFactory {
    func createRunner(landType: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        throw CancellationError()
    }
}
