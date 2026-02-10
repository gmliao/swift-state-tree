// Tests/SwiftStateTreeNIOTests/NIOLandHostTests.swift
//
// Tests for NIOLandHost initialization, configuration, and registration.
// Corresponds to Archive Hummingbird LandHostTests and LandHostRegistrationTests.

import Foundation
import Logging
import Testing
import SwiftStateTree
import SwiftStateTreeTransport
@testable import SwiftStateTreeNIO

// MARK: - Test State Types

@StateNodeBuilder
private struct TestState1: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0
    init() {}
}

@StateNodeBuilder
private struct TestState2: StateNodeProtocol {
    @Sync(.broadcast)
    var name: String = ""
    init() {}
}

// MARK: - Test Land Definitions

private enum TestGame1 {
    static func makeLand() -> LandDefinition<TestState1> {
        Land("test-game-1", using: TestState1.self) { Rules {} }
    }
}

private enum TestGame2 {
    static func makeLand() -> LandDefinition<TestState2> {
        Land("test-game-2", using: TestState2.self) { Rules {} }
    }
}

// MARK: - Tests

@Suite("NIO LandHost Tests")
struct NIOLandHostTests {

    @Test("NIOLandHost can be initialized with default configuration")
    func testDefaultConfiguration() async {
        let config = NIOLandHostConfiguration(
            host: "localhost",
            port: 8080,
            logger: Logger(label: "test"),
            adminAPIKey: nil
        )
        let host = NIOLandHost(configuration: config)

        let hostConfig = await host.configuration
        #expect(hostConfig.host == "localhost")
        #expect(hostConfig.port == 8080)
        #expect(hostConfig.adminAPIKey == nil)
    }

    @Test("NIOLandHost can be initialized with custom configuration")
    func testCustomConfiguration() async {
        let logger = Logger(label: "test-landhost")
        let config = NIOLandHostConfiguration(
            host: "0.0.0.0",
            port: 9000,
            logger: logger,
            eventLoopThreads: 2,
            schemaProvider: nil,
            adminAPIKey: "custom-admin-key"
        )
        let host = NIOLandHost(configuration: config)

        let hostConfig = await host.configuration
        #expect(hostConfig.host == "0.0.0.0")
        #expect(hostConfig.port == 9000)
        #expect(hostConfig.adminAPIKey == "custom-admin-key")
    }

    @Test("NIOLandHost can register one land type at default-like path")
    func testRegisterOneLandType() async throws {
        let logger = Logger(label: "test")
        let config = NIOLandHostConfiguration(
            host: "localhost",
            port: 8080,
            logger: logger,
            adminAPIKey: nil
        )
        let host = NIOLandHost(configuration: config)

        let serverConfig = NIOLandServerConfiguration(
            logger: logger,
            allowAutoCreateOnJoin: false,
            transportEncoding: .json
        )

        try await host.register(
            landType: "game1",
            land: TestGame1.makeLand(),
            initialState: TestState1(),
            webSocketPath: "/game/game1",
            configuration: serverConfig
        )

        let realm = await host.realm
        #expect(await realm.isRegistered(landType: "game1"))
        let lands = await realm.listAllLands()
        #expect(lands.isEmpty, "No land instances created yet; list is empty")
    }

    @Test("NIOLandHost can register multiple land types at different paths")
    func testRegisterMultipleLandTypes() async throws {
        let logger = Logger(label: "test")
        let config = NIOLandHostConfiguration(
            host: "localhost",
            port: 8080,
            logger: logger,
            adminAPIKey: nil
        )
        let host = NIOLandHost(configuration: config)

        let serverConfig = NIOLandServerConfiguration(
            logger: logger,
            allowAutoCreateOnJoin: false,
            transportEncoding: .json
        )

        try await host.register(
            landType: "chess",
            land: TestGame1.makeLand(),
            initialState: TestState1(),
            webSocketPath: "/game/chess",
            configuration: serverConfig
        )

        try await host.register(
            landType: "cardgame",
            land: TestGame2.makeLand(),
            initialState: TestState2(),
            webSocketPath: "/game/cardgame",
            configuration: serverConfig
        )

        let realm = await host.realm
        #expect(await realm.isRegistered(landType: "chess"))
        #expect(await realm.isRegistered(landType: "cardgame"))
        let lands = await realm.listAllLands()
        #expect(lands.isEmpty, "No land instances created yet; list is empty")
    }

    @Test("NIOLandHost registerAdminRoutes does not throw when adminAPIKey is set")
    func testRegisterAdminRoutesWithKey() async throws {
        let logger = Logger(label: "test")
        let config = NIOLandHostConfiguration(
            host: "localhost",
            port: 8080,
            logger: logger,
            adminAPIKey: "test-admin-key"
        )
        let host = NIOLandHost(configuration: config)

        try await host.register(
            landType: "game1",
            land: TestGame1.makeLand(),
            initialState: TestState1(),
            webSocketPath: "/game/game1",
            configuration: NIOLandServerConfiguration(
                logger: logger,
                allowAutoCreateOnJoin: false,
                transportEncoding: .json
            )
        )

        await host.registerAdminRoutes()
    }

    @Test("NIOLandHost registerAdminRoutes does nothing when adminAPIKey is nil")
    func testRegisterAdminRoutesWithoutKey() async throws {
        let logger = Logger(label: "test")
        let config = NIOLandHostConfiguration(
            host: "localhost",
            port: 8080,
            logger: logger,
            adminAPIKey: nil
        )
        let host = NIOLandHost(configuration: config)

        try await host.register(
            landType: "game1",
            land: TestGame1.makeLand(),
            initialState: TestState1(),
            webSocketPath: "/game/game1",
            configuration: NIOLandServerConfiguration(
                logger: logger,
                allowAutoCreateOnJoin: false,
                transportEncoding: .json
            )
        )

        await host.registerAdminRoutes()
    }
}
