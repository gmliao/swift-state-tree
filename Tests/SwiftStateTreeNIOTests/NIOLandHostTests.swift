// Tests/SwiftStateTreeNIOTests/NIOLandHostTests.swift
//
// Tests for NIOLandHost initialization, configuration, and registration.
// Corresponds to Archive Hummingbird LandHostTests and LandHostRegistrationTests.

import Foundation
import Logging
import NIOCore
import NIOPosix
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

    @Test("NIOLandHost cancels middleware tasks when server.start() throws")
    func testMiddlewareCancellationOnStartupFailure() async throws {
        let port: UInt16 = 39399
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        // Bind to port first so host will fail with address-in-use
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeSucceededFuture(())
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: Int(port)).get()

        let tracker = CancellationTracker()
        let middleware = TrackingMiddleware(tracker: tracker)
        let config = NIOLandHostConfiguration(
            host: "127.0.0.1",
            port: port,
            logger: Logger(label: "test"),
            middlewares: [middleware]
        )
        let host = NIOLandHost(configuration: config)
        try await host.register(
            landType: "game1",
            land: TestGame1.makeLand(),
            initialState: TestState1(),
            webSocketPath: "/game/game1",
            configuration: NIOLandServerConfiguration(
                logger: Logger(label: "test"),
                allowAutoCreateOnJoin: false,
                transportEncoding: .json
            )
        )

        do {
            try await host.run()
            #expect(Bool(false), "Expected run() to throw")
        } catch {
            // Expected: port already in use
        }

        try await channel.close()
        try await group.shutdownGracefully()

        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelled = await tracker.cancelled
        #expect(cancelled, "Middleware task should be cancelled when startup fails")
    }

    @Test("NIOLandHost calls middleware onShutdown when server.start() throws")
    func testMiddlewareOnShutdownOnStartupFailure() async throws {
        let port: UInt16 = 39400
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeSucceededFuture(())
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: Int(port)).get()

        let onShutdownTracker = OnShutdownTracker()
        let middleware = OnShutdownTrackingMiddleware(tracker: onShutdownTracker)
        let config = NIOLandHostConfiguration(
            host: "127.0.0.1",
            port: port,
            logger: Logger(label: "test"),
            middlewares: [middleware]
        )
        let host = NIOLandHost(configuration: config)
        try await host.register(
            landType: "game1",
            land: TestGame1.makeLand(),
            initialState: TestState1(),
            webSocketPath: "/game/game1",
            configuration: NIOLandServerConfiguration(
                logger: Logger(label: "test"),
                allowAutoCreateOnJoin: false,
                transportEncoding: .json
            )
        )

        do {
            try await host.run()
            #expect(Bool(false), "Expected run() to throw")
        } catch {
            // Expected: port already in use
        }

        try await channel.close()
        try await group.shutdownGracefully()

        try await Task.sleep(nanoseconds: 100_000_000)
        let onShutdownCalled = await onShutdownTracker.wasCalled
        #expect(onShutdownCalled, "Middleware onShutdown should be called when startup fails")
    }
}

// MARK: - Test Middleware for Cancellation

private actor CancellationTracker: Sendable {
    var cancelled = false
    func markCancelled() {
        cancelled = true
    }
}

private final class TrackingMiddleware: HostMiddleware, @unchecked Sendable {
    let tracker: CancellationTracker
    init(tracker: CancellationTracker) {
        self.tracker = tracker
    }

    func onStart(context: HostContext) async throws -> Task<Void, Never>? {
        let t = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            await tracker.markCancelled()
        }
        return t
    }

    func onShutdown(context: HostContext) async throws {}
}

// MARK: - Test Middleware for OnShutdown Verification

private actor OnShutdownTracker: Sendable {
    var wasCalled = false
    func markCalled() {
        wasCalled = true
    }
}

private final class OnShutdownTrackingMiddleware: HostMiddleware, @unchecked Sendable {
    let tracker: OnShutdownTracker
    init(tracker: OnShutdownTracker) {
        self.tracker = tracker
    }

    func onStart(context: HostContext) async throws -> Task<Void, Never>? {
        nil
    }

    func onShutdown(context: HostContext) async throws {
        await tracker.markCalled()
    }
}
