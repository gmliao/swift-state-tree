// An echo server for the Autobahn|Testsuite.
//
// It starts `NIOWebSocketServer` with a `WebSocketTransport` whose delegate sends every received
// message back to its session. No land, no adapter: the suite exercises `WebSocketSessionHandler`
// (keepalive, close handling, backlog bounds), `WebSocketFragmentReassembler` (fragmentation and
// the size limit) and NIO's frame decoder.
//
// Usage: AutobahnEcho [port]   (default 9001; the AUTOBAHN_ECHO_PORT environment variable
// overrides the default, and an argument overrides both). It listens on 127.0.0.1 and runs
// until SIGINT or SIGTERM.
//
// The server sends every frame as binary (`WebSocketSessionHandler.sendOnLoop`), so the suite's
// text echo cases fail for that reason alone (#798).

import Dispatch
import Foundation
import Logging
import SwiftStateTree
import SwiftStateTreeNIO
import SwiftStateTreeTransport

/// Sends each received message back to the session it came from.
final class EchoDelegate: TransportDelegate, Sendable {
    private let transport: WebSocketTransport

    init(transport: WebSocketTransport) {
        self.transport = transport
    }

    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {}

    func onDisconnect(sessionID: SessionID, clientID: ClientID) async {}

    func onMessage(_ message: Data, from sessionID: SessionID) async {
        await transport.send(message, to: .session(sessionID))
    }
}

/// The port from the first argument, else `AUTOBAHN_ECHO_PORT`, else 9001.
func listenPort() -> Int {
    let defaultPort = 9001
    let arguments = CommandLine.arguments
    if arguments.count > 1 {
        guard let port = Int(arguments[1]), (1...65535).contains(port) else {
            FileHandle.standardError.write(Data("AutobahnEcho: invalid port '\(arguments[1])'\n".utf8))
            exit(2)
        }
        return port
    }
    if let text = ProcessInfo.processInfo.environment["AUTOBAHN_ECHO_PORT"] {
        guard let port = Int(text), (1...65535).contains(port) else {
            FileHandle.standardError.write(Data("AutobahnEcho: invalid AUTOBAHN_ECHO_PORT '\(text)'\n".utf8))
            exit(2)
        }
        return port
    }
    return defaultPort
}

/// Resumes a continuation once, whichever signal arrives first.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}

/// Returns once SIGINT or SIGTERM arrives.
func waitForTerminationSignal() async {
    let sources = [SIGINT, SIGTERM].map { signalNumber in
        signal(signalNumber, SIG_IGN)
        return DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let once = ResumeOnce(continuation)
        for source in sources {
            source.setEventHandler { once.resume() }
            source.resume()
        }
    }
    for source in sources { source.cancel() }
}

var logger = Logger(label: "autobahn-echo")
logger.logLevel = .warning

let port = listenPort()
// The server's default frame limit (16 MiB) covers every case outside the excluded performance
// sections (9.x, whose messages go up to 16 MiB); the other limits are the defaults too.
let configuration = NIOWebSocketServerConfiguration(
    host: "127.0.0.1",
    port: port,
    maxFrameSize: 1 << 24,
    logger: logger
)

let transport = WebSocketTransport(logger: logger)
await transport.setDelegate(EchoDelegate(transport: transport))

let server = NIOWebSocketServer(
    configuration: configuration,
    transport: transport,
    pathMatcher: { _ in true }
)

do {
    try await server.start()
} catch {
    FileHandle.standardError.write(Data("AutobahnEcho: could not start on port \(port): \(error)\n".utf8))
    exit(1)
}
FileHandle.standardOutput.write(Data("AutobahnEcho listening on ws://127.0.0.1:\(port)\n".utf8))

await waitForTerminationSignal()
try? await server.shutdown()
