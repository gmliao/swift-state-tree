// Tests/SwiftStateTreeNIOTests/NIOAdminDebugStateRoutesTests.swift
//
// Debug state routes (#79): registered only with ENABLE_DEBUG_STATE_ROUTES, guarded by the
// admin API key, and mapped to freeze / projection / resume on the land's server.

import Foundation
import NIOHTTP1
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeNIO
@testable import SwiftStateTreeTransport

private let apiKey = "test-admin-key"
private let landType = "debug-land"
private let landID = LandID(landType: landType, instanceId: "room-1")

@Suite("NIO admin debug state routes (#79)")
struct NIOAdminDebugStateRoutesTests {

    @Test("Routes are not registered when the flag is off (the server answers 404)")
    func notRegisteredWhenDisabled() async throws {
        let router = try await makeRouter(enableDebugStateRoutes: false)
        for (method, path) in debugRoutes() {
            let response = try await router.handle(request(method, path))
            #expect(response == nil, "\(path) is registered without ENABLE_DEBUG_STATE_ROUTES")
        }
    }

    @Test("The flag reads ENABLE_DEBUG_STATE_ROUTES and defaults to off")
    func flagFromEnvironment() {
        #expect(NIOEnvConfig.fromEnvironment(environment: [:]).enableDebugStateRoutes == false)
        #expect(NIOEnvConfig.fromEnvironment(environment: [EnvKeys.Debug.enableDebugStateRoutes: "true"]).enableDebugStateRoutes)
    }

    @Test("Without the admin key every route answers 401")
    func requireAdminKey() async throws {
        let router = try await makeRouter(enableDebugStateRoutes: true)
        for (method, path) in debugRoutes() {
            let response = try #require(try await router.handle(request(method, path, apiKey: nil)))
            #expect(response.status == .unauthorized, "\(path)")
        }
    }

    @Test("Unknown land answers 404")
    func unknownLand() async throws {
        let router = try await makeRouter(enableDebugStateRoutes: true)
        let other = LandID(landType: landType, instanceId: "missing")
        for (method, path) in debugRoutes(for: other) {
            let response = try #require(try await router.handle(request(method, path)))
            #expect(response.status == .notFound, "\(path)")
        }
    }

    @Test("Freeze, projection and resume round trip; projection before freeze answers 409")
    func roundTrip() async throws {
        let router = try await makeRouter(enableDebugStateRoutes: true)
        let base = "/admin/lands/\(landID.stringValue)/debug"

        let early = try #require(try await router.handle(request(.GET, "\(base)/projection?playerID=p1")))
        #expect(early.status == .conflict)

        let freeze = try #require(try await router.handle(request(.POST, "\(base)/freeze")))
        #expect(freeze.status == .ok)
        let freezeBody = try decode(DebugFreezeResponse.self, from: freeze)
        #expect(freezeBody.freezeToken == "token-1")

        let projection = try #require(try await router.handle(request(.GET, "\(base)/projection?playerID=p1")))
        #expect(projection.status == .ok)
        let projectionBody = try decode(DebugProjectionResponse.self, from: projection)
        #expect(projectionBody.playerID == "p1")
        #expect(projectionBody.state["score"] == .int(3))

        let broadcast = try #require(try await router.handle(request(.GET, "\(base)/projection")))
        #expect(try decode(DebugProjectionResponse.self, from: broadcast).playerID == nil)

        let resume = try #require(try await router.handle(request(.POST, "\(base)/resume")))
        #expect(resume.status == .ok)
        #expect(try decode(DebugResumeResponse.self, from: resume) == DebugResumeResponse(freezeCount: 0, resumed: true))
    }
}

// MARK: - Helpers

private func debugRoutes(for id: LandID = landID) -> [(HTTPMethod, String)] {
    let base = "/admin/lands/\(id.stringValue)/debug"
    return [(.POST, "\(base)/freeze"), (.GET, "\(base)/projection"), (.POST, "\(base)/resume")]
}

private func makeRouter(enableDebugStateRoutes: Bool) async throws -> NIOHTTPRouter {
    let realm = LandRealm()
    try await realm.register(landType: landType, server: MockDebugLandServer(debug: MockDebugLand()))
    let routes = NIOAdminRoutes(
        landRealm: realm,
        adminAuth: NIOAdminAuth(apiKey: apiKey),
        enableDebugStateRoutes: enableDebugStateRoutes
    )
    let router = NIOHTTPRouter()
    await routes.registerRoutes(on: router)
    return router
}

private func request(_ method: HTTPMethod, _ uri: String, apiKey key: String? = apiKey) -> NIOHTTPRequest {
    var headers = HTTPHeaders()
    if let key {
        headers.add(name: "X-API-Key", value: key)
    }
    return NIOHTTPRequest(method: method, uri: uri, headers: headers, body: nil)
}

private func decode<T: Codable & Sendable>(_ type: T.Type, from response: NIOHTTPResponse) throws -> T {
    let body = try #require(response.body)
    let decoded = try JSONDecoder().decode(AdminAPIResponse<T>.self, from: body)
    #expect(decoded.success)
    return try #require(decoded.data)
}

/// Freeze bookkeeping of the mock land.
private actor MockDebugLand {
    private var frozen = false

    func freeze() -> DebugFreezeResponse {
        frozen = true
        return DebugFreezeResponse(freezeToken: "token-1", tickId: 4, freezeCount: 1, reused: false)
    }

    func projection(playerID: PlayerID?) throws -> DebugProjectionResponse {
        guard frozen else { throw DebugFreezeError.notFrozen }
        return DebugProjectionResponse(
            freezeToken: "token-1",
            tickId: 4,
            playerID: playerID?.rawValue,
            membershipChanged: false,
            state: playerID == nil ? [:] : ["score": .int(3)]
        )
    }

    func resume() -> DebugResumeResponse {
        frozen = false
        return DebugResumeResponse(freezeCount: 0, resumed: true)
    }
}

@StateNodeBuilder
private struct MockDebugLandState: StateNodeProtocol {
    @Sync(.broadcast)
    var score: Int = 0
}

private struct MockDebugLandServer: LandServerProtocol {
    typealias State = MockDebugLandState
    let debug: MockDebugLand

    func shutdown() async throws {}
    func healthCheck() async -> Bool { true }
    func listLands() async -> [LandID] { [landID] }
    func getLandStats(landID _: LandID) async -> LandStats? { nil }
    func removeLand(landID _: LandID) async {}
    func getReevaluationRecord(landID _: LandID) async throws -> Data? { nil }

    func debugFreeze(landID id: LandID) async throws -> DebugFreezeResponse? {
        guard id == landID else { return nil }
        return await debug.freeze()
    }

    func debugProjection(landID id: LandID, playerID: PlayerID?) async throws -> DebugProjectionResponse? {
        guard id == landID else { return nil }
        return try await debug.projection(playerID: playerID)
    }

    func debugResume(landID id: LandID) async -> DebugResumeResponse? {
        guard id == landID else { return nil }
        return await debug.resume()
    }
}
