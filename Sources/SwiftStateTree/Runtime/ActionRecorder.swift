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
    public var rngSeed: UInt64? { rngSeedCoding?.value }
    /// Written as 16 hex digits (a JSON number above 2^53 does not survive JavaScript readers);
    /// a number, as older records wrote it, is still read.
    private let rngSeedCoding: SyncHashCoding?

    /// Optional rule variant identifier (reserved for future Rule Re-evaluation).
    public let ruleVariantId: String?

    /// Optional rule parameters overlay (reserved for future Rule Re-evaluation).
    public let ruleParams: [String: AnyCodable]?

    /// Record format version. The recorder writes `ReevaluationRecordVersion.current` whatever a
    /// caller passes (`ReevaluationRecorder.setMetadata`): the build decides how hashes are
    /// defined, so the version must be the writer's. Only records built directly carry another.
    public let version: String?

    /// Optional extensions for future land-specific data.
    public let extensions: [String: AnyCodable]?
    
    /// Hardware information where the record was created.
    /// Used to verify deterministic behavior across different CPU architectures.
    public let hardwareInfo: HardwareInfo?

    /// Whether the live run recorded its sync stream (`syncOutputs`, `syncMarkers`): true with
    /// in-turn sync on, false with it off, nil in records older than 2.1. A reader tells "no sync
    /// outputs because none were recorded" from "recorded, and there were none" by it.
    public let recordsSyncStream: Bool?

    /// How the live adapter planned its syncs, for the sync-output verifier; nil without a sync
    /// stream, and in records older than 2.2.
    public let syncConfig: ReevaluationSyncConfig?

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
        hardwareInfo: HardwareInfo? = nil,
        recordsSyncStream: Bool? = nil,
        syncConfig: ReevaluationSyncConfig? = nil
    ) {
        self.landID = landID
        self.landType = landType
        self.createdAt = createdAt
        self.metadata = metadata
        self.landDefinitionID = landDefinitionID
        self.initialStateHash = initialStateHash
        self.landConfig = landConfig
        self.rngSeedCoding = rngSeed.map(SyncHashCoding.init)
        self.ruleVariantId = ruleVariantId
        self.ruleParams = ruleParams
        self.version = version
        self.extensions = extensions
        self.hardwareInfo = hardwareInfo
        self.recordsSyncStream = recordsSyncStream
        self.syncConfig = syncConfig
    }

    /// This metadata with `version` set to the version this build writes.
    func stampedWithCurrentVersion() -> ReevaluationRecordMetadata {
        ReevaluationRecordMetadata(
            landID: landID,
            landType: landType,
            createdAt: createdAt,
            metadata: metadata,
            landDefinitionID: landDefinitionID,
            initialStateHash: initialStateHash,
            landConfig: landConfig,
            rngSeed: rngSeed,
            ruleVariantId: ruleVariantId,
            ruleParams: ruleParams,
            version: ReevaluationRecordVersion.current,
            extensions: extensions,
            hardwareInfo: hardwareInfo,
            recordsSyncStream: recordsSyncStream,
            syncConfig: syncConfig
        )
    }

    private enum CodingKeys: String, CodingKey {
        case landID, landType, createdAt, metadata, landDefinitionID, initialStateHash, landConfig
        case rngSeedCoding = "rngSeed"
        case ruleVariantId, ruleParams, version, extensions, hardwareInfo, recordsSyncStream, syncConfig
    }
}

/// The live adapter's sync planning, as the verifier must reproduce it.
public struct ReevaluationSyncConfig: Codable, Sendable, Equatable {
    /// Opcode 107: the broadcast update and the queued events go in one merged frame, and the
    /// per-player scope holds only per-player patches. Otherwise each player gets one combined
    /// update (broadcast patches included) and events are not queued.
    public let mergedBroadcastFrame: Bool
    /// The full-snapshot strategy: every plan diffs against an empty baseline.
    public let fullSnapshot: Bool

    public init(mergedBroadcastFrame: Bool, fullSnapshot: Bool) {
        self.mergedBroadcastFrame = mergedBroadcastFrame
        self.fullSnapshot = fullSnapshot
    }
}

/// A record whose version a reader cannot read (different major, missing or malformed).
public enum ReevaluationRecordVersionError: Error, Equatable, Sendable, CustomStringConvertible {
    case incompatible(recorded: String?, required: String)
    /// The major version matches, but the record is older than the oldest version this build
    /// reads (`ReevaluationRecordVersion.minimumSupported`): re-record it with the current server.
    case unsupported(recorded: String, minimum: String)

    public var description: String {
        switch self {
        case let .incompatible(recorded, required):
            return "incompatible record version \(recorded ?? "missing") (this build reads \(required))"
        case let .unsupported(recorded, _):
            return ReevaluationRecordVersion.unsupportedReason(recorded: recorded) ?? "unsupported record version \(recorded)"
        }
    }
}

/// What a recorded state or initialize hash covers.
public enum ReevaluationHashDefinition: Sendable, Equatable {
    /// Every `@Sync` field at every depth, whatever its policy (`fullStateSnapshot()`); not
    /// `@Internal` properties. Records from 2.4 on.
    case fullState
    /// The broadcast view, `snapshot(for: nil)`: what the hash covered before 2.4.
    case broadcastView
}

/// Record format versions, `"<major>.<minor>"`.
///
/// Readers accept a record with their major version from `minimumSupported` on: a newer minor adds
/// keys an older reader ignores. A record older than `minimumSupported` is unsupported (re-record
/// it); a different major, or a missing or malformed version, is incompatible.
public enum ReevaluationRecordVersion {
    /// The version this package writes. 2.1 adds the sync stream (`syncOutputs`, `syncMarkers`,
    /// `recordsSyncStream`) and the initialize record; 2.2 adds what the sync-output verifier
    /// needs (`syncConfig`, `perPlayerUnverified`, `perPlayerUncommitted`, `resetsKeyScopes`,
    /// `eventsThroughSequence`). A 2.1 record is still read; its sync outputs are not verified.
    /// 2.3 marks hashes computed with nested state nodes' own `@Sync` policies applied (#175);
    /// an older record's state and sync-output hashes are not comparable with this build's.
    /// 2.4 records full-state hashes (`ReevaluationHashDefinition.fullState`, #180) and
    /// `stateHashUnavailable`; older records hold broadcast-view hashes and are verified
    /// against those. 2.5 writes `PlayerID`, `ClientID`, `SessionID` and `LandID` as strings,
    /// and a dictionary keyed by one as an object, in recorded payloads and events (#154). In
    /// the state hash, `PlayerID` was already a string, but `ClientID`, `SessionID` and `LandID`
    /// leaves were objects before 2.5, so a state holding one hashes differently from 2.4.
    /// 2.6 sends a `.masked` field below a `.broadcast` field, masked, in broadcast snapshots
    /// and diffs (#179); it was left out before. Nothing else changed, the state hash included,
    /// so 2.5 is still read; a 2.5 record of a state with that shape replays with sync-output
    /// mismatches, which are not marked as not comparable (no example land has the shape).
    /// 3.0 changes the file, not the content: an append-only log of canonical MessagePack
    /// records (`ReevaluationRecordLog`, #245) instead of one JSON document. Every 2.6 rule
    /// holds for 3.x, and 2.5 and 2.6 files are still read.
    public static let current = "3.0"

    /// The first 2.x minor this build reads. Records before 2.5 hold identifiers as `{rawValue}`
    /// objects, which no longer decode (#154); they are not converted, but rejected as
    /// unsupported (not comparable, never a mismatch): re-record them with the current server.
    public static let minimumSupportedMinor = 5

    /// The oldest version this build reads.
    public static let minimumSupported = "2.\(minimumSupportedMinor)"

    /// Why a 2.x record written as `recorded` cannot be read by this build (it is older than
    /// `minimumSupported`), or nil when it can be (or is incompatible).
    public static func unsupportedReason(recorded: String?) -> String? {
        guard let recorded, let parsed = parse(recorded),
              parsed.major == 2, parsed.minor < minimumSupportedMinor
        else { return nil }
        return "unsupported record version \(recorded) (this build reads \(minimumSupported) and later); re-record with the current server"
    }

    /// The first minor whose state and initialize hashes cover the full state (#180).
    public static let fullStateHashMinor = 4

    /// The hash a record written as `recorded` holds: the full state from 2.4 on, the broadcast
    /// view before. A missing or malformed version (an incompatible record) maps to the
    /// current definition.
    public static func hashDefinition(recorded: String?) -> ReevaluationHashDefinition {
        isBefore(recorded, minor: fullStateHashMinor) ? .broadcastView : .fullState
    }

    /// The first minor whose state and sync-output hashes this build can reproduce: before it,
    /// a `@SnapshotConvertible` state node in a `[String: X]` / `[PlayerID: X]` map was
    /// converted with every field, server-only ones included (#175).
    public static let nestedNodePoliciesMinor = 3

    /// Why a state hash mismatch in a record written as `recorded` does not mean a replay
    /// difference, or nil when it does. Only a record older than 2.3 of a land whose state type
    /// has the shape #175 changed (`hashChangedByNestedNodePolicies`) qualifies; every other
    /// mismatch is a real failure. Only meaningful for a compatible record (`isCompatible`).
    public static func hashIncomparability(recorded: String?, stateType: any StateNodeProtocol.Type) -> String? {
        guard isBefore(recorded, minor: nestedNodePoliciesMinor),
              hashChangedByNestedNodePolicies(stateType)
        else { return nil }
        return "recorded before #175 (record \(recorded ?? "?")), hash not comparable"
    }

    /// Whether `stateType` has, at any depth, a state node that is also `SnapshotValueConvertible`
    /// (`@SnapshotConvertible`) as the value of a `[String: X]` or `[PlayerID: X]` map, reached
    /// through `.broadcast` fields only: the only shape whose broadcast view, and so whose state
    /// hash, #175 changed. Fields of other policies are not in that view, or (masked, custom)
    /// not followed, so a mismatch there stays a failure. Decided from the type, not from a
    /// recording.
    public static func hashChangedByNestedNodePolicies(_ stateType: any StateNodeProtocol.Type) -> Bool {
        var visited: Set<ObjectIdentifier> = []
        return containsChangedShape(stateType, visited: &visited)
    }

    private static func containsChangedShape(_ type: Any.Type, visited: inout Set<ObjectIdentifier>) -> Bool {
        if let wrapped = OptionalTypeHelper.wrappedType(of: type) {
            return containsChangedShape(wrapped, visited: &visited)
        }
        if let valueType = SchemaHelper.dictionaryValueType(from: type) {
            let keyType = SchemaHelper.dictionaryKeyType(from: type)
            let stringKeyed = keyType == String.self || keyType == PlayerID.self
            if stringKeyed, valueType is any StateNodeProtocol.Type, valueType is any SnapshotValueConvertible.Type {
                return true
            }
            return containsChangedShape(valueType, visited: &visited)
        }
        if let elementType = SchemaHelper.arrayElementType(from: type) {
            return containsChangedShape(elementType, visited: &visited)
        }
        if let nodeType = type as? any StateNodeProtocol.Type {
            guard visited.insert(ObjectIdentifier(nodeType)).inserted else { return false }
            return nodeType.getFieldMetadata().contains {
                $0.policy == .broadcast && containsChangedShape($0.type, visited: &visited)
            }
        }
        return false
    }

    /// Whether a record written as `recorded` can be read by a reader that requires `required`:
    /// the same major, and readable (`isReadable`). Callers that name a version (a server's
    /// `REEVALUATION_REPLAY_REQUIRED_RECORD_VERSION`, the replay start's `expectedRecordVersion`)
    /// use this, so a server requiring 3.0 refuses a 2.6 record.
    public static func isCompatible(recorded: String?, required: String) -> Bool {
        guard let recorded,
              let recordedMajor = parse(recorded)?.major,
              let requiredMajor = parse(required)?.major
        else { return false }
        return recordedMajor == requiredMajor && isReadable(recorded: recorded)
    }

    /// Whether this build reads a record written as `recorded`: 2.5 and later 2.x, and 3.x.
    public static func isReadable(recorded: String?) -> Bool {
        guard let recorded, let parsed = parse(recorded) else { return false }
        switch parsed.major {
        case 2: return parsed.minor >= minimumSupportedMinor
        case 3: return true
        default: return false
        }
    }

    /// Whether `recorded` is a 2.x version before `2.<minor>` (3.x has every 2.x change).
    /// A missing or malformed version is not.
    static func isBefore(_ recorded: String?, minor: Int) -> Bool {
        guard let parsed = recorded.flatMap(parse) else { return false }
        return parsed.major < 2 || (parsed.major == 2 && parsed.minor < minor)
    }

    /// The minor version of `version` (0 when it has none), nil when missing or malformed.
    public static func minor(of version: String?) -> Int? {
        version.flatMap(parse)?.minor
    }

    private static func parse(_ version: String) -> (major: Int, minor: Int)? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0])
        else { return nil }
        let minor = parts.count == 2 ? Int(parts[1]) : 0
        return minor.map { (major, $0) }
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

/// Values of the shared sequence counter captured at fixed points of a live tick.
///
/// Live mode numbers actions, client events, lifecycle events and emitted server events
/// from one counter. Inputs take numbers when they arrive (possibly ticks before they run,
/// or without ever being recorded), so re-evaluation cannot derive the counter from the
/// recorded inputs alone. These watermarks let re-evaluation restore it exactly.
public struct ReevaluationSequenceWatermarks: Sendable, Equatable {
    /// Counter value right before pending inputs are processed in the tick.
    public let beforeInputs: Int64?
    /// Counter value right before the tick handler runs.
    public let beforeTickHandler: Int64?

    public init(beforeInputs: Int64?, beforeTickHandler: Int64?) {
        self.beforeInputs = beforeInputs
        self.beforeTickHandler = beforeTickHandler
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
    /// Sequence counter right before pending inputs were processed (ticked lands only; nil in older records).
    public let sequenceBeforeInputs: Int64?
    /// Sequence counter right before the tick handler ran (ticked lands only; nil in older records).
    public let sequenceBeforeTickHandler: Int64?
    /// Sync outputs whose plan read state after this tick (`observedTickId`), in any order: the
    /// stream order is `streamIndex`. Outputs with `observedTickId == -1` are in frame 0.
    /// Empty in records older than 2.1 and in records without a sync stream.
    public let syncOutputs: [ReevaluationRecordedSyncOutput]
    /// Seed, clear and initialize markers merged into this frame, ordered by `streamIndex`.
    public let syncMarkers: [ReevaluationRecordedSyncMarker]
    /// Frame 0 only, in records from 2.1: what OnInitialize did.
    public let initialize: ReevaluationRecordedInitialize?

    public init(
        tickId: Int64,
        stateHash: String? = nil,
        actions: [ReevaluationRecordedAction],
        clientEvents: [ReevaluationRecordedClientEvent],
        lifecycleEvents: [ReevaluationRecordedLifecycleEvent],
        serverEvents: [ReevaluationRecordedServerEvent] = [],
        sequenceBeforeInputs: Int64? = nil,
        sequenceBeforeTickHandler: Int64? = nil,
        syncOutputs: [ReevaluationRecordedSyncOutput] = [],
        syncMarkers: [ReevaluationRecordedSyncMarker] = [],
        initialize: ReevaluationRecordedInitialize? = nil
    ) {
        self.tickId = tickId
        self.stateHash = stateHash
        self.actions = actions
        self.clientEvents = clientEvents
        self.lifecycleEvents = lifecycleEvents
        self.serverEvents = serverEvents
        self.sequenceBeforeInputs = sequenceBeforeInputs
        self.sequenceBeforeTickHandler = sequenceBeforeTickHandler
        self.syncOutputs = syncOutputs
        self.syncMarkers = syncMarkers
        self.initialize = initialize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tickId = try container.decode(Int64.self, forKey: .tickId)
        stateHash = try container.decodeIfPresent(String.self, forKey: .stateHash)
        actions = try container.decode([ReevaluationRecordedAction].self, forKey: .actions)
        clientEvents = try container.decode([ReevaluationRecordedClientEvent].self, forKey: .clientEvents)
        lifecycleEvents = try container.decode([ReevaluationRecordedLifecycleEvent].self, forKey: .lifecycleEvents)
        serverEvents = try container.decodeIfPresent([ReevaluationRecordedServerEvent].self, forKey: .serverEvents) ?? []
        sequenceBeforeInputs = try container.decodeIfPresent(Int64.self, forKey: .sequenceBeforeInputs)
        sequenceBeforeTickHandler = try container.decodeIfPresent(Int64.self, forKey: .sequenceBeforeTickHandler)
        syncOutputs = try container.decodeIfPresent([ReevaluationRecordedSyncOutput].self, forKey: .syncOutputs) ?? []
        syncMarkers = try container.decodeIfPresent([ReevaluationRecordedSyncMarker].self, forKey: .syncMarkers) ?? []
        initialize = try container.decodeIfPresent(ReevaluationRecordedInitialize.self, forKey: .initialize)
    }

    /// The frame's sequence watermarks, or nil when the frame carries none (older records, tickless lands).
    public var sequenceWatermarks: ReevaluationSequenceWatermarks? {
        guard sequenceBeforeInputs != nil || sequenceBeforeTickHandler != nil else { return nil }
        return ReevaluationSequenceWatermarks(
            beforeInputs: sequenceBeforeInputs,
            beforeTickHandler: sequenceBeforeTickHandler
        )
    }

    /// Copy with replaced contents; the watermarks are carried over unless new values are given.
    func replacing(
        stateHash: String?? = nil,
        actions: [ReevaluationRecordedAction]? = nil,
        clientEvents: [ReevaluationRecordedClientEvent]? = nil,
        lifecycleEvents: [ReevaluationRecordedLifecycleEvent]? = nil,
        serverEvents: [ReevaluationRecordedServerEvent]? = nil,
        sequenceBeforeInputs: Int64? = nil,
        sequenceBeforeTickHandler: Int64? = nil,
        syncOutputs: [ReevaluationRecordedSyncOutput]? = nil,
        syncMarkers: [ReevaluationRecordedSyncMarker]? = nil,
        initialize: ReevaluationRecordedInitialize? = nil
    ) -> ReevaluationTickFrame {
        ReevaluationTickFrame(
            tickId: tickId,
            stateHash: stateHash ?? self.stateHash,
            actions: actions ?? self.actions,
            clientEvents: clientEvents ?? self.clientEvents,
            lifecycleEvents: lifecycleEvents ?? self.lifecycleEvents,
            serverEvents: serverEvents ?? self.serverEvents,
            sequenceBeforeInputs: sequenceBeforeInputs ?? self.sequenceBeforeInputs,
            sequenceBeforeTickHandler: sequenceBeforeTickHandler ?? self.sequenceBeforeTickHandler,
            syncOutputs: syncOutputs ?? self.syncOutputs,
            syncMarkers: syncMarkers ?? self.syncMarkers,
            initialize: initialize ?? self.initialize
        )
    }

    private enum CodingKeys: String, CodingKey {
        case tickId, stateHash, actions, clientEvents, lifecycleEvents, serverEvents
        case sequenceBeforeInputs, sequenceBeforeTickHandler
        case syncOutputs, syncMarkers, initialize
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tickId, forKey: .tickId)
        try container.encodeIfPresent(stateHash, forKey: .stateHash)
        try container.encode(actions, forKey: .actions)
        try container.encode(clientEvents, forKey: .clientEvents)
        try container.encode(lifecycleEvents, forKey: .lifecycleEvents)
        try container.encode(serverEvents, forKey: .serverEvents)
        try container.encodeIfPresent(sequenceBeforeInputs, forKey: .sequenceBeforeInputs)
        try container.encodeIfPresent(sequenceBeforeTickHandler, forKey: .sequenceBeforeTickHandler)
        // Omitted when empty, so frames without a sync stream stay as before.
        if !syncOutputs.isEmpty { try container.encode(syncOutputs, forKey: .syncOutputs) }
        if !syncMarkers.isEmpty { try container.encode(syncMarkers, forKey: .syncMarkers) }
        try container.encodeIfPresent(initialize, forKey: .initialize)
    }
}

/// Everything one keeper turn recorded for a tick, submitted with
/// `ReevaluationRecorder.recordTick(_:)`.
public struct ReevaluationTickRecord: Sendable {
    public let tickId: Int64
    public var actions: [ReevaluationRecordedAction]
    public var clientEvents: [ReevaluationRecordedClientEvent]
    public var lifecycleEvents: [ReevaluationRecordedLifecycleEvent]
    public var serverEvents: [ReevaluationRecordedServerEvent]
    public var stateHash: String?
    public var stateSnapshot: StateSnapshot?
    public var sequenceBeforeInputs: Int64?
    public var sequenceBeforeTickHandler: Int64?
    public var syncOutputs: [ReevaluationRecordedSyncOutput]
    public var syncMarkers: [ReevaluationRecordedSyncMarker]
    public var initialize: ReevaluationRecordedInitialize?

    public init(
        tickId: Int64,
        actions: [ReevaluationRecordedAction] = [],
        clientEvents: [ReevaluationRecordedClientEvent] = [],
        lifecycleEvents: [ReevaluationRecordedLifecycleEvent] = [],
        serverEvents: [ReevaluationRecordedServerEvent] = [],
        stateHash: String? = nil,
        stateSnapshot: StateSnapshot? = nil,
        sequenceBeforeInputs: Int64? = nil,
        sequenceBeforeTickHandler: Int64? = nil,
        syncOutputs: [ReevaluationRecordedSyncOutput] = [],
        syncMarkers: [ReevaluationRecordedSyncMarker] = [],
        initialize: ReevaluationRecordedInitialize? = nil
    ) {
        self.tickId = tickId
        self.actions = actions
        self.clientEvents = clientEvents
        self.lifecycleEvents = lifecycleEvents
        self.serverEvents = serverEvents
        self.stateHash = stateHash
        self.stateSnapshot = stateSnapshot
        self.sequenceBeforeInputs = sequenceBeforeInputs
        self.sequenceBeforeTickHandler = sequenceBeforeTickHandler
        self.syncOutputs = syncOutputs
        self.syncMarkers = syncMarkers
        self.initialize = initialize
    }
}

extension ReevaluationTickRecord {
    /// No inputs, server events, hash or watermarks.
    public var isEmpty: Bool {
        actions.isEmpty && clientEvents.isEmpty && lifecycleEvents.isEmpty && serverEvents.isEmpty
            && stateHash == nil && sequenceBeforeInputs == nil && sequenceBeforeTickHandler == nil
            && syncOutputs.isEmpty && syncMarkers.isEmpty && initialize == nil
    }
}

extension ReevaluationTickFrame {
    /// This frame with `record` merged in: lists appended, hash and watermarks set when present.
    func merging(_ record: ReevaluationTickRecord) -> ReevaluationTickFrame {
        replacing(
            stateHash: record.stateHash.map { .some($0) },
            actions: actions + record.actions,
            clientEvents: clientEvents + record.clientEvents,
            lifecycleEvents: lifecycleEvents + record.lifecycleEvents,
            serverEvents: serverEvents + record.serverEvents,
            sequenceBeforeInputs: record.sequenceBeforeInputs,
            sequenceBeforeTickHandler: record.sequenceBeforeTickHandler,
            syncOutputs: syncOutputs + record.syncOutputs,
            syncMarkers: syncMarkers + record.syncMarkers,
            initialize: record.initialize
        )
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

    /// Convert ReevaluationEventTargetRecord back to EventTarget for replay forwarding.
    public func toEventTarget() -> EventTarget {
        switch kind {
        case "all":
            return .all
        case "player":
            if let id = ids.first {
                return .player(PlayerID(id))
            }
            return .all
        case "client":
            if let id = ids.first {
                return .client(ClientID(id))
            }
            return .all
        case "session":
            if let id = ids.first {
                return .session(SessionID(id))
            }
            return .all
        case "players":
            return .players(ids.map { PlayerID($0) })
        default:
            return .all
        }
    }
}

/// Unwraps `Optional<T>` to `T` at the type level.
private protocol OptionalTypeProtocol {
    static var wrappedType: Any.Type { get }
}

extension Optional: OptionalTypeProtocol {
    fileprivate static var wrappedType: Any.Type { Wrapped.self }
}

private enum OptionalTypeHelper {
    static func wrappedType(of type: Any.Type) -> Any.Type? {
        (type as? any OptionalTypeProtocol.Type)?.wrappedType
    }
}
