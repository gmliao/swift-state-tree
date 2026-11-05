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

    @Test("An explicit listenBacklog wins and is clamped to 1...Int32.max")
    func explicitValue() {
        #expect(NIOWebSocketServerConfiguration(listenBacklog: 1024).listenBacklog == 1024)
        #expect(NIOWebSocketServerConfiguration(listenBacklog: 0).listenBacklog == 1)
        #expect(NIOWebSocketServerConfiguration(listenBacklog: Int.max).listenBacklog == Int(Int32.max))
    }
}
