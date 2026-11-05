// Sources/ServerLoadTest/ClientSimulator.swift
//
// Async client simulator that runs join/action loops independently.

import Foundation
import GameContent
import SwiftStateTree
import SwiftStateTreeDeterministicMath
import SwiftStateTreeTransport
import LoadTestPacing

// MARK: - Client Simulator

actor ClientSimulator {
    enum Phase: Sendable {
        case rampUp
        case steady
        case rampDown
        case done
    }

    private let config: LoadTestConfig
    private let roomManager: RoomManager
    private let traffic: TrafficCounter
    private let transport: WebSocketTransport
    private let messageKindRecorder: MessageKindRecorder?
    private let makeJoinData: @Sendable (Int, Int) throws -> Data
    private let makeClientEventData: @Sendable (Int) throws -> Data

    private var isRunning = true
    private(set) var phase: Phase = .rampUp
    private(set) var totalPlayersAssigned = 0
    /// Actions sent so far, counted as each one is sent; samplers take deltas of it.
    private(set) var totalActionsSent = 0
    private(set) var elapsedSeconds = 0

    init(
        config: LoadTestConfig,
        roomManager: RoomManager,
        traffic: TrafficCounter,
        transport: WebSocketTransport,
        makeJoinData: @escaping @Sendable (Int, Int) throws -> Data,
        makeClientEventData: @escaping @Sendable (Int) throws -> Data,
        messageKindRecorder: MessageKindRecorder?
    ) {
        self.config = config
        self.roomManager = roomManager
        self.traffic = traffic
        self.transport = transport
        self.makeJoinData = makeJoinData
        self.makeClientEventData = makeClientEventData
        self.messageKindRecorder = messageKindRecorder
    }

    func stop() {
        isRunning = false
        phase = .done
    }

    /// Run the client simulation loop asynchronously.
    /// This function runs independently and does not block the main measurement loop.
    ///
    /// Second `t` starts at `origin + t s` (deadline-based: work time doesn't push later seconds
    /// back). Within a second, joins are spread evenly and each session's actions sit at a stable
    /// per-session offset (see `LoadTestPacing`), so the server sees no once-per-second burst.
    func run(origin: ContinuousClock.Instant) async {
        let totalPlayers = config.totalPlayers
        let steadySeconds = config.durationSeconds
        let totalSeconds = config.totalSeconds
        for t in 0 ..< totalSeconds {
            guard isRunning else { break }
            elapsedSeconds = t
            let secondStart = origin + .seconds(t)
            // Determine phase
            let isRampUp = t < config.rampUpSeconds
            let isSteady = t >= config.rampUpSeconds && t < (config.rampUpSeconds + steadySeconds)
            let isRampDown = t >= (config.rampUpSeconds + steadySeconds) && config.rampDownSeconds > 0

            // Ramp up: Players join gradually until all are assigned
            // Continue even beyond rampUpSeconds if needed to ensure all players join
            let joining = totalPlayersAssigned < totalPlayers
            if joining {
                phase = .rampUp
            } else if isRampUp {
                phase = .rampUp
            } else if isSteady {
                phase = .steady
            } else if isRampDown {
                phase = .rampDown
            }

            // Joins and actions for this second run side by side, each paced over the second.
            async let joins: Void = joining ? performRampUp(totalPlayers: totalPlayers, from: secondStart) : ()
            async let actions: Void = (isSteady || isRampDown) ? performActions(from: secondStart) : ()
            _ = await (joins, actions)

            // Ramp down: disconnect players gradually
            if isRampDown {
                await performRampDown()
            }

            await LoadTestPacing.sleep(until: secondStart + .seconds(1))
        }
        phase = .done
    }

    // MARK: - Private Methods

    private func performRampUp(totalPlayers: Int, from secondStart: ContinuousClock.Instant) async {
        let targetPlayersThisSecond = min(totalPlayers, totalPlayersAssigned + config.playersPerSecondUp)
        let playersToJoinThisSecond = targetPlayersThisSecond - totalPlayersAssigned
        guard playersToJoinThisSecond > 0 else { return }

        let plan = LoadTestPacing.joinPlan(count: playersToJoinThisSecond, period: .seconds(1), mode: config.pacing)
        await LoadTestPacing.run(plan, from: secondStart) { [self] _ in
            if await joinOnePlayer() {
                await noteJoined()
            }
        }
    }

    private func noteJoined() {
        totalPlayersAssigned += 1
    }

    /// Assigns, connects and joins one player; false when assignment or the join data failed.
    private nonisolated func joinOnePlayer() async -> Bool {
        guard let (roomIndex, playerIndexInRoom, sessionID) = await roomManager.assignPlayer() else {
            return false
        }
        let conn = CountingWebSocketConnection(
            counter: traffic,
            sessionID: sessionID,
            onJoinSuccess: { [roomManager] sessionID in
                await roomManager.markPlayerJoined(sessionID: sessionID)
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

    private func performActions(from secondStart: ContinuousClock.Instant) async {
        guard config.actionsPerPlayerPerSecond > 0 else { return }

        let connectedSessions = await roomManager.getJoinedSessions()
        guard !connectedSessions.isEmpty else { return }

        let payloadData: Data
        do {
            payloadData = try makeClientEventData(elapsedSeconds)
        } catch {
            return
        }
        let plan = LoadTestPacing.actionPlan(
            keys: connectedSessions.map(\.rawValue),
            perKey: config.actionsPerPlayerPerSecond,
            period: .seconds(1),
            mode: config.pacing
        )
        let traffic = traffic
        let transport = transport
        await LoadTestPacing.run(plan, from: secondStart) { [self] index in
            let sessionID = connectedSessions[index]
            await traffic.recordSent(bytes: payloadData.count) // Client sends Action
            await transport.handleIncomingMessage(sessionID: sessionID, data: payloadData)
            await noteActionSent()
        }
    }

    private func noteActionSent() {
        totalActionsSent += 1
    }

    private func performRampDown() async {
        let connectedSessions = await roomManager.getJoinedSessions()
        guard !connectedSessions.isEmpty else { return }

        let sessionsToClose = min(connectedSessions.count, config.sessionsPerSecondDown)
        let closing = Array(connectedSessions.prefix(sessionsToClose))

        for sessionID in closing {
            await transport.handleDisconnection(sessionID: sessionID)
            await roomManager.removeSession(sessionID)
        }
    }
}

// MARK: - Counting WebSocket Connection

struct CountingWebSocketConnection: WebSocketConnection, Sendable {
    let counter: TrafficCounter
    let sessionID: SessionID
    let onJoinSuccess: (@Sendable (SessionID) async -> Void)?
    let messageKindRecorder: MessageKindRecorder?

    func send(_ data: Data) async throws {
        // Server sends to Client = Client receives
        await counter.recordReceived(bytes: data.count)
        if let messageKindRecorder {
            await messageKindRecorder.record(data: data)
        }

        // Detect JoinResponse message to mark session as joined
        if let onJoinSuccess = onJoinSuccess {
            if let json = try? JSONSerialization.jsonObject(with: data) {
                var isJoinResponse = false

                // Format 1: JSON object format
                if let dict = json as? [String: Any],
                   let kind = dict["kind"] as? String,
                   kind == "joinResponse",
                   let payload = dict["payload"] as? [String: Any],
                   let joinResponsePayload = payload["joinResponse"] as? [String: Any]
                {
                    if let successBool = joinResponsePayload["success"] as? Bool, successBool == true {
                        isJoinResponse = true
                    } else if let successInt = joinResponsePayload["success"] as? Int, successInt == 1 {
                        isJoinResponse = true
                    }
                }

                // Format 2: JSON opcode array format
                if !isJoinResponse,
                   let array = json as? [Any],
                   array.count >= 3,
                   let opcode = array[0] as? Int,
                   opcode == 105
                {
                    if let successInt = array[2] as? Int, successInt == 1 {
                        isJoinResponse = true
                    } else if let successBool = array[2] as? Bool, successBool == true {
                        isJoinResponse = true
                    }
                }

                if isJoinResponse {
                    await onJoinSuccess(sessionID)
                }
            }
        }
    }

    func close() async throws {}
}
