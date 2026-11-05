# Join as a turn input: firstSync with OnJoin in one turn (#69, with #90 and #92)

Status: plan, not started. Base: main f05d7ea.

## Problem

A join today is several actor segments with awaits between them. Router path (`LandRouter` → `TransportAdapter.performJoin`, inside the membership queue):

1. `await keeper.join(...)`: CanJoin (and its resolvers), the max-players check, "kick old" (`await leave`), `players[playerID] = …`, then OnJoin is **queued** as a lifecycle `PendingItem`. A land with a tick handler returns at once; OnJoin runs in a later tick turn. A tickless land waits for its input turn.
2. `membershipCoordinator.registerPlayer`, slot allocation, `await registerSession` (WebSocketTransport actor).
3. Back in the router: `await sendJoinResponse` (JSON handshake encoding), `sessionHandshakePhase = .joined`, then `await syncStateForNewPlayer`, which inserts the player into `initialSyncingPlayers`, reads `await keeper.currentStateLocated()`, then plans and commits the firstSync.

That gives four windows:

- **W1 (#69)**: from step 2 to the insert in step 3, the player is a joined recipient and not initial-syncing, so a sync phase sends its session a diff before its `JoinResponse` and firstSync.
- **W2**: with a tick handler, the firstSync's state read can come before the joiner's own OnJoin has run. Its OnJoin effects then arrive as a later diff, or (with W3) not at all.
- **W3 (#69 comment 1)**: a full cycle while the joiner is skipped clears dirty flags, so a per-player change made in that window can be lost for the joiner.
- **W4 (#69 comment 2)**: events emitted while the joiner is initial-syncing are skipped for it and then removed at the end of the cycle, although they come after its snapshot point.

#90 (late joiners can't decode merged 107 frames) and #92 (two sessions of one player share key tables and caches; the router never kicks the old session; the old session's disconnect wipes the new one's per-player state) have the same root: per-player and per-session state that the join and disconnect paths change across awaits, with no single point where a session becomes a recipient.

## Target shape (in-turn sync on)

A join is admitted in one synchronous segment and becomes a recipient in one keeper turn.

**Admission** (membership queue, one synchronous segment after the keeper's checks):

- The keeper's part stays where it is: CanJoin, resolvers, max players and the `players` insert. OnJoin is queued as a lifecycle input, as now.
- The adapter registers the session as **`.joining(generation)`** in the membership coordinator: it holds its player slot and its transport registration, but it is **not** a sync or event recipient. This replaces the later `initialSyncingPlayers.insert` and closes W1 on both paths (on and off).
- Duplicate login (#92, option 1): in the same segment, every other session of the player is marked leaving: it is removed as a recipient, and its close is enqueued. Its later disconnect callback finds that it no longer owns the player (generation check, below) and clears nothing shared.
- The membership queue is released **before** waiting for the turn. Holding it would serialize joins at one per tick, about 20 joins/s per land at 50 ms ticks, which breaks the connect ramps.

**The join turn**: the turn that applies the join's lifecycle input. That is the next tick turn for a land with a tick handler, or an input turn right away for a tickless land.

- **Joins without an OnJoin input** (reconnects, a second session, reevaluation observers, lands without OnJoin) still need a turn for the atomic flip. They get a "join-sync" input that changes no state, so it can run as an immediate sync-only-style turn without waiting for a tick. Replay determinism is unaffected, because nothing in the state changes.
- **Inputs first**: the turn applies its inputs (OnJoin among them), then the tick handler, as now.
- **The flip**: in the turn's output step (`runTurnOutputs`, the same synchronous segment as the sync phase), each `.joining` session whose input was applied, and whose generation is still current, flips to joined. It gets its frames in the turn's writer element, after the other recipients' frames: first the **JoinResponse**, then the **firstSync** of the end-of-turn state.
  - **The JoinResponse** is built by the router (it stays a JSON handshake frame, and the router knows landType, instanceId and encoding). It is handed to the adapter with the join and enqueued by the turn.
  - **The firstSync** is planned in that segment. When this turn's sync phase is due, the firstSync goes in the same plan and commit as the other recipients' diffs. When it isn't due, the plan has only the joiners' firstSyncs and leaves everyone else's cadence alone.
- **Snapshot point = end of the join turn.** This is the boundary #69 comment 2 asks for:
  - events emitted in the join turn, OnJoin's included, are reflected in the firstSync and not delivered to the joiner;
  - events from the next turn on reach it.
  - **Decision for Main**: an OnJoin event targeted at the joiner itself (a "welcome" event) is dropped by this rule. Option B delivers events *targeted at the joiner* from its join turn as separate event frames after its firstSync. Recommendation: A (the rule as stated) now, and B as a follow-up if a game needs it.
- **Router and legacy join paths** both call `performJoin(…, joinResponse:)`. It returns after admission (slot known), and a second call, `awaitJoined(sessionID)`, resolves when the flip has happened (or fails if the session ended first). The router sets `.joined` in its handshake as before, but no longer calls `sendJoinResponse`/`syncStateForNewPlayer` itself on the in-turn path.

What this removes on the in-turn path:

- **W1**: there is no recipient before the flip.
- **W2**: the firstSync reads the state after OnJoin, in the same segment.
- **W3**: the joiner's cache is staged from the snapshot of the segment that commits it, and no cycle runs between the read and the commit.
- **W4**: the boundary is the snapshot point.

`initialSyncingPlayers` is no longer used on that path.

**One accepted overlap**: after a firstSync taken at a turn whose sync wasn't due, the next cycle's broadcast diff (computed from the shared broadcast cache) can repeat changes the joiner already has. Patches are absolute (`set`/`remove` by path), and today's firstSync already relies on this, so I'll keep it and test it.

**Leave and disconnect**: a disconnect before the flip enqueues the leave lifecycle input after the join input (same input order), and the turn skips the flip for an ended generation. `handleDisconnectQueued` clears per-player state (sync cache, firstSync mark, slot) only when the disconnecting session still owns the player (generation check). This is #92 comment 1, and it is needed on both paths.

## Off path (`IN_TURN_SYNC=false`, the kill switch)

It keeps today's structure, plus the parts that don't need a turn:

- `.joining` at admission (W1);
- the disconnect generation check;
- the duplicate-login kick in the admission segment (#92 on the router path, and the legacy race in #92 comment 2: check and kick under the membership queue, all sessions of the player).

W2–W4 stay as known limits of the kill-switch path and are documented in code.

**Decision for Main**: is parity on the off path required before reruns? Recommendation: no, since reruns use in-turn sync. The off path only has to stay correct for what it promised before.

## #90: broadcast key table for joiners

The join turn gives a place where no 107 frame can come between the joiner's firstSync and its first broadcast frame, but the key table still has to reach the joiner. There are two options, and the choice is **Main's decision**:

- **(i) Broadcast-scope reset per join turn.** It reuses the existing reset mechanism (`keyScopeResetPending`, firstSync-typed updates): in a turn that flips a joiner, every recipient's broadcast scope is reset and redefined, at most once per turn.
  - Pros: no protocol or SDK change, and the code path is already tested.
  - Cost: definitions for every broadcast key go to every client on every turn that admits a joiner (ramps: up to 20 resets/s). Slots are renumbered for everyone, which goes against #90's "Expected" line; that line would need amending.
- **(ii) A key-table frame for the joiner only.** After its firstSync and before any 107, the joiner gets a "define broadcast slots" frame holding the current broadcast table (slot → key; the whole table, not only keys present in the state, because a removed and re-added key comes back as a bare slot).
  - Needs: a new frame kind, an encoder "dump without reset" and SDK handling.
  - Pros: no cost to other clients and no renumbering.

**Recommendation: (ii).** Its cost doesn't scale with joins × clients, and the ramp is exactly when we measure. It's a protocol change, so it gets its own PR and an SDK version note.

Reconnects take the same path (a reconnect is a join with a new session), so the SDK clearing both maps on reconnect is covered.

## #92: duplicate login and per-player state

- **Option 1** (one session per player; the newest wins) falls out of the admission segment above. It also removes these #92 symptoms:
  - (a) and (b): shared per-player key tables;
  - the shared diff cache;
  - the per-player firstSync mark;
  - the wiped state on the old session's disconnect, which is the generation check.
- **Option 2** (multi-session, `.perSession` scopes and caches) is not planned. It would be needed for multi-device play.

## Tests

All tests force the interleaving with holds at the awaits (the keeper's `joinHook`, `inTurnProbeForTesting` and adapter holds), not with timing.

1. **No frame before firstSync (W1)**: hold a join between admission and its turn, and run a tick turn with a due sync. The joiner's session has received nothing. In its join turn it receives JoinResponse, then firstSync, then only later diffs. Its final view equals the server projection.
2. **OnJoin in the firstSync (W2)**: a tick land whose OnJoin adds a player entity. The firstSync contains it, and no later diff re-adds it as new.
3. **No lost per-player change (W3)**: a per-player change by another input in the join turn, and one in the next turn. Both are in the joiner's view, and none is lost to dirty-flag clearing.
4. **Event boundary (W4)**: events emitted in the join turn don't reach the joiner (their effects are in its firstSync), and events from the next turn do. Shown for opcodeJsonArray and opcodeMessagePack, broadcast and targeted.
5. **Disconnect before the flip**: the join input is applied, the turn skips the flip, no frame goes to the ended session, OnLeave runs after OnJoin, and the slot is released once.
6. **Old session's disconnect (#92 comment 1)**: join P as S1, then join P as S2 with S2 held before its turn, and disconnect S1. P's slot, cache and joining state are unchanged, and S2 flips normally.
7. **Duplicate login, router and legacy (#92)**: two joins of P, the first held before admission. Afterwards exactly one session of P is joined, the other is closed, and `allJoinedEntries` has one entry.
8. **Joins don't serialize on the turn**: 200 joins to one tick land are admitted while the first waits for its turn, and all flip in one or two turns.
9. **#90**: the reproduction from the issue (opcodeMessagePack plus path hashes, a broadcast `[String: T]`): join A, add k, sync; join B, mutate k, sync. B's frames decode with the SDK rules, with no "used before definition". SDK side: feed the captured frames to the runtime. Reconnect variant included.
10. **Off path**: tests 1, 6 and 7 with `IN_TURN_SYNC=false`. W2–W4 are documented as limits and not tested.
11. **E2E**: hero-defense scenarios in `Tools/CLI/scenarios/` with a late joiner (after monsters spawned), a reconnect, and two clients with one playerID, under messagepack with gating `assertConverged`. They run on both CI matrix legs.

## PR split

Each PR is core, reviewed, with `Closes`/`Refs` as listed. The order keeps each one small and leaves main shippable.

1. **Disconnect ownership** (Refs #92): the generation check in `handleDisconnectQueued`, plus test 6. Small and independent.
2. **`.joining` at admission** (Refs #69): replaces the late `initialSyncingPlayers` insert on both paths, with tests 1 and 10 (W1 only). This fixes W1 even before the turn work.
3. **Join as a turn input** (Closes #69): the join and join-sync inputs, the flip in `runTurnOutputs`, `awaitJoined`, and the router and legacy paths moved onto it, with tests 2–5, 8 and test 1 redone at the turn level. The largest PR; it gets a Notes/plans design check before review.
4. **Duplicate login policy** (Closes #92): the admission-segment kick for router and legacy, with test 7 and the two-sessions E2E.
5. **Broadcast key table for joiners** (Closes #90): the encoder, frame kind and SDK, with test 9 and the late-joiner and reconnect E2E.

**Measurements**: PR 3 changes join latency for tick lands (a join completes at its turn, at most one tick later) and moves firstSync work into the turn. Before merge, the json50 and ramp runs on the 7600X need: zero join failures under the new ws-loadtest join checks, and the turn p99 from the measure branch compared with the current baseline.

## Decisions requested

1. An OnJoin event targeted at the joiner: A (not delivered, since the snapshot is the boundary) or B (delivered after the firstSync)? Recommendation: A.
2. Off-path parity for W2–W4 before reruns? Recommendation: no.
3. #90 approach: (i) reset per join turn, or (ii) a key-table frame for the joiner? Recommendation: (ii).
4. #92 policy: option 1 (one session per player, newest wins)? Recommendation: yes.
