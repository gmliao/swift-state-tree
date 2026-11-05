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
    /// One hash over (playerID, hash) pairs sorted by player ID, for committed players.
    public let perPlayerHash: UInt64?
    /// Committed players' hashes; present only with `recordSyncDetails`.
    public let perPlayerHashes: [String: UInt64]?
    /// Opcode 107 mode only.
    public let eventsHash: UInt64?
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
        perPlayerHashes: [String: UInt64]? = nil,
        eventsHash: UInt64? = nil,
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
        self.perPlayerHashes = perPlayerHashes
        self.eventsHash = eventsHash
        self.extractionDrops = extractionDrops
        self.encodeDropScopes = encodeDropScopes
        self.patches = patches
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

    public let kind: Kind
    /// Seed and clear only.
    public let playerID: String?
    /// Seed only: `lastCommittedTickId` of the firstSync's state read.
    public let observedTickId: Int64?
    public let streamIndex: UInt64
    public let sequence: Int64
    /// Seed only: a rejoin (reconnection) rather than a first join.
    public let rejoin: Bool
    /// Seed only: the per-player hash of the firstSync view.
    public let viewHash: UInt64?

    public init(
        kind: Kind,
        playerID: String? = nil,
        observedTickId: Int64? = nil,
        streamIndex: UInt64,
        sequence: Int64,
        rejoin: Bool = false,
        viewHash: UInt64? = nil
    ) {
        self.kind = kind
        self.playerID = playerID
        self.observedTickId = observedTickId
        self.streamIndex = streamIndex
        self.sequence = sequence
        self.rejoin = rejoin
        self.viewHash = viewHash
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
