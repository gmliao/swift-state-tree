// Tests/SwiftStateTreeNIOTests/NIOLandServerAssemblyTests.swift
//
// The server's assembly (#555): the adoption level it resolves, its refusal of an unknown
// TRANSPORT_ADAPTER_ADOPTION, and `attach()` installing the router as the transport's delegate.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeNIO

@StateNodeBuilder
struct AssemblyState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
}

private func makeServer(
    adoption: TransportAdapterAdoption? = nil,
    environment: [String: String],
    transport: WebSocketTransport = WebSocketTransport()
) throws -> NIOLandServer<AssemblyState> {
    let definition = Land("assembly", using: AssemblyState.self) { Rules {} }
    var configuration = NIOLandServerConfiguration(allowAutoCreateOnJoin: true, transportEncoding: .json)
    configuration.adoption = adoption
    return try NIOLandServer<AssemblyState>(
        landType: "assembly",
        landFactory: { _ in definition },
        initialStateFactory: { _ in AssemblyState() },
        configuration: configuration,
        transport: transport,
        autoStartLoops: false,
        environment: environment
    )
}

@Suite("NIOLandServer assembly (#555)")
struct NIOLandServerAssemblyTests {
    @Test("An unknown TRANSPORT_ADAPTER_ADOPTION stops the server's construction")
    func unknownAdoptionIsRefused() {
        #expect(throws: TransportAdapterAdoptionError.unknown("nope")) {
            try makeServer(environment: ["TRANSPORT_ADAPTER_ADOPTION": "nope"])
        }
    }

    @Test("The level is the configuration's override, else the environment's, else legacy")
    func adoptionResolution() throws {
        #expect(try makeServer(environment: [:]).landManager.adoption == .legacy)
        #expect(try makeServer(environment: ["TRANSPORT_ADAPTER_ADOPTION": "legacy"]).landManager.adoption == .legacy)
        // The override wins: an unknown env value isn't read when the configuration sets one.
        #expect(try makeServer(adoption: .legacy, environment: ["TRANSPORT_ADAPTER_ADOPTION": "nope"]).landManager.adoption == .legacy)
    }

    @Test("The router becomes the transport's delegate at attach(), not at construction")
    func attachInstallsTheRouter() async throws {
        let transport = WebSocketTransport()
        let server = try makeServer(environment: [:], transport: transport)
        #expect(await transport.delegate == nil)
        await server.attach()
        #expect(await transport.delegate as? LandRouter<AssemblyState> === server.landRouter)
    }
}
