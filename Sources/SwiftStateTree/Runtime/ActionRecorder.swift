import Foundation

// MARK: - Re-evaluation Record Data Structures

/// Recorded resolver output with type information for re-evaluation validation.
public struct ReevaluationRecordedResolverOutput: Codable, Sendable {
    /// Type identifier of the resolver output (e.g., "SlowDeterministicOutput")
    public let typeIdentifier: String
    /// The actual resolver output value as AnyCodable
    public let value: AnyCodable
    
    public init(typeIdentifier: String, value: AnyCodable) {
        self.typeIdentifier = typeIdentifier
        self.value = value
    }
}

/// Metadata describing the land instance and initialization parameters for a re-evaluation record.
public struct ReevaluationRecordMetadata: Codable, Sendable {
    public let landID: String
    public let landType: String
    public let createdAt: Date

    /// Land creation parameters (e.g., mapId, gameMode, difficulty).
    public let metadata: [String: String]

    /// Optional identifier for the land definition used to create this land.
    public let landDefinitionID: String?

    /// Optional hash of the initial state for debugging/verification.
    public let initialStateHash: String?

    /// Optional extended configuration (e.g., tick interval, sync settings).
    public let landConfig: [String: AnyCodable]?

    /// Optional RNG seed used for deterministic random number generation.
    /// This is critical for deterministic re-evaluation when RNG is used in game logic.
    public let rngSeed: UInt64?

    /// Optional rule variant identifier (reserved for future Rule Re-evaluation).
    public let ruleVariantId: String?

    /// Optional rule parameters overlay (reserved for future Rule Re-evaluation).
    public let ruleParams: [String: AnyCodable]?

    /// Optional record format version.
    public let version: String?

    /// Optional extensions for future land-specific data.
    public let extensions: [String: AnyCodable]?
    
    /// Hardware information where the record was created.
    /// Used to verify deterministic behavior across different CPU architectures.
    public let hardwareInfo: HardwareInfo?

    public init(
        landID: String,
        landType: String,
        createdAt: Date,
        metadata: [String: String],
        landDefinitionID: String? = nil,
        initialStateHash: String? = nil,
        landConfig: [String: AnyCodable]? = nil,
        rngSeed: UInt64? = nil,
        ruleVariantId: String? = nil,
        ruleParams: [String: AnyCodable]? = nil,
        version: String? = nil,
        extensions: [String: AnyCodable]? = nil,
        hardwareInfo: HardwareInfo? = nil
    ) {
        self.landID = landID
        self.landType = landType
        self.createdAt = createdAt
        self.metadata = metadata
        self.landDefinitionID = landDefinitionID
        self.initialStateHash = initialStateHash
        self.landConfig = landConfig
        self.rngSeed = rngSeed
        self.ruleVariantId = ruleVariantId
        self.ruleParams = ruleParams
        self.version = version
        self.extensions = extensions
        self.hardwareInfo = hardwareInfo
    }
}

/// Recorded lifecycle event for re-evaluation (initialize/join/leave).
public struct ReevaluationRecordedLifecycleEvent: Codable, Sendable {
    public let kind: String // "initialize" | "join" | "leave" | "landCreated"
    public let sequence: Int64
    public let tickId: Int64
    public let playerID: String?
    public let clientID: String?
    public let sessionID: String?
    public let deviceID: String?
    public let isGuest: Bool?
    public let metadata: [String: String]
    public let resolverOutputs: [String: ReevaluationRecordedResolverOutput]
    public let resolvedAtTick: Int64

    public init(
        kind: String,
        sequence: Int64,
        tickId: Int64,
        playerID: String?,
        clientID: String?,
        sessionID: String?,
        deviceID: String?,
        isGuest: Bool?,
        metadata: [String: String],
        resolverOutputs: [String: ReevaluationRecordedResolverOutput],
        resolvedAtTick: Int64
    ) {
        self.kind = kind
        self.sequence = sequence
        self.tickId = tickId
        self.playerID = playerID
        self.clientID = clientID
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.isGuest = isGuest
        self.metadata = metadata
        self.resolverOutputs = resolverOutputs
        self.resolvedAtTick = resolvedAtTick
    }
}

/// A single tick frame of recorded inputs and outputs for deterministic re-evaluation.
public struct ReevaluationTickFrame: Codable, Sendable {
    public let tickId: Int64
    /// Optional per-tick state hash recorded in live mode (ground truth).
    public let stateHash: String?
    public let actions: [ReevaluationRecordedAction]
    public let clientEvents: [ReevaluationRecordedClientEvent]
    public let lifecycleEvents: [ReevaluationRecordedLifecycleEvent]
    /// Server events emitted during this tick (for verification).
    public let serverEvents: [ReevaluationRecordedServerEvent]

    public init(
        tickId: Int64,
        stateHash: String? = nil,
        actions: [ReevaluationRecordedAction],
        clientEvents: [ReevaluationRecordedClientEvent],
        lifecycleEvents: [ReevaluationRecordedLifecycleEvent],
        serverEvents: [ReevaluationRecordedServerEvent] = []
    ) {
        self.tickId = tickId
        self.stateHash = stateHash
        self.actions = actions
        self.clientEvents = clientEvents
        self.lifecycleEvents = lifecycleEvents
        self.serverEvents = serverEvents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tickId = try container.decode(Int64.self, forKey: .tickId)
        stateHash = try container.decodeIfPresent(String.self, forKey: .stateHash)
        actions = try container.decode([ReevaluationRecordedAction].self, forKey: .actions)
        clientEvents = try container.decode([ReevaluationRecordedClientEvent].self, forKey: .clientEvents)
        lifecycleEvents = try container.decode([ReevaluationRecordedLifecycleEvent].self, forKey: .lifecycleEvents)
        serverEvents = try container.decodeIfPresent([ReevaluationRecordedServerEvent].self, forKey: .serverEvents) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case tickId, stateHash, actions, clientEvents, lifecycleEvents, serverEvents
    }
}

/// Recorded action for re-evaluation.
public struct ReevaluationRecordedAction: Codable, Sendable {
    public let kind: String // "action"
    public let sequence: Int64
    public let typeIdentifier: String
    public let payload: AnyCodable
    public let playerID: String
    public let clientID: String
    public let sessionID: String
    public let resolverOutputs: [String: ReevaluationRecordedResolverOutput]
    public let resolvedAtTick: Int64
    
    public init(
        kind: String,
        sequence: Int64,
        typeIdentifier: String,
        payload: AnyCodable,
        playerID: String,
        clientID: String,
        sessionID: String,
        resolverOutputs: [String: ReevaluationRecordedResolverOutput],
        resolvedAtTick: Int64
    ) {
        self.kind = kind
        self.sequence = sequence
        self.typeIdentifier = typeIdentifier
        self.payload = payload
        self.playerID = playerID
        self.clientID = clientID
        self.sessionID = sessionID
        self.resolverOutputs = resolverOutputs
        self.resolvedAtTick = resolvedAtTick
    }
}

/// Recorded client event for re-evaluation.
public struct ReevaluationRecordedClientEvent: Codable, Sendable {
    public let kind: String // "clientEvent"
    public let sequence: Int64
    public let typeIdentifier: String
    public let payload: AnyCodable
    public let playerID: String
    public let clientID: String
    public let sessionID: String
    public let resolvedAtTick: Int64
    
    public init(
        kind: String,
        sequence: Int64,
        typeIdentifier: String,
        payload: AnyCodable,
        playerID: String,
        clientID: String,
        sessionID: String,
        resolvedAtTick: Int64
    ) {
        self.kind = kind
        self.sequence = sequence
        self.typeIdentifier = typeIdentifier
        self.payload = payload
        self.playerID = playerID
        self.clientID = clientID
        self.sessionID = sessionID
        self.resolvedAtTick = resolvedAtTick
    }
}

/// Recorded server event for re-evaluation.
public struct ReevaluationRecordedServerEvent: Codable, Sendable {
    public let kind: String // "serverEvent"
    public let sequence: Int64
    public let tickId: Int64
    public let typeIdentifier: String
    public let payload: AnyCodable
    public let target: ReevaluationEventTargetRecord
    
    public init(
        kind: String,
        sequence: Int64,
        tickId: Int64,
        typeIdentifier: String,
        payload: AnyCodable,
        target: ReevaluationEventTargetRecord
    ) {
        self.kind = kind
        self.sequence = sequence
        self.tickId = tickId
        self.typeIdentifier = typeIdentifier
        self.payload = payload
        self.target = target
    }
}

/// Serializable representation of EventTarget.
public struct ReevaluationEventTargetRecord: Codable, Sendable {
    public let kind: String // "all" | "player" | "client" | "session" | "players"
    public let ids: [String]
    
    public init(kind: String, ids: [String]) {
        self.kind = kind
        self.ids = ids
    }
    
    /// Convert EventTarget to ReevaluationEventTargetRecord.
    public static func from(_ target: EventTarget) -> ReevaluationEventTargetRecord {
        switch target {
        case .all:
            return ReevaluationEventTargetRecord(kind: "all", ids: [])
        case .player(let playerID):
            return ReevaluationEventTargetRecord(kind: "player", ids: [playerID.rawValue])
        case .client(let clientID):
            return ReevaluationEventTargetRecord(kind: "client", ids: [clientID.rawValue])
        case .session(let sessionID):
            return ReevaluationEventTargetRecord(kind: "session", ids: [sessionID.rawValue])
        case .players(let playerIDs):
            return ReevaluationEventTargetRecord(kind: "players", ids: playerIDs.map { $0.rawValue })
        }
    }
}

// MARK: - ReevaluationRecorder Actor

/// Actor responsible for recording inputs and outputs for deterministic re-evaluation.
public actor ReevaluationRecorder {
    private var metadata: ReevaluationRecordMetadata?
    private var frames: [ReevaluationTickFrame] = []
    private var currentFrame: ReevaluationTickFrame?
    private var currentTickId: Int64 = -1
    private let flushInterval: Int64
    private var lastFlushTick: Int64 = -1
    
    public init(flushInterval: Int64 = 60) {
        self.flushInterval = flushInterval
    }

    /// Set record metadata (required before saving).
    public func setMetadata(_ metadata: ReevaluationRecordMetadata) {
        self.metadata = metadata
    }

    public func getMetadata() -> ReevaluationRecordMetadata? {
        metadata
    }
    
    /// Record actions and client events for a specific tick.
    public func record(
        tickId: Int64,
        actions: [ReevaluationRecordedAction],
        clientEvents: [ReevaluationRecordedClientEvent],
        lifecycleEvents: [ReevaluationRecordedLifecycleEvent]
    ) {
        // If this is a new tick, finalize the previous frame
        if tickId != currentTickId {
            if let frame = currentFrame {
                frames.append(frame)
            }
            currentTickId = tickId
            currentFrame = ReevaluationTickFrame(
                tickId: tickId,
                stateHash: nil,
                actions: [],
                clientEvents: [],
                lifecycleEvents: [],
                serverEvents: []
            )
        }
        
        // Append actions and client events to current frame
        guard var frame = currentFrame else {
            // Should not happen, but handle gracefully
            currentFrame = ReevaluationTickFrame(
                tickId: tickId,
                stateHash: nil,
                actions: actions,
                clientEvents: clientEvents,
                lifecycleEvents: lifecycleEvents,
                serverEvents: []
            )
            return
        }
        
        frame = ReevaluationTickFrame(
            tickId: frame.tickId,
            stateHash: frame.stateHash,
            actions: frame.actions + actions,
            clientEvents: frame.clientEvents + clientEvents,
            lifecycleEvents: frame.lifecycleEvents + lifecycleEvents,
            serverEvents: frame.serverEvents
        )
        currentFrame = frame
    }
    
    public func recordLifecycleEvent(_ event: ReevaluationRecordedLifecycleEvent) {
        // Find or create frame for this tick
        if event.tickId != currentTickId {
            if let frame = currentFrame {
                frames.append(frame)
            }
            currentTickId = event.tickId
            currentFrame = ReevaluationTickFrame(
                tickId: event.tickId,
                stateHash: nil,
                actions: [],
                clientEvents: [],
                lifecycleEvents: [],
                serverEvents: []
            )
        }

        guard var frame = currentFrame else {
            currentFrame = ReevaluationTickFrame(
                tickId: event.tickId,
                stateHash: nil,
                actions: [],
                clientEvents: [],
                lifecycleEvents: [event],
                serverEvents: []
            )
            return
        }

        frame = ReevaluationTickFrame(
            tickId: frame.tickId,
            stateHash: frame.stateHash,
            actions: frame.actions,
            clientEvents: frame.clientEvents,
            lifecycleEvents: frame.lifecycleEvents + [event],
            serverEvents: frame.serverEvents
        )
        currentFrame = frame
    }

    /// Set the per-tick state hash (live ground truth).
    public func setStateHash(tickId: Int64, stateHash: String) {
        if tickId != currentTickId {
            if let frame = currentFrame {
                frames.append(frame)
            }
            currentTickId = tickId
            currentFrame = ReevaluationTickFrame(
                tickId: tickId,
                stateHash: stateHash,
                actions: [],
                clientEvents: [],
                lifecycleEvents: [],
                serverEvents: []
            )
            return
        }

        guard let frame = currentFrame else {
            currentFrame = ReevaluationTickFrame(
                tickId: tickId,
                stateHash: stateHash,
                actions: [],
                clientEvents: [],
                lifecycleEvents: [],
                serverEvents: []
            )
            return
        }

        currentFrame = ReevaluationTickFrame(
            tickId: frame.tickId,
            stateHash: stateHash,
            actions: frame.actions,
            clientEvents: frame.clientEvents,
            lifecycleEvents: frame.lifecycleEvents,
            serverEvents: frame.serverEvents
        )
    }

    /// Record server events emitted for a specific tick.
    public func recordServerEvents(tickId: Int64, events: [ReevaluationRecordedServerEvent]) {
        if tickId != currentTickId {
            if let frame = currentFrame {
                frames.append(frame)
            }
            currentTickId = tickId
            currentFrame = ReevaluationTickFrame(
                tickId: tickId,
                stateHash: nil,
                actions: [],
                clientEvents: [],
                lifecycleEvents: [],
                serverEvents: events
            )
            return
        }
        guard let frame = currentFrame else {
            currentFrame = ReevaluationTickFrame(
                tickId: tickId,
                stateHash: nil,
                actions: [],
                clientEvents: [],
                lifecycleEvents: [],
                serverEvents: events
            )
            return
        }
        currentFrame = ReevaluationTickFrame(
            tickId: frame.tickId,
            stateHash: frame.stateHash,
            actions: frame.actions,
            clientEvents: frame.clientEvents,
            lifecycleEvents: frame.lifecycleEvents,
            serverEvents: events
        )
    }

    /// Flush frames to disk if needed (based on flushInterval)
    public func flushIfNeeded(currentTick: Int64) async throws {
        guard currentTick - lastFlushTick >= flushInterval else {
            return
        }

        // NOTE:
        // We currently do not flush to disk incrementally (save() writes everything).
        // Finalizing/clearing currentFrame here can create duplicate tick frames if more records
        // arrive for the same tick after "flush". We therefore only advance the flush marker.
        lastFlushTick = currentTick
    }
    
    /// Save all recorded tick frames to a JSON file.
    public func save(to filePath: String) async throws {
        guard let metadata = metadata else {
            throw NSError(domain: "ReevaluationRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Re-evaluation record metadata must be set before saving"
            ])
        }

        // Finalize current frame
        if let frame = currentFrame {
            frames.append(frame)
            currentFrame = nil
        }
        
        // Sort frames by tickId
        let sortedFrames = frames.sorted { $0.tickId < $1.tickId }

        struct ReevaluationRecordFile: Codable {
            let recordMetadata: ReevaluationRecordMetadata
            let tickFrames: [ReevaluationTickFrame]
        }

        let recordingFile = ReevaluationRecordFile(recordMetadata: metadata, tickFrames: sortedFrames)

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(recordingFile)
        
        // Write to file
        let url = URL(fileURLWithPath: filePath)
        try data.write(to: url)
    }

    /// Encode the current record into JSON data without mutating recorder state.
    public func encode() throws -> Data {
        guard let metadata = metadata else {
            throw NSError(domain: "ReevaluationRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Re-evaluation record metadata must be set before encoding"
            ])
        }

        let allFrames = frames + (currentFrame.map { [$0] } ?? [])
        let sortedFrames = allFrames.sorted { $0.tickId < $1.tickId }

        struct ReevaluationRecordFile: Codable {
            let recordMetadata: ReevaluationRecordMetadata
            let tickFrames: [ReevaluationTickFrame]
        }
        let recordingFile = ReevaluationRecordFile(recordMetadata: metadata, tickFrames: sortedFrames)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(recordingFile)
    }
    
    /// Get all recorded frames (for testing/debugging)
    public func getAllFrames() -> [ReevaluationTickFrame] {
        var allFrames = frames
        if let frame = currentFrame {
            allFrames.append(frame)
        }
        return allFrames.sorted { $0.tickId < $1.tickId }
    }
}
