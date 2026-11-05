# Join as a turn input: firstSync with OnJoin in one turn (#69, with #90 and #92)

Status: plan **rev 3**, not started; decisions recorded (maintainer, 2026-11-05). Base: main 1d5e861.

History:
- Rev 1's review found 3 blocking, 7 should and 3 nits; rev 2 answered them.
- Rev 2's check closed B2 and S5, partly closed the rest, and found 3 new blocking items (N1–N3), 6 shoulds and 2 nits. None of them changes the design.
- "Changes in rev 3" maps each item to its answer.

## Problem

A join today is several actor segments with awaits between them. Router path (`LandRouter` → `TransportAdapter.performJoin`, inside the membership queue):

1. `await keeper.join(...)`:
   - CanJoin (and its resolvers), the max-players check, and "kick old" (`await leave`, which runs OnLeave);
   - `players[playerID] = …`, then OnJoin is queued as a lifecycle `PendingItem`;
   - a land with a tick handler returns at once (OnJoin runs in a later tick turn). A tickless in-turn land awaits its input turn (`awaitInputTurn`) before returning.
2. `membershipCoordinator.registerPlayer`, slot allocation, `await registerSession` (WebSocketTransport actor).
3. Back in the router:
   - `await sendJoinResponse` (JSON handshake encoding), then `sessionHandshakePhase = .joined`;
   - `await syncStateForNewPlayer`: inserts into `initialSyncingPlayers`, reads `await keeper.currentStateLocated()`, then plans and commits the firstSync.

Windows:

- **W1 (#69)**: from step 2 to the insert in step 3, the player is a recipient and not initial-syncing, so it gets a diff before its JoinResponse and firstSync.
- **W2**: on tick lands, the firstSync read can come before the joiner's own OnJoin.
- **W3 (#69 comment 1)**: a full cycle while the joiner is skipped clears dirty flags, so a per-player change can be lost for it.
- **W4 (#69 comment 2)**: events emitted while the joiner is initial-syncing are skipped for it, then removed.

#90 (late joiners can't decode merged 107 frames) and #92 (two sessions of one player; the router never kicks the old one; the old session's disconnect wipes the new one's per-player state) share the root: per-player and per-session state changed across awaits, with no single point where a session becomes a recipient.

## Target shape (in-turn sync on)

### 1. Admission (B1, N1)

**Two admission points, chosen per adapter.**

- **The in-turn path** (`transport.runsSyncPhaseInTurn(of: keeper)` is true, so the adapter shares the keeper's executor):
  - the keeper's join keeps its async part (CanJoin, resolvers, kick-old) up to the append of the OnJoin input;
  - **in the same synchronous segment as that append** (or, for a join without an OnJoin input, as the `players` insert), the keeper calls the new `LandKeeperTransport.admitJoiningSession(...)` through `assumeIsolated`, as `runSyncPhaseInTurn` does.
- **The off path** (the kill switch, and every reevaluation/replay adapter, which `LandManager` builds with `inTurnSync && !isReevaluationKeeper`):
  - the adapter has its own executor (`ownExecutorHost`), so `assumeIsolated` from the keeper would trap. The keeper never calls the callback here; it is gated on `runsSyncPhaseInTurn(of:)`;
  - the adapter admits right after `keeper.join` returns, inside the membership queue, before any other await (rev 1's shape).
- `admitJoiningSession` defaults to a no-op in the protocol extension, so other and mock transports are unaffected.

**What admission records.** The adapter records the session as `.joining` with:
- session, clientID, playerID, generation;
- the join input's sequence (or `nil`);
- the router-built JSON JoinResponse frame and the player slot, allocated in that segment;
- `transportRegistered = false`.

A `.joining` session holds its slot but is **not** a sync or event recipient. This replaces the late `initialSyncingPlayers.insert` and closes W1.

**The keeper doesn't await the turn for adapter-originated joins (S4).** `keeper.join` gets a parameter (`awaitTurn: Bool`, default `true`):
- the adapter passes `false` on the in-turn path, so tickless lands no longer block inside `keeper.join`, and the caller awaits `awaitJoined(sessionID)` instead;
- direct callers (tests, `E2EStateSnapshotDiffTests`, `ReevaluationRunner`) keep today's behaviour: after `join` returns, OnJoin has run.

**After admission.**
- `await registerSession` (the transport map) runs after admission and sets `transportRegistered = true`. A session can't flip before that (see the flip conditions).
- The membership queue is released before `awaitJoined`. Holding it would serialize joins at about one per tick.

### 2. The flip: only in a turn whose full sync phase commits (B2, S2, N2)

**Flip conditions.** A `.joining` session flips to joined in the output step of the **first turn whose full sync phase commits** after all of these hold:
- its join input's sequence has been **consumed**: applied, or failed because OnJoin threw (or it has none);
- `transportRegistered`;
- its generation is current;
- it is within the turn's flip budget (S6: default 64 per land per turn, configurable). Eligible joiners are picked in FIFO admission order.

**OnJoin throws.** If the join input's OnJoin throws, the waiter fails at once with `onJoinFailed`, and the session is cleaned up (§3). It doesn't flip.

**What the flip commit carries.** The joiner's **firstSync** (end-of-turn state) is planned with the other recipients' diffs. The joiner's frames go after theirs, in the turn's writer element: the **JoinResponse**, then the **firstSync**, then (decision 1) its targeted events, then (decision 3) the key-table frame.

**Why only a committed sync (B2).** After that commit, the shared broadcast cache equals the end-of-turn state, which equals the joiner's firstSync. So the joiner's first diff has the same baseline as everyone else's. A flip at a non-committing turn would leave the joiner's next diff based on an older broadcast cache, and sequences like A→B→A or spawn→despawn between syncs would produce no patch: a stuck value or a ghost entity. Rev 1's "accepted overlap" is withdrawn.

**Getting the commit (N2).**
- **Tick lands**: the next due sync (coincident-sync rule). Join latency is at most one sync interval plus one tick, and the cadence is unchanged.
- **Tickless lands, joins without an OnJoin input, and joiners left over a full flip budget**: the commit comes from a sync-only turn (the existing `runSyncOnlyTurn` path), requested by the turn **that consumes the join's sequence**, not by admission. So the sync-only turn always runs after the input turn. Rev 2's admission-time request could run first, see OnJoin not yet applied, not flip, and leave the join waiting for the timeout. The request repeats while eligible joiners remain:
  - a flip commit that leaves eligible joiners (budget) requests the next sync-only turn;
  - a join with no OnJoin input requests it from the admission segment, since there's no input to consume. Its eligibility then needs only `transportRegistered`, and a flip deferred for that is re-requested by `registerSession`.
- No extra input or output sequence is created (S3).

**Early returns in `runSyncPhaseInTurn` (S2).**

| Early return | Flip? |
|---|---|
| `!includeSync` | no (not a sync turn) |
| `.deferredBackPressure` | no; the joiner waits for the next commit (re-requested on tickless lands) |
| freeze (`debugDeferSyncIfFrozen`) | no |
| `outboundWriter.isFinished` | no; the joiner's waiter fails (teardown, §3) |
| no joined members | **flip-only commit**: the shared `membershipCoordinator.isEmpty` guard is unchanged (it also gates freeze `hasMembers` and the key-reset path), and a separate predicate `hasEligibleJoiners` lets the turn run a commit for joiners alone, so the first joiner on an empty land flips |

**Back-pressure.** `hasPendingStateElement` is writer-wide, so a backlogged writer delays every join. Over the join timeout (10 s), every pending join is rejected. That's acceptable. The rejection reason (`timeout`, with `deferredBackPressure` as the last deferral cause) is logged and counted, and a test covers it. The deferral count is reported (`deferredTurns` on the measure branch), and the 7600X runs check it.

**Events** (the snapshot is the boundary; decision 1 = B):
- Broadcast events emitted after the join input was consumed and before the flip are reflected in the firstSync, and not delivered.
- The joiner isn't a recipient of the flip turn's merged 107 frame. Its first merged frame comes from a later turn, so opcodeMessagePack doesn't re-deliver unstamped broadcast events already in the snapshot.
- **Exception (decision 1 = B)**: events *targeted at the joiner* (its player, session or client) from its OnJoin, or emitted while it is `.joining`, are kept per joining session and enqueued right after its firstSync, in the same writer element, as event frames. They are never dropped while the join succeeds.

**Encode failure at the flip (S5).** The JoinResponse is still sent and the joiner flips. Its firstSync goes through the existing `skippedJoiner` path, so it isn't marked as having received its firstSync, and the next full cycle's from-empty path gives it its whole view.

**The recorder (S3).**
- `planFirstSync` no longer sets `isFirstSync` for the whole plan. A merged plan records the turn as usual, with each joiner's seed (`digest.seeds[playerID]`) as that player's reset point.
- A joiner-only commit (a sync-only turn, or the empty-land flip-only commit) records as a sync-only turn with seeds.
- A kick (see §4) records a clear marker for the kicked session's player before the new seed.

### 3. Failure, teardown, timeout and freeze (B3)

**The router keeps the session binding** (`sessionToBoundLandID`) until `awaitJoined` returns. On failure, it routes the session's cleanup to the adapter as usual: membership, slot, transport registration, and `keeper.leave`, which queues OnLeave after OnJoin.

**`awaitJoined` fails with a reason**:
- `superseded`: a newer session of the same player was admitted (the kick, §4);
- `disconnected`: the session's generation ended because the client disconnected;
- `landClosed`: the land was torn down, destroyed or recreated (#116), and every waiter fails;
- `onJoinFailed`: OnJoin threw (§2);
- `inboundOverflow`: see §5;
- `timeout`: after `JOIN_FLIP_TIMEOUT` (default 10 s, read through EnvHelpers).

**What a failure does.**
- On `timeout`, `onJoinFailed` and `inboundOverflow`, the router sends a join error and **closes the session**.
- On `superseded` and `disconnected`, the session is already closing.
- **Cleanup is idempotent per generation.** The first cleanup for (session, generation) runs it. A later disconnect callback, or a timeout firing after a kick, finds the generation already cleaned and does nothing. So there's no double `keeper.leave`. A retry on a new connection is a new session, and doesn't get `joinAlreadyJoined`, because the old session's `players[P]` entry was removed by that one cleanup.

**Freeze.**
- No sync commits while frozen, so joins admitted before the freeze wait, and the timeout keeps running. A join that times out under freeze is rejected and cleaned up.
- New admissions during a freeze are allowed, and wait the same way.
- Pending `.joining` sessions don't block the freeze settle: the settle waits for in-flight turns, and a `.joining` session's input is an ordinary input that its turn consumes before the settle completes. The flip waits for the unfreeze.
- This is documented on `debugFreeze`.

### 4. Duplicate login: newest wins (#92 option 1; S4)

- **Semantics**: a join of player P while P has sessions = **OnLeave, then OnJoin** (the keeper's kick-old path already does this). The new session is P's only session.
- **The adapter side** runs in the admission segment:
  - every other session of P is marked leaving, stops being a recipient, has its inbound dropped and its close enqueued;
  - a session of P that is still `.joining` has its waiter failed with `superseded`;
  - an old session's later disconnect callback finds that it doesn't own P any more, and clears nothing shared (PR 1's check, extended with the generation).
- **The keeper-kick → admission gap.** Between the kick's `leave` and the new append, the old session can still send actions as P. The keeper's action and event intake rejects a sender only when **`players[P]` exists and its `clientID` or session differs from the sender's**. Rejections are logged and counted. The rest of the rules:
  - **`players[P]` absent**: unchanged from today (the intake has no member to compare with, and the existing not-joined handling applies), so direct callers that send before or without a join keep working;
  - **exempt**: the system player/client IDs and any keeper not in `.live` mode (reevaluation and replay feed recorded inputs);
  - **unaffected**: direct callers that join and then send with the same clientID, such as the 18 test files using that pattern, `E2EStateSnapshotDiffTests`, and `ReevaluationRunner`'s join then `handleClientEvent`.
- **`keeper.leave(playerID:clientID:)` (nit)**: clientIDs are short (6 hex). `leave` and the intake check also compare the session (`lastSessionID`) when one is recorded, so two clients with colliding IDs can't remove each other.
- **The legacy path** (`handleJoinRequest`) drops `handleDuplicateLoginIfNeeded`, whose check goes stale across `onDisconnect`, and gets the same admission-segment kick.

### 5. Router handshake (S1)

- After `performJoin` returns (admission done), the router sets a new **`.joinPending`** phase. It accepts the negotiated message encoding (MessagePack included) and forwards to the adapter.
- The adapter **defers inbound messages from `.joining` sessions**, keeping them in order and applying them after the flip; they are dropped if the join fails.
  - A client can't normally send before its JoinResponse, which only goes out at the flip. This covers a client that acts on a late or duplicated JoinResponse.
  - **The deferred queue is bounded**: per session, 256 messages and 256 KiB by default (configurable). An overflow fails the join with `inboundOverflow` and closes the session.
- After `awaitJoined`, the phase becomes `.joined`.

## Off path (`IN_TURN_SYNC=false`, the kill switch, and reevaluation/replay adapters)

It keeps today's structure, plus the parts that don't need a turn (decision 2):
- `.joining` at admission, right after `keeper.join` returns (§1, N1);
- the disconnect ownership check, with the generation;
- newest-wins in the admission segment, and the keeper intake rule (§4);
- idempotent cleanup per generation;
- the encode-failure rule: `.joining` is cleared when its firstSync attempt ends, whatever the outcome (S5).

W2–W4 stay as documented limits of this path.

## #90: broadcast key table for joiners (decision 3 = (ii))

- **(ii)**: after its firstSync and before any 107 frame (both in the flip's writer element), the joiner gets a **broadcast key-table frame** with the **whole current broadcast table**: slot → key, not only the keys present in the state, because a key that was removed and re-added comes back as a bare slot.
  - The dump is taken **after the flip turn's 107 is encoded**, so keys first assigned in that turn are included.
  - This needs an encoder "dump without reset", a new frame kind, and TS SDK handling.
- **Version gate**: the client advertises its SDK protocol version in the handshake (join metadata). For a client below that version, the server applies the fallback below:
  - **(i) delayed reset (N3), the default**: set `keyScopeResetPending` for **the first commit after the flip**, which is that joiner's first 107. Setting it in the flip turn (rev 2) would not fix #90, because the joiner isn't a recipient of that turn's 107, so its first 107 would come a turn later with bare slots. The cost: every client's broadcast table is renumbered on that commit, so each broadcast key is re-sent with its full name once, for every client and per old-SDK join (one turn's worth of full-key encoding, about the size of a firstSync's key names, per recipient).
  - It keeps old SDKs working, and the cost only applies to old-SDK joins. PR 5 may revisit it if the cost shows up in runs; the alternative is to **reject** an old SDK's join when the broadcast table isn't empty, with a version error, at no cost to other clients.
- **Reconnects** take the same path (a reconnect is a join with a new session), so the SDK clearing both maps on reconnect is covered.

## Tests

Interleavings are forced with holds at the awaits (keeper `joinHook`/`leaveHook`, `inTurnProbeForTesting`, adapter holds), never with timing. The test numbers are referenced in the PR split.

1. **W1**: hold between admission and the flip, and run a tick turn with a due sync. The joiner received nothing. At the flip it receives JoinResponse, then firstSync, then only later diffs, and its view equals the server projection.
2. **W2**: a tick land whose OnJoin adds an entity. The firstSync contains it, and no later diff re-adds it.
3. **W3**: per-player changes by other inputs in the OnJoin turn, in a non-due turn before the flip, and after the flip are all in the joiner's view.
4. **W4 and decision 1**: broadcast events between the join input and the flip don't reach the joiner. Events targeted at it (OnJoin's included) arrive after its firstSync, and events from later turns arrive normally. opcodeJsonArray and opcodeMessagePack (unstamped broadcast events at a non-due flip).
5. **B2 regressions**: A→B→A and spawn→despawn between the OnJoin turn and the flip, and between the flip and the next sync. The joiner's view equals the projection, with no stuck value and no ghost.
6. **B1 hops**, forced holds at:
   - the append → admission callback (a tickless land, whose input turn runs immediately);
   - `registerSession` (the flip waits for `transportRegistered`, then is re-requested);
   - `awaitJoined` → router `.joined`.

   No hang, and the frame order holds.
7. **Early returns (S2)**:
   - back-pressure: the flip is deferred, then done;
   - back-pressure past the timeout: every pending join is rejected with `timeout`, the logged cause is `deferredBackPressure`, and cleanup runs;
   - freeze: the flip is deferred, the timeout rejects with cleanup, and the freeze settle isn't blocked by `.joining` sessions;
   - the first joiner on an empty land flips, while freeze `hasMembers` and the key-reset path still see an empty land;
   - `!includeSync` turns don't flip.
8. **B3 failures**: a disconnect while `.joining` (`disconnected`), a kick while `.joining` (`superseded`), destroy/recreate while `.joining` (`landClosed`), a timeout (`timeout`, and the session is closed), and OnJoin throwing (`onJoinFailed`, failed at once, not at the timeout).
   - Each one: the waiter fails with that reason, the router sends a join error where §3 says so, and the slot, membership, transport registration and `keeper.players[P]` are cleaned up exactly once, with OnLeave after OnJoin.
   - A retry on a new connection then joins normally.
9. **Old session's disconnect (#92 comment 1)**: covered by PR 1's tests (including the hold at `keeper.leave`), extended with the generation.
10. **Newest wins (#92)**: router and legacy. Two joins of P, the first held before admission.
    - Afterwards there is exactly one joined session, and the old one is closed.
    - The old session's action in the kick → admission gap is rejected.
    - The kick's clear marker is recorded.
    - Direct-caller intake (join then send with the same clientID, P absent, a system ID, a replay keeper) is unchanged.
11. **Flip budget (S6, N2)**: 200 joins on one tick land flip over ceil(200/64) commits in FIFO admission order, all succeed, and none hits the timeout. The same on a **tickless land with no further inputs**: the leftovers flip through re-requested sync-only turns.
12. **Encode failure at the flip (S5)**, on and off: the JoinResponse is sent, the from-empty repair follows, and `.joining` is never stuck.
13. **Handshake (S1)**:
    - a MessagePack action arriving right after the JoinResponse is applied, in order;
    - one arriving while `.joining` is applied after the flip;
    - overflowing the deferred queue (count, then bytes) fails the join with `inboundOverflow` and closes the session.
14. **Recorder (S3)**: a merged plan with a joiner records the turn plus the joiner's seed. A joiner-only commit records a sync-only turn. Replay of a recorded run with late joins has 0 mismatches.
15. **#90**: the issue's reproduction (opcodeMessagePack plus path hashes, a broadcast `[String: T]`, a key removed and re-added) for the late joiner and for a reconnect.
    - The key-table dump includes a key first assigned in the flip turn.
    - SDK runtime test with the captured frames.
    - The old-SDK fallback: the joiner's first 107 decodes.
16. **Off path**: tests 1, 9, 10 and 12 with `IN_TURN_SYNC=false`, plus **a replay-viewer join on a reevaluation land** (no trap, admitted after `keeper.join` returns).
17. **N2 ordering**: a tickless land where the join's input turn and a pending sync-only turn are both queued, in each order. The join flips in the first commit after its sequence is consumed, well before the timeout.
18. **E2E** (`Tools/CLI/scenarios/`): a late joiner after monsters spawned, a reconnect, and two clients with one playerID, under messagepack with gating `assertConverged`, on both CI matrix legs.

## PR split (duplicate login before the turn work)

1. **Disconnect ownership** (Refs #92): clear per-player state only for the player's last session, checked after the `keeper.leave` await. In review as its own PR now.
2. **`.joining` at admission** (Refs #69), on both paths:
   - the in-turn append-segment callback, gated on `runsSyncPhaseInTurn(of:)`;
   - the off-path admission after `keeper.join`;
   - the `awaitTurn` parameter.

   Tests 1 (on and off), 6 (first two hops), and 16 (the replay-viewer join).
3. **Newest wins** (Closes #92): the admission-segment kick for router and legacy, the keeper intake rule (§4), the `leave` session check, and idempotent cleanup per generation. Tests 10 and 16 (part).
4. **Join as a turn input** (Closes #69):
   - the flip at a committed sync, the flip conditions, budget, and N2's request rules;
   - `awaitJoined`, failure reasons and timeout, and freeze;
   - the router `.joinPending` phase, adapter inbound deferral and its cap;
   - the recorder changes, and the targeted-event exception.

   Tests 2–8, 11–14 and 17. It gets a design check before review and 7600X runs before merge (below).
5. **Broadcast key table for joiners** (Closes #90): the encoder dump, the frame kind, the SDK, the version gate and the fallback. Test 15 and the E2E.

**Before PR 4 merges** (7600X):
- json50 and ramp runs with zero join failures under the new ws-loadtest checks;
- turn p99, `deferredTurns` and join latency (JoinResponse arrival − connect) against the current baseline, from the measure branch.

## Changes in rev 3 (from rev 2's check)

| Item | Answered in |
|---|---|
| N1 admission callback traps off path / replay | §1 (two admission points, gated on `runsSyncPhaseInTurn(of:)`, protocol default no-op), off path, test 16 |
| N2 tickless join can wait for the timeout | §2 (the sync-only turn is requested by the turn that consumes the sequence, repeated while eligible joiners remain; "consumed" flip condition; OnJoin throw fails at once), tests 8, 11 and 17 |
| N3 the (i) fallback doesn't fix #90 | #90 (default: reset on the commit after the flip, the joiner's first 107; cost stated; reject as the alternative), test 15 |
| S4 intake check breaks direct callers | §4 (reject only on a differing `players[P]`; absent P, system IDs and non-live keepers exempt), §1 (`awaitTurn` parameter), test 10 |
| Unbounded deferred inbound queue | §5 (256 messages / 256 KiB, `inboundOverflow`), test 13 |
| Timeout path | §3 (close on timeout, idempotent cleanup per generation, retry works), test 8 |
| Back-pressure over 10 s; freeze settle | §2 back-pressure, §3 freeze, test 7 |
| Flip budget FIFO; tickless leftovers | §2, test 11 |
| Don't count `.joining` in `isEmpty` | §2 table (`hasEligibleJoiners`, flip-only commit), test 7 |
| Nit: key-table dump after the flip turn's 107 | #90, test 15 |
| Nit: a kick fails with `superseded` | §3 and §4, test 8 |

## Changes in rev 2 (from rev 1's review)

| Review item | Answered in |
|---|---|
| B1 the flip can miss `.joining` | §1, §2 flip conditions, test 6 |
| B2 overlap loses updates | §2 (flip only at a committed sync; overlap withdrawn), tests 4 and 5 |
| B3 post-admission failure leaks | §3, test 8 |
| S1 handshake race | §5, test 13 |
| S2 early returns, empty land, back-pressure | §2 table, test 7 |
| S3 recorder | §2 recorder, test 14 |
| S4 reconnect semantics, kick → admission gap | §4, test 10 |
| S5 encode failure | §2 and the off path, test 12 |
| S6 flip budget | §2, test 11 |
| S7 forced-hold tests, A→B→A, spawn/despawn, MessagePack events | tests 4–8 |
| Nits: version gate, duplicate login before the turn work, `leave` clientID collisions | #90, PR split, §4 |

## Decisions (maintainer, 2026-11-05)

1. **An OnJoin event targeted at the joiner: B.** It is delivered right after the firstSync, never dropped. The same holds for other events targeted at the joiner while it is `.joining`.
2. **Off path:** only the admission fix (`.joining`, the generation check, the newest-wins kick). W2–W4 stay documented limits.
3. **#90: option (ii).** A joiner-only key-table frame (a new frame kind plus TS SDK support), gated on an SDK version in the handshake. A client below that version gets the delayed reset on its first 107 (the default, with the stated cost; PR 5 may revisit it).
4. **#92: one session per player, newest wins.** For the game this is OnLeave, then OnJoin.
