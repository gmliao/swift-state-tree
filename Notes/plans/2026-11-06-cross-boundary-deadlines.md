# Deadlines on cross-boundary awaits (#104)

Status: open (rev 1, for review).

## Problem

Some awaits that cross a component boundary have no time bound. When one stalls, its caller stalls with it, and so does every later operation queued behind it.

| Await | Bounded today? | What a stall blocks |
|---|---|---|
| Router: `lookUpLand` (`getOrCreateLand`: initial state, replay load, keeper init) | no | the session's join; with #113, its reads after the chain bound |
| Router: `admitJoin` (the wait in the membership queue, then `keeper.joinReportingAdmission`) | no | the session's join |
| Membership queue: `keeper.join` (CanJoin and OnJoin resolvers, the kick-old `leave`) | no | every later join and leave of the land (head-of-line) |
| Membership queue: `keeper.leave` (OnLeave resolvers) | no | the same |
| Action and client-event dispatch: resolvers | no | the session's later frames (the inbound chain) |
| The in-turn join's flip | yes, `JOIN_FLIP_TIMEOUT_MS` (10 s) | n/a |
| Sends and closes | yes: #225 (send backlog), #231 (close frame) | n/a |
| The inbound chain | read backpressure (#113); 1001 on a pause longer than the pong timeout | n/a |

The keeper waits that aren't user code are short: `ensureInitialized`, and the legacy path's `awaitInputTurn` / `runLegacyPass`, which wait for a turn. Every unbounded wait in the table comes down to two causes: **resolvers** (user code, usually calling an external service) and **land creation**.

## Why not race each keeper call in the membership queue

The issue suggests racing `keeper.join` / `keeper.leave` in the queue and moving on at the deadline. That breaks what the queue is there for. The queue serializes a land's joins and leaves, so the keeper sees them in order.

- **A timed-out leave that keeps running.** `leave` removes the player and takes its sequence before its OnLeave resolvers. Inputs run in order of `resolvedAtTick`, then sequence (`readyPendingItemsInOrder`). If the queue moves on, a rejoin of the same player resolves first and its OnJoin runs first. The old OnLeave then runs after it, against the new player's state.
- **A timed-out join that keeps running** can still insert its player after the queue has moved on, for example after the session's own leave ran: a ghost player (#97).
- **Cancelling the operation instead** cancels the resolvers inside it. For a leave, that drops OnLeave after the player was already removed. For a join that is kicking an old session, the cancellation reaches the inner `leave`'s OnLeave.

So nothing moves the queue past a keeper call still in flight. The bound goes where the time is spent.

## Design

### 1. A resolver deadline (core)

`ResolverExecutor.executeResolvers` races the resolver group against a deadline.

- **On timeout**, it cancels the group and throws `ResolverExecutionError.timedOut(names:after:)`, naming the resolvers still running.
- **The race returns at the deadline even if a resolver ignores cancellation.** It is an unstructured race, like `raceDeadline`, because a task group waits for its children. A resolver that ignores cancellation is left running and its result is dropped. The race never writes keeper state, so a late result changes nothing.
- **One deadline for all resolvers:** `RESOLVER_TIMEOUT_MS`, default 5000; 0 disables it. It goes in `EnvKeys`, read once through `EnvHelpers`. `LandDefinition` can't override it yet; see Open.

A timeout takes the same path as a resolver that throws. Each caller handles that today, except OnJoin:

| Caller | What happens on a throw |
|---|---|
| CanJoin resolvers | the join throws before anything is inserted; the adapter abandons the joining record; the router answers a join error |
| OnJoin resolvers | **today: a ghost.** The keeper inserted the player before the resolvers, and the throw propagates without removing it (`joinReportingAdmission` has no catch there). The adapter abandons its own records, so the keeper keeps a player no session holds. **Fix:** a catch that removes the entry if it is still this join's (`generation`), in the catch's segment, as the drain guard below it does. Then the join throws, as for CanJoin. |
| OnLeave resolvers | the player is already removed; OnLeave is dropped and logged; `leave` throws; the adapter logs it |
| Action and event resolvers | the client gets `ACTION_HANDLER_ERROR` / `EVENT_HANDLER_ERROR` |

The OnJoin fix stands on its own: it fixes a resolver that throws today. It goes first in the same PR, with its own test.

The membership queue then moves on, because the keeper call returned. Ordering is kept, since nothing is still running against the keeper. A land's head-of-line wait becomes at most the resolver deadline per queued operation.

**The OnLeave trade-off:** OnLeave is dropped when its resolvers time out, as it is today when they throw. A dropped OnLeave leaves the player's game state behind (the player itself is gone). The alternative, running OnLeave without its resolver outputs, changes what an OnLeave handler can assume. See Open.

### 2. A join deadline in the router (transport)

`handleJoinRequest` races `lookUpLand` plus everything up to the admission against `JOIN_ADMISSION_TIMEOUT_MS` (default 10000). That is below the CLI's 15 s join timeout (#86), so the client hears the error first.

- **The bound is end to end:** land creation, the wait in the membership queue behind other operations, and the keeper's join. The resolver deadline bounds each step; this bounds the sum.
- **On timeout, the session is closed.** The router ends the attempt and sends a `JOIN_DENIED` "Join timed out" error as the session's final frame, then closes it. It uses the same path as the flip timeout (`sendFinalFrameAndClose`, then `onDisconnect`).
- **A late result changes nothing.** The admission task is left running. When it returns, the router's existing check after admission (`isCurrent` is false, since the session ended) undoes it through `adapter.onDisconnect`, and the adapter's `endedSessions` already refuses a stale admission still queued (#230). No new compensation path is needed. A retry is a new session, as after a flip timeout.
- **Closing, not answering with the session left open, is deliberate.** An open session would retry under the same `SessionID`. A late admission's undo (`onDisconnect`) would then mark that session ended, and the retry would be refused as stale. Closing keeps one join attempt per connection's fate simple.

### 3. Measurement

- **Profiler counters:** `resolverTimeouts`, and `joinAdmissionTimeouts`, the router's timed-out joins.
- **Logs:** a warning per timeout, with the resolver names or the join's land and session.

### 4. Out of scope

- **Land creation's own deadline.** It sits under the router's join deadline, and a timed-out creation keeps running. `SingleFlight` already lets a later join share it.
- **Destroying a land stuck in OnJoin or OnLeave handlers.** Those are synchronous; the deadline bounds only their resolvers.
- **Per-player membership queues.** They would bound head-of-line across players differently. See Open.

## Tests (no timing: deadlines of a few ms, plus holds)

1. **Resolver deadline.** A resolver that suspends forever and ignores cancellation: `executeResolvers` throws `.timedOut` naming it. With a resolver that finishes, the same deadline passes.
2. **Join, CanJoin resolver stuck.** The join fails, no player is inserted, the queue processes the next join, and the router answers the error.
3. **Join, OnJoin resolver throws** (no deadline; the fix): the keeper holds no player afterwards, and its capacity is free. Then the same case **with the resolver stuck past the deadline**: the same, and the next leave and join of the land go through.
4. **Leave, OnLeave resolver stuck.** The player is removed, OnLeave is dropped and counted, and a rejoin of the same player afterwards runs its OnJoin with no stale OnLeave after it.
5. **Router join deadline.** The admission is held (`holds.at(.beforeAdmit)` or a stuck land creation): the client gets the timeout error and the close. When the admission is released, the adapter holds no member, slot or joining record for the session, and the keeper holds no player.
6. **A late admission that already happened** (released after the deadline, before the undo): the undo removes the player; no ghost.
7. **Env parsing** for both keys, including 0 = disabled.

Mutation checks:
- no cancel on the resolver timeout (test 1 still returns at the deadline);
- no removal in the OnJoin catch (test 3);
- the router doesn't close (test 5);
- no undo of a late admission (test 6).

## Open for review

- **The OnLeave trade-off.** Drop OnLeave on a resolver timeout, as for a throw today, or run it without the timed-out outputs?
- **Defaults.** 5 s for resolvers and 10 s for the router's join, under the CLI's 15 s. Should the resolver deadline be configurable per `LandDefinition`, or per resolver?
- **The error code.** `JOIN_DENIED` with "Join timed out" matches the flip timeout. A distinct `JOIN_TIMEOUT` would be clearer for clients, but it is an SDK-visible change.
- **One PR or two.** (1) is core, `SwiftStateTree`, and stands alone. (2) is transport and needs (1) only to bound the queue wait. I'd do (1) then (2).
