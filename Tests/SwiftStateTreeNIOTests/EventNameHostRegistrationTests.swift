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

@Payload
struct EHReplayOnlyEvent: ServerEventPayload {
    let n: Int
}

/// Renamed from `EHOldBell`; the hand-written wire name keeps the old one.
struct EHBellEvent: ServerEventPayload {
    static var _payloadWireName: String { "EHOldBell" }
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

    @Test("A separate replay definition with a replay-only event missing from the live table is refused before anything registers")
    func customReplayRefusedUpFront() async throws {
        let host = makeHost()
        let replay = Land("eh-custom-replay", using: EventNameHostState.self) {
            ServerEvents {
                Register(EHLiveEvent.self)
                Register(EHReplayOnlyEvent.self)
            }
            Rules {}
        }
        let error = try await #require(throws: LandRegistrationError.self) {
            try await host.registerWithReevaluation(
                landType: "eh-custom",
                liveLand: liveLand("eh-custom"),
                liveInitialState: EventNameHostState(),
                liveWebSocketPath: "/game/eh-custom",
                replayLand: replay,
                replayInitialState: EventNameHostState(),
                configuration: configuration(eventHashes: try liveTable("eh-custom")),
                reevaluation: feature()
            )
        }
        #expect(error.landType == "eh-custom-replay")
        #expect(error.serverEventsWithoutHash.map { $0.hasPrefix("EHReplayOnly (") } == [true], "\(error)")
        #expect(await host.realm.isRegistered(landType: "eh-custom") == false, "the live land type isn't registered")
        #expect(await host.realm.isRegistered(landType: "eh-custom-replay") == false)
        #expect(await host.transportForTesting(webSocketPath: "/game/eh-custom") == nil, "the live path isn't mapped")
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
