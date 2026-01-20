import Foundation

// MARK: - Recording Data Structures

/// Recorded resolver output with type information for replay validation
public struct RecordedResolverOutput: Codable, Sendable {
    /// Type identifier of the resolver output (e.g., "SlowDeterministicOutput")
    public let typeIdentifier: String
    /// The actual resolver output value as AnyCodable
    public let value: AnyCodable
    
    public init(typeIdentifier: String, value: AnyCodable) {
        self.typeIdentifier = typeIdentifier
        self.value = value
    }
}

/// Metadata describing the land instance and initialization parameters for a recording.
public struct RecordingMetadata: Codable, Sendable {
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
    /// This is critical for replay determinism when RNG is used in game logic.
    public let rngSeed: UInt64?

    /// Optional recording format version.
    public let version: String?

    /// Optional extensions for future land-specific data.
    public let extensions: [String: AnyCodable]?

    public init(
        landID: String,
        landType: String,
        createdAt: Date,
        metadata: [String: String],
        landDefinitionID: String? = nil,
        initialStateHash: String? = nil,
        landConfig: [String: AnyCodable]? = nil,
        rngSeed: UInt64? = nil,
        version: String? = nil,
        extensions: [String: AnyCodable]? = nil
    ) {
        self.landID = landID
        self.landType = landType
        self.createdAt = createdAt
        self.metadata = metadata
        self.landDefinitionID = landDefinitionID
        self.initialStateHash = initialStateHash
        self.landConfig = landConfig
        self.rngSeed = rngSeed
        self.version = version
        self.extensions = extensions
    }
}

/// Recorded lifecycle event for replay (initialize/join/leave).
public struct RecordedLifecycleEvent: Codable, Sendable {
    public let kind: String // "initialize" | "join" | "leave" | "landCreated"
    public let sequence: Int64
    public let tickId: Int64
    public let playerID: String?
    public let clientID: String?
    public let sessionID: String?
    public let deviceID: String?
    public let isGuest: Bool?
    public let metadata: [String: String]
    public let resolverOutputs: [String: RecordedResolverOutput]
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
        resolverOutputs: [String: RecordedResolverOutput],
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

/// A single frame of recorded actions and server events for a specific tick
public struct RecordingFrame: Codable, Sendable {
    public let tickId: Int64
    public let actions: [RecordedAction]
    public let clientEvents: [RecordedClientEvent]
    public let serverEvents: [RecordedServerEvent]
    public let lifecycleEvents: [RecordedLifecycleEvent]
    
    public init(
        tickId: Int64,
        actions: [RecordedAction],
        clientEvents: [RecordedClientEvent],
        serverEvents: [RecordedServerEvent],
        lifecycleEvents: [RecordedLifecycleEvent]
    ) {
        self.tickId = tickId
        self.actions = actions
        self.clientEvents = clientEvents
        self.serverEvents = serverEvents
        self.lifecycleEvents = lifecycleEvents
    }
}

/// Recorded action for replay
public struct RecordedAction: Codable, Sendable {
    public let kind: String // "action"
    public let sequence: Int64
    public let typeIdentifier: String
    public let payload: AnyCodable
    public let playerID: String
    public let clientID: String
    public let sessionID: String
    public let resolverOutputs: [String: RecordedResolverOutput]
    public let resolvedAtTick: Int64
    
    public init(
        kind: String,
        sequence: Int64,
        typeIdentifier: String,
        payload: AnyCodable,
        playerID: String,
        clientID: String,
        sessionID: String,
        resolverOutputs: [String: RecordedResolverOutput],
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

/// Recorded client event for replay
public struct RecordedClientEvent: Codable, Sendable {
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

/// Recorded server event for replay
public struct RecordedServerEvent: Codable, Sendable {
    public let kind: String // "serverEvent"
    public let sequence: Int64
    public let tickId: Int64
    public let typeIdentifier: String
    public let payload: AnyCodable
    public let target: EventTargetRecord
    
    public init(
        kind: String,
        sequence: Int64,
        tickId: Int64,
        typeIdentifier: String,
        payload: AnyCodable,
        target: EventTargetRecord
    ) {
        self.kind = kind
        self.sequence = sequence
        self.tickId = tickId
        self.typeIdentifier = typeIdentifier
        self.payload = payload
        self.target = target
    }
}

/// Serializable representation of EventTarget
public struct EventTargetRecord: Codable, Sendable {
    public let kind: String // "all" | "player" | "client" | "session" | "players"
    public let ids: [String]
    
    public init(kind: String, ids: [String]) {
        self.kind = kind
        self.ids = ids
    }
    
    /// Convert EventTarget to EventTargetRecord
    public static func from(_ target: EventTarget) -> EventTargetRecord {
        switch target {
        case .all:
            return EventTargetRecord(kind: "all", ids: [])
        case .player(let playerID):
            return EventTargetRecord(kind: "player", ids: [playerID.rawValue])
        case .client(let clientID):
            return EventTargetRecord(kind: "client", ids: [clientID.rawValue])
        case .session(let sessionID):
            return EventTargetRecord(kind: "session", ids: [sessionID.rawValue])
        case .players(let playerIDs):
            return EventTargetRecord(kind: "players", ids: playerIDs.map { $0.rawValue })
        }
    }
}

// MARK: - ActionRecorder Actor

/// Actor responsible for recording actions, client events, and server events for deterministic replay
public actor ActionRecorder {
    private var metadata: RecordingMetadata?
    private var frames: [RecordingFrame] = []
    private var currentFrame: RecordingFrame?
    private var currentTickId: Int64 = -1
    private let flushInterval: Int64
    private var lastFlushTick: Int64 = -1
    
    public init(flushInterval: Int64 = 60) {
        self.flushInterval = flushInterval
    }

    /// Set recording metadata (required before saving).
    public func setMetadata(_ metadata: RecordingMetadata) {
        self.metadata = metadata
    }

    public func getMetadata() -> RecordingMetadata? {
        metadata
    }
    
    /// Record actions and client events for a specific tick
    public func record(
        tickId: Int64,
        actions: [RecordedAction],
        clientEvents: [RecordedClientEvent],
        lifecycleEvents: [RecordedLifecycleEvent]
    ) {
        // If this is a new tick, finalize the previous frame
        if tickId != currentTickId {
            if let frame = currentFrame {
                frames.append(frame)
            }
            currentTickId = tickId
            currentFrame = RecordingFrame(
                tickId: tickId,
                actions: [],
                clientEvents: [],
                serverEvents: [],
                lifecycleEvents: []
            )
        }
        
        // Append actions and client events to current frame
        guard var frame = currentFrame else {
            // Should not happen, but handle gracefully
            currentFrame = RecordingFrame(
                tickId: tickId,
                actions: actions,
                clientEvents: clientEvents,
                serverEvents: [],
                lifecycleEvents: lifecycleEvents
            )
            return
        }
        
        frame = RecordingFrame(
            tickId: frame.tickId,
            actions: frame.actions + actions,
            clientEvents: frame.clientEvents + clientEvents,
            serverEvents: frame.serverEvents,
            lifecycleEvents: frame.lifecycleEvents + lifecycleEvents
        )
        currentFrame = frame
    }
    
    public func recordLifecycleEvent(_ event: RecordedLifecycleEvent) {
        // Find or create frame for this tick
        if event.tickId != currentTickId {
            if let frame = currentFrame {
                frames.append(frame)
            }
            currentTickId = event.tickId
            currentFrame = RecordingFrame(
                tickId: event.tickId,
                actions: [],
                clientEvents: [],
                serverEvents: [],
                lifecycleEvents: []
            )
        }

        guard var frame = currentFrame else {
            currentFrame = RecordingFrame(
                tickId: event.tickId,
                actions: [],
                clientEvents: [],
                serverEvents: [],
                lifecycleEvents: [event]
            )
            return
        }

        frame = RecordingFrame(
            tickId: frame.tickId,
            actions: frame.actions,
            clientEvents: frame.clientEvents,
            serverEvents: frame.serverEvents,
            lifecycleEvents: frame.lifecycleEvents + [event]
        )
        currentFrame = frame
    }

    /// Record a server event
    public func recordServerEvent(_ event: RecordedServerEvent) {
        // Find or create frame for this tick
        if event.tickId != currentTickId {
            // Finalize current frame if exists
            if let frame = currentFrame {
                frames.append(frame)
            }
            currentTickId = event.tickId
            currentFrame = RecordingFrame(
                tickId: event.tickId,
                actions: [],
                clientEvents: [],
                serverEvents: [],
                lifecycleEvents: []
            )
        }
        
        guard var frame = currentFrame else {
            // Should not happen, but handle gracefully
            currentFrame = RecordingFrame(
                tickId: event.tickId,
                actions: [],
                clientEvents: [],
                serverEvents: [event],
                lifecycleEvents: []
            )
            return
        }
        
        frame = RecordingFrame(
            tickId: frame.tickId,
            actions: frame.actions,
            clientEvents: frame.clientEvents,
            serverEvents: frame.serverEvents + [event],
            lifecycleEvents: frame.lifecycleEvents
        )
        currentFrame = frame
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
    
    /// Save all recorded frames to a JSON file
    public func save(to filePath: String) async throws {
        guard let metadata = metadata else {
            throw NSError(domain: "ActionRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Recording metadata must be set before saving"
            ])
        }

        // Finalize current frame
        if let frame = currentFrame {
            frames.append(frame)
            currentFrame = nil
        }
        
        // Sort frames by tickId
        let sortedFrames = frames.sorted { $0.tickId < $1.tickId }

        struct RecordingFile: Codable {
            let metadata: RecordingMetadata
            let frames: [RecordingFrame]
        }

        let recordingFile = RecordingFile(metadata: metadata, frames: sortedFrames)

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(recordingFile)
        
        // Write to file
        let url = URL(fileURLWithPath: filePath)
        try data.write(to: url)
    }
    
    /// Get all recorded frames (for testing/debugging)
    public func getAllFrames() -> [RecordingFrame] {
        var allFrames = frames
        if let frame = currentFrame {
            allFrames.append(frame)
        }
        return allFrames.sorted { $0.tickId < $1.tickId }
    }
}
