// Sources/ServerLoadTest/ClientSimulator.swift
//
// Async client simulator that runs join/action loops independently.

import Foundation
import GameContent
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

    private let config: LoadTestConfig
    private let roomManager: RoomManager
    private let traffic: TrafficCounter
    private let transport: WebSocketTransport
    private let messageKindRecorder: MessageKindRecorder
    private let makeJoinData: @Sendable (Int, Int) throws -> Data
    private let makeClientEventData: @Sendable (Int) throws -> Data

    private var isRunning = true
    private(set) var phase: Phase = .rampUp
    private(set) var totalPlayersAssigned = 0
    private(set) var totalActionsSent = 0
    private var actionsSentInWindow = 0
    private(set) var elapsedSeconds = 0

    init(
        config: LoadTestConfig,
        roomManager: RoomManager,
        traffic: TrafficCounter,
        transport: WebSocketTransport,
        makeJoinData: @escaping @Sendable (Int, Int) throws -> Data,
        makeClientEventData: @escaping @Sendable (Int) throws -> Data,
        messageKindRecorder: MessageKindRecorder
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
    func run() async {
        let totalPlayers = config.totalPlayers
        let steadySeconds = config.durationSeconds
        let totalSeconds = config.totalSeconds

        for t in 0 ..< totalSeconds {
            guard isRunning else { break }
            elapsedSeconds = t

            // Determine phase
            let isRampUp = t < config.rampUpSeconds
            let isSteady = t >= config.rampUpSeconds && t < (config.rampUpSeconds + steadySeconds)
            let isRampDown = t >= (config.rampUpSeconds + steadySeconds) && config.rampDownSeconds > 0

            // Ramp up: Players join gradually until all are assigned
            // Continue even beyond rampUpSeconds if needed to ensure all players join
            if totalPlayersAssigned < totalPlayers {
                phase = .rampUp
                await performRampUp(t: t, totalPlayers: totalPlayers)
            } else if isRampUp {
                phase = .rampUp
            } else if isSteady {
                phase = .steady
            } else if isRampDown {
                phase = .rampDown
            }

            // Steady + ramp down: inject client events spread over the second
            if isSteady || isRampDown {
                await performActions(t: t)
            }

            // Ramp down: disconnect players gradually
            if isRampDown {
                await performRampDown()
            }

            // Wait for the next second
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        phase = .done
    }

    // MARK: - Private Methods

    private func performRampUp(t _: Int, totalPlayers: Int) async {
        let playersPerSecondUp = config.playersPerSecondUp
        let targetPlayersThisSecond = min(totalPlayers, totalPlayersAssigned + playersPerSecondUp)
        let playersToJoinThisSecond = targetPlayersThisSecond - totalPlayersAssigned

        guard playersToJoinThisSecond > 0 else { return }

        // Calculate maxConcurrentJoins based on target join rate
        // Use 1.5x multiplier to ensure we can meet the target rate even with network latency
        let maxConcurrentJoins = max(20, Int(Double(playersPerSecondUp) * 1.5))

        var successfulAssignments = 0

        // Worker pool pattern: limit concurrent tasks
        await withTaskGroup(of: Bool.self) { group in
            var submitted = 0
            var completed = 0

            while submitted < playersToJoinThisSecond || completed < submitted {
                // Fill worker pool up to maxConcurrentJoins
                while submitted < playersToJoinThisSecond, (submitted - completed) < maxConcurrentJoins {
                    group.addTask { [self] in
                        guard let (roomIndex, playerIndexInRoom, sessionID) = await roomManager.assignPlayer() else {
                            return false // Assignment failed
                        }

                        // Create connection with join success callback
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
                            return true // Assignment succeeded
                        } catch {
                            return false // Join data creation failed
                        }
                    }
                    submitted += 1
                }

                // Wait for one worker to complete
                if let success = await group.next() {
                    if success { successfulAssignments += 1 }
                    completed += 1
                }
            }
        }

        totalPlayersAssigned += successfulAssignments
    }

    private func performActions(t: Int) async {
        guard config.actionsPerPlayerPerSecond > 0 else { return }

        let connectedSessions = await roomManager.getJoinedSessions()
        guard !connectedSessions.isEmpty else { return }

        let actionsPerPlayer = config.actionsPerPlayerPerSecond

        do {
            let payloadData = try makeClientEventData(t)

            for _ in 0 ..< actionsPerPlayer {
                await withTaskGroup(of: Void.self) { group in
                    for sessionID in connectedSessions {
                        group.addTask { [self] in
                            await traffic.recordSent(bytes: payloadData.count) // Client sends Action
                            await transport.handleIncomingMessage(sessionID: sessionID, data: payloadData)
                        }
                    }
                }
            }

            totalActionsSent += connectedSessions.count * actionsPerPlayer
            actionsSentInWindow += connectedSessions.count * actionsPerPlayer
        } catch {
            // Log error but continue
        }
    }

    func getAndResetActionCount() -> Int {
        let count = actionsSentInWindow
        actionsSentInWindow = 0
        return count
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
    let messageKindRecorder: MessageKindRecorder

    func send(_ data: Data) async throws {
        // Server sends to Client = Client receives
        await counter.recordReceived(bytes: data.count)
        await messageKindRecorder.record(data: data)

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
