import Foundation
import SwiftStateTree
import SwiftStateTreeMessagePack

// MARK: - Sync phase types

/// The prefix of each pending event queue that one sync phase read. Its commit removes exactly
/// this prefix; events queued later stay for the next cycle. A plan reads the queue once, and
/// every frame it builds covers exactly `[0, count)`. A plan that throws commits nothing, so the
/// queue is unchanged.
struct SyncPhaseConsumedEvents: Sendable, Equatable {
    var targeted = 0
    var broadcast = 0
}

/// A plan's sync-lag classification (#332): written to the lag state by the plan's commit, so a
/// plan that doesn't commit changes nothing.
struct SyncLagPlanned: Sendable {
    /// Sessions whose frames this plan withholds because they are pending, newly or still.
    var markPending: [SessionID] = []
    /// Sessions this plan resyncs: true for the lagging one (counted), false for another session
    /// of the same player, which gets the snapshot too.
    var resyncs: [SessionID: Bool] = [:]
    /// Terminal closes the classification found due.
    var closes: [(sessionID: SessionID, code: UInt16)] = []
    /// The players whose full view this plan types as a resync.
    var resyncPlayers: Set<PlayerID> = []
    /// The session whose join firstSync this plan is (`planFirstSync`): tracking starts at it.
    var firstSyncSession: SessionID?
    /// This plan's resyncs made it reset the broadcast key scope (#90), and that frame's bytes
    /// over all recipients.
    var causedKeyScopeReset = false
    var keyScopeResetBytes = 0
    /// Events this plan consumes for sessions it withholds: dropped, counted at commit.
    var droppedEvents = 0
}

/// One frame of a sync phase, addressed to one session of this land.
/// Encoded bytes and the WebSocket frame type they go out in: the kind of the encoder that
/// produced them (JSON text, MessagePack binary), carried with the bytes so nothing guesses it.
struct EncodedFrame: Sendable {
    let data: Data
    let kind: WebSocketFrameKind
}

struct SyncPhaseFrame: Sendable {
    let data: Data
    let sessionID: SessionID
    /// The frame type of the encoder that produced `data`.
    let kind: WebSocketFrameKind
    /// A state-update frame (it carries the plan's sync sequence, #332); not an event frame or a
    /// JoinResponse.
    var isStateUpdate = false
    /// A resync's snapshot (#332): sent ahead of the session's other frames of the plan.
    var isResyncSnapshot = false
    /// Row addressing, merged frames: an unsynced recipient's full view, which holds the committed
    /// tables and is sent ahead of the shared frame that brings them to live.
    var isFullViewBeforeSharedFrame = false
}

/// A standalone firstSync plan on a land with row addressing in effect (a programming error).
struct StandaloneFirstSyncRefused: Error {}

/// A session that receives this cycle's frames: joined and not in initial sync (#69).
struct SyncPhaseRecipient: Sendable {
    let sessionID: SessionID
    let playerID: PlayerID
}

/// A ready in-turn join flipped by a full sync phase (#69): its firstSync is planned from the
/// turn's end state with the others' diffs, and its frames follow theirs.
struct SyncPhaseJoiner: Sendable {
    let recipient: SyncPhaseRecipient
    let ticket: Ticket<SessionID>
    let joinResponse: Data
}

/// A state update that failed to encode (`TransportAdapter.encodeUpdatesSerially`).
struct SyncPhaseEncodeFailure: Sendable {
    let sessionID: SessionID
    let playerID: PlayerID
    let error: any Error
}

/// The failure `TransportAdapter.syncEncodeFaultForTesting` injects.
struct SyncPhaseInjectedEncodeFault: Error {}

extension StateUpdate {
    /// The update's patches (none for `.noChange`).
    var patchList: [StatePatch] {
        switch self {
        case .noChange: return []
        case .diff(let patches), .firstSync(let patches): return patches
        }
    }
}

/// Everything one sync phase sends and consumes.
///
/// The sync phase of a room turn has two synchronous steps, run in the same actor turn:
/// - **plan** (`planSyncPhase`, `planFirstSync`): reads the state
///   copy, the recipients and the event queue, passed as parameters; computes the diffs, staging
///   the cache updates in `staged` instead of writing them; encodes every frame. It changes
///   nothing else, except the encoders' dynamic key tables (see `keyScopeResetPending`). It also reads the adapter's
///   configuration (encoding, dirty-tracking settings) and membership details (player slots,
///   membership stamps) directly; that is synchronous and fine until the sync phase runs inside
///   the keeper's turn.
/// - **commit** (`commitSyncPhase`): writes the staged caches and firstSync marks, removes the
///   consumed events, and enqueues the frames as one writer element.
///
/// A frame that doesn't encode, or a field whose snapshot conversion throws, fails the plan
/// (#535): it throws a `LandFailure`, commits nothing and sends nothing, and the land ends.
/// Caches, firstSync marks and events are unchanged; no later plan runs.
/// One sync plan's phase times: snapshot extraction (broadcast and per-player in one call), the
/// broadcast diff, and the per-player diffs. Encoding is in none of them. `combined`: no merged
/// broadcast frames, so the per-player time includes folding the broadcast diff in.
struct SyncPhaseTimes: Equatable, Sendable {
    var extract: Duration
    var broadcast: Duration
    var perPlayer: Duration
    var combined: Bool
}

struct SyncPhasePlan {
    /// The land's sync sequence every state-update frame of this plan carries (#332); nil with
    /// lag tracking off.
    var syncSeq: UInt64?
    /// What this plan's lag classification decided (#332), applied by its commit.
    var syncLag = SyncLagPlanned()
    #if DEBUG
    /// Unsynced recipients that get their initial full view in this plan, not a resync's
    /// (tests: `initialSyncCommittedForTesting`).
    var initialViewSessions: [SessionID] = []
    #endif
    /// Frames in issue order. Per session: merged broadcast frame, targeted event frames,
    /// per-player state frame.
    var frames: [SyncPhaseFrame] = []
    /// State update frames among `frames` (profiling counter).
    var stateUpdateCount = 0
    var consumedEvents = SyncPhaseConsumedEvents()
    /// A full cycle's plan (`syncNow`): its commit ends the carry of failed plans' dirty fields.
    var isFullCycle = false
    /// The plan typed every recipient's update `.firstSync` (key scopes reset): its commit ends a
    /// pending key scope reset.
    var resetsKeyScopes = false
    /// Cache updates and firstSync marks; the commit writes them to the sync engine.
    var staged = SyncEngine.StagedCaches()
    /// The typed tables' writes to last-sent (the broadcast diff on the tables); the commit
    /// applies them. Stands for `staged.broadcast`, which stays nil then.
    var stagedTables = SyncTableStaged()
    /// The per-player tables' writes (#514); the commit applies them. Stands for
    /// `staged.perPlayer`, which stays empty then. Its lifecycle mirrors that cache's: a
    /// per-player encode failure discards the player's part, a failed plan all of it.
    var stagedPerPlayerTables = SyncTablePerPlayerStaged()
    /// Phase times of a full plan, only with transport profiling on.
    var phaseTimes: SyncPhaseTimes?
    /// A player's firstSync was committed outside a broadcast key scope reset (#90): its client's
    /// broadcast key map is empty, while the shared broadcast key table still holds every slot
    /// defined before the join, so later merged broadcast frames would reference slots it never
    /// learned. The commit requests a key scope reset: the next plan with recipients types its
    /// merged broadcast frame `.firstSync`, and every client and the encoder define again.
    var needsBroadcastKeyReset = false
    /// The plan encoded a merged broadcast frame with state patches: the shared broadcast key
    /// table may hold slots from here on (`broadcastKeysMayBeDefined`).
    var encodesBroadcastPatches = false
    /// In-turn joins this plan flips (#69): the commit ends their joining and resumes their
    /// waiters. Their frames (JoinResponse, then firstSync) are in `frames`.
    var flips: [(sessionID: SessionID, ticket: Ticket<SessionID>)] = []
    /// Opcode 107: the event frames this plan's consumed targeted events hold for each joining
    /// session (#69), read by a full plan to decide the held-event bound before it picks its
    /// flips; the commit appends them. `heldEventsEnd` is the targeted count they were read to;
    /// the commit reads them again if the plan consumed a different count.
    var heldEvents: [SessionID: [EncodedFrame]]?
    var heldEventsEnd = 0
    /// What the plan intends to send, per scope, for the sync stream; nil unless the land records
    /// it (`TransportAdapter.digestsPlans`).
    var digest: SyncOutputDigestInput?
    /// A field whose conversion threw ends the land (#535 rows 1, 3, 4 and 6): the plan throws
    /// and commits nothing. The extraction still drops the field to find which one threw.
    func noteExtractionDrops(_ drops: ExtractionDrops) throws {
        guard drops.count > 0 else { return }
        throw LandFailure(
            kind: .syncConversion,
            field: drops.firstField,
            detail: drops.firstError ?? "a synced value didn't convert",
            position: LandFailurePosition(stage: .syncPhase)
        )
    }
}

/// One plan's scopes for the sync stream (record format 2.1): the patches it intends to send
/// before encoding, the fields its extraction dropped, and the scopes whose encoding dropped
/// patches. The commit hashes it in its own synchronous segment.
struct SyncOutputDigestInput {
    /// The broadcast diff; nil when the plan has no broadcast scope.
    var broadcastPatches: [StatePatch]?
    /// Each recipient player's update patches (in combined encodings, broadcast included).
    var perPlayerPatches: [PlayerID: [StatePatch]] = [:]
    /// Top-level fields the extraction dropped: "broadcast" or a player ID.
    var extractionDrops: [String: [String]] = [:]
    /// Scopes ("broadcast" or a player ID) whose encoding dropped patches: unverifiable.
    var encodeDropScopes: Set<String> = []
    /// Players whose whole view this plan sends (a firstSync, or a full view after a failed
    /// one). Each gets a seed marker instead of a per-player scope in the output; a view that
    /// was not sent at all has no entry.
    var seeds: [PlayerID: SeedDigest] = [:]
    /// Players this plan resyncs in place (#332). Their seeds follow a clear in the stream, as
    /// a reconnect's do: the verifier drops the view it had for them before the output.
    var resyncPlayers: Set<PlayerID> = []
    /// Players every session of which sync lag left out of this plan (pending, newly or still,
    /// or a close due), #572: the plan has no per-player entry for them, so the output lists them
    /// in `perPlayerUnverified` and replay doesn't compare or stage them there.
    var withheldPlayers: Set<PlayerID> = []
    /// Opcode 107: the events the plan consumed, in emit order; nil in the other encodings or
    /// when one of them has no canonical form.
    var events: [CanonicalSyncEvent]?
    /// Opcode 107: the largest keeper sequence among the consumed events that have one.
    var eventsThroughSequence: Int64?
    /// A full plan: it commits the per-player scope of its recipients (`recipients`). False for
    /// a firstSync.
    var commitsPerPlayer = false
    /// The plan reset its recipients' key scopes (`keyScopeResetPending`).
    var resetsKeyScopes = false
    /// A full plan's recipients that have a committed firstSync (not those it sends a full view).
    var recipients: [PlayerID] = []
    /// Recipients whose planned update was not sent at all: their per-player cache was not
    /// committed.
    var uncommitted: Set<PlayerID> = []
    /// A firstSync plan: it records seed markers only, no output.
    var isFirstSync = false

    static let broadcastScope = "broadcast"
    /// The events scope in `encodeDropScopes`: a consumed event without a canonical form.
    static let eventsScope = "events"

    /// A seed's planned view, and what was dropped from the view the client got.
    struct SeedDigest {
        var patches: [StatePatch]
        var drops: Set<ReevaluationRecordedSyncMarker.ViewDrop> = []
        /// The fields whose extraction was dropped from the view (`viewDropFields`).
        var dropFields: [String] = []
    }

    /// A player's encode dropped patches: its scope is unverifiable. With a frame (`committed`)
    /// its seed, if any, was degraded; with none, its per-player cache and firstSync mark were
    /// not committed and nothing reached the client, so it leaves the output and has no seed.
    mutating func noteEncodeDrop(playerID: PlayerID, committed: Bool) {
        encodeDropScopes.insert(playerID.rawValue)
        if committed {
            seeds[playerID]?.drops.insert(.encode)
        } else {
            perPlayerPatches.removeValue(forKey: playerID)
            if seeds.removeValue(forKey: playerID) == nil {
                uncommitted.insert(playerID)
            }
        }
    }

    mutating func noteDrops(_ drops: ExtractionDrops) {
        if !drops.broadcastFields.isEmpty {
            extractionDrops["broadcast", default: []].append(contentsOf: drops.broadcastFields.sorted())
        }
        for (player, fields) in drops.perPlayerFields where !fields.isEmpty {
            extractionDrops[player.rawValue, default: []].append(contentsOf: fields.sorted())
        }
    }
}

/// Where the plan about to run read its state, for the sync output it records.
struct SyncOutputRead {
    let turnKind: ReevaluationRecordedSyncOutput.TurnKind
    /// Nil when the read cannot be located.
    let position: SyncReadPosition?
}
