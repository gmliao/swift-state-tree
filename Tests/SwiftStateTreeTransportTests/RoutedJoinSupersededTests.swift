// Tests/SwiftStateTreeTransportTests/RoutedJoinSupersededTests.swift
//
// A routed join whose keeper entry is replaced while its OnJoin resolvers run fails with
// `JoinError.superseded` (#860). The router answers it like the flip-stage supersede (#861): the
// `JOIN_DENIED` error is the session's last frame, with the 4017 `superseded` close behind it, so
// the client doesn't rejoin into a kick loop. Hosted joins of one player are serialized by the
// adapter's membership queue, so here a direct keeper caller makes the newer join.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct RoutedSupersedeState: StateNodeProtocol {
    @Sync(.broadcast)
    var joins: [String] = []
}

@PlainData
struct RoutedSupersedeOutput: ResolverOutput {}

/// Holds the OnJoin resolver of a session registered here.
private enum RoutedSupersedeHold {
    static let gates = KeyedGates<SessionID, TestGate> { TestGate() }
}

struct RoutedSupersedeResolver: ContextResolver {
    typealias Output = RoutedSupersedeOutput

    static func resolve(ctx: ResolverContext) async throws -> RoutedSupersedeOutput {
        if let gate = RoutedSupersedeHold.gates.registeredGate(ctx.sessionID) {
            await gate.arrive()
        }
        return RoutedSupersedeOutput()
    }
}

/// Records what the transport sends to one session and how it was closed. Tests wait on these
/// events (`waitFor`), not on time.
private actor RoutedSupersedeConnection: WebSocketConnection {
    private(set) var messages: [Data] = []
    private(set) var closes: [SessionClose] = []
    private var waiters: [UInt64: (condition: @Sendable ([Data], [SessionClose]) -> Bool, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var nextWaiter: UInt64 = 0

    func send(_ data: Data, kind: WebSocketFrameKind) async throws {
        messages.append(data)
        resumeWaiters()
    }

    func close() async throws { record(.normal) }
    func close(with close: SessionClose) async throws { record(close) }

    private func record(_ close: SessionClose) {
        closes.append(close)
        resumeWaiters()
    }

    /// Returns once `condition` holds, or once the task is cancelled (the suite's time limit);
    /// the expectations after the wait then fail.
    func waitFor(_ condition: @escaping @Sendable ([Data], [SessionClose]) -> Bool) async {
        if condition(messages, closes) || Task.isCancelled { return }
        nextWaiter += 1
        let id = nextWaiter
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(); return }
                waiters[id] = (condition, continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }

    private func resumeWaiters() {
        for (id, waiter) in waiters where waiter.condition(messages, closes) {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    /// Each error frame's code and message, in order.
    var errors: [(code: String, message: String)] {
        messages.compactMap { data in
            guard let message = try? JSONDecoder().decode(TransportMessage.self, from: data),
                  case .error(let payload) = message.payload else { return nil }
            return (payload.code, payload.message)
        }
    }
}

@Suite("A routed join superseded during its OnJoin resolvers (#860)", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct RoutedJoinSupersededTests {
    @Test("Its JOIN_DENIED is the session's last frame, with the 4017 superseded close behind it; the newer join keeps the player")
    func supersededJoinClosesWith4017() async throws {
        let definition = Land("routed-supersede", using: RoutedSupersedeState.self) {
            Rules {
                OnJoin(resolvers: RoutedSupersedeResolver.self) { state, _, ctx in
                    state.joins.append(ctx.clientID.rawValue)
                }
            }
        }
        let transport = WebSocketTransport()
        let registry = try LandTypeRegistry(
            landFactory: { _, _ in definition },
            initialStateFactory: { _, _ in RoutedSupersedeState() }
        )
        let manager = LandManager<RoutedSupersedeState>(
            landFactory: { _ in definition },
            initialStateFactory: { _ in RoutedSupersedeState() },
            transport: transport
        )
        // A budget of one refused frame: a supersede that counted would close with 1008.
        let router = LandRouter<RoutedSupersedeState>(
            landManager: manager,
            landTypeRegistry: registry,
            transport: transport,
            allowAutoCreateOnJoin: true,
            transportEncoding: .json,
            maxRefusedHandshakeFrames: 1
        )
        await transport.setDelegate(router)

        let session = SessionID("s-routed")
        let connection = RoutedSupersedeConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        let gate = RoutedSupersedeHold.gates.register(session)
        defer { gate.open() }

        // The routed join: its OnJoin resolver holds.
        let join = try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-1", landType: "routed-supersede", landInstanceId: "one",
            playerID: "p1", deviceID: nil, metadata: StateUpdateFeature.joinMetadata
        ))
        // Sent from its own task: the transport handles the frame through the router's join,
        // which parks at the held resolver.
        let routed = Task { await transport.handleIncomingMessage(sessionID: session, data: join) }
        defer { routed.cancel() }
        guard await gate.waitForArrivals(1) else {
            Issue.record("the routed join's OnJoin resolver never ran")
            return
        }

        // A direct keeper join of the same player kicks the pending entry and joins. It runs in
        // its own task and reports its end at `directEnded`: the test never awaits a call that a
        // regression could park.
        let container = try #require(await manager.getLand(landID: LandID(landType: "routed-supersede", instanceId: "one")))
        let directEnded = TestGate()
        defer { directEnded.open() }
        let direct = Task { () -> (any Error)? in
            defer { Task { await directEnded.arrive() } }
            do {
                try await container.keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c-direct"), sessionID: SessionID("s-direct"))
                return nil
            } catch {
                return error
            }
        }
        guard await directEnded.waitForArrivals(1) else {
            Issue.record("the direct join didn't end while the routed join was held")
            return
        }
        let directError = await direct.value
        #expect(directError == nil, "the direct join threw \(String(describing: directError))")

        gate.open()
        let closed = await withinHangBound { await connection.waitFor { _, closes in !closes.isEmpty } }
        #expect(closed, "the session wasn't closed")

        let errors = await connection.errors
        #expect(errors.map(\.code) == [ErrorCode.joinDenied.rawValue], "errors \(errors)")
        #expect(errors.first?.message == "Join superseded by a newer join of the player")
        let closes = await connection.closes
        #expect(closes.map(\.code) == [SessionClose.Code.superseded], "closes \(closes)")
        #expect(await container.keeper.currentState().joins == ["c-direct"])
    }
}
