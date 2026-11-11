# Plan: bound what a hung resolver costs (#364)

Status: revision 3. **Scope: PR 1.** PR 2 (the leak transition) is deferred to #498. PR 3 waits for the maintainer's decisions. Read on exp/next 2e1792f3.

## How it works now

- **The race** (`ResolverExecutor.runWithDeadline`, Sources/SwiftStateTree/Resolver/ResolverExecutor.swift:111–186).
  - The group runs in an unstructured `work` Task. The caller waits on a continuation raced against a timer.
  - At the deadline, or when the caller is cancelled, the race settles with `.timedOut` or `CancellationError` and cancels `work`, and the caller resumes.
  - A resolver that ignores cancellation keeps running, and its late result is dropped: "the race writes no keeper state".
  - Both the generic abandoned gauge (`metrics.noteAbandonedEnded()`, called by `runWithDeadline` itself) and `ActionAbandonment.noteEnded` come down only when `work` ends (:161–164, :176–181). A resolver that never ends keeps them up forever.
- **Actions** pass an `ActionAbandonment` (`executeActionResolvers`, :59–70).
  - It is a `Sendable` class with an `NSLock` (ActionJobLimits.swift:76–110).
  - Its `noteBegan`/`noteEnded` keep the process gauge `abandonedActions`.
  - `onEnded` hops to the keeper by `Task` and runs `releaseCompletedActionJob` (LandKeeper.swift:2101). Its `actionJobs[sequence]?.completed == true` guard (:2102) makes a late or second release a no-op. The sequence is never reused, so it works as the ticket.
  - Until the release, the job counts against the session's in-flight cap (`rejectIfOverActionJobLimits`, :2109–2130: 8 per session by default, and 256 abandoned process-wide).
- **Joins, leaves, CanJoin and OnInitialize** use `executeResolvers` / `executeInitializeResolvers` with no `abandonment`. Their abandoned groups move only the generic total and gauge, and no cap reads them (docs/core/resolver.md says so).
- **`RESOLVER_TIMEOUT_MS`** defaults to 5000. Only an explicit 0 (`ResolverDeadline.current == nil`) removes the race: `runGroup` is then awaited directly (:51–52, :63–64), and the caller waits as long as the resolver runs.
- **The public `handleActionEnvelope`** passes `enforcingLimits: false`. In Sources, only the benchmarks call it.

## What a bound does to a resolver that is still running

Swift can't stop a task that ignores cancellation, so no bound ends the resolver. It keeps running, and so do its external effects. A bound can only change **accounting**: which caps count the task, and when a cap slot is given back.

- **Releasing early is safe for keeper state.** The race has settled and drops the late result, and the sequence ticket makes a late release a no-op.
- **It isn't safe for resources.** The task still holds what it holds. A released slot must stay visible in its own gauge (PR 2), not vanish.

**Against CLAUDE.md's exception** ("the join/leave resolvers still re-check by hand"):
- Those re-checks run when the caller's await returns, at the deadline or with the result, not when the abandoned task ends:
  - the OnJoin generation check (LandKeeper.swift:1465–1466 and :1683–1684);
  - the leave's `guard !isDraining` after its resolvers (:2388).
- An abandoned group never resumes the keeper, so counting it can't skip or break a re-check. Counting join and leave groups changes reporting (and, for actions, intake) only.
- `RESOLVER_TIMEOUT_MS=0` is where the exception bites. A hung join or leave resolver then holds the adapter's membership queue forever, so every later join, leave and disconnect of that land waits. That's a liveness failure, not accounting, and no cap reaches it. It has its own issue, #497.

**Why a lock, not the reentrancy helpers.** `Lifecycle` and `GenerationTable` guard **actor** state across an `await`. The abandonment is one `Sendable` object touched from non-keeper tasks (the timer, the work's end, later the leak timer). Each transition is one lock acquisition with no await inside, so there's no check-then-act split to protect, and `ActionAbandonment` already works this way. The keyed part, the keeper's `actionJobs`, already uses the sequence as its ticket.

## PR 1

1. **`ResolverAbandonment(kind:)` on every deadline call.**
   - It replaces `ActionAbandonment`, with `kind` one of `action`, `canJoin`, `onJoin`, `onLeave`, `onInitialize`. `executeResolvers` and `executeInitializeResolvers` take one too, and the keeper passes it at each call site. Destroy handlers keep `executeResolversWithoutDeadline`.
   - **Its state** is `running → abandoned → ended`, under its lock. PR 2 adds `leaked`.
   - **Every gauge change goes through a transition's result** :
     - `noteBegan()` and `noteEnded()` each return what they did (`.began` / `.none`, `.ended` / `.none`), decided under the lock;
     - the gauges change from that value, inside the abandonment;
     - `runWithDeadline` no longer calls `metrics.noteAbandonedEnded()` itself. The generic gauge comes down in `noteEnded`, from its `.ended` result.

     After PR 2's leak, `noteEnded` returns `.endedAfterLeak` and lowers `leaked`, not `abandoned`, so no gauge is decremented twice.
   - `onEnded` (the keeper's job release) still runs only after `.ended`, and only for the `action` kind.
2. **The per-land count lives in a lock-guarded counter the land owns** .
   - `LandAbandonmentCounter` is a `Sendable` final class with a lock and a `[Kind: Int]` map, held by the keeper as a `let` and shared by its abandonments.
   - It is updated inside the transition: the abandonment calls it under its own lock.
   - **The full lock order is three deep: race → abandonment → counter.** `noteBegan` runs inside `ResolverDeadlineRace.settle`'s lock (ResolverDeadline.swift:243–245). The metrics and the counter are leaf locks. **Nothing is called while the counter's or the metrics' lock is held:** no logging, no callback. The same text goes as a code comment on both locks, so a later change sees it where it matters.
   - Begin before end is a real guarantee: begin happens inside settle's lock, and the end's Task is created after settle returns.
   - It is read synchronously at intake.
   - Not keeper state fed by `Task` hops: two separate hops aren't ordered, so an end could land before its begin and the count would dip below zero or stick one high. With the counter, begin and end are ordered by the abandonment's own transitions.
3. **The cap is per kind** .
   - Abandoned groups are counted per kind. A new `RESOLVER_ABANDONED_ACTIONS_MAX_PER_LAND` (default 32, `getEnvUInt` plus a named key in the resolver env keys) caps **actions on the action count only**.
   - `rejectIfOverActionJobLimits` reads `counter.count(.action)` in its synchronous segment, beside the session and process checks, before the sequence is taken.
   - Other kinds are reported, not capped. So an outage behind CanJoin's resolvers (an auth service) doesn't stop gameplay on lands whose players are already in.
   - A new rejection reason, `.landAbandonedResolverLimit(limit)`, has its message.
4. **Reporting:**
   - per-kind abandoned gauges in the land's metrics snapshot and the profiler output;
   - docs/core/resolver.md (both languages): what is counted per kind, what the per-land action cap does, and that an abandoned resolver keeps running.
5. **Process cap unchanged.** `RESOLVER_ABANDONED_ACTIONS_MAX` keeps its key and its actions-only meaning, so no config change.

### Hooks

- **`abandonedGroupEndedForTesting`:** a `@TaskLocal` hook in `runWithDeadline`, called on both abandoned paths between `_ = await work.result` and `abandonment.noteEnded()`. A test holds the end there.
- **`leakFiredForTesting` (PR 2):** replaces the leak timer's sleep with a gate, never a short duration. It is called just before the leak takes the abandonment's lock.
- PR 1 only needs the first. Both are named here so PR 2 adds the second at the place the first already marks.

### Tests (no timing)

The resolvers ignore cancellation and hang on a `TestGate`. Deadlines are set through the `ResolverDeadline` test overrides.
1. **Per-land action cap:** with the cap at 2, two actions on land A hang past the deadline. A's next resolver action is refused with `.landAbandonedResolverLimit`, and land B's runs. After A's gate opens, its count is 0, and A's next action runs.
2. **Kinds are separate** : a CanJoin resolver hangs past its deadline on A. `count(.canJoin) == 1`, and A's resolver actions still run. The same for OnJoin and OnLeave.
3. **Gauges exactly once** : one abandoned action and one abandoned join end (the gate opens, then the end hook is released). The generic gauge, `abandonedActions` and A's per-kind counts each return to 0, not −1.
4. **Begin before end on the cancel path:** the caller is cancelled (the `onCancel` branch), and the end is held at `abandonedGroupEndedForTesting`. The count is 1 while held and 0 after the release, never negative.
5. **Mutants:**
   - no per-land count;
   - the cap reading the all-kinds total (test 2 fails);
   - `runWithDeadline` still lowering the generic gauge as well (test 3: a double decrement);
   - the counter updated by a `Task` hop from the keeper (test 4);
   - joins not counted.

## Deferred

- **PR 2, the leak transition** (#498).
  - `RESOLVER_LEAK_AFTER_MS` moves a group that hasn't ended from `abandoned` to `leaked`. That releases its session slot and abandoned counts, and raises `leakedResolvers`.
  - The leak timer uses `safeTaskSleep` and is cancelled at the end transition .
  - **Tests are two hold-forced orders:**
    - (a) the leak is held at `leakFiredForTesting`; the end runs fully; then the leak is released. It finds `ended`, does nothing, and `leaked` is never raised.
    - (b) the leak runs fully, then the gate opens. The end returns `.endedAfterLeak` and lowers `leaked`, not `abandoned`.
  - **Mutant:** the generic gauge lowered after a leak.
  - **Why it matters despite short sessions:** the per-session and per-land counts go away with the land, but the process cap lives as long as the server. A destroyed land's hung resolvers keep counting in `abandonedActions`, so over days a server can creep toward 256. A cheaper alternative is to release a destroyed land's counts at its destroy.
- **PR 3 and the maintainer's decisions** (refusing joins, the leak default and cap, `=0`, `handleActionEnvelope` enforcing by default). PR 1 needs none of them. Decision 1 is settled for PR 1 as "count per kind; cap actions on actions".

## Overlap

PR 1 touches `ResolverExecutor`, `ActionJobLimits`, the keeper's resolver call sites and intake, and the resolver docs. PR A (#390) and #234 don't touch those.

## Solutions consulted

- `2026-11-06-unbounded-queues-and-awaits-at-boundaries.md`: every wait needs a bound, and a bound that can't stop the work must say what it releases.
- `2026-11-05-hold-points-not-timing-in-race-tests.md`: the end hook and the leak gate.
