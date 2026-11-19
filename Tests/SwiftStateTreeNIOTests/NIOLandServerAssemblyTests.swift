// Tests/SwiftStateTreeNIOTests/NIOLandServerAssemblyTests.swift
//
// The server's assembly (#555): `attach()`, not the construction, installs the router as the
// transport's delegate.

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

@Suite("NIOLandServer assembly (#555)")
struct NIOLandServerAssemblyTests {
    @Test("The router becomes the transport's delegate at attach(), not at construction")
    func attachInstallsTheRouter() async throws {
        let transport = WebSocketTransport()
        let definition = Land("assembly", using: AssemblyState.self) { Rules {} }
        let server = try NIOLandServer<AssemblyState>(
            landType: "assembly",
            landFactory: { _ in definition },
            initialStateFactory: { _ in AssemblyState() },
            configuration: NIOLandServerConfiguration(allowAutoCreateOnJoin: true, transportEncoding: .json),
            transport: transport,
            autoStartLoops: false
        )
        #expect(await transport.delegate == nil)
        await server.attach()
        #expect(await transport.delegate as? LandRouter<AssemblyState> === server.landRouter)
    }
}
