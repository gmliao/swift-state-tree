// Sources/SwiftStateTree/Runtime/SyncOutputVerifier.swift
//
// The sync-output hash verifier of re-evaluation: a shadow sync engine, fed the replay state,
// re-plans every recorded sync output and compares its hashes with the recorded ones.
// See Notes/plans/2026-11-05-sync-output-replay.md, "Reevaluation side".

import Foundation

// MARK: - Result

/// Per-scope counts of a sync-output verification.
public struct SyncOutputScopeCounts: Sendable, Equatable {
    /// Hashes compared (and equal, unless the run failed on this scope).
    public var compared = 0
    /// Comparisons the record does not allow: a seed without `viewHash`, a player whose latest
    /// seed had none, an events scope without a hash.
    public var unverifiable = 0
    /// Scopes the live plan did not commit (a broadcast scope without a hash, a player whose
    /// update was not sent).
    public var skipped = 0

    public init(compared: Int = 0, unverifiable: Int = 0, skipped: Int = 0) {
        self.compared = compared
        self.unverifiable = unverifiable
        self.skipped = skipped
    }

    /// `compared/unverifiable/skipped`.
    public var summary: String { "\(compared)/\(unverifiable)/\(skipped)" }
}

/// The first recorded hash the replay did not reproduce.
public struct SyncOutputMismatch: Sendable, Equatable {
    /// The output's `index`; nil for a seed.
    public let outputIndex: Int?
    public let streamIndex: UInt64
    public let observedTickId: Int64
    /// Nil for a seed.
    public let turnKind: ReevaluationRecordedSyncOutput.TurnKind?
    public let sequence: Int64
    /// `broadcast`, `per-player (combined)`, `events` or `seed (player <id>)`.
    public let scope: String
    public let recorded: UInt64
    public let replayed: UInt64

    public var summary: String {
        let what = outputIndex.map { "output \($0) (\(turnKind?.rawValue ?? "?"), sequence \(sequence))" }
            ?? "seed (sequence \(sequence))"
        return "sync output mismatch at tick \(observedTickId), \(what), scope: \(scope)"
    }
}

/// Overall verdict of a sync-output verification.
public enum SyncOutputVerdict: Sendable, Equatable {
    /// Every scope compared at least once, nothing unverifiable, no mismatch.
    case passed
    /// No mismatch, but some scope was never compared or had unverifiable comparisons.
    case partial
    /// A recorded hash was not reproduced; verification stopped there.
    case failed(SyncOutputMismatch)
    /// The record cannot be verified at all (no sync stream, no sync config, an unsupported
    /// strategy).
    case skipped(reason: String)
    /// The sync stream contradicts itself (an output without a position, a tick past the end).
    case malformed(reason: String)
}

/// Result of the sync-output verification of a re-evaluation run.
public struct SyncOutputVerification: Sendable, Equatable {
    public let verdict: SyncOutputVerdict
    public let broadcast: SyncOutputScopeCounts
    /// One count per (output, recipient) of outputs that commit the per-player scope.
    public let perPlayer: SyncOutputScopeCounts
    /// Opcode 107 only (`eventsApplicable`).
    public let events: SyncOutputScopeCounts
    public let seed: SyncOutputScopeCounts
    /// Whether the events scope is part of the verdict (opcode 107 records).
    public let eventsApplicable: Bool
    /// Outputs that reset their recipients' key scopes. Their empty updates carry no patches and
    /// are compared as no change, on both sides.
    public let keyScopeResets: Int

    public init(
        verdict: SyncOutputVerdict,
        broadcast: SyncOutputScopeCounts = .init(),
        perPlayer: SyncOutputScopeCounts = .init(),
        events: SyncOutputScopeCounts = .init(),
        seed: SyncOutputScopeCounts = .init(),
        eventsApplicable: Bool = false,
        keyScopeResets: Int = 0
    ) {
        self.verdict = verdict
        self.broadcast = broadcast
        self.perPlayer = perPlayer
        self.events = events
        self.seed = seed
        self.eventsApplicable = eventsApplicable
        self.keyScopeResets = keyScopeResets
    }

    /// One line for the CLIs.
    public var summary: String {
        let head: String
        switch verdict {
        case .passed: head = "passed"
        case .partial: head = "partial"
        case .failed(let mismatch): head = "FAILED: \(mismatch.summary)"
        case .skipped(let reason): return "skipped (\(reason))"
        case .malformed(let reason): return "malformed (\(reason))"
        }
        var scopes = ["broadcast \(broadcast.summary)", "per-player \(perPlayer.summary)"]
        if eventsApplicable { scopes.append("events \(events.summary)") }
        scopes.append("seed \(seed.summary)")
        var line = "\(head) [compared/unverifiable/skipped: \(scopes.joined(separator: ", "))]"
        if keyScopeResets > 0 { line += ", \(keyScopeResets) key scope resets" }
        return line
    }
}

// MARK: - Shadow

/// The shadow of the live adapter's sync engine. It re-plans each recorded output from the
/// replay state, with full extraction (so it does not depend on the live dirty tracking: a
/// field the live run failed to mark dirty shows up as a mismatch), the recorded extraction
/// drops applied, and only the scopes the output committed.
package struct SyncOutputShadow<State: StateNodeProtocol> {
    private var engine = SyncEngine()
    private var seeded: Set<PlayerID> = []
    /// Replayed server events not yet consumed by an output (opcode 107); nil where the payload
    /// has no canonical form.
    private var pendingEvents: [(sequence: Int64, event: CanonicalSyncEvent?)] = []
    private let mergedBroadcastFrame: Bool

    private(set) var broadcast = SyncOutputScopeCounts()
    private(set) var perPlayer = SyncOutputScopeCounts()
    private(set) var events = SyncOutputScopeCounts()
    private(set) var seed = SyncOutputScopeCounts()
    private(set) var keyScopeResets = 0
    private(set) var mismatch: SyncOutputMismatch?

    package init(mergedBroadcastFrame: Bool) {
        self.mergedBroadcastFrame = mergedBroadcastFrame
    }

    /// Replayed server events, in any order across calls (sorted on consumption).
    package mutating func addEvents(_ recorded: [ReevaluationRecordedServerEvent]) {
        guard mergedBroadcastFrame else { return }
        for event in recorded {
            let canonical = (try? SnapshotValue.make(from: event.payload.base)).map {
                CanonicalSyncEvent(sequence: event.sequence, type: event.typeIdentifier, payload: $0)
            }
            pendingEvents.append((event.sequence, canonical))
        }
    }

    package mutating func seed(_ marker: ReevaluationRecordedSyncMarker, playerID: PlayerID, state: State) {
        var staged = SyncEngine.StagedCaches()
        var drops = ExtractionDrops()
        let snapshot = engine.lateJoinSnapshot(for: playerID, from: state, staged: &staged, drops: &drops)
        let patches = engine.computeDiff(from: StateSnapshot(values: [:]), to: snapshot, onlyPaths: nil)
        staged.firstSyncReceived.insert(playerID)
        engine.applyStaged(staged)
        seeded.insert(playerID)
        guard let recorded = marker.viewHash else {
            seed.unverifiable += 1
            return
        }
        let replayed = CanonicalPatchList(patches).hash
        if replayed == recorded {
            seed.compared += 1
        } else {
            mismatch = SyncOutputMismatch(
                outputIndex: nil,
                streamIndex: marker.streamIndex,
                observedTickId: marker.observedTickId ?? -1,
                turnKind: nil,
                sequence: marker.sequence,
                scope: "seed (player \(playerID.rawValue))",
                recorded: recorded,
                replayed: replayed
            )
        }
    }

    package mutating func clear(_ playerID: PlayerID) {
        engine.clearCacheForDisconnectedPlayer(playerID)
        seeded.remove(playerID)
    }

    package mutating func output(_ output: ReevaluationRecordedSyncOutput, observedTickId: Int64, state: State) {
        var staged = SyncEngine.StagedCaches()
        var drops = ExtractionDrops()

        let broadcastSnapshot = Self.substituting(
            output.extractionDrops[SyncOutputScope.broadcast],
            in: engine.extractBroadcastSnapshot(from: state, mode: .all, drops: &drops),
            cache: engine.cachedBroadcastSnapshot
        )
        let broadcastDiff = engine.computeBroadcastDiffFromSnapshot(
            currentBroadcast: broadcastSnapshot,
            mode: .all,
            baseline: .cached,
            staged: &staged
        )
        if let recorded = output.broadcastHash {
            guard compare(recorded, CanonicalPatchList(broadcastDiff).hash, scope: "broadcast", output, observedTickId) else { return }
            broadcast.compared += 1
        } else {
            broadcast.skipped += 1
            staged.broadcast = nil
        }

        if let recorded = output.perPlayerHash {
            let unverified = Set(output.perPlayerUnverified ?? [])
            let uncommitted = Set(output.perPlayerUncommitted ?? [])
            var pairs: [(String, UInt64)] = []
            for playerID in seeded.sorted(by: { SnapshotValue.utf8Less($0.rawValue, $1.rawValue) }) {
                let perPlayerSnapshot = Self.substituting(
                    output.extractionDrops[playerID.rawValue],
                    in: engine.extractPerPlayerSnapshot(for: playerID, from: state, mode: .all, drops: &drops),
                    cache: engine.cachedPerPlayerSnapshot(playerID)
                )
                let update = mergedBroadcastFrame
                    ? engine.generatePerPlayerUpdateFromSnapshot(
                        for: playerID, perPlayerSnapshot: perPlayerSnapshot, perPlayerMode: .all, staged: &staged)
                    : engine.generateUpdateFromBroadcastDiff(
                        for: playerID, broadcastDiff: broadcastDiff, perPlayerSnapshot: perPlayerSnapshot,
                        perPlayerMode: .all, staged: &staged)
                if uncommitted.contains(playerID.rawValue) {
                    staged.perPlayer.removeValue(forKey: playerID)
                    perPlayer.skipped += 1
                    continue
                }
                if unverified.contains(playerID.rawValue) {
                    perPlayer.unverifiable += 1
                    continue
                }
                perPlayer.compared += 1
                let patches = update.patches
                if !patches.isEmpty {
                    pairs.append((playerID.rawValue, CanonicalPatchList(patches).hash))
                }
            }
            guard compare(recorded, CanonicalPatchList.combinedHash(pairs), scope: "per-player (combined)", output, observedTickId) else { return }
            if output.resetsKeyScopes == true { keyScopeResets += 1 }
        }

        if mergedBroadcastFrame {
            let through = output.eventsThroughSequence ?? Int64.min
            let consumed = pendingEvents.filter { $0.sequence <= through }.sorted { $0.sequence < $1.sequence }
            pendingEvents.removeAll { $0.sequence <= through }
            let canonical = consumed.compactMap(\.event)
            if output.encodeDropScopes.contains(SyncOutputScope.events) || canonical.count != consumed.count {
                events.unverifiable += 1
            } else if let recorded = output.eventsHash {
                guard compare(recorded, CanonicalSyncEvent.hash(canonical), scope: "events", output, observedTickId) else { return }
                events.compared += 1
            } else {
                events.skipped += 1
            }
        }

        engine.applyStaged(staged)
    }

    /// Records the mismatch and returns false when `replayed` differs.
    private mutating func compare(
        _ recorded: UInt64,
        _ replayed: UInt64,
        scope: String,
        _ output: ReevaluationRecordedSyncOutput,
        _ observedTickId: Int64
    ) -> Bool {
        guard recorded != replayed else { return true }
        mismatch = SyncOutputMismatch(
            outputIndex: output.index,
            streamIndex: output.streamIndex,
            observedTickId: observedTickId,
            turnKind: output.turnKind,
            sequence: output.sequence,
            scope: scope,
            recorded: recorded,
            replayed: replayed
        )
        return false
    }

    /// The live extraction gave each dropped field its cached value (none without one); the
    /// shadow does the same with its own cache, which equals the live one up to this output.
    private static func substituting(_ dropped: [String]?, in snapshot: StateSnapshot, cache: StateSnapshot?) -> StateSnapshot {
        guard let dropped, !dropped.isEmpty else { return snapshot }
        var result = snapshot
        for field in dropped {
            result.values[field] = cache?.values[field]
        }
        return result
    }
}

/// Scope names in `extractionDrops` and `encodeDropScopes` (the others are player IDs).
package enum SyncOutputScope {
    package static let broadcast = "broadcast"
    package static let events = "events"
}

extension StateUpdate {
    fileprivate var patches: [StatePatch] {
        switch self {
        case .noChange: return []
        case .diff(let patches), .firstSync(let patches): return patches
        }
    }
}

// MARK: - Driver

/// Steps the shadow through a record's sync stream in `streamIndex` order, alongside the replay.
///
/// Each entry needs the replay state at its `observedTickId`: -1 is the state before OnInitialize
/// until the stream's initialize marker, the state after it from then on. The replay feeds the
/// state of every tick it steps; the driver keeps the states the remaining entries still need
/// (entries are in stream order, which a legacy cycle's late commit can put after outputs of
/// later ticks).
package struct SyncOutputReplayDriver<State: StateNodeProtocol> {
    private var shadow: SyncOutputShadow<State>
    private var entries: [ReevaluationSyncStreamEntry]
    private var next = 0
    private var neededCounts: [Int64: Int] = [:]
    private var window: [Int64: State] = [:]
    private var beforeInitialize: State?
    private var afterInitialize: State?
    private var initializeApplied = false
    private let hasInitializeMarker: Bool
    private var lastSteppedTick: Int64 = -1
    private let skipReason: String?
    private let eventsApplicable: Bool
    private var malformed: String?

    package init(metadata: ReevaluationRecordMetadata, stream: [ReevaluationSyncStreamEntry]) {
        let presence = ReevaluationSyncStreamPresence.of(metadata: metadata, stream: stream)
        let config = metadata.syncConfig
        if case .absent(let reason) = presence {
            skipReason = "no sync stream: \(reason)"
        } else if config == nil {
            skipReason = "record \(metadata.version ?? "unknown") predates syncConfig"
        } else if config?.fullSnapshot == true {
            skipReason = "full-snapshot strategy is not verified"
        } else {
            skipReason = nil
        }
        let merged = config?.mergedBroadcastFrame ?? false
        shadow = SyncOutputShadow(mergedBroadcastFrame: merged)
        eventsApplicable = merged
        entries = skipReason == nil ? stream : []
        // Without an initialize marker OnInitialize was not a turn: it ran before the adapter
        // existed, so every recorded entry read the state after it.
        hasInitializeMarker = entries.contains {
            if case .marker(let marker) = $0 { return marker.kind == .initialize } else { return false }
        }
        initializeApplied = !hasInitializeMarker
        for entry in entries {
            if let tick = Self.neededTick(entry), tick >= 0 {
                neededCounts[tick, default: 0] += 1
            }
        }
    }

    /// The state before and after OnInitialize, and the events OnInitialize emitted.
    package mutating func begin(beforeInitialize: State, afterInitialize: State, initializeEvents: [ReevaluationRecordedServerEvent]) {
        self.beforeInitialize = beforeInitialize
        self.afterInitialize = afterInitialize
        // OnInitialize's events reached the adapter's queue only when it ran as a turn.
        if hasInitializeMarker {
            shadow.addEvents(initializeEvents)
        }
        drain()
    }

    /// The replay stepped `tickId`: its state and the server events it emitted.
    package mutating func stepped(tickId: Int64, state: State, events: [ReevaluationRecordedServerEvent]) {
        guard skipReason == nil, malformed == nil, shadow.mismatch == nil else { return }
        lastSteppedTick = tickId
        if neededCounts[tickId] != nil {
            window[tickId] = state
        }
        shadow.addEvents(events)
        drain()
    }

    package func finish() -> SyncOutputVerification {
        let verdict: SyncOutputVerdict
        if let skipReason {
            verdict = .skipped(reason: skipReason)
        } else if let malformed {
            verdict = .malformed(reason: malformed)
        } else if let mismatch = shadow.mismatch {
            verdict = .failed(mismatch)
        } else if next < entries.count {
            verdict = .malformed(reason: "sync stream entry \(entries[next].streamIndex) observed a tick past the record's last tick")
        } else {
            var scopes = [shadow.broadcast, shadow.perPlayer, shadow.seed]
            if eventsApplicable { scopes.append(shadow.events) }
            verdict = scopes.allSatisfy({ $0.compared > 0 && $0.unverifiable == 0 }) ? .passed : .partial
        }
        return SyncOutputVerification(
            verdict: verdict,
            broadcast: shadow.broadcast,
            perPlayer: shadow.perPlayer,
            events: shadow.events,
            seed: shadow.seed,
            eventsApplicable: eventsApplicable,
            keyScopeResets: shadow.keyScopeResets
        )
    }

    private mutating func drain() {
        while next < entries.count, malformed == nil, shadow.mismatch == nil {
            let entry = entries[next]
            let needed = Self.neededTick(entry)
            if let needed, needed > lastSteppedTick { return }
            let state: State?
            if let needed {
                state = needed == -1 ? (initializeApplied ? afterInitialize : beforeInitialize) : window[needed]
            } else {
                state = nil
            }
            guard needed == nil || state != nil else {
                // begin() not called yet for a -1 entry: wait for it.
                if needed == -1 && beforeInitialize == nil { return }
                malformed = "no replay state for sync stream entry \(entry.streamIndex)"
                return
            }
            apply(entry, state: state)
            next += 1
            if let needed, needed >= 0 {
                neededCounts[needed, default: 1] -= 1
                if neededCounts[needed] == 0 {
                    neededCounts.removeValue(forKey: needed)
                    window.removeValue(forKey: needed)
                }
            }
        }
    }

    private mutating func apply(_ entry: ReevaluationSyncStreamEntry, state: State?) {
        switch entry {
        case .output(let output):
            guard let observed = output.observedTickId, let state else {
                malformed = "sync output \(output.index) has no observedTickId"
                return
            }
            shadow.output(output, observedTickId: observed, state: state)
        case .marker(let marker):
            switch marker.kind {
            case .initialize:
                initializeApplied = true
            case .seed:
                guard let player = marker.playerID, let state else {
                    malformed = "seed marker \(marker.streamIndex) has no player or position"
                    return
                }
                shadow.seed(marker, playerID: PlayerID(player), state: state)
            case .clear:
                guard let player = marker.playerID else {
                    malformed = "clear marker \(marker.streamIndex) has no player"
                    return
                }
                shadow.clear(PlayerID(player))
            }
        }
    }

    /// The tick whose state the entry reads; nil when it reads none (clear, initialize).
    private static func neededTick(_ entry: ReevaluationSyncStreamEntry) -> Int64? {
        switch entry {
        case .output(let output): return output.observedTickId ?? -1
        case .marker(let marker):
            return marker.kind == .seed ? (marker.observedTickId ?? -1) : nil
        }
    }
}
