// Tests/SwiftStateTreeNIOTests/ResolverDocExamplesTests.swift
//
// The resolver guide's services registration and lifecycle examples compile here, and each
// marked region (`docs:begin` … `docs:end`) appears in docs/core/resolver.md and its zh-TW twin,
// compared without leading whitespace.

import Foundation
import Testing
import SwiftStateTree
import SwiftStateTreeTransport
@testable import SwiftStateTreeNIO

// MARK: - The guide's types

private struct DocProduct: Sendable {
    let id: String
}

private struct ProductDatabase: Sendable {
    func fetchProduct(by id: String) async throws -> DocProduct { DocProduct(id: id) }
}

private protocol HasProductDatabase: Sendable {
    var productDatabase: ProductDatabase { get }
}

private struct ShopServices: HasProductDatabase {
    let productDatabase: ProductDatabase
}

@StateNodeBuilder
private struct ShopState: StateNodeProtocol {
    @Sync(.broadcast)
    var maxPlayers: Int = 0

    @Sync(.broadcast)
    var scores: [String: Int] = [:]

    init() {}
}

@PlainData
private struct RoomConfigOutput: ResolverOutput {
    let maxPlayers: Int
}

@PlainData
private struct RoomConfig<D: Sendable>: Resolver {
    typealias Dependencies = D
    let roomID: String
    func resolve(_ deps: D) async throws -> RoomConfigOutput { RoomConfigOutput(maxPlayers: 8) }
}

@PlainData
private struct SaveResultsOutput: ResolverOutput {
    let saved: Bool
}

@PlainData
private struct SaveResults<D: Sendable>: Resolver {
    typealias Dependencies = D
    let landID: String
    let scores: [String: Int]
    func resolve(_ deps: D) async throws -> SaveResultsOutput { SaveResultsOutput(saved: true) }
}

@Suite("Resolver guide examples")
struct ResolverDocExamplesTests {
    @Test("The services registration example registers the land")
    func servicesRegistration() async throws {
        let host = NIOLandHost(configuration: NIOLandHostConfiguration(host: "localhost", port: 8080))
        let database = ProductDatabase()
        let shop = Land("shop", using: ShopState.self, services: ShopServices.self) {
            Rules {}
        }
        // docs:begin
        try await host.register(
            landType: "shop",
            land: shop,
            services: { _, _ in ShopServices(productDatabase: database) },
            initialState: ShopState(),
            webSocketPath: "/game/shop",
            configuration: NIOLandServerConfiguration()
        )
        // docs:end
        #expect(await host.realm.isRegistered(landType: "shop"))
    }

    @Test("The lifecycle example builds a land that registers")
    func lifecycle() throws {
        let land = Land("room", using: ShopState.self) {
            // docs:begin
            Lifetime {
                OnInitialize(resolvers: { _, ctx in RoomConfig(roomID: ctx.landID) }) { state, config, _ in
                    state.maxPlayers = config?.maxPlayers ?? 4
                }
                OnFinalize(resolvers: { state, ctx in SaveResults(landID: ctx.landID, scores: state.scores) }) { _, _, _ in }
            }
            // docs:end
        }
        try land.validateForRegistration(context: .encodingIndependent)
    }

    @Test("Each marked example appears in the resolver guide, in both languages")
    func documentationMatchesTheTests() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func flat(_ text: some StringProtocol) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.drop { $0 == " " } }
                .joined(separator: "\n")
        }
        let source = try String(contentsOf: here, encoding: .utf8)
        let regions = source.components(separatedBy: "// docs:begin\n").dropFirst()
            .map { $0.components(separatedBy: "// docs:end")[0] }
        #expect(regions.count == 2)
        for page in ["docs/core/resolver.md", "docs/core/resolver.zh-TW.md"] {
            let text = flat(try String(contentsOf: root.appendingPathComponent(page), encoding: .utf8))
            for region in regions {
                #expect(text.contains(flat(region)), "\(page): missing\n\(region)")
            }
        }
    }
}
