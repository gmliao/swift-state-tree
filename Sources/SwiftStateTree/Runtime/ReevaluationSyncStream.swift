// Sources/SwiftStateTree/Runtime/ReevaluationSyncStream.swift
//
// The sync stream of a re-evaluation record (format 2.1): what each committed sync plan sent,
// as canonical hashes, and the markers that place per-player views and OnInitialize in it.
// See Notes/plans/2026-11-05-sync-output-replay.md, "What is recorded".

import Foundation

/// One committed sync plan's output.
public struct ReevaluationRecordedSyncOutput: Codable, Sendable, Equatable {
    /// How the plan ran.
    public enum TurnKind: String, Codable, Sendable {
        /// In a tick turn (or an input or initialize turn) of the keeper.
        case tick
        /// In a sync-only turn, at the sync loop's interval.
        case syncOnly
        /// A cycle committed outside a turn while in-turn sync is on (freeze settle, deferred
        /// sync on resume).
        case legacyCycle
    }

    /// Consistency check only: position among the outputs after the same tick (0-based).
    public let index: Int
    public let turnKind: TurnKind
    /// `lastCommittedTickId` when the plan read state; nil when the read cannot be located.
    public let observedTickId: Int64?
    /// Position in the sync stream; replay orders by it, never by array position or tick.
    public let streamIndex: UInt64
    /// Keeper output sequence when the plan read state (cross-check only).
    public let sequence: Int64
    /// Nil when the broadcast scope was not committed.
    public let broadcastHash: UInt64?
    /// One hash over (playerID, hash) pairs sorted by player ID, for the committed players with
    /// patches, leaving out `perPlayerUnverified` and `perPlayerUncommitted`. Nil when the plan
    /// committed no per-player scope (a broadcast-only cycle).
    public let perPlayerHash: UInt64?
    /// Recipients left out of `perPlayerHash` because their latest seed was not verifiable
    /// (`viewHash` nil), until a verifiable seed; sorted. Nil when empty.
    public let perPlayerUnverified: [String]?
    /// Recipients whose update was planned but not sent at all (an encode failure): their
    /// per-player cache was not committed. Sorted; nil when empty.
    public let perPlayerUncommitted: [String]?
    /// Committed players' hashes; present only with `recordSyncDetails`.
    public let perPlayerHashes: [String: UInt64]?
    /// Opcode 107 mode only.
    public let eventsHash: UInt64?
    /// Opcode 107 mode only: the largest keeper sequence among the events the plan consumed; nil
    /// when it consumed none with a sequence. The verifier consumes its replayed events up to it.
    public let eventsThroughSequence: Int64?
    /// Opcode 107: sequences of in-turn events emitted since the previous output that had no
    /// recipient (nothing was queued or sent); the verifier does not expect them. Sorted; nil
    /// when empty.
    public let eventsNotQueued: [Int64]?
    /// Opcode 107: in-turn events emitted since the previous output that were not merged
    /// although they had recipients (the body did not encode). The verifier does not expect them
    /// in a merged frame, and this output's events scope is unverifiable. Nil when empty.
    public let eventsNotMerged: ReevaluationUnmergedEvents?
    /// The plan reset its recipients' dynamic key scopes: every recipient got a `.firstSync`
    /// update, empty ones included. Empty updates carry no patches and are left out of
    /// `perPlayerHash` like a no-change; the verifier counts them. Nil when false.
    public let resetsKeyScopes: Bool?
    /// Top-level fields the plan's extraction dropped, per scope ("broadcast" or a player ID).
    public let extractionDrops: [String: [String]]
    /// Scopes whose patches did not encode and were dropped.
    public let encodeDropScopes: [String]
    /// Canonical patch lists per scope; present only with `recordSyncPatches`.
    public let patches: [String: [StatePatch]]?

    public init(
        index: Int,
        turnKind: TurnKind,
        observedTickId: Int64?,
        streamIndex: UInt64,
        sequence: Int64,
        broadcastHash: UInt64? = nil,
        perPlayerHash: UInt64? = nil,
        perPlayerUnverified: [String]? = nil,
        perPlayerUncommitted: [String]? = nil,
        perPlayerHashes: [String: UInt64]? = nil,
        eventsHash: UInt64? = nil,
        eventsThroughSequence: Int64? = nil,
        eventsNotQueued: [Int64]? = nil,
        eventsNotMerged: ReevaluationUnmergedEvents? = nil,
        resetsKeyScopes: Bool? = nil,
        extractionDrops: [String: [String]] = [:],
        encodeDropScopes: [String] = [],
        patches: [String: [StatePatch]]? = nil
    ) {
        self.index = index
        self.turnKind = turnKind
        self.observedTickId = observedTickId
        self.streamIndex = streamIndex
        self.sequence = sequence
        self.broadcastHash = broadcastHash
        self.perPlayerHash = perPlayerHash
        self.perPlayerUnverified = perPlayerUnverified
        self.perPlayerUncommitted = perPlayerUncommitted
        self.perPlayerHashes = perPlayerHashes
        self.eventsHash = eventsHash
        self.eventsThroughSequence = eventsThroughSequence
        self.eventsNotQueued = eventsNotQueued
        self.eventsNotMerged = eventsNotMerged
        self.resetsKeyScopes = resetsKeyScopes
        self.extractionDrops = extractionDrops
        self.encodeDropScopes = encodeDropScopes
        self.patches = patches
    }

    private enum CodingKeys: String, CodingKey {
        case index, turnKind, observedTickId, streamIndex, sequence, broadcastHash, perPlayerHash
        case perPlayerUnverified, perPlayerUncommitted, perPlayerHashes, eventsHash, eventsThroughSequence, eventsNotQueued, eventsNotMerged
        case resetsKeyScopes, extractionDrops, encodeDropScopes, patches
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        turnKind = try container.decode(TurnKind.self, forKey: .turnKind)
        observedTickId = try container.decodeIfPresent(Int64.self, forKey: .observedTickId)
        streamIndex = try container.decode(UInt64.self, forKey: .streamIndex)
        sequence = try container.decode(Int64.self, forKey: .sequence)
        broadcastHash = try container.decodeSyncHashIfPresent(forKey: .broadcastHash)
        perPlayerHash = try container.decodeSyncHashIfPresent(forKey: .perPlayerHash)
        perPlayerUnverified = try container.decodeIfPresent([String].self, forKey: .perPlayerUnverified)
        perPlayerUncommitted = try container.decodeIfPresent([String].self, forKey: .perPlayerUncommitted)
        perPlayerHashes = try container.decodeIfPresent([String: SyncHashCoding].self, forKey: .perPlayerHashes)?
            .mapValues(\.value)
        eventsHash = try container.decodeSyncHashIfPresent(forKey: .eventsHash)
        eventsThroughSequence = try container.decodeIfPresent(Int64.self, forKey: .eventsThroughSequence)
        eventsNotQueued = try container.decodeIfPresent([Int64].self, forKey: .eventsNotQueued)
        eventsNotMerged = try container.decodeIfPresent(ReevaluationUnmergedEvents.self, forKey: .eventsNotMerged)
        resetsKeyScopes = try container.decodeIfPresent(Bool.self, forKey: .resetsKeyScopes)
        extractionDrops = try container.decode([String: [String]].self, forKey: .extractionDrops)
        encodeDropScopes = try container.decode([String].self, forKey: .encodeDropScopes)
        patches = try container.decodeIfPresent([String: [StatePatch]].self, forKey: .patches)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(turnKind, forKey: .turnKind)
        try container.encodeIfPresent(observedTickId, forKey: .observedTickId)
        try container.encode(streamIndex, forKey: .streamIndex)
        try container.encode(sequence, forKey: .sequence)
        try container.encodeSyncHashIfPresent(broadcastHash, forKey: .broadcastHash)
        try container.encodeSyncHashIfPresent(perPlayerHash, forKey: .perPlayerHash)
        try container.encodeIfPresent(perPlayerUnverified, forKey: .perPlayerUnverified)
        try container.encodeIfPresent(perPlayerUncommitted, forKey: .perPlayerUncommitted)
        try container.encodeIfPresent(perPlayerHashes?.mapValues(SyncHashCoding.init), forKey: .perPlayerHashes)
        try container.encodeSyncHashIfPresent(eventsHash, forKey: .eventsHash)
        try container.encodeIfPresent(eventsThroughSequence, forKey: .eventsThroughSequence)
        try container.encodeIfPresent(eventsNotQueued, forKey: .eventsNotQueued)
        try container.encodeIfPresent(eventsNotMerged, forKey: .eventsNotMerged)
        try container.encodeIfPresent(resetsKeyScopes, forKey: .resetsKeyScopes)
        try container.encode(extractionDrops, forKey: .extractionDrops)
        try container.encode(encodeDropScopes, forKey: .encodeDropScopes)
        try container.encodeIfPresent(patches, forKey: .patches)
    }
}

/// Opcode 107 events that had recipients but did not reach a merged frame, by what became of
/// them; keeper sequences, sorted.
public struct ReevaluationUnmergedEvents: Codable, Sendable, Equatable {
    /// Sent as their own frame.
    public var sentAlone: [Int64]
    /// Their own frame did not encode either: no client got them.
    public var lost: [Int64]

    public init(sentAlone: [Int64] = [], lost: [Int64] = []) {
        self.sentAlone = sentAlone
        self.lost = lost
    }

    public var isEmpty: Bool { sentAlone.isEmpty && lost.isEmpty }
    /// Every sequence, sorted.
    public var all: [Int64] { (sentAlone + lost).sorted() }

    /// Both lists sorted.
    public func sorted() -> ReevaluationUnmergedEvents {
        ReevaluationUnmergedEvents(sentAlone: sentAlone.sorted(), lost: lost.sorted())
    }
}

/// A sync hash in a record: written as 16 lowercase hex digits (like the state hashes), since
/// JSON numbers above 2^53 do not survive JavaScript readers (the admin download, the CLI
/// tools). Read from hex, or from a JSON number as 2.1 records wrote it.
package struct SyncHashCoding: Codable, Sendable {
    package let value: UInt64

    package init(_ value: UInt64) { self.value = value }

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let hex = try? container.decode(String.self) {
            guard hex.count == 16, let value = UInt64(hex, radix: 16) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "sync hash \(hex) is not 16 hex digits")
            }
            self.value = value
        } else {
            value = try container.decode(UInt64.self)
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(DeterministicHash.toHex64(value))
    }
}

extension KeyedDecodingContainer {
    fileprivate func decodeSyncHashIfPresent(forKey key: Key) throws -> UInt64? {
        try decodeIfPresent(SyncHashCoding.self, forKey: key)?.value
    }
}

extension KeyedEncodingContainer {
    fileprivate mutating func encodeSyncHashIfPresent(_ value: UInt64?, forKey key: Key) throws {
        try encodeIfPresent(value.map(SyncHashCoding.init), forKey: key)
    }
}

/// A point in the sync stream that is not an output.
public struct ReevaluationRecordedSyncMarker: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// A player's client view was seeded (firstSync or rejoin).
        case seed
        /// A player's per-player cache and firstSync mark were dropped.
        case clear
        /// OnInitialize changed state; outputs before it read the state before it.
        case initialize
    }

    /// Why a seed's view is not verifiable (its `viewHash` is then nil).
    public enum ViewDrop: String, Codable, Sendable {
        /// A field's snapshot conversion threw and was left out of the view.
        case extraction
        /// Patches that did not encode were dropped from the frame the client got.
        case encode
    }

    public let kind: Kind
    /// Seed and clear only.
    public let playerID: String?
    /// Seed only: `lastCommittedTickId` of the firstSync's state read.
    public let observedTickId: Int64?
    public let streamIndex: UInt64
    public let sequence: Int64
    /// Seed only: a rejoin (reconnection) rather than a first join.
    public let rejoin: Bool
    /// Seed only: the per-player hash of the firstSync view; nil when `viewDrops` is not empty.
    public let viewHash: UInt64?
    /// Seed only: what was dropped from the view the client got (sorted); empty for a full view.
    public let viewDrops: [ViewDrop]

    public init(
        kind: Kind,
        playerID: String? = nil,
        observedTickId: Int64? = nil,
        streamIndex: UInt64,
        sequence: Int64,
        rejoin: Bool = false,
        viewHash: UInt64? = nil,
        viewDrops: [ViewDrop] = []
    ) {
        self.kind = kind
        self.playerID = playerID
        self.observedTickId = observedTickId
        self.streamIndex = streamIndex
        self.sequence = sequence
        self.rejoin = rejoin
        self.viewHash = viewHash
        self.viewDrops = viewDrops
    }

    private enum CodingKeys: String, CodingKey {
        case kind, playerID, observedTickId, streamIndex, sequence, rejoin, viewHash, viewDrops
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        playerID = try container.decodeIfPresent(String.self, forKey: .playerID)
        observedTickId = try container.decodeIfPresent(Int64.self, forKey: .observedTickId)
        streamIndex = try container.decode(UInt64.self, forKey: .streamIndex)
        sequence = try container.decode(Int64.self, forKey: .sequence)
        rejoin = try container.decode(Bool.self, forKey: .rejoin)
        viewHash = try container.decodeSyncHashIfPresent(forKey: .viewHash)
        viewDrops = try container.decodeIfPresent([ViewDrop].self, forKey: .viewDrops) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(playerID, forKey: .playerID)
        try container.encodeIfPresent(observedTickId, forKey: .observedTickId)
        try container.encode(streamIndex, forKey: .streamIndex)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(rejoin, forKey: .rejoin)
        try container.encodeSyncHashIfPresent(viewHash, forKey: .viewHash)
        if !viewDrops.isEmpty {
            try container.encode(viewDrops, forKey: .viewDrops)
        }
    }
}

/// One element of the sync stream, an output or a marker.
public enum ReevaluationSyncStreamEntry: Sendable, Equatable {
    case output(ReevaluationRecordedSyncOutput)
    case marker(ReevaluationRecordedSyncMarker)

    public var streamIndex: UInt64 {
        switch self {
        case .output(let output): return output.streamIndex
        case .marker(let marker): return marker.streamIndex
        }
    }

    /// Every output and marker of `frames`, in stream order (`streamIndex` alone).
    public static func stream(of frames: [ReevaluationTickFrame]) -> [ReevaluationSyncStreamEntry] {
        let entries = frames.flatMap { frame in
            frame.syncOutputs.map(ReevaluationSyncStreamEntry.output)
                + frame.syncMarkers.map(ReevaluationSyncStreamEntry.marker)
        }
        return entries.sorted { $0.streamIndex < $1.streamIndex }
    }
}

/// Whether a record carries a sync stream, before any verification.
///
/// A record without one never verifies as "0 mismatches": its sync output check is `absent`,
/// with the reason the header gives.
public enum ReevaluationSyncStreamPresence: Equatable, Sendable {
    /// No sync stream: the reason is the header's.
    case absent(reason: String)
    /// Recorded (`recordsSyncStream` true), with this many outputs and markers; both can be 0.
    case recorded(outputs: Int, markers: Int)

    /// One line for reports: `absent (<reason>)` or `recorded (<n> outputs, <m> markers)`.
    public var summary: String {
        switch self {
        case .absent(let reason):
            return "absent (\(reason))"
        case .recorded(let outputs, let markers):
            return "recorded (\(outputs) outputs, \(markers) markers)"
        }
    }

    public static func of(
        metadata: ReevaluationRecordMetadata,
        stream: [ReevaluationSyncStreamEntry]
    ) -> ReevaluationSyncStreamPresence {
        switch metadata.recordsSyncStream {
        case nil:
            return .absent(reason: "record version \(metadata.version ?? "unknown") predates sync-output recording")
        case false?:
            return .absent(reason: "recorded with in-turn sync off")
        case true?:
            let outputs = stream.filter { if case .output = $0 { return true } else { return false } }.count
            return .recorded(outputs: outputs, markers: stream.count - outputs)
        }
    }
}

/// What OnInitialize did in the live run (format 2.1, in frame 0), on both sync paths: the
/// server events it emitted and the state hash right after it. Independent of the sync stream;
/// with in-turn sync on, the stream's `initialize` marker places it.
public struct ReevaluationRecordedInitialize: Codable, Sendable {
    /// The output sequence of OnInitialize's lifecycle event.
    public let sequence: Int64
    /// Server events OnInitialize emitted, in sequence order.
    public let serverEvents: [ReevaluationRecordedServerEvent]
    /// State hash right after OnInitialize (the live state hash), nil without live hashing.
    public let stateHash: String?

    public init(sequence: Int64, serverEvents: [ReevaluationRecordedServerEvent], stateHash: String?) {
        self.sequence = sequence
        self.serverEvents = serverEvents
        self.stateHash = stateHash
    }
}

/// Where a sync plan read state: the keeper's `lastCommittedTickId` and output sequence, taken
/// in the same job as the state.
package struct SyncReadPosition: Sendable, Equatable {
    package let observedTickId: Int64
    package let sequence: Int64

    package init(observedTickId: Int64, sequence: Int64) {
        self.observedTickId = observedTickId
        self.sequence = sequence
    }
}
