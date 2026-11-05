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
    /// Comparisons that cannot vouch for what a client got: a seed without `viewHash`; a player
    /// whose latest seed had none; a scope whose encode dropped patches, and a player whose
    /// client has diverged since (until a seed with `viewHash`); events without a canonical form.
    public var unverifiable = 0
    /// Scopes the live plan did not commit, each with a `SyncOutputSkipReason`.
    public var skipped = 0

    public init(compared: Int = 0, unverifiable: Int = 0, skipped: Int = 0) {
        self.compared = compared
        self.unverifiable = unverifiable
        self.skipped = skipped
    }

    /// `compared/unverifiable/skipped`.
    public var summary: String { "\(compared)/\(unverifiable)/\(skipped)" }
}

/// Which check found a mismatch.
public enum SyncOutputCheck: String, Sendable, Equatable {
    /// A recorded hash was not reproduced.
    case hash
    /// The patch-apply oracle: the replay's patches, applied to the replay's previous view of the
    /// scope, do not give its new view (a diff bug both sides share, which no hash shows).
    ///
    /// The oracle is an RFC 6901 reference client (`SnapshotClientView`), not the TypeScript SDK's
    /// `view.ts`: it unescapes `~0`/`~1`, reads `[n]` as a key, and rejects removing a missing
    /// field or writing below a non-object, where `view.ts` does not (#121). A passing check
    /// proves the patches are correct; it does not prove that the TypeScript client converges.
    case apply
}

/// The first check the replay failed.
public struct SyncOutputMismatch: Sendable, Equatable {
    /// The output's `index`; nil for a seed.
    public let outputIndex: Int?
    public let streamIndex: UInt64
    public let observedTickId: Int64
    /// Nil for a seed.
    public let turnKind: ReevaluationRecordedSyncOutput.TurnKind?
    public let sequence: Int64
    public let check: SyncOutputCheck
    /// `broadcast`, `per-player (combined)`, `per-player (player <id>)`, `events` or
    /// `seed (player <id>)`.
    public let scope: String
    /// Hash check: the recorded and replayed hashes. Apply check: the hashes of the expected and
    /// the applied view.
    public let recorded: UInt64
    public let replayed: UInt64
    /// Where it differs, as far as the record tells (the player, the first differing path), or
    /// which recording detail would tell.
    public let detail: String?

    public init(
        outputIndex: Int?,
        streamIndex: UInt64,
        observedTickId: Int64,
        turnKind: ReevaluationRecordedSyncOutput.TurnKind?,
        sequence: Int64,
        check: SyncOutputCheck = .hash,
        scope: String,
        recorded: UInt64,
        replayed: UInt64,
        detail: String? = nil
    ) {
        self.outputIndex = outputIndex
        self.streamIndex = streamIndex
        self.observedTickId = observedTickId
        self.turnKind = turnKind
        self.sequence = sequence
        self.check = check
        self.scope = scope
        self.recorded = recorded
        self.replayed = replayed
        self.detail = detail
    }

    public var summary: String {
        let what = outputIndex.map { "output \($0) (\(turnKind?.rawValue ?? "?"), sequence \(sequence))" }
            ?? "seed (sequence \(sequence))"
        var line = "sync output mismatch at tick \(observedTickId), \(what), check: \(check.rawValue), scope: \(scope)"
        if let detail { line += "; \(detail)" }
        return line
    }
}

/// Why a scope was skipped. Only `benign` reasons allow `passed`: the others leave a gap the
/// record cannot explain.
public enum SyncOutputSkipReason: String, Sendable, CaseIterable, Comparable {
    /// Opcode 107: a per-player update was not sent. Its cache was not committed, so the next
    /// diff resends the change: the client does not diverge. Benign once a later comparison for
    /// that player (an output, or a seed with a view hash) has seen the resend.
    case perPlayerResent = "per-player update not sent (resent by the next diff)"
    /// Opcode 107: a per-player update was not sent, and no later comparison saw it resent (the
    /// record ended, or the player left, first).
    case perPlayerResendNotSeen = "per-player update not sent, resend never compared"
    /// A joiner's full view did not encode at all (no seed, nothing sent), and a later seed for
    /// that player was compared: its client got a verified view after all. Benign.
    case viewSentLater = "full view not sent (a later seed was compared)"
    /// A joiner's full view did not encode at all, and no later seed for that player was
    /// compared: its client may never have got any state.
    case viewNotSent = "full view not sent, no later seed compared"
    /// An output without a broadcast hash: the broadcast scope was not committed.
    case broadcastNotCommitted = "broadcast not committed"
    /// An opcode 107 output without an events hash, and no events drop recorded.
    case eventsHashMissing = "events hash missing"

    /// The reasons that allow `passed`.
    public static let benign: Set<SyncOutputSkipReason> = [.perPlayerResent, .viewSentLater]

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Overall verdict of a sync-output verification.
public enum SyncOutputVerdict: Sendable, Equatable {
    /// No mismatch, every scope compared at least once (not every output: a broadcast-only cycle
    /// has no per-player scope), nothing unverifiable, every skip has a benign reason
    /// (`SyncOutputSkipReason.benign`), and no replayed event is left after the last output.
    ///
    /// The apply scope's part proves the patches correct against a reference client
    /// (`SyncOutputCheck.apply`), not that the TypeScript SDK converges (#121).
    case passed
    /// No mismatch, but some scope was never compared, had unverifiable comparisons, was skipped
    /// for a reason that is not benign, or events were left after the last output.
    case partial
    /// A recorded hash was not reproduced; verification stopped there.
    case failed(SyncOutputMismatch)
    /// The record cannot be verified at all (no sync stream, no sync config, an unsupported
    /// strategy).
    case skipped(reason: String)
    /// The sync stream contradicts itself (stream indices not exactly `0..<n`, an output without
    /// a position, a tick past the end).
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
    /// The patch-apply oracle: one check per seed and per diffed scope with a previous view.
    public let apply: SyncOutputScopeCounts
    /// Whether the events scope is part of the verdict (opcode 107 records).
    public let eventsApplicable: Bool
    /// Outputs that reset their recipients' key scopes. Their empty updates carry no patches and
    /// are compared as no change, on both sides.
    public let keyScopeResets: Int
    /// The skipped scopes per reason.
    public let skipReasons: [SyncOutputSkipReason: Int]
    /// Opcode 107: replayed events no output consumed, all after the last output's
    /// `eventsThroughSequence` (a run that ends between an event and the next sync). Events
    /// without a recipient or not merged count here too when no output follows them, since an
    /// output lists those (`eventsNotQueued`, `eventsNotMerged`). Makes the verdict `partial`.
    public let eventsAfterLastOutput: Int
    /// Opcode 107: events that missed the merged frame and went out as their own frame, and
    /// those that were lost (`eventsNotMerged`); each makes its output's events unverifiable.
    public let eventsSentAlone: Int
    public let eventsLost: Int

    public init(
        verdict: SyncOutputVerdict,
        broadcast: SyncOutputScopeCounts = .init(),
        perPlayer: SyncOutputScopeCounts = .init(),
        events: SyncOutputScopeCounts = .init(),
        seed: SyncOutputScopeCounts = .init(),
        apply: SyncOutputScopeCounts = .init(),
        eventsApplicable: Bool = false,
        keyScopeResets: Int = 0,
        skipReasons: [SyncOutputSkipReason: Int] = [:],
        eventsAfterLastOutput: Int = 0,
        eventsSentAlone: Int = 0,
        eventsLost: Int = 0
    ) {
        self.verdict = verdict
        self.broadcast = broadcast
        self.perPlayer = perPlayer
        self.events = events
        self.seed = seed
        self.apply = apply
        self.eventsApplicable = eventsApplicable
        self.keyScopeResets = keyScopeResets
        self.skipReasons = skipReasons
        self.eventsAfterLastOutput = eventsAfterLastOutput
        self.eventsSentAlone = eventsSentAlone
        self.eventsLost = eventsLost
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
        scopes.append("apply \(apply.summary)")
        var line = "\(head) [compared/unverifiable/skipped: \(scopes.joined(separator: ", "))]"
        if !skipReasons.isEmpty {
            let reasons = skipReasons.sorted { $0.key < $1.key }.map { "\($0.key.rawValue): \($0.value)" }
            line += "; skipped: \(reasons.joined(separator: ", "))"
        }
        if keyScopeResets > 0 { line += "; \(keyScopeResets) key scope resets" }
        if eventsAfterLastOutput > 0 { line += "; \(eventsAfterLastOutput) events after the last output" }
        if eventsSentAlone > 0 { line += "; \(eventsSentAlone) events sent outside the merged frame" }
        if eventsLost > 0 { line += "; \(eventsLost) events lost (did not encode)" }
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
    /// Players whose client no longer matches the live cache (an encode dropped patches of a
    /// committed update, or a combined-mode update was not sent while the broadcast cache was
    /// committed), until a seed with `viewHash`. Their hashes are still compared, since the live
    /// hash covers what the diff planned; their counts are unverifiable.
    private var diverged: Set<PlayerID> = []
    /// Opcode 107: sequences the live adapter never queued or merged (`eventsNotQueued`,
    /// `eventsNotMerged`).
    private var notQueued: Set<Int64> = []
    /// Opcode 107: players with skipped (unsent) updates whose resend no comparison has seen yet,
    /// with the number of such skips.
    private var pendingResends: [PlayerID: Int] = [:]
    /// Skips whose player left before a comparison saw the resend.
    private var resendsNotSeen = 0
    /// Players outside `seeded` whose full view did not encode (`encodeDropScopes`), with the
    /// number of such outputs, until a compared seed for them.
    private var pendingViews: [PlayerID: Int] = [:]
    /// Those skips a compared seed resolved.
    private var viewsSentLater = 0

    private var recordedSkipReasons: [SyncOutputSkipReason: Int] = [:]
    private(set) var broadcast = SyncOutputScopeCounts()
    private(set) var perPlayer = SyncOutputScopeCounts()
    private(set) var events = SyncOutputScopeCounts()
    private(set) var seed = SyncOutputScopeCounts()
    /// Patch-apply checks (one per diffed scope with a previous view, and per seed).
    private(set) var apply = SyncOutputScopeCounts()
    private(set) var keyScopeResets = 0
    private(set) var eventsSentAlone = 0
    private(set) var eventsLost = 0
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
        let position = Position(marker)
        let scope = "seed (player \(playerID.rawValue))"
        if let recorded = marker.viewHash {
            diverged.remove(playerID)
            let replayed = CanonicalPatchList(patches).hash
            guard compare(recorded, replayed, scope: scope, at: position) else { return }
            seed.compared += 1
            pendingResends.removeValue(forKey: playerID)
            viewsSentLater += pendingViews.removeValue(forKey: playerID) ?? 0
        } else {
            seed.unverifiable += 1
        }
        if let failure = Self.applyCheck(patches, to: [:], expected: snapshot.values, scope: scope, at: position) {
            mismatch = failure
        } else {
            apply.compared += 1
        }
    }

    package mutating func clear(_ playerID: PlayerID) {
        engine.clearCacheForDisconnectedPlayer(playerID)
        seeded.remove(playerID)
        diverged.remove(playerID)
        resendsNotSeen += pendingResends.removeValue(forKey: playerID) ?? 0
    }

    package mutating func output(_ output: ReevaluationRecordedSyncOutput, observedTickId: Int64, state: State) {
        var staged = SyncEngine.StagedCaches()
        var drops = ExtractionDrops()

        let broadcastSnapshot = Self.substituting(
            output.extractionDrops[SyncOutputScope.broadcast],
            in: engine.extractBroadcastSnapshot(from: state, mode: .all, drops: &drops),
            cache: engine.cachedBroadcastSnapshot
        )
        let position = Position(output, observedTickId: observedTickId)
        // The first apply-check failure; reported after the hashes, which say more when they
        // fail too.
        var applyFailure: SyncOutputMismatch?
        func checkApply(_ patches: [StatePatch], to old: [String: SnapshotValue]?, expected: [String: SnapshotValue], scope: String) {
            // Without a previous view the diff seeds the cache and sends nothing.
            guard let old, applyFailure == nil else { return }
            if let failure = Self.applyCheck(patches, to: old, expected: expected, scope: scope, at: position) {
                applyFailure = failure
            } else {
                apply.compared += 1
            }
        }

        let previousBroadcast = staged.broadcast ?? engine.cachedBroadcastSnapshot
        let broadcastDiff = engine.computeBroadcastDiffFromSnapshot(
            currentBroadcast: broadcastSnapshot,
            mode: .all,
            baseline: .cached,
            staged: &staged
        )
        checkApply(broadcastDiff, to: previousBroadcast?.values, expected: broadcastSnapshot.values, scope: SyncOutputScope.broadcast)
        let encodeDrops = Set(output.encodeDropScopes)
        // A joiner whose whole view did not encode: nothing reached it, and it has no seed.
        for scope in output.encodeDropScopes where scope != SyncOutputScope.broadcast && scope != SyncOutputScope.events {
            let playerID = PlayerID(scope)
            guard !seeded.contains(playerID) else { continue }
            skip(.viewNotSent, \.perPlayer)
            pendingViews[playerID, default: 0] += 1
        }
        if let recorded = output.broadcastHash {
            let replayed = CanonicalPatchList(broadcastDiff)
            guard compare(
                recorded, replayed.hash, scope: SyncOutputScope.broadcast, at: position,
                detail: { Self.locate(recorded: output.patches?[SyncOutputScope.broadcast], replayed: replayed.patches) }
            ) else { return }
            if encodeDrops.contains(SyncOutputScope.broadcast) {
                broadcast.unverifiable += 1
            } else {
                broadcast.compared += 1
            }
        } else {
            skip(.broadcastNotCommitted, \.broadcast)
            staged.broadcast = nil
        }

        if let recorded = output.perPlayerHash {
            let unverified = Set(output.perPlayerUnverified ?? [])
            let uncommitted = Set(output.perPlayerUncommitted ?? [])
            var pairs: [(String, UInt64)] = []
            var replayedPatches: [String: [StatePatch]] = [:]
            for playerID in seeded.sorted(by: { SnapshotValue.utf8Less($0.rawValue, $1.rawValue) }) {
                let perPlayerSnapshot = Self.substituting(
                    output.extractionDrops[playerID.rawValue],
                    in: engine.extractPerPlayerSnapshot(for: playerID, from: state, mode: .all, drops: &drops),
                    cache: engine.cachedPerPlayerSnapshot(playerID)
                )
                let previousPerPlayer = staged.perPlayer[playerID] ?? engine.cachedPerPlayerSnapshot(playerID)
                let update = mergedBroadcastFrame
                    ? engine.generatePerPlayerUpdateFromSnapshot(
                        for: playerID, perPlayerSnapshot: perPlayerSnapshot, perPlayerMode: .all, staged: &staged)
                    : engine.generateUpdateFromBroadcastDiff(
                        for: playerID, broadcastDiff: broadcastDiff, perPlayerSnapshot: perPlayerSnapshot,
                        perPlayerMode: .all, staged: &staged)
                let scope = "per-player (player \(playerID.rawValue))"
                if mergedBroadcastFrame {
                    checkApply(update.patches, to: previousPerPlayer?.values, expected: perPlayerSnapshot.values, scope: scope)
                } else if let previousBroadcast {
                    // The combined update carries both scopes: check the client's whole view.
                    checkApply(
                        update.patches,
                        to: previousPerPlayer.map { previousBroadcast.values.merging($0.values) { _, perPlayer in perPlayer } },
                        expected: broadcastSnapshot.values.merging(perPlayerSnapshot.values) { _, perPlayer in perPlayer },
                        scope: scope
                    )
                }
                if uncommitted.contains(playerID.rawValue) {
                    staged.perPlayer.removeValue(forKey: playerID)
                    if mergedBroadcastFrame {
                        skip(.perPlayerResent, \.perPlayer)
                        pendingResends[playerID, default: 0] += 1
                    } else {
                        // The combined update carried the broadcast changes, whose cache was
                        // committed: this client missed them.
                        diverged.insert(playerID)
                        perPlayer.unverifiable += 1
                    }
                    continue
                }
                if unverified.contains(playerID.rawValue) {
                    perPlayer.unverifiable += 1
                    continue
                }
                if encodeDrops.contains(playerID.rawValue) {
                    diverged.insert(playerID)
                }
                if diverged.contains(playerID) {
                    perPlayer.unverifiable += 1
                } else {
                    perPlayer.compared += 1
                    pendingResends.removeValue(forKey: playerID)
                }
                let patches = update.patches
                if !patches.isEmpty {
                    let canonical = CanonicalPatchList(patches)
                    pairs.append((playerID.rawValue, canonical.hash))
                    replayedPatches[playerID.rawValue] = canonical.patches
                }
            }
            let replayedPairs = pairs
            let replayedByPlayer = replayedPatches
            guard compare(
                recorded, CanonicalPatchList.combinedHash(pairs), scope: "per-player (combined)", at: position,
                detail: { Self.locatePlayer(output, replayed: replayedPairs, replayedPatches: replayedByPlayer) }
            ) else { return }
            if output.resetsKeyScopes == true { keyScopeResets += 1 }
        }

        if mergedBroadcastFrame {
            notQueued.formUnion(output.eventsNotQueued ?? [])
            notQueued.formUnion(output.eventsNotMerged?.all ?? [])
            eventsSentAlone += output.eventsNotMerged?.sentAlone.count ?? 0
            eventsLost += output.eventsNotMerged?.lost.count ?? 0
            pendingEvents.removeAll { notQueued.contains($0.sequence) }
            let through = output.eventsThroughSequence ?? Int64.min
            let consumed = pendingEvents.filter { $0.sequence <= through }.sorted { $0.sequence < $1.sequence }
            pendingEvents.removeAll { $0.sequence <= through }
            let canonical = consumed.compactMap(\.event)
            // Events sent alone or lost: what the clients got is not in any merged frame.
            let notMerged = !(output.eventsNotMerged?.isEmpty ?? true)
            if output.encodeDropScopes.contains(SyncOutputScope.events) || canonical.count != consumed.count || notMerged {
                events.unverifiable += 1
            } else if let recorded = output.eventsHash {
                guard compare(recorded, CanonicalSyncEvent.hash(canonical), scope: SyncOutputScope.events, at: position) else { return }
                events.compared += 1
            } else {
                skip(.eventsHashMissing, \.events)
            }
        }

        if let applyFailure {
            mismatch = applyFailure
            return
        }
        engine.applyStaged(staged)
    }

    /// Replayed events no output consumed (never queued ones left out).
    package var unconsumedEvents: Int {
        pendingEvents.filter { !notQueued.contains($0.sequence) }.count
    }

    /// The skipped scopes per reason. Resend skips no comparison saw resolved (the player left,
    /// or the record ended) count as `perPlayerResendNotSeen`; unsent views a compared seed
    /// resolved count as `viewSentLater`.
    var skipReasons: [SyncOutputSkipReason: Int] {
        var reasons = recordedSkipReasons
        let notSeen = resendsNotSeen + pendingResends.values.reduce(0, +)
        if notSeen > 0 {
            let resent = (reasons[.perPlayerResent] ?? 0) - notSeen
            reasons[.perPlayerResent] = resent > 0 ? resent : nil
            reasons[.perPlayerResendNotSeen] = notSeen
        }
        if viewsSentLater > 0 {
            let notSent = (reasons[.viewNotSent] ?? 0) - viewsSentLater
            reasons[.viewNotSent] = notSent > 0 ? notSent : nil
            reasons[.viewSentLater] = viewsSentLater
        }
        return reasons
    }

    private mutating func skip(_ reason: SyncOutputSkipReason, _ counts: WritableKeyPath<Self, SyncOutputScopeCounts>) {
        self[keyPath: counts].skipped += 1
        recordedSkipReasons[reason, default: 0] += 1
    }

    /// Where in the stream a check ran.
    private struct Position {
        let outputIndex: Int?
        let streamIndex: UInt64
        let observedTickId: Int64
        let turnKind: ReevaluationRecordedSyncOutput.TurnKind?
        let sequence: Int64

        init(_ output: ReevaluationRecordedSyncOutput, observedTickId: Int64) {
            outputIndex = output.index
            streamIndex = output.streamIndex
            self.observedTickId = observedTickId
            turnKind = output.turnKind
            sequence = output.sequence
        }

        init(_ marker: ReevaluationRecordedSyncMarker) {
            outputIndex = nil
            streamIndex = marker.streamIndex
            observedTickId = marker.observedTickId ?? -1
            turnKind = nil
            sequence = marker.sequence
        }

        func mismatch(_ check: SyncOutputCheck, scope: String, recorded: UInt64, replayed: UInt64, detail: String?) -> SyncOutputMismatch {
            SyncOutputMismatch(
                outputIndex: outputIndex,
                streamIndex: streamIndex,
                observedTickId: observedTickId,
                turnKind: turnKind,
                sequence: sequence,
                check: check,
                scope: scope,
                recorded: recorded,
                replayed: replayed,
                detail: detail
            )
        }
    }

    /// Records the mismatch and returns false when `replayed` differs.
    private mutating func compare(
        _ recorded: UInt64,
        _ replayed: UInt64,
        scope: String,
        at position: Position,
        detail: () -> String? = { nil }
    ) -> Bool {
        guard recorded != replayed else { return true }
        mismatch = position.mismatch(.hash, scope: scope, recorded: recorded, replayed: replayed, detail: detail())
        return false
    }

    /// The patch-apply oracle: `patches` applied to `old` (with `SnapshotClientView`, which shares
    /// no path handling with the diff) must give `expected`. Nil when it does.
    private static func applyCheck(
        _ patches: [StatePatch],
        to old: [String: SnapshotValue],
        expected: [String: SnapshotValue],
        scope: String,
        at position: Position
    ) -> SyncOutputMismatch? {
        var view = SnapshotClientView(fields: old)
        let detail: String
        do {
            try view.apply(patches)
            SyncOutputApplyCaseRecorder.current?.add(.init(
                streamIndex: position.streamIndex, scope: scope, before: old, patches: patches, after: view.fields
            ))
            guard !SnapshotValue.sameFields(view.fields, expected) else { return nil }
            detail = "first differing path: \(firstDifference(expected, view.fields) ?? "?")"
        } catch {
            detail = "a patch does not apply: \(error)"
        }
        return position.mismatch(.apply, scope: scope, recorded: viewHash(expected), replayed: viewHash(view.fields), detail: detail)
    }

    private static func viewHash(_ fields: [String: SnapshotValue]) -> UInt64 {
        var hasher = DeterministicHash.FNV1a64()
        SnapshotValue.object(fields).hash(into: &hasher)
        return hasher.value
    }

    /// The first path (keys in UTF-8 order, depth first) where the two views differ.
    private static func firstDifference(_ expected: [String: SnapshotValue], _ actual: [String: SnapshotValue], under path: String = "") -> String? {
        let keys = Set(expected.keys).union(actual.keys).sorted { SnapshotValue.utf8Less($0, $1) }
        for key in keys {
            let child = path + "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
            switch (expected[key], actual[key]) {
            case (.object(let lhs)?, .object(let rhs)?):
                if let found = firstDifference(lhs, rhs, under: child) { return found }
            case (let lhs, let rhs):
                if !SnapshotValue.sameValue(lhs, rhs) { return child }
            }
        }
        return nil
    }

    /// The first patch where a recorded canonical list differs from the replayed one, or the hint
    /// to record the lists.
    private static func locate(recorded: [StatePatch]?, replayed: [StatePatch]) -> String {
        let replayed = replayed.map(\.jsonSafe)
        guard let recorded else {
            return "rerun with \(EnvKeys.Reevaluation.recordSyncPatches)=true for the first differing patch"
        }
        guard let index = (0..<max(recorded.count, replayed.count)).first(where: { index in
            index >= recorded.count || index >= replayed.count || recorded[index] != replayed[index]
        }) else {
            return "the recorded patches are equal (a hash collision, or a record edited by hand)"
        }
        let path = index < recorded.count ? recorded[index].path : replayed[index].path
        return "first differing patch #\(index) at \(path) (recorded \(recorded.count) patches, replayed \(replayed.count))"
    }

    /// The first player whose recorded hash differs, then its first differing patch; or the hint
    /// to record per-player hashes.
    private static func locatePlayer(
        _ output: ReevaluationRecordedSyncOutput,
        replayed: [(String, UInt64)],
        replayedPatches: [String: [StatePatch]]
    ) -> String {
        guard let recorded = output.perPlayerHashes else {
            return "rerun with \(EnvKeys.Reevaluation.recordSyncDetails)=true to name the player"
        }
        let replayedHashes = Dictionary(replayed, uniquingKeysWith: { first, _ in first })
        let players = Set(recorded.keys).union(replayedHashes.keys).sorted { SnapshotValue.utf8Less($0, $1) }
        guard let player = players.first(where: { recorded[$0] != replayedHashes[$0] }) else {
            return "every recorded per-player hash matches"
        }
        let patches = locate(recorded: output.patches.map { $0[player] ?? [] }, replayed: replayedPatches[player] ?? [])
        return "player \(player): \(patches)"
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
        // The keeper's stream counter is dense: a gap or a repeat is a lost or duplicated entry.
        if entries.map(\.streamIndex) != Array(0 ..< UInt64(entries.count)) {
            let indices = entries.map(\.streamIndex)
            let firstBad = indices.enumerated().first { $0.element != UInt64($0.offset) }
            malformed = "sync stream indices are not 0..<\(entries.count) (first difference at position \(firstBad?.offset ?? 0): \(firstBad.map { "\($0.element)" } ?? "?"))"
        }
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
            var scopes = [shadow.broadcast, shadow.perPlayer, shadow.seed, shadow.apply]
            if eventsApplicable { scopes.append(shadow.events) }
            let complete = scopes.allSatisfy { $0.compared > 0 && $0.unverifiable == 0 }
            let benignSkips = shadow.skipReasons.keys.allSatisfy { SyncOutputSkipReason.benign.contains($0) }
            verdict = complete && benignSkips && shadow.unconsumedEvents == 0 ? .passed : .partial
        }
        return SyncOutputVerification(
            verdict: verdict,
            broadcast: shadow.broadcast,
            perPlayer: shadow.perPlayer,
            events: shadow.events,
            seed: shadow.seed,
            apply: shadow.apply,
            eventsApplicable: eventsApplicable,
            keyScopeResets: shadow.keyScopeResets,
            skipReasons: shadow.skipReasons,
            eventsAfterLastOutput: shadow.unconsumedEvents,
            eventsSentAlone: shadow.eventsSentAlone,
            eventsLost: shadow.eventsLost
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

/// Collects the apply oracle's cases (the view before, the patches, the oracle's view after)
/// while bound with `$current`. The golden recordings export them, so the TypeScript SDK can
/// apply the same patches and be compared with the oracle (#121).
package final class SyncOutputApplyCaseRecorder: @unchecked Sendable {
    package struct Case: Codable, Sendable, Equatable {
        /// The stream entry (output or marker) the case belongs to.
        package let streamIndex: UInt64
        package let scope: String
        package let before: [String: SnapshotValue]
        /// In canonical order: the diff's own order depends on hashing, and canonical order
        /// only moves patches to unrelated paths, so applying it gives the same view.
        package let patches: [StatePatch]
        package let after: [String: SnapshotValue]

        package init(streamIndex: UInt64, scope: String, before: [String: SnapshotValue], patches: [StatePatch], after: [String: SnapshotValue]) {
            self.streamIndex = streamIndex
            self.scope = scope
            self.before = before
            self.patches = CanonicalPatchList(patches).patches
            self.after = after
        }
    }

    @TaskLocal package static var current: SyncOutputApplyCaseRecorder?

    private let lock = NSLock()
    private var recorded: [Case] = []

    package init() {}

    package func add(_ applyCase: Case) {
        lock.withLock { recorded.append(applyCase) }
    }

    /// By stream entry, then scope: the order within one entry depends on hashing.
    package var cases: [Case] {
        lock.withLock { recorded }.enumerated().sorted { a, b in
            (a.element.streamIndex, a.element.scope, a.offset) < (b.element.streamIndex, b.element.scope, b.offset)
        }.map(\.element)
    }
}
