// Tests/SwiftStateTreeNIOTests/NIOLandHostLoggerTests.swift
//
// The host's configured logger reaches the realm and the land's stack (#452): without it they
// built their own loggers at `.info`, so a server run at `LOG_LEVEL=error` still printed their
// INFO lines, and a server's chosen handler never saw them.

import Foundation
import Logging
import Testing
import SwiftStateTree
import SwiftStateTreeTransport
@testable import SwiftStateTreeNIO

@StateNodeBuilder
private struct LoggerTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0
    init() {}
}

/// Records every log record that passes the logger's level, as `level message`.
private final class LogRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(level: Logger.Level, message: String)] = []

    func append(_ level: Logger.Level, _ message: String) {
        lock.withLock { records.append((level, message)) }
    }

    var all: [(level: Logger.Level, message: String)] {
        lock.withLock { records }
    }

    func messages(containing text: String) -> [String] {
        all.map(\.message).filter { $0.contains(text) }
    }
}

private struct RecordingLogHandler: LogHandler {
    let records: LogRecords
    var logLevel: Logger.Level
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        records.append(level, message.description)
    }
}

private func recordingLogger(_ records: LogRecords, level: Logger.Level) -> Logger {
    Logger(label: "logger-test") { _ in RecordingLogHandler(records: records, logLevel: level) }
}

/// Accepts every frame; the test only needs the connection to be accepted.
private struct SilentConnection: WebSocketConnection {
    func send(_ data: Data) async throws {}
    func close() async throws {}
}

/// One INFO line from each part of the stack, as the test triggers it. The router and the
/// manager take their logger from the server's configuration, so their lines also show what
/// the server was given. The server's own "Shutting down NIOLandServer" line isn't logged here:
/// by design, the host doesn't call `NIOLandServer.shutdown()`; it runs the same steps itself
/// through `HostShutdownParticipant`, each bounded, and then stops the transport (#351).
private let realmLine = "Registered land type 'logger-test' with State type"
private let routerLine = "Client connected: session=logger-session"
private let managerLine = "Created new land"
private let transportLine = "WebSocketTransport stopped"
/// The lines the land's stack logs (all but the realm's).
private let landStackLines = [routerLine, managerLine, transportLine]

/// Registers one land type on a host logging to `hostLogger`, starts it, connects a session
/// (the router logs it), creates a land (the manager logs it), and shuts the host down (the
/// transport logs it).
private func runHost(hostLogger: Logger, landLogger: Logger?) async throws {
    let host = NIOLandHost(configuration: NIOLandHostConfiguration(
        host: "127.0.0.1",
        port: 0,
        logger: hostLogger,
        eventLoopThreads: 1
    ))
    let land = Land("logger-test", using: LoggerTestState.self) { Rules {} }
    try await host.register(
        landType: "logger-test",
        land: land,
        initialState: LoggerTestState(),
        webSocketPath: "/game/logger-test",
        configuration: NIOLandServerConfiguration(logger: landLogger, transportEncoding: .json)
    )
    try await host.start()
    let server = try #require(await host.shutdownParticipantsForTesting.first as? NIOLandServer<LoggerTestState>)
    _ = await server.transport.handleConnection(sessionID: SessionID("logger-session"), connection: SilentConnection())
    _ = try await server.landManager.getOrCreateLand(
        landID: LandID(landType: "logger-test", instanceId: "one"),
        definition: land,
        initialState: LoggerTestState(),
        metadata: [:]
    )
    try await host.shutdown()
}

@Suite("NIOLandHost: the configured logger reaches the realm and the land's stack", .timeLimit(.minutes(1)))
struct NIOLandHostLoggerTests {
    @Test("With no land logger, the host's logger and its level reach the realm, router, manager and transport", arguments: [Logger.Level.info, .error])
    func hostLoggerReachesTheStack(level: Logger.Level) async throws {
        let records = LogRecords()
        try await runHost(hostLogger: recordingLogger(records, level: level), landLogger: nil)
        for line in [realmLine] + landStackLines {
            // Each line reaches the host's handler at .info, and the host's level filters it at
            // .error. Reverted, a part logs through a logger of its own at .info, and its line
            // never reaches the handler, so the .info case fails.
            #expect(records.messages(containing: line).count == (level == .info ? 1 : 0), "\(line)")
        }
        #expect(records.all.allSatisfy { $0.level >= level }, "\(records.all)")
    }

    @Test("A land logger takes the land's stack; the realm's line stays with the host's logger")
    func landLoggerTakesTheStack() async throws {
        let hostRecords = LogRecords()
        let landRecords = LogRecords()
        try await runHost(
            hostLogger: recordingLogger(hostRecords, level: .info),
            landLogger: recordingLogger(landRecords, level: .info)
        )
        for line in landStackLines {
            #expect(landRecords.messages(containing: line).count == 1, "\(line)")
            #expect(hostRecords.messages(containing: line).isEmpty, "\(line)")
        }
        #expect(hostRecords.messages(containing: realmLine).count == 1)
        #expect(landRecords.messages(containing: realmLine).isEmpty)
    }
}
