// Sources/ServerLoadTest/ClientSimulator.swift
//
// Async client simulator that runs join/action loops independently.

import Foundation
import GameContent
import LoadTestPacing
import SwiftStateTree
import SwiftStateTreeDeterministicMath
import SwiftStateTreeTransport

// MARK: - Client Simulator

actor ClientSimulator {
    enum Phase: Sendable {
        case rampUp
        case steady
        case rampDown
        case done
    }

    /// One send the paced generator schedules.
    enum Work: Sendable {
        case join
        case action(SessionID, Data)
    }

    private let config: LoadTestConfig
    private let roomManager: RoomManager
    private let traffic: TrafficCounter
    private let transport: WebSocketTransport
    private let messageKindRecorder: MessageKindRecorder?
    private let streamDump: StreamDump?
    private let makeJoinData: @Sendable (Int, Int) throws -> Data
    private let makeClientEventData: @Sendable (Int) throws -> Data
    /// Caps joins and actions in flight (`--max-in-flight`; paced modes only).
    let inFlight: LoadTestPacing.InFlightLimit
    /// The clients' sync acks (#332): a hosted land closes a client that doesn't ack.
    let syncAcks = SyncAckClients()
    private let ackBinary: Bool

    private var isRunning = true
    private(set) var phase: Phase = .rampUp
    private(set) var totalPlayersAssigned = 0
    /// Joins started and not finished yet; they count toward the ramp target.
    private var joinsInFlight = 0
    /// Actions started, counted as each send starts; samplers take deltas of it.
    private(set) var totalActionsSent = 0
    /// Actions whose send to the transport has returned.
    private(set) var totalActionsCompleted = 0
    private(set) var elapsedSeconds = 0
    /// Per-second pacing stats (paced modes), by second.
    private(set) var periodStats: [LoadTestPacing.PeriodStats] = []
    /// Running totals of `periodStats` for the progress log.
    private(set) var lateSecondsSoFar = 0
    private(set) var skippedByCapSoFar = 0

    init(
        config: LoadTestConfig,
        roomManager: RoomManager,
        traffic: TrafficCounter,
        transport: WebSocketTransport,
        makeJoinData: @escaping @Sendable (Int, Int) throws -> Data,
        makeClientEventData: @escaping @Sendable (Int) throws -> Data,
        messageKindRecorder: MessageKindRecorder?,
        streamDump: StreamDump? = nil,
        ackBinary: Bool
    ) {
        self.ackBinary = ackBinary
        self.streamDump = streamDump
        self.config = config
        self.roomManager = roomManager
        self.traffic = traffic
        self.transport = transport
        self.makeJoinData = makeJoinData
        self.makeClientEventData = makeClientEventData
        self.messageKindRecorder = messageKindRecorder
        inFlight = LoadTestPacing.InFlightLimit(cap: config.maxInFlight)
    }

    func stop() {
        isRunning = false
        phase = .done
    }

    /// Run the client simulation from `origin`. This function runs independently and does not
    /// block the main measurement loop. Returns when every started send has finished.
    func run(origin: ContinuousClock.Instant) async {
        let acks = Task { [self] in await runAcks() }
        defer { acks.cancel() }
        switch config.pacing {
        case .spread:
            await runPaced(origin: origin, mode: .spread)
        case .aligned:
            await runPaced(origin: origin, mode: .aligned)
        case .legacy:
            await LoadTestPacing.sleep(until: origin)
            await runLegacy()
        }
        phase = .done
    }

    /// Every client acks its last received sequence once a second, as the SDK does.
    private nonisolated func runAcks() async {
        while !Task.isCancelled, await isRunning {
            try? await safeTaskSleep(for: .seconds(1))
            for (sessionID, ack) in await syncAcks.acks(binary: ackBinary) {
                await traffic.recordSent(bytes: ack.count)
                await transport.handleIncomingMessage(sessionID: sessionID, data: ack)
            }
        }
    }

    // MARK: - Paced modes (spread, aligned)

    /// Second `t` starts on its own deadline `origin + t s`, whether or not the previous second's
    /// sends have finished; joins and actions share one in-flight cap. Per-second stats record
    /// start lag, sends in flight at the deadline, sends skipped by the cap and late seconds.
    private func runPaced(origin: ContinuousClock.Instant, mode: LoadTestPacing.Mode) async {
        await LoadTestPacing.runPeriods(
            origin: origin,
            period: .seconds(1),
            count: config.totalSeconds,
            limit: inFlight,
            shouldContinue: { [self] in await isRunning },
            plan: { [self] t in await planSecond(t, mode: mode) },
            perform: { [self] work in await perform(work) },
            skipped: { [self] work in await skippedByCap(work) },
            onPeriod: { [self] stats in await record(stats) }
        )
    }

    private func record(_ stats: LoadTestPacing.PeriodStats) {
        periodStats.append(stats)
        if stats.late { lateSecondsSoFar += 1 }
        skippedByCapSoFar += stats.skippedByCap
    }

    /// Phase bookkeeping and ramp-down for second `t`, and the second's joins and actions.
    private func planSecond(_ t: Int, mode: LoadTestPacing.Mode) async -> [LoadTestPacing.Scheduled<Work>] {
        elapsedSeconds = t
        let totalPlayers = config.totalPlayers
        let isRampUp = t < config.rampUpSeconds
        let isSteady = t >= config.rampUpSeconds && t < (config.rampUpSeconds + config.durationSeconds)
        let isRampDown = t >= (config.rampUpSeconds + config.durationSeconds) && config.rampDownSeconds > 0

        // Ramp up continues past rampUpSeconds until every player is assigned.
        let reserved = totalPlayersAssigned + joinsInFlight
        if reserved < totalPlayers || isRampUp {
            phase = .rampUp
        } else if isSteady {
            phase = .steady
        } else if isRampDown {
            phase = .rampDown
        }

        var work: [LoadTestPacing.Scheduled<Work>] = []
        let joins = max(0, min(config.playersPerSecondUp, totalPlayers - reserved))
        joinsInFlight += joins
        for send in LoadTestPacing.joinPlan(count: joins, period: .seconds(1), mode: mode) {
            work.append(.init(offset: send.offset, item: .join))
        }

        // A ramp-down second closes its sessions here, and its actions go only to the others
        // (`LoadTestPacing.rampDownPeriod`): the work runs after this returns.
        var sessions = await roomManager.getJoinedSessions()
        if isRampDown {
            let split = LoadTestPacing.rampDownPeriod(joined: sessions, closeCount: config.sessionsPerSecondDown)
            await close(split.closing)
            sessions = split.actionTargets
        }

        if (isSteady || isRampDown), config.actionsPerPlayerPerSecond > 0 {
            if !sessions.isEmpty, let payload = try? makeClientEventData(t) {
                let plan = LoadTestPacing.actionPlan(
                    keys: sessions.map(\.rawValue),
                    perKey: config.actionsPerPlayerPerSecond,
                    period: .seconds(1),
                    mode: mode
                )
                for send in plan {
                    work.append(.init(offset: send.offset, item: .action(sessions[send.index], payload)))
                }
                work.sort { $0.offset < $1.offset }
            }
        }
        return work
    }

    private nonisolated func perform(_ work: Work) async {
        switch work {
        case .join:
            let joined = await joinOnePlayer()
            await joinFinished(joined)
        case let .action(sessionID, payload):
            await actionStarted()
            await sendAction(sessionID: sessionID, payload: payload)
            await actionCompleted()
        }
    }

    private func skippedByCap(_ work: Work) {
        if case .join = work {
            joinsInFlight -= 1
        }
    }

    private func joinFinished(_ joined: Bool) {
        joinsInFlight -= 1
        if joined {
            totalPlayersAssigned += 1
        }
    }

    private func actionStarted() {
        totalActionsSent += 1
    }

    private func actionCompleted() {
        totalActionsCompleted += 1
    }

    private nonisolated func sendAction(sessionID: SessionID, payload: Data) async {
        await traffic.recordSent(bytes: payload.count) // Client sends Action
        await transport.handleIncomingMessage(sessionID: sessionID, data: payload)
    }

    /// Assigns, connects and joins one player; false when assignment or the join data failed.
    private nonisolated func joinOnePlayer() async -> Bool {
        guard let (roomIndex, playerIndexInRoom, sessionID) = await roomManager.assignPlayer() else {
            return false
        }
        let conn = CountingWebSocketConnection(
            counter: traffic,
            syncAcks: syncAcks,
            sessionID: sessionID,
            streamDump: streamDump,
            streamName: "room-\(roomIndex)-\(sessionID.rawValue)",
            onJoinSuccess: { [roomManager] sessionID, features in
                await roomManager.markPlayerJoined(sessionID: sessionID, features: features)
            },
            messageKindRecorder: messageKindRecorder
        )
        await transport.handleConnection(sessionID: sessionID, connection: conn, authInfo: nil)
        do {
            let joinData = try makeJoinData(roomIndex, playerIndexInRoom)
            await traffic.recordSent(bytes: joinData.count) // Client sends Join
            await transport.handleIncomingMessage(sessionID: sessionID, data: joinData)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Legacy mode

    /// The generator before deadline pacing: each second's joins go through a worker pool capped
    /// at `max(20, 1.5 × rate)`, each round of actions is sent to every session at once and
    /// awaited before the next round, and the loop sleeps a full second after the work, so a
    /// second lasts 1 s + work time.
    private func runLegacy() async {
        let totalPlayers = config.totalPlayers
        for t in 0 ..< config.totalSeconds {
            guard isRunning else { break }
            elapsedSeconds = t
            let isRampUp = t < config.rampUpSeconds
            let isSteady = t >= config.rampUpSeconds && t < (config.rampUpSeconds + config.durationSeconds)
            let isRampDown = t >= (config.rampUpSeconds + config.durationSeconds) && config.rampDownSeconds > 0

            if totalPlayersAssigned < totalPlayers {
                phase = .rampUp
                await legacyRampUp(totalPlayers: totalPlayers)
            } else if isRampUp {
                phase = .rampUp
            } else if isSteady {
                phase = .steady
            } else if isRampDown {
                phase = .rampDown
            }
            if isSteady || isRampDown {
                await legacyActions(t: t)
            }
            if isRampDown {
                await performRampDown()
            }
            try? await safeTaskSleep(for: .seconds(1))
        }
    }

    private func legacyRampUp(totalPlayers: Int) async {
        let playersPerSecondUp = config.playersPerSecondUp
        let playersToJoin = min(totalPlayers, totalPlayersAssigned + playersPerSecondUp) - totalPlayersAssigned
        guard playersToJoin > 0 else { return }
        let maxConcurrentJoins = max(20, Int(Double(playersPerSecondUp) * 1.5))
        var successful = 0
        await withTaskGroup(of: Bool.self) { group in
            var submitted = 0
            var completed = 0
            while submitted < playersToJoin || completed < submitted {
                while submitted < playersToJoin, (submitted - completed) < maxConcurrentJoins {
                    group.addTask { [self] in await joinOnePlayer() }
                    submitted += 1
                }
                if let success = await group.next() {
                    if success { successful += 1 }
                    completed += 1
                }
            }
        }
        totalPlayersAssigned += successful
    }

    private func legacyActions(t: Int) async {
        guard config.actionsPerPlayerPerSecond > 0 else { return }
        let sessions = await roomManager.getJoinedSessions()
        guard !sessions.isEmpty, let payload = try? makeClientEventData(t) else { return }
        for _ in 0 ..< config.actionsPerPlayerPerSecond {
            totalActionsSent += sessions.count
            await withTaskGroup(of: Void.self) { group in
                for sessionID in sessions {
                    group.addTask { [self] in await sendAction(sessionID: sessionID, payload: payload) }
                }
            }
            totalActionsCompleted += sessions.count
        }
    }

    // MARK: - Ramp down

    private func performRampDown() async {
        let connectedSessions = await roomManager.getJoinedSessions()
        await close(LoadTestPacing.rampDownPeriod(joined: connectedSessions, closeCount: config.sessionsPerSecondDown).closing)
    }

    private func close(_ closing: [SessionID]) async {
        for sessionID in closing {
            await transport.handleDisconnection(sessionID: sessionID)
            await syncAcks.ended(sessionID)
            await roomManager.removeSession(sessionID)
        }
    }
}

// MARK: - Counting WebSocket Connection

struct CountingWebSocketConnection: WebSocketConnection, Sendable {
    let counter: TrafficCounter
    let syncAcks: SyncAckClients
    let sessionID: SessionID
    let streamDump: StreamDump?
    let streamName: String
    let onJoinSuccess: (@Sendable (SessionID, [String]?) async -> Void)?
    let messageKindRecorder: MessageKindRecorder?

    func send(_ data: Data) async throws {
        // Server sends to Client = Client receives
        await counter.recordReceived(bytes: data.count, sessionID: sessionID)
        if let seq = SyncSequencePeek.seq(data) {
            await syncAcks.received(seq, sessionID: sessionID)
        }
        if let streamDump {
            await streamDump.append(data, to: streamName)
        }
        if let messageKindRecorder {
            await messageKindRecorder.record(data: data)
        }

        // Detect a successful JoinResponse to mark the session joined, with the features it was given.
        if let onJoinSuccess = onJoinSuccess,
           let json = try? JSONSerialization.jsonObject(with: data),
           let features = successfulJoinFeatures(json) {
            await onJoinSuccess(sessionID, features)
        }
    }

    func close() async throws {}

    func close(with close: SessionClose) async throws {
        await syncAcks.closedByServer(sessionID, code: close.code)
    }
}
