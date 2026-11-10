// Tests/SwiftStateTreeNIOTests/NIOLandHostLoggerTests.swift
//
// The host's configured logger reaches the realm and the land's transport (#452): without it they
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

/// Registers one land type on a host logging to `hostLogger`, starts and shuts it down.
private func runHost(hostLogger: Logger, landLogger: Logger?) async throws {
    let host = NIOLandHost(configuration: NIOLandHostConfiguration(
        host: "127.0.0.1",
        port: 0,
        logger: hostLogger,
        eventLoopThreads: 1
    ))
    try await host.register(
        landType: "logger-test",
        land: Land("logger-test", using: LoggerTestState.self) { Rules {} },
        initialState: LoggerTestState(),
        webSocketPath: "/game/logger-test",
        configuration: NIOLandServerConfiguration(logger: landLogger, transportEncoding: .json)
    )
    try await host.start()
    try await host.shutdown()
}

@Suite("NIOLandHost: the configured logger reaches the realm and the transport", .timeLimit(.minutes(1)))
struct NIOLandHostLoggerTests {
    @Test("With no land logger, the realm's and the transport's lines go to the host's logger")
    func hostLoggerReachesRealmAndTransport() async throws {
        let records = LogRecords()
        try await runHost(hostLogger: recordingLogger(records, level: .info), landLogger: nil)
        #expect(records.messages(containing: "Registered land type 'logger-test' with State type").count == 1)
        #expect(records.messages(containing: "WebSocketTransport stopped").count == 1)
    }

    @Test("A host logger at .error records nothing below .error from the realm or the transport")
    func hostLevelApplies() async throws {
        let records = LogRecords()
        try await runHost(hostLogger: recordingLogger(records, level: .error), landLogger: nil)
        #expect(records.all.filter { $0.level < .error }.isEmpty, "\(records.all)")
    }

    @Test("A land logger takes the land's transport lines; the realm's stay with the host's logger")
    func landLoggerTakesTransport() async throws {
        let hostRecords = LogRecords()
        let landRecords = LogRecords()
        try await runHost(
            hostLogger: recordingLogger(hostRecords, level: .info),
            landLogger: recordingLogger(landRecords, level: .info)
        )
        #expect(landRecords.messages(containing: "WebSocketTransport stopped").count == 1)
        #expect(hostRecords.messages(containing: "WebSocketTransport stopped").isEmpty)
        #expect(hostRecords.messages(containing: "Registered land type 'logger-test'").count == 1)
    }
}
