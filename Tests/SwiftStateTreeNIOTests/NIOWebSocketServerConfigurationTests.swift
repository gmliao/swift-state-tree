// Tests/SwiftStateTreeNIOTests/NIOWebSocketServerConfigurationTests.swift
//
// The listen backlog (#119): configurable, LISTEN_BACKLOG through EnvKeys, default 4096, and
// always a valid Int32 for `ChannelOptions.backlog`.

import Foundation
import Testing
import SwiftStateTree
@testable import SwiftStateTreeNIO

@Suite("NIOWebSocketServerConfiguration: listen backlog")
struct NIOWebSocketServerConfigurationTests {

    @Test("LISTEN_BACKLOG unset or invalid gives the default of 4096")
    func defaultBacklog() {
        #expect(NIOWebSocketServerConfiguration.defaultListenBacklog == 4096)
        #expect(NIOWebSocketServerConfiguration.listenBacklog(environment: [:]) == 4096)
        for raw in ["", "abc", "0", "-5", "12.5"] {
            #expect(
                NIOWebSocketServerConfiguration.listenBacklog(environment: [EnvKeys.Server.listenBacklog: raw]) == 4096,
                "LISTEN_BACKLOG=\(raw)"
            )
        }
    }

    @Test("LISTEN_BACKLOG sets the backlog, capped at Int32.max")
    func environmentOverride() {
        #expect(NIOWebSocketServerConfiguration.listenBacklog(environment: [EnvKeys.Server.listenBacklog: "256"]) == 256)
        #expect(NIOWebSocketServerConfiguration.listenBacklog(environment: [EnvKeys.Server.listenBacklog: "65535"]) == 65535)
        let huge = String(Int64(Int32.max) + 1)
        #expect(NIOWebSocketServerConfiguration.listenBacklog(environment: [EnvKeys.Server.listenBacklog: huge]) == Int(Int32.max))
    }

    @Test("An explicit listenBacklog wins; 0 or below gives 4096, as the env path does")
    func explicitValue() {
        #expect(NIOWebSocketServerConfiguration(listenBacklog: 1024).listenBacklog == 1024)
        #expect(NIOWebSocketServerConfiguration(listenBacklog: 0).listenBacklog == 4096)
        #expect(NIOWebSocketServerConfiguration(listenBacklog: -5).listenBacklog == 4096)
        #expect(NIOWebSocketServerConfiguration(listenBacklog: Int.max).listenBacklog == Int(Int32.max))
    }

    @Test("A NIOLandHostConfiguration listenBacklog reaches the server configuration")
    func hostValueReachesServer() {
        let host = NIOLandHostConfiguration(host: "127.0.0.1", port: 9999, eventLoopThreads: 2, listenBacklog: 2048)
        #expect(host.listenBacklog == 2048)
        let server = host.webSocketServerConfiguration()
        #expect(server.listenBacklog == 2048)
        #expect(server.host == "127.0.0.1")
        #expect(server.port == 9999)
        #expect(server.eventLoopThreads == 2)

        #expect(NIOLandHostConfiguration(listenBacklog: 0).listenBacklog == 4096)
        // Without an argument the host uses the same env-or-default value as the server.
        #expect(NIOLandHostConfiguration().listenBacklog == NIOWebSocketServerConfiguration.listenBacklog())
    }
}
