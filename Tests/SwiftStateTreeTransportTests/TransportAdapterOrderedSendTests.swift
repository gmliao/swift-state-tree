// Tests/SwiftStateTreeTransportTests/TransportAdapterOrderedSendTests.swift
//
// Regression tests for #60: every state frame of a session must arrive in the order the sync
// cycles produced it. Clients apply absolute patches in arrival order, so an older update applied
// after a newer one leaves a stale value. The adapter used to send the per-player batch through
// the transport's send queue (not awaited) and the merged broadcast frame from one unstructured
// task per session, while `syncBroadcastOnly` sent directly; back-to-back cycles could reorder.
//
// The tests use the real `WebSocketTransport` with a recording connection, wired as
// `LandManager` wires it.

import Foundation
import Testing
import SwiftStateTreeMessagePack
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test state, action and event

@StateNodeBuilder
struct OrderedSendTestState: StateNodeProtocol {
    /// Broadcast marker, "mk-NNNNNN": increases with every change.
    @Sync(.broadcast) var stamp: String = "mk-000000"
    /// Per-player marker, "pp-NNNNNN".
    @Sync(.perPlayerSlice()) var mine: [PlayerID: String] = [:]
    init() {}
}

@Payload
struct OrderedSendSetAction: ActionPayload {
    typealias Response = OrderedSendSetResponse
    /// New broadcast marker number.
    let stamp: Int
    /// New per-player marker number for every player (negative: leave unchanged).
    let mine: Int
    /// Marker number echoed in the response, "rs-NNNNNN".
    let echo: Int
}

@Payload
struct OrderedSendSetResponse: ResponsePayload {
    let echo: String
}

@Payload
struct OrderedSendEvent: ServerEventPayload {
    let message: String
    init(message: String) {
        self.message = message
    }
}

private func marker(_ prefix: String, _ n: Int) -> String {
    prefix + "-" + String(format: "%06d", n)
}

// MARK: - Recording connection

/// Records the frames that reach one session's connection, in arrival order.
private actor OrderedSendConnection: WebSocketConnection {
    private var frames: [Data] = []

    func send(_ data: Data) async throws {
        frames.append(data)
    }

    func close() async throws {}

    func recorded() -> [Data] {
        frames
    }
}

// MARK: - Frame inspection

/// Marker numbers with `prefix` found in `frame`, in byte order. Markers are plain strings, so
/// they appear verbatim in JSON and MessagePack frames alike.
private func markers(_ prefix: String, in frame: Data) -> [Int] {
    let text = String(decoding: frame, as: UTF8.self)
    var result: [Int] = []
    var searchRange = text.startIndex..<text.endIndex
    let token = prefix + "-"
    while let range = text.range(of: token, range: searchRange) {
        let digitsEnd = text.index(range.upperBound, offsetBy: 6, limitedBy: text.endIndex) ?? text.endIndex
        if let value = Int(text[range.upperBound..<digitsEnd]) {
            result.append(value)
        }
        searchRange = digitsEnd..<text.endIndex
    }
    return result
}

/// Marker numbers per frame, flattened in arrival order.
private func markerSequence(_ prefix: String, in frames: [Data]) -> [Int] {
    frames.flatMap { markers(prefix, in: $0) }
}

private func isStrictlyIncreasing(_ values: [Int]) -> Bool {
    zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
}

/// First element of a MessagePack array frame (0...2 state update, 103 event, 107 merged).
private func messagePackOpcode(_ frame: Data) -> Int64? {
    guard let unpacked = try? unpack(frame),
          case .array(let array) = unpacked,
          case .int(let opcode) = array.first else { return nil }
    return opcode
}

// MARK: - Fixture

private struct OrderedSendMember {
    let session: SessionID
    let client: ClientID
    let player: PlayerID
    let connection: OrderedSendConnection

    init(_ name: String) {
        session = SessionID("os-session-\(name)")
        client = ClientID("os-client-\(name)")
        player = PlayerID("os-player-\(name)")
        connection = OrderedSendConnection()
    }
}

private struct OrderedSendFixture {
    let keeper: LandKeeper<OrderedSendTestState>
    let adapter: TransportAdapter<OrderedSendTestState>
    let transport: WebSocketTransport
    let members: [OrderedSendMember]

    static func make(
        encoding: TransportEncodingConfig,
        members count: Int = 3
    ) async throws -> OrderedSendFixture {
        let definition = Land("ordered-send-test", using: OrderedSendTestState.self) {
            ServerEvents { Register(OrderedSendEvent.self) }
            Rules {
                OnJoin { (state: inout OrderedSendTestState, ctx: LandContext) in
                    state.mine[ctx.playerID] = marker("pp", 0)
                }
                HandleAction(OrderedSendSetAction.self) { (state: inout OrderedSendTestState, action: OrderedSendSetAction, _: LandContext) in
                    state.stamp = marker("mk", action.stamp)
                    if action.mine >= 0 {
                        for playerID in Array(state.mine.keys) {
                            state.mine[playerID] = marker("pp", action.mine)
                        }
                    }
                    return OrderedSendSetResponse(echo: marker("rs", action.echo))
                }
            }
        }
        let keeper = LandKeeper<OrderedSendTestState>(
            definition: definition,
            initialState: OrderedSendTestState()
        )
        let transport = WebSocketTransport()
        let adapter = TransportAdapter<OrderedSendTestState>(
            keeper: keeper,
            transport: transport,
            landID: "ordered-send-test",
            // Fixed so env vars cannot change the sync path.
            transportEnvConfig: TransportEnvConfig(
                enableDirtyTracking: true,
                useSnapshotForSync: true,
                syncStrategy: .delta,
                enableChangeObjectMetrics: false,
                changeObjectMetricsLogEvery: 10,
                changeObjectMetricsEmaAlpha: 0.2,
                enableAutoDirtyTracking: false,
                autoDirtyOffThreshold: 0.55,
                autoDirtyOnThreshold: 0.30,
                autoDirtyRequiredConsecutiveSamples: 30,
                profilingConfig: nil
            ),
            encodingConfig: encoding,
            suppressMissingPathHashesWarning: true
        )
        let members = (0..<count).map { OrderedSendMember("m\($0)") }
        // Register connections before the delegate is set, so the test controls the client IDs.
        for member in members {
            await transport.handleConnection(sessionID: member.session, connection: member.connection)
        }
        await transport.setDelegate(adapter)
        for member in members {
            await adapter.onConnect(sessionID: member.session, clientID: member.client)
            try await simulateRouterJoin(
                adapter: adapter,
                keeper: keeper,
                sessionID: member.session,
                clientID: member.client,
                playerID: member.player
            )
        }
        await adapter.syncNow()
        return OrderedSendFixture(keeper: keeper, adapter: adapter, transport: transport, members: members)
    }

    func set(stamp: Int, mine: Int) async throws {
        let member = members[0]
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: OrderedSendSetAction.self),
            payload: AnyCodable(OrderedSendSetAction(stamp: stamp, mine: mine, echo: 0))
        )
        _ = try await keeper.handleActionEnvelope(
            envelope,
            playerID: member.player,
            clientID: member.client,
            sessionID: member.session
        )
    }

    /// Waits until every session received a frame carrying `stamp` marker `final` and no frame
    /// arrived for a while after that. Records an Issue on timeout.
    func waitForFinal(stamp final: Int) async {
        let deadline = ContinuousClock.now + .seconds(10)
        var last = -1
        while ContinuousClock.now < deadline {
            var total = 0
            var allFinal = true
            for member in members {
                let frames = await member.connection.recorded()
                total += frames.count
                if !markerSequence("mk", in: frames).contains(final) { allFinal = false }
            }
            if allFinal && total == last { return }
            last = total
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("sessions did not receive marker \(final) and settle within 10 s")
    }
}

private let allEncodings: [(String, TransportEncodingConfig)] = [
    ("json", .json),
    ("opcodeJsonArray", .opcode),
    ("opcodeMessagePack", .messagepack),
]

// MARK: - Tests

@Suite("TransportAdapter sends state frames in cycle order (#60)", .timeLimit(.minutes(1)))
struct TransportAdapterOrderedSendTests {

    /// Back-to-back cycles: `syncNow`, then `syncBroadcastOnly` right after it, many times.
    /// Returns the final broadcast marker.
    private func runBackToBack(_ f: OrderedSendFixture, iterations: Int) async throws -> Int {
        for i in 1...iterations {
            try await f.set(stamp: 2 * i, mine: i)
            await f.adapter.syncNow()
            try await f.set(stamp: 2 * i + 1, mine: -1)
            await f.adapter.syncBroadcastOnly()
        }
        return 2 * iterations + 1
    }

    @Test(
        "1, 2: syncNow followed by syncBroadcastOnly: every session sees markers in cycle order",
        arguments: allEncodings.map(\.0)
    )
    func backToBackCyclesArriveInOrder(encodingName: String) async throws {
        let encoding = allEncodings.first { $0.0 == encodingName }!.1
        let f = try await OrderedSendFixture.make(encoding: encoding)
        let final = try await runBackToBack(f, iterations: 40)
        await f.waitForFinal(stamp: final)

        for member in f.members {
            let frames = await member.connection.recorded()
            let stamps = markerSequence("mk", in: frames)
            let mine = markerSequence("pp", in: frames)
            #expect(
                isStrictlyIncreasing(stamps),
                "\(encodingName) \(member.session.rawValue): broadcast markers out of order: \(stamps)"
            )
            #expect(
                isStrictlyIncreasing(mine),
                "\(encodingName) \(member.session.rawValue): per-player markers out of order: \(mine)"
            )
        }
    }

    @Test(
        "3: the client copy built from received patches equals the server projection",
        arguments: allEncodings.map(\.0)
    )
    func clientCopyMatchesServer(encodingName: String) async throws {
        let encoding = allEncodings.first { $0.0 == encodingName }!.1
        let f = try await OrderedSendFixture.make(encoding: encoding)
        let final = try await runBackToBack(f, iterations: 20)
        await f.waitForFinal(stamp: final)

        // Patches are absolute `set`s of these fields, so applying them in arrival order leaves
        // the value of the last frame that carries each field.
        let state = await f.keeper.currentState()
        for member in f.members {
            let frames = await member.connection.recorded()
            let clientStamp = markerSequence("mk", in: frames).last.map { marker("mk", $0) }
            let clientMine = markerSequence("pp", in: frames).last.map { marker("pp", $0) }
            #expect(clientStamp == state.stamp, "\(encodingName) \(member.session.rawValue)")
            #expect(clientMine == state.mine[member.player], "\(encodingName) \(member.session.rawValue)")
        }
    }

    /// Like `runBackToBack`, but each cycle's frames leave the writer before the next cycle
    /// starts, so sync back-pressure never skips a cycle.
    private func runDrainedBackToBack(_ f: OrderedSendFixture, iterations: Int) async throws -> Int {
        for i in 1...iterations {
            try await f.set(stamp: 2 * i, mine: i)
            await f.adapter.syncNow()
            #expect(await f.adapter.waitForOutboundDrain())
            try await f.set(stamp: 2 * i + 1, mine: -1)
            await f.adapter.syncBroadcastOnly()
            #expect(await f.adapter.waitForOutboundDrain())
        }
        return 2 * iterations + 1
    }

    @Test(
        "4: per-session frame counts per cycle are unchanged",
        arguments: allEncodings.map(\.0)
    )
    func frameCountsPerSession(encodingName: String) async throws {
        let encoding = allEncodings.first { $0.0 == encodingName }!.1
        let f = try await OrderedSendFixture.make(encoding: encoding)
        await f.waitForFinal(stamp: 0)
        var before: [SessionID: Int] = [:]
        for member in f.members {
            before[member.session] = await member.connection.recorded().count
        }

        // Cycles that do run send the same frames as before; back-to-back cycles while the
        // writer still holds the previous one are skipped (sync back-pressure), so drain between.
        let iterations = 10
        let skipsBefore = await f.adapter.syncSkipCounts()
        let final = try await runDrainedBackToBack(f, iterations: iterations)
        await f.waitForFinal(stamp: final)
        #expect(await f.adapter.syncSkipCounts() == skipsBefore, "no cycle was skipped")

        // Per iteration and session: syncNow sends one combined update (json, opcodeJsonArray) or
        // a merged broadcast frame plus a per-player frame (opcodeMessagePack); syncBroadcastOnly
        // sends one broadcast frame.
        let perIteration = encodingName == "opcodeMessagePack" ? 3 : 2
        for member in f.members {
            let frames = await member.connection.recorded()
            let sent = frames.count - before[member.session]!
            #expect(
                sent == iterations * perIteration,
                "\(encodingName) \(member.session.rawValue): \(sent) frames, expected \(iterations * perIteration)"
            )
            let bytes = frames.dropFirst(before[member.session]!).reduce(0) { $0 + $1.count }
            print("[ordered-send] \(encodingName) \(member.session.rawValue) frames=\(sent) bytes=\(bytes)")
        }
    }

    @Test("5: a session's targeted events arrive once, after the merged frame and before its state frame (runSyncNowCycle order doc)")
    func targetedEventsPrecedeTheCycleStateFrame() async throws {
        let f = try await OrderedSendFixture.make(encoding: .messagepack)
        await f.waitForFinal(stamp: 0)
        let target = f.members[1]
        let before = await target.connection.recorded().count

        try await f.set(stamp: 1, mine: 1)
        await f.adapter.sendEvent(
            AnyServerEvent(OrderedSendEvent(message: "tg-cycle-1")),
            to: .player(target.player)
        )
        await f.adapter.sendEvent(AnyServerEvent(OrderedSendEvent(message: "bc-cycle-1")), to: .all)
        await f.adapter.syncNow()
        await f.waitForFinal(stamp: 1)

        let frames = Array(await target.connection.recorded().dropFirst(before))
        let contains = { (frame: Data, text: String) in frame.range(of: Data(text.utf8)) != nil }
        let targeted = frames.indices.filter { contains(frames[$0], "tg-cycle-1") }
        let merged = frames.indices.filter { messagePackOpcode(frames[$0]) == 107 }
        let state = frames.indices.filter { (0...2).contains(messagePackOpcode(frames[$0]) ?? -1) }
        #expect(targeted.count == 1, "targeted event must arrive exactly once; frames \(frames.map(messagePackOpcode))")
        #expect(merged.count == 1 && state.count == 1, "frames \(frames.map(messagePackOpcode))")
        if let t = targeted.first, let m = merged.first, let s = state.first {
            #expect(m < t, "the merged frame (with bc-cycle-1) arrives before the targeted event")
            #expect(t < s, "the targeted event arrives before the cycle's per-player state frame")
            #expect(contains(frames[m], "bc-cycle-1"), "the broadcast event rides in the merged frame")
        }
    }

    @Test("mixed paths (json): state frames, immediate events and action responses arrive in issue order")
    func mixedPathsArriveInIssueOrder() async throws {
        let f = try await OrderedSendFixture.make(encoding: .json)
        await f.waitForFinal(stamp: 0)
        var before: [SessionID: Int] = [:]
        for member in f.members {
            before[member.session] = await member.connection.recorded().count
        }

        let sender = f.members[0]
        let iterations = 15
        let skipsBefore = await f.adapter.syncSkipCounts()
        for i in 1...iterations {
            // State frame of this cycle (marker mk-2i). Drained before the next cycle, so sync
            // back-pressure never skips one and every cycle's frame is expected below.
            try await f.set(stamp: 2 * i, mine: -1)
            await f.adapter.syncNow()
            #expect(await f.adapter.waitForOutboundDrain())
            // Immediate event (json sends events when emitted).
            await f.adapter.sendEvent(AnyServerEvent(OrderedSendEvent(message: marker("ev", i))), to: .all)
            // Action through the adapter: its response goes to the sender only. Its state change
            // (mk-2i+1) is sent by the next cycle.
            let envelope = ActionEnvelope(
                typeIdentifier: String(describing: OrderedSendSetAction.self),
                payload: AnyCodable(OrderedSendSetAction(stamp: 2 * i + 1, mine: -1, echo: i))
            )
            let message = TransportMessage.action(requestID: "req-\(i)", action: envelope)
            await f.adapter.onMessage(try JSONEncoder().encode(message), from: sender.session)
        }
        #expect(await f.adapter.waitForOutboundDrain())
        try await f.set(stamp: 2 * iterations + 2, mine: -1)
        await f.adapter.syncNow()
        await f.waitForFinal(stamp: 2 * iterations + 2)
        #expect(await f.adapter.syncSkipCounts() == skipsBefore, "no cycle was skipped")

        for member in f.members {
            let frames = Array(await member.connection.recorded().dropFirst(before[member.session]!))
            var received: [String] = []
            for frame in frames {
                for prefix in ["mk", "ev", "rs"] {
                    received += markers(prefix, in: frame).map { marker(prefix, $0) }
                }
            }
            var expected: [String] = []
            for i in 1...iterations {
                // Cycle i carries mk-2i: the previous action set 2i-1, then set() set 2i.
                expected.append(marker("mk", 2 * i))
                expected.append(marker("ev", i))
                if member.session == sender.session { expected.append(marker("rs", i)) }
            }
            expected.append(marker("mk", 2 * iterations + 2))
            #expect(received == expected, "\(member.session.rawValue): received \(received)")
        }
    }

    @Test("mixed paths (json), transport blocked: a queued state frame is not overtaken by a later event or action response")
    func mixedPathsQueuedBehindBlockedTransportKeepOrder() async throws {
        let transport = BlockingTransport()
        let definition = Land("ordered-send-mixed-blocked", using: OrderedSendTestState.self) {
            ServerEvents { Register(OrderedSendEvent.self) }
            Rules {
                OnJoin { (state: inout OrderedSendTestState, ctx: LandContext) in
                    state.mine[ctx.playerID] = marker("pp", 0)
                }
                HandleAction(OrderedSendSetAction.self) { (state: inout OrderedSendTestState, action: OrderedSendSetAction, _: LandContext) in
                    state.stamp = marker("mk", action.stamp)
                    return OrderedSendSetResponse(echo: marker("rs", action.echo))
                }
            }
        }
        let keeper = LandKeeper<OrderedSendTestState>(definition: definition, initialState: OrderedSendTestState())
        let adapter = TransportAdapter<OrderedSendTestState>(
            keeper: keeper,
            transport: transport,
            landID: "ordered-send-mixed-blocked",
            encodingConfig: .json,
            suppressMissingPathHashesWarning: true
        )
        await transport.setDelegate(adapter)
        let members = [OrderedSendMember("mixed-blocked-a"), OrderedSendMember("mixed-blocked-b")]
        for member in members {
            await adapter.onConnect(sessionID: member.session, clientID: member.client)
            try await simulateRouterJoin(
                adapter: adapter, keeper: keeper,
                sessionID: member.session, clientID: member.client, playerID: member.player
            )
        }
        await adapter.syncNow()
        try await waitUntilTransportIdle(transport)
        var before: [SessionID: Int] = [:]
        for member in members { before[member.session] = transport.frames(for: member.session).count }

        let sender = members[0]
        let rounds = 5
        for i in 1...rounds {
            transport.block()
            // Blocker: an event element that the transport holds, so everything after it queues.
            await adapter.sendEvent(AnyServerEvent(OrderedSendEvent(message: marker("bl", i))), to: .all)
            try await orderedWaitUntil("blocker \(i) to reach the transport") {
                members.allSatisfy { m in transport.frames(for: m.session).contains { markers("bl", in: $0).contains(i) } }
            }
            // Queued behind it, in issue order: this cycle's state, an immediate event, an action response.
            let set = ActionEnvelope(
                typeIdentifier: String(describing: OrderedSendSetAction.self),
                payload: AnyCodable(OrderedSendSetAction(stamp: 2 * i, mine: -1, echo: 0))
            )
            _ = try await keeper.handleActionEnvelope(set, playerID: sender.player, clientID: sender.client, sessionID: sender.session)
            await adapter.syncNow()
            #expect(await adapter.hasPendingStateElement, "round \(i): the cycle's element is queued")
            await adapter.sendEvent(AnyServerEvent(OrderedSendEvent(message: marker("ev", i))), to: .all)
            let action = ActionEnvelope(
                typeIdentifier: String(describing: OrderedSendSetAction.self),
                payload: AnyCodable(OrderedSendSetAction(stamp: 2 * i + 1, mine: -1, echo: i))
            )
            let message = TransportMessage.action(requestID: "mixed-blocked-\(i)", action: action)
            await adapter.onMessage(try JSONEncoder().encode(message), from: sender.session)
            transport.release()
            #expect(await adapter.waitForOutboundDrain())
        }

        for member in members {
            let frames = Array(transport.frames(for: member.session).dropFirst(before[member.session]!))
            var received: [String] = []
            for frame in frames {
                for prefix in ["bl", "mk", "ev", "rs"] {
                    received += markers(prefix, in: frame).map { marker(prefix, $0) }
                }
            }
            var expected: [String] = []
            for i in 1...rounds {
                expected += [marker("bl", i), marker("mk", 2 * i), marker("ev", i)]
                if member.session == sender.session { expected.append(marker("rs", i)) }
            }
            #expect(received == expected, "\(member.session.rawValue): received \(received)")
        }
    }

    @Test("the sync cycle does not wait for the transport: syncNow returns and endSync runs while sends are blocked")
    func cycleDoesNotWaitForTheTransport() async throws {
        let transport = BlockingTransport()
        let definition = Land("ordered-send-blocking", using: OrderedSendTestState.self) {
            Rules {
                OnJoin { (state: inout OrderedSendTestState, ctx: LandContext) in
                    state.mine[ctx.playerID] = marker("pp", 0)
                }
                HandleAction(OrderedSendSetAction.self) { (state: inout OrderedSendTestState, action: OrderedSendSetAction, _: LandContext) in
                    state.stamp = marker("mk", action.stamp)
                    if action.mine >= 0 {
                        for playerID in Array(state.mine.keys) {
                            state.mine[playerID] = marker("pp", action.mine)
                        }
                    }
                    return OrderedSendSetResponse(echo: marker("rs", action.echo))
                }
            }
        }
        let keeper = LandKeeper<OrderedSendTestState>(definition: definition, initialState: OrderedSendTestState())
        let adapter = TransportAdapter<OrderedSendTestState>(
            keeper: keeper,
            transport: transport,
            landID: "ordered-send-blocking",
            encodingConfig: .messagepack,
            suppressMissingPathHashesWarning: true
        )
        await transport.setDelegate(adapter)
        let member = OrderedSendMember("blocking")
        await adapter.onConnect(sessionID: member.session, clientID: member.client)
        try await simulateRouterJoin(
            adapter: adapter, keeper: keeper,
            sessionID: member.session, clientID: member.client, playerID: member.player
        )
        await adapter.syncNow()
        try await waitUntilTransportIdle(transport)

        transport.block()
        let cycles = 3
        for i in 1...cycles {
            let envelope = ActionEnvelope(
                typeIdentifier: String(describing: OrderedSendSetAction.self),
                payload: AnyCodable(OrderedSendSetAction(stamp: i, mine: i, echo: 0))
            )
            _ = try await keeper.handleActionEnvelope(
                envelope, playerID: member.player, clientID: member.client, sessionID: member.session
            )
            let returned = OrderedSendFlag()
            Task {
                await adapter.syncNow()
                returned.set()
            }
            try await orderedWaitUntil("syncNow \(i) to return while the transport is blocked") { returned.isSet }
            // endSync ran: a new cycle can begin.
            let state = await keeper.beginSync(clearDirtyFlags: false)
            #expect(state != nil, "cycle \(i) must have ended (endSync) while the transport is blocked")
            if state != nil { await keeper.endSync() }
        }

        // Cycle 1's element blocks in the transport; cycles 2...n are skipped while it is in the
        // writer (sync back-pressure) and run once, after the release, with the latest state.
        #expect(await adapter.syncSkipCounts().outboundBacklog == cycles - 1)
        transport.release()
        try await orderedWaitUntil("the deferred cycle to deliver the latest state") {
            markerSequence("mk", in: transport.frames(for: member.session)).contains(cycles)
        }
        let frames = transport.frames(for: member.session)
        let stamps = markerSequence("mk", in: frames).filter { $0 > 0 }
        let mine = markerSequence("pp", in: frames).filter { $0 > 0 }
        #expect(stamps == [1, cycles], "broadcast markers after release: \(stamps)")
        #expect(mine == [1, cycles], "per-player markers after release: \(mine)")
    }

    @Test("WebSocketTransport exposes no polling send queue")
    func webSocketTransportHasNoSendQueue() {
        let transport = WebSocketTransport()
        #expect(transport.transportSendQueue == nil, "the polling drain task must not exist")
    }

}

// MARK: - Blocking transport

final class OrderedSendFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

func orderedWaitUntil(
    _ what: String,
    timeout: Duration = .seconds(3),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

func waitUntilTransportIdle(_ transport: BlockingTransport) async throws {
    var last = -1
    for _ in 0..<100 {
        let now = transport.frameCount
        if now == last { return }
        last = now
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Lock-protected state of `BlockingTransport`, readable from the test without hopping onto it.
final class BlockingTransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(SessionID?, Data)] = []
    private var isBlocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var closed: [SessionID] = []

    func recordClose(_ sessionID: SessionID) { lock.lock(); closed.append(sessionID); lock.unlock() }
    var closedSessions: [SessionID] { lock.lock(); defer { lock.unlock() }; return closed }

    func block() { lock.lock(); isBlocked = true; lock.unlock() }

    func release() {
        lock.lock()
        isBlocked = false
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return recorded.count }

    func frames(for session: SessionID) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return recorded.compactMap { $0.0 == session ? $0.1 : nil }
    }

    func record(_ data: Data, _ target: SwiftStateTreeTransport.EventTarget) {
        lock.lock(); defer { lock.unlock() }
        if case .session(let id) = target { recorded.append((id, data)) } else { recorded.append((nil, data)) }
    }

    func waitIfBlocked() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isBlocked {
                waiters.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }
}

/// Records frames when a send starts; while blocked, `sendBatch` does not return until `release()`.
actor BlockingTransport: Transport {
    nonisolated let box = BlockingTransportBox()
    var delegate: TransportDelegate?

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}

    nonisolated func block() { box.block() }
    nonisolated func release() { box.release() }
    nonisolated var frameCount: Int { box.frameCount }
    nonisolated func frames(for session: SessionID) -> [Data] { box.frames(for: session) }
    /// Sessions closed through `closeSession`, in call order.
    nonisolated var closedSessions: [SessionID] { box.closedSessions }

    func closeSession(_ sessionID: SessionID) async {
        box.recordClose(sessionID)
    }

    nonisolated var supportsCloseSession: Bool { true }

    /// `Transport.send` is synchronous: it records and returns. Only `sendBatch` can block.
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        box.record(message, target)
    }

    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates { box.record(data, target) }
        await box.waitIfBlocked()
    }
}
