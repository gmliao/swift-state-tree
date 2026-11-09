# The leave as a turn: OnLeave's resolvers off the membership queue

Status: open. Design note for the leave half of #363, and the first of the two PRs the maintainer chose for #334 (D7 (c), 2026-11-09): this PR moves today's leave onto the request → result-turn shape, and the disconnect grace (`Notes/plans/2026-11-09-disconnect-grace.md`) builds on it. Docs only, for the maintainer's choices (§ 8); Code-1 implements after #369. Targets `exp/next`.

Line numbers are from `exp/next` at 6a251cea.

## 1. Problem

A disconnect's leave holds the land's whole membership queue while OnLeave's resolvers run.
- `TransportAdapter.enqueueMembership` (`TransportAdapter.swift:2754-2763`) keeps one serial tail per adapter, so one per land. Every join (`admitJoin` → `performJoinQueued`, `:1989`) and every disconnect (`_onDisconnectImpl`, `:1303-1314`) goes through it.
- The disconnect awaits `keeper.leave(playerID:clientID:sessionID:)` (`:1355`). `LandKeeper.leave` (`LandKeeper.swift:2255-2391`) removes the entry, then awaits OnLeave's resolvers inline (`:2306-2340`) under `RESOLVER_TIMEOUT_MS`, appends the `.leave` input, and on a tickless land waits for its turn (`awaitInputTurn`, or `runLegacyPass` off in-turn sync).
- So one player's slow OnLeave resolver holds every other player's join and leave on that land, up to the deadline (5 s by default, unbounded at 0). CLAUDE.md lists the leave among the paths not yet in turns.

The join half of #363 (CanJoin's and OnJoin's resolvers, still awaited inside the queue) is out of scope; § 9.

## 2. What the queue guarantees, and how they're kept

The maintainer built the membership queue for exactly this: joins and leaves of one land in order, and a half-done leave never crossed by an immediate rejoin (`Notes/plans/2026-02-01-membership-queue-reconnect.md`). Those guarantees stay. What changes is how they're kept: by per-player state in the keeper, not by holding the queue across a resolver's await.

| Guarantee | Today | After |
|---|---|---|
| A land's membership inputs apply in arrival order | The queue runs each operation to its end, OnLeave's resolvers included | The queue still submits them in arrival order. A leave's operation ends at its leave turn; what's left of the leave (its resolvers, then its `.leave` apply) is ordered by the keeper's pending-leave state and the inputs' sequences |
| A player's leave and rejoin never cross | The rejoin waits in the queue until the leave, OnLeave's resolvers and (tickless) its apply are done | The keeper records a pending leave for the player ID between the leave turn and the `.leave` apply. A join for that player ID can't apply before it (L1, § 8), and its OnJoin always takes a later sequence than the OnLeave |
| A stale result never acts | — (nothing outlives the queue's await) | OnLeave's resolver result carries a ticket (the removed entry's generation and the leave's sequence), and its result turn acts only when the pending leave still holds that ticket |

## 3. The rules this follows

The maintainer's phase-separated turn, on every leave path (CLAUDE.md § Reentrancy, `Notes/plans/2026-11-05-reentrancy-helpers.md`):

1. **Keeper state changes only inside a synchronous turn,** with no `await` between a check and the write it guards.
2. **Async work is a request.** It carries a ticket captured in the turn that issued it; its result comes back as a turn input, whose turn validates the ticket against the current state.
3. **What a turn produces for the transport is an output,** emitted after the turn commits (the sync output, the broadcast-only sync). The keeper never awaits the transport inside a turn.
4. **A timer or task only enqueues an input.** It never reads or writes keeper state from its own task.

## 4. The design

**The leave turn (a turn input).** The adapter submits the leave from its membership queue with the session it ended (L2, § 8). In one synchronous segment, the leave turn:
- matches the entry, as today: the player ID, the client ID and the recorded session ID (`LandKeeper.swift:2266-2277`); a mismatch is a no-op;
- removes the entry (today `:2287`) and cancels its generation's action jobs (`cancelActionJobs(ofEntryGeneration:)`, `:2151`);
- in reevaluation mode, or with no OnLeave, ends here, as today (`:2291-2295`);
- takes the leave's sequence (`outputCollector.takeNextSequence()`, today `:2298`);
- **without OnLeave resolvers:** appends the `.leave` input at once, with the entry's client and session IDs and `resolvedAtTick` = `lastCommittedTickId`;
- **with OnLeave resolvers:** records the **pending leave**, `pendingLeaves[playerID] = (entryGeneration, sequence)`, and issues the resolvers as a request.

**OnLeave's resolvers (a request).** The group runs in its own task under the resolver deadline, as an action job does since the action completion queue (`startActionJob`, `completeAction`, `LandKeeper.swift:1928-2045`). Its ticket is the removed entry's generation plus the leave's sequence. The task never touches keeper state (rule 4): it ends by submitting its result as a turn input.

**The leave's result turn (a turn input).** In one synchronous segment:
- it validates the ticket: `pendingLeaves[playerID]` must hold this generation and sequence; otherwise the result is stale and dropped;
- on success it appends the `.leave` input with the resolvers' outputs and `resolvedAtTick` = `lastCommittedTickId` (today the same tick is read after the resolvers, `:2339`);
- on a resolver failure or the deadline, it drops the leave as today (logged, counted with `onLeaveDropped`; a sequence gap replay steps over, `:2330-2338`);
- if the land is draining, it drops the leave as today (`:2344-2352`);
- in every case it ends the pending leave once the `.leave` input applies (or at once, for a drop), which releases what waits on it (§ 5, L1).

**The `.leave` apply** is unchanged: on a tickless land in the next input turn (or the legacy pass off in-turn sync), on a tick land in the next tick, in the pending-input order (`resolvedAtTick`, then sequence). It sets `shouldSyncBroadcastOnly` (`:3193`), and the broadcast-only sync is the output after that turn commits (rule 3).

**The result always arrives.** The request ends on success, on a resolver failure, at the resolver deadline (the race returns at the deadline even when a resolver ignores cancellation, `ResolverExecutor.swift:107-160`), and on the keeper's cancellation when a drain starts. Each comes back as the result turn, so a pending leave always ends. The exception is `RESOLVER_TIMEOUT_MS=0`, which disables the deadline: a resolver that never ends then keeps its pending leave forever. Today the same resolver holds the land's whole queue forever, so this is no worse, and the code documents it.

**The empty-land timer is held by a pending leave.** `scheduleDestroyIfNeeded` (`:4584-4597`) guards only `players.isEmpty`, and the leave turn removes the entry before OnLeave's resolvers return. Armed there, a `destroyWhenEmptyAfter` shorter than the resolver deadline would destroy the land before the result turn: OnLeave would never apply, and no `.leave` would be recorded. Today the timer is armed only at the end of `leave`, after the resolvers. So the guard becomes `players.isEmpty && pendingLeaves.isEmpty`, and the `.leave` apply (or the result turn that drops the leave) arms it (L4, § 8).

## 5. Interleavings

Every row: today's outcome, the new one, and why the new one is equal or better. "Held" means the land's membership queue waits.

| Interleaving | Today | After | Verdict |
|---|---|---|---|
| **A leaves (OnLeave resolvers), then A rejoins** | The rejoin waits in the queue behind A's whole leave: OnLeave's resolvers, the append, (tickless) the apply. Then CanJoin and OnJoin run. Order: OnLeave, OnJoin | A's leave operation ends at its leave turn. The rejoin reaches the keeper while A's leave is pending and waits there (L1 (a)), then its admission runs. Order: OnLeave, OnJoin | Equal. Under L1 (a) the rejoin waits inside its queue operation, so the queue is held while it waits, as today |
| **A joins, and A's session disconnects before the join's resolvers return** | The disconnect is queued behind the join: the join completes (or fails, e.g. at its flip timeout), then the disconnect's leave runs (`failInTurnJoin(.disconnected)`, `:1323`) | Unchanged: joins still await their resolvers inside the queue (the join half of #363 isn't in this PR). The leave, once it runs, is the new leave turn | Equal |
| **Two joins for one player (newest wins)** | The second join waits in the queue for the first. Its keeper join then kicks the first client through `leave` (`:1564-1570`), awaiting OnLeave's resolvers inline inside its own join, then inserts and runs OnJoin | The kick is the new leave turn and leaves a pending leave; the second join, being the same player ID, waits on it (L1 (a)) and then inserts. Order: OnLeave, OnJoin | Equal |
| **A leave pending at a drain or destroy** | The drain starts during OnLeave's resolvers; the leave sees `isDraining` and drops OnLeave (`:2344-2352`, `onLeaveDropped`). The queue is held until the resolvers return; joins after it fail (`landShuttingDown`) | The drain cancels the request; the result turn sees the drain and drops the leave, counted the same. A same-player join waiting on it fails with `landShuttingDown`. The empty-land timer can't destroy the land before the result turn (§ 4) | Equal; the empty-timer guard closes a gap the new shape would otherwise open |
| **B joins or leaves while A's leave is pending** | B waits in the queue until A's OnLeave resolvers return: up to the deadline (the #363 symptom) | B's operation runs at once: A's leave operation ended at its leave turn | **Better** (the point of this PR). Exception: if a same-player rejoin of A is already waiting under L1 (a), B waits behind it in the queue, as long as today |
| **A leaves twice** (a second disconnect of an already-left session) | The second `leave` finds no entry and returns (`:2258-2262`) | The second leave turn finds no entry: a no-op | Equal |
| **A stale result** (a result after its pending leave ended by a drain) | — | The result turn finds no matching pending leave and changes nothing | New path, covered by its ticket |

## 6. What the membership queue still serializes

The queue keeps its role for what is per connection and per adapter, in arrival order:
- the disconnect's adapter-side teardown (the connection generation, join attempt, inbound drain, session ticket, sync-lag entry, action-response tickets; `TransportAdapter.swift:1316-1350`) and the membership invalidation;
- the submission of the leave turn, in order with the joins and disconnects queued around it;
- the post-leave adapter cleanup (`:1367-1393`: the sync cache and firstSync mark, the sync-stream `clear` marker, the player slot). It moves with the leave operation's end (L3, § 8);
- joins, whose CanJoin and OnJoin resolvers are still awaited inside the queue until the join half of #363, and with them any same-player join that waits on a pending leave (L1 (a)).

## 7. Record and replay

No record format change.
- The `.leave` input is today's lifecycle input (`PendingLifecycleItem`, kind `.leave`, `:2354-2368`): the player, client and session IDs, the device ID, guest flag and metadata, the resolver outputs and `resolvedAtTick`. Replay applies it as today (`:3174-3196`).
- The leave's sequence is taken in the leave turn, as today it is taken before the resolvers (`:2298`). A dropped leave is a sequence gap, as today.
- `resolvedAtTick` is read in the result turn, the tick current when the resolvers' result is applied; today it is read right after the resolvers return. Same meaning.
- A same-player join that waited takes its OnJoin sequence when its admission runs, after the leave's sequence, so the record's order is OnLeave, then OnJoin, as live.
- The sync-stream `clear` marker is recorded by the adapter's post-leave cleanup, outside turns (`outsideTurn: true`), as today; under L3 (a) it is earlier in wall time.

## 8. Open choices (for the maintainer, one at a time)

**L1. A join of the same player ID while that player's leave is pending.**
- (a) **It waits on the pending leave inside its keeper join, then its admission runs** (CanJoin included, so it sees the state after OnLeave, as today). It still runs inside the membership queue, so while it waits the queue is held, as long as today's leave held it. Others are held only when such a rejoin exists.
- (b) **It is refused with a retryable error** (`JOIN_IN_PROGRESS`, which the client retries). The queue is never held by a pending leave, but a reconnect costs the client a retry, and newest wins needs its own path (the kicking join can't refuse itself).
- (c) **It supersedes the pending leave:** cancel the request and restore the entry. Not viable: the entry is already removed and its jobs cancelled, and an OnLeave already dropped can't be undone.

**Recommended: (a).** It is equal to today in every row of § 5 and better for other players in the common case, with no client change. When the join half of #363 makes the join a turn input, the waiting join becomes a parked input and stops holding the queue; (a) is written to carry over.

**L2. The public `LandKeeper.leave(playerID:clientID:sessionID:)`.**
- (a) **It keeps its contract** (returns once the leave is applied or dropped), as `submitLeave` plus a wait on the leave's sequence; only the adapter's disconnect uses `submitLeave`. This mirrors `handleActionEnvelope` over `submitAction` (`:2399-2441`).
- (b) It returns after the leave turn, and callers that need the apply wait for it themselves.

**Recommended: (a).** 18 test and example files call `leave(...)` and expect today's return point; (a) keeps them, and the adapter's disconnect is the one caller that must not wait.

**L3. When the adapter's post-leave cleanup runs** (the sync cache, the `clear` marker, the player slot).
- (a) **Right after the leave turn,** in the same queue operation. The entry is already gone then, as it is today when the cleanup runs after the resolvers, so nothing reads the player's sync state in between.
- (b) After the `.leave` applies, through a keeper-to-transport output (the `playerLeft` notification #334 introduces).

**Recommended: (a).** It needs no new output in this PR; #334 adds `playerLeft` for the grace's expiry, which the adapter didn't start.

**L4. The empty-land timer and a pending leave.**
- (a) **Guard it with `players.isEmpty && pendingLeaves.isEmpty`,** armed by the `.leave` apply or by the result turn that drops the leave.
- (b) Arm it at the leave turn, and have its fire re-check for pending leaves (the fire only enqueues an input, rule 4, whose turn re-checks).

**Recommended: (a).** The timer never runs while a leave is pending, as today (where it is armed only after the resolvers). (b) is a timer that starts early and must be re-checked every time.

## 9. Hold tests

Every gate and hold key comes from `KeyedGates.freshKey()` or `fresh` (#358). The resolver hold is a test OnLeave resolver on a gate. New keeper hold points: `.leaveResolved` (before the result turn) and `.pendingLeaveWait` (when a same-player join starts waiting, under L1 (a)). Each test runs in both in-turn sync modes, and the record tests with `recordsSyncStream` on and off.

1. **Another player isn't held (the #363 symptom).** A's OnLeave resolvers held; B joins and then leaves. Expected: B's join and leave complete while A's resolvers are still held.
2. **A same-player join waits.** A's OnLeave resolvers held; A rejoins. Expected: `.pendingLeaveWait` is reached; after release, OnLeave applies, then CanJoin and OnJoin; the test land's log shows that order, and the new A's game state isn't deleted.
3. **A failing or timed-out OnLeave resolver.** As test 2, with the resolver throwing, then running past the deadline, then ignoring cancellation. Expected: the leave is dropped and counted (`onLeaveDropped`), its sequence is a gap, and the waiting join runs after it.
4. **A drain while a leave is pending.** A's OnLeave resolvers held, A's rejoin waiting; start `shutdownAllLands()`. Expected: the leave is dropped and counted, the rejoin fails with `landShuttingDown`, and the land is released (`waitUntilReleased`, as in #350's tests).
5. **The empty-land timer.** A sole player with a `destroyWhenEmptyAfter` shorter than the hold; OnLeave's resolvers held past it, then released. Expected: no destroy while the leave is pending; one `.leave` recorded and applied; then the timer arms and the land is destroyed.
6. **A stale result.** Hold at `.leaveResolved`, end the pending leave by a drain, then release. Expected: the result turn finds no matching pending leave and changes nothing.
7. **Newest wins.** A connected; a second session joins as A. Expected: the kick's leave turn runs, the new join waits on it, OnLeave applies, then OnJoin, and the old session gets no answer after its ticket ended.
8. **The public `leave(...)` (L2 (a)).** Called directly with OnLeave resolvers: it returns only after the `.leave` is applied (or dropped); `submitLeave` returns after the leave turn.
9. **Join then disconnect during the join's resolvers.** Hold A's CanJoin resolvers; disconnect A's session. Expected: as today, the disconnect waits for the join, then the leave turn runs.
10. **Record and replay.** Two players leave with OnLeave resolvers, one rejoins while its leave is pending, and one leave is dropped by a failing resolver. Expected: the replay verifies with 0 mismatches; OnLeave ran in the replay with the recorded IDs; the dropped leave is a gap.
11. **No resolvers.** A land whose OnLeave has none: the leave turn appends the `.leave` at once; there is never a pending leave.
12. **The existing suites.** Every current leave and join test passes unchanged.

## 10. Out of scope

- The join half of #363: CanJoin's and OnJoin's resolvers as a request with a result turn. L1 (a)'s waiting join becomes a parked input then.
- The disconnect grace (#334), the second PR.
- A cap on abandoned join, leave and OnInitialize resolvers (only actions are capped today; the 11-08 resolver review's finding (b)).
