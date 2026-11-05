# Join as a turn input: firstSync with OnJoin in one turn (#69, with #90 and #92)

Status: plan **rev 2**, not started; decisions recorded (maintainer, 2026-11-05). Base: main d7ea8e3. Rev 1's review found 3 blocking, 7 should and 3 nits; the "Changes from rev 1" section maps each one to where this revision answers it.

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

### 1. Admission: one synchronous segment with the keeper's append (B1)

- The keeper's join keeps its async part (CanJoin, resolvers, kick-old) up to the append of the OnJoin input.
- **In the same synchronous segment as that append** (or, for a join without an OnJoin input, as the `players` insert), the keeper calls the transport's new `admitJoiningSession(...)` (through `assumeIsolated` on the shared executor, as `runSyncPhaseInTurn` does).
- **The adapter records `.joining`** with:
  - session, clientID, playerID, generation;
  - the join input's sequence (or `nil`);
  - the router-built JSON JoinResponse frame and the player slot, allocated in that segment;
  - `transportRegistered = false`.

  A `.joining` session holds its slot but is **not** a sync or event recipient. This replaces the late `initialSyncingPlayers.insert` and closes W1.
- **The keeper doesn't await the turn** on the in-turn path, so tickless lands no longer block inside `keeper.join`. The join's caller awaits `awaitJoined(sessionID)` instead.
- **The `await registerSession` (transport map)** runs after admission and sets `transportRegistered = true`. A session can't flip before that (see the flip conditions).
- **The membership queue** is released before `awaitJoined`. Holding it would serialize joins at about one per tick.

### 2. The flip: only in a turn whose full sync phase commits (B2, S2)

A `.joining` session flips to joined in the output step of the **first turn whose full sync phase commits** after all of these hold:

- its join input's sequence has been applied (or it has none);
- `transportRegistered`;
- its generation is current;
- it is within the turn's flip budget (S6, default 64 per land per turn, configurable).

The condition is "this input's sequence has been applied", not "applied in this turn" (B1). In that commit, the joiner's **firstSync** (end-of-turn state) is planned with the other recipients' diffs, and the joiner's frames go after theirs in the turn's writer element: the **JoinResponse**, then the **firstSync**.

Why the flip waits for a committed sync, not just any turn (B2): after this commit, the shared broadcast cache equals the end-of-turn state, which equals the joiner's firstSync. So the joiner's first diff is computed against the same baseline as everyone else's. A flip at a non-committing turn would leave the joiner's next diff based on an older broadcast cache, and sequences like A→B→A or spawn→despawn between syncs would produce no patch: a stuck value or a ghost entity. Rev 1's "accepted overlap" is withdrawn.

How each kind of land gets that commit:

- **Tick lands**: the next due sync (coincident-sync rule). Join latency is at most one sync interval plus one tick, and the cadence is unchanged.
- **Tickless lands and joins without an OnJoin input**: admission requests a sync-only turn (the existing `runSyncOnlyTurn` path). No extra input or output sequence is created (S3).

How each early return in `runSyncPhaseInTurn` affects the flip (S2):

| Early return | Flip? |
|---|---|
| `!includeSync` | no (not a sync turn) |
| `.deferredBackPressure` | no; the joiner waits for the next commit |
| freeze (`debugDeferSyncIfFrozen`) | no |
| `outboundWriter.isFinished` | no; the joiner's waiter fails (teardown, B3) |
| `membershipCoordinator.isEmpty` | **changed**: the guard counts `.joining` sessions, so the first joiner on an empty land flips |

**Back-pressure** (`hasPendingStateElement`) is writer-wide, so a persistently backlogged writer delays every join. That's bounded by the join timeout (B3). The deferral count is reported (`deferredTurns` on the measure branch), and the 7600X runs check it.

**Events** (the snapshot is the boundary; decision 1 = B):

- Broadcast and targeted events emitted after the join input was applied and before the flip are reflected in the firstSync, and not delivered.
- The joiner isn't a recipient of the flip turn's merged 107 frame. Its first merged frame comes from a later turn, so opcodeMessagePack doesn't re-deliver unstamped broadcast events already in the snapshot.
- **Exception (decision 1 = B)**: events *targeted at the joiner* (its player, session or client) from its OnJoin, or emitted while it is `.joining`, are kept per joining session and enqueued right after its firstSync, in the same writer element, as event frames.

**Encode failure at the flip (S5)**: the JoinResponse is still sent and the joiner flips. Its firstSync goes through the existing `skippedJoiner` path, so it isn't marked as having received its firstSync, and the next full cycle's from-empty path gives it its whole view.

**The recorder (S3)**:

- `planFirstSync` no longer sets `isFirstSync` for the whole plan. A merged plan records the turn as usual, with each joiner's seed (`digest.seeds[playerID]`) as that player's reset point.
- A joiner-only commit (a sync-only turn) records as a sync-only turn with seeds.
- A kick (see §4) records a clear marker for the kicked session's player before the new seed.

### 3. Failure, teardown, timeout and freeze (B3)

- **The router keeps the session binding** (`sessionToBoundLandID`) until `awaitJoined` returns. On failure, it routes the session's disconnect to the adapter as usual, so the normal cleanup runs: membership, slot, transport registration, and `keeper.leave`, which queues OnLeave after OnJoin.
- **`awaitJoined` fails** when:
  - the session's generation ends (a disconnect or a kick while `.joining`);
  - the land is torn down, destroyed or recreated (#116), at which point every waiter fails;
  - it times out (`JOIN_FLIP_TIMEOUT`, default 10 s, read through EnvHelpers).

  On a failure, the router sends a join error and the session cleanup above runs.
- **Freeze**: no sync commits while frozen, so joins admitted before the freeze wait, and the timeout keeps running. A join that times out under freeze is rejected and cleaned up. New admissions during a freeze are allowed (they wait the same way). This is documented on `debugFreeze`.

### 4. Duplicate login: newest wins (#92 option 1; S4)

- **Semantics**: a join of player P while P has sessions = **OnLeave, then OnJoin** (the keeper's kick-old path already does this). The new session is P's only session.
- **The adapter side** runs in the admission segment: every other session of P is marked leaving, stops being a recipient, has its inbound dropped and its close enqueued. Its later disconnect callback finds that it doesn't own P any more, and clears nothing shared (PR 1's check, which this extends with the generation).
- **The keeper-kick → admission gap (S4)**: between the kick's `leave` and the new append, the old session can still send actions as P. The keeper's action and event intake checks the sender's `clientID` against `players[P].clientID`, and rejects a mismatch (logged and counted). This also covers the old session after admission until its close lands.
- **`keeper.leave(playerID:clientID:)` (nit)**: clientIDs are short (6 hex). `leave` and the intake check also compare the session (`lastSessionID`), so two clients with colliding IDs can't remove each other.
- **The legacy path** (`handleJoinRequest`) drops `handleDuplicateLoginIfNeeded`, whose check goes stale across `onDisconnect`, and gets the same admission-segment kick.

### 5. Router handshake (S1)

- After `performJoin` returns (admission done), the router sets a new **`.joinPending`** phase. It accepts the negotiated message encoding (MessagePack included) and forwards to the adapter.
- The adapter **defers inbound messages from `.joining` sessions**, keeping them in order and applying them after the flip; they are dropped if the join fails. A client can't normally send before its JoinResponse, which only goes out at the flip. This covers a client that acts on a late or duplicated JoinResponse.
- After `awaitJoined`, the phase becomes `.joined`.

## Off path (`IN_TURN_SYNC=false`, the kill switch)

It keeps today's structure, plus the parts that don't need a turn:

- `.joining` at admission (W1);
- the disconnect ownership check;
- newest-wins in the admission segment;
- the keeper intake clientID/session check;
- the encode-failure rule: `.joining` is cleared when its firstSync attempt ends, whatever the outcome (S5).

W2–W4 stay as documented limits of the kill-switch path (decision 2).

## #90: broadcast key table for joiners (decision 3 = (ii))

- **(ii)**: after its firstSync and before any 107 frame (both in the flip's writer element), the joiner gets a **broadcast key-table frame** with the **whole current broadcast table** (slot → key, not only the keys present in the state, because a key that was removed and re-added comes back as a bare slot). This needs an encoder "dump without reset" and SDK handling.
- **Version gate**: the client advertises its SDK protocol version in the handshake (join metadata). A client without support gets the (i) behaviour instead: the flip turn resets the broadcast scope for every recipient (existing `keyScopeResetPending` machinery, at most once per turn).
- **Reconnects** take the same path (a reconnect is a join with a new session), so the SDK clearing both maps on reconnect is covered.

## Tests

Interleavings are forced with holds at the awaits (keeper `joinHook`, `inTurnProbeForTesting`, adapter holds), never with timing. The test numbers are referenced in the PR split.

1. **W1**: hold between admission and the flip, and run a tick turn with a due sync. The joiner received nothing. At the flip it receives JoinResponse, then firstSync, then only later diffs, and its view equals the server projection.
2. **W2**: a tick land whose OnJoin adds an entity. The firstSync contains it, and no later diff re-adds it.
3. **W3**: per-player changes by other inputs in the OnJoin turn, in a non-due turn before the flip, and after the flip are all in the joiner's view.
4. **W4 and decision 1**: broadcast events between the join input and the flip don't reach the joiner. Events targeted at it (OnJoin's included) arrive after its firstSync, and events from later turns arrive normally. opcodeJsonArray and opcodeMessagePack (unstamped broadcast events at a non-due flip).
5. **B2 regressions**: A→B→A and spawn→despawn between the OnJoin turn and the flip, and between the flip and the next sync. The joiner's view equals the projection, with no stuck value and no ghost.
6. **B1 hops**, forced holds at:
   - the append → admission callback (a tickless land, whose input turn runs immediately);
   - `registerSession` (the flip waits for `transportRegistered`);
   - `awaitJoined` → router `.joined`.

   No hang, and the frame order holds.
7. **Early returns (S2)**: back-pressure (flip deferred, then done), freeze (deferred, and the timeout rejects with cleanup), the first joiner on an empty land (flips), and `!includeSync` turns (no flip).
8. **B3 failures**: a disconnect while `.joining`, a kick while `.joining`, destroy/recreate while `.joining`, and a timeout. Each one: the waiter fails, the router sends a join error, and the slot, membership, transport registration and `keeper.players[P]` are cleaned up, with OnLeave after OnJoin.
9. **Old session's disconnect (#92 comment 1)**: covered by PR 1's tests, extended with the generation.
10. **Newest wins (#92)**: router and legacy. Two joins of P, the first held before admission. Afterwards exactly one joined session, the old one closed, the old session's action in the kick → admission gap rejected, and the kick's clear marker recorded.
11. **Flip budget (S6)**: 200 joins on one land flip over ceil(200/64) commits, all succeed, and none hits the timeout.
12. **Encode failure at the flip (S5)**, on and off: the JoinResponse is sent, the from-empty repair follows, and `.joining` is never stuck.
13. **Handshake (S1)**: a MessagePack action arriving right after the JoinResponse is applied, in order. One arriving while `.joining` is applied after the flip.
14. **Recorder (S3)**: a merged plan with a joiner records the turn plus the joiner's seed. A joiner-only commit records a sync-only turn. Replay of a recorded run with late joins has 0 mismatches.
15. **#90**: the issue's reproduction (opcodeMessagePack plus path hashes, a broadcast `[String: T]`, a key removed and re-added) for the late joiner and for a reconnect. SDK runtime test with the captured frames, plus the old-SDK fallback.
16. **Off path**: tests 1, 9, 10 and 12 with `IN_TURN_SYNC=false`.
17. **E2E** (`Tools/CLI/scenarios/`): a late joiner after monsters spawned, a reconnect, and two clients with one playerID, under messagepack with gating `assertConverged`, on both CI matrix legs.

## PR split (order changed: duplicate login before the turn work)

1. **Disconnect ownership** (Refs #92): clear per-player state only for the player's last session, checked after the `keeper.leave` await. In review as its own PR now.
2. **`.joining` at admission** (Refs #69): on both paths, with the admission-in-the-append-segment callback (B1). Tests 1 (on and off) and 6 (first two hops).
3. **Newest wins** (Closes #92): the admission-segment kick for router and legacy, the keeper intake clientID/session check, and the `leave` session check. Tests 10 and 16 (part).
4. **Join as a turn input** (Closes #69):
   - the flip at committed sync, flip conditions and budget, `awaitJoined`, failures and timeout, freeze;
   - the router `.joinPending` phase, adapter inbound deferral, the recorder changes, and the targeted-event exception.

   Tests 2–8 and 11–14. It gets a design check before review and 7600X runs before merge (below).
5. **Broadcast key table for joiners** (Closes #90): the encoder dump, frame kind, SDK and version gate. Test 15 and the E2E.

**Before PR 4 merges** (7600X):
- json50 and ramp runs with zero join failures under the new ws-loadtest checks;
- turn p99, `deferredTurns` and join latency (JoinResponse arrival − connect) against the current baseline, from the measure branch.

## Changes from rev 1

| Review item | Answered in |
|---|---|
| B1 the flip can miss `.joining` | §1 (admission in the append segment, no turn await in `keeper.join`), §2 (flip on "sequence applied" + `transportRegistered`), test 6 |
| B2 overlap loses updates | §2 (flip only at a committed sync; overlap withdrawn), tests 4 and 5 |
| B3 post-admission failure leaks | §3, test 8 |
| S1 handshake race | §5, test 13 |
| S2 early returns, empty land, back-pressure | §2 table, test 7 |
| S3 recorder | §2 recorder, test 14; no extra input or output sequence for joins without OnJoin |
| S4 reconnect semantics, kick → admission gap | §4, test 10 |
| S5 encode failure | §2 and the off path, test 12 |
| S6 flip budget | §2, test 11 |
| S7 forced-hold tests, A→B→A, spawn/despawn, MessagePack events | tests 4–8 |
| Nit: version gate | #90 section |
| Nit: duplicate login before the turn work | PR split (3 before 4) |
| Nit: `leave` clientID collisions | §4 |

## Decisions (maintainer, 2026-11-05)

1. **An OnJoin event targeted at the joiner: B.** It is delivered right after the firstSync, never dropped. The same holds for other events targeted at the joiner while it is `.joining`.
2. **Off path:** only the admission fix (`.joining`, the generation check, the newest-wins kick). W2–W4 stay documented limits.
3. **#90: option (ii).** A joiner-only key-table frame (a new frame kind plus TS SDK support), gated on an SDK version in the handshake. A client below that version falls back to the per-turn broadcast-scope reset (i).
4. **#92: one session per player, newest wins.** For the game this is OnLeave, then OnJoin.
