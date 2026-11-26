# The destroy handlers' outputs, and AfterFinalize's off the keeper's actor (#893)

**Status:** rev 2, Review GO on rev 1 (2026-11-26: (c), 0 must-fix, 1 should, 1 nit, all folded in here). Rev 2 settles Review's three open points (§6):
- the rule covers every destroy handler (the should);
- the counter is separate, `afterFinalizeOutputsDropped`, renamed `destroyHandlerOutputsDropped` because the rule now covers all of them;
- the change gets its own PR, after #892 and before the move.

The P1 test asserts the drop count (the nit). Plan and probe only: the code comes after #892 merges, since it flips #892's `afterFinalizeContextIsScoped`. #893 stays open until then.

## 1. The problem

`AfterFinalize` is the last destroy handler. It is `async`, and the keeper awaits it inside the drain (`shutdownIfIdle`).

Its `LandContext` comes from `makeContext`, as every handler's does. The context's output closures (`emitEvent`, `requestSyncNow`, `requestSyncBroadcastOnly`) call the keeper's `OutputCollector` directly. `OutputCollector` is a class with no lock, and it holds four things:
- the sequence counter (`nextSequence`);
- the emitted events;
- the sync requests per tick;
- the overflow flags.

After an await inside `AfterFinalize`, the handler resumes on the global executor, not on the keeper's actor. While it is suspended, the keeper runs other calls. Two kinds of call reach the collector during the drain:
- a join resumed from `CanJoin`'s resolvers: CanJoin's handler emits, and its `isDraining` refusal comes after it;
- a leave, which takes a sequence number in L1, before its drain check.

So the collector's array, dictionary and counter can be written by two threads at once.

#892 (K2-E) gives each handler call a `StepScope` with its own lock. That lock orders an output against its own scope's close, not against another scope's output, so it doesn't serialize these writes. #892's `StepScope` doc names this race and points here.

## 2. What the probe shows (P1, P2; § Probes)

- **P1.** On main, `AfterFinalize`'s emit after its await runs while the actor is blocked inside `CanJoin`'s synchronous handler. It takes the sequence number between CanJoin's two emits (`[1, 2, 3]` in append order). This is the race's precondition, shown without timing: two segments write the collector, and one of them isn't on the actor. TSan is not used, because it doesn't catch this class (CLAUDE.md § Reentrancy).
- **P2.** In the same run, all three events are still in the collector after the land is destroyed. Nothing after the drain takes an emitted event:
  - the tick and sync loops are cancelled when the drain starts;
  - the pending inputs are dropped, and every intake is refused while draining;
  - `flushOutputs` and `takeEmittedEvents` are called only from tick, sync and input turns.

  So **an `AfterFinalize` emit or sync request is never delivered or recorded.** It stays in the collector until the keeper is released. Before the await, the same holds: its emits happen after the last turn.
- **The same holds for the other destroy handlers** (rev 2, Review's should). `OnDestroyWhenEmpty` and `OnFinalize` run in the same drain, after the same start, through `runDestroyHandler` → `withHandlerStep`. They are synchronous and on the actor, so they don't race. But their outputs go into a collector that nothing takes after the drain starts, as Review confirmed for the adapter:
  - `acceptsSyncTurn` refuses once the land is draining (LK:6417);
  - `runSyncOnlyTurn` returns on a failure;
  - `flushOutputs` runs only on the re-evaluation paths (:1415, :4792, :5255);
  - the takes run only in turn bodies, and none runs after the drain.

  P2's events were all emitted after the drain began, so it covers this case too.
- **Not covered here:** `CanJoin` during the drain. The join is refused right after its handler (`guard !isDraining`), and its outputs sit in the same collector. But CanJoin is not a destroy handler, and it runs on the actor, so it stays as it is.

## 3. Options

**(a) Synchronize the collector: one lock for the whole structure.** Every member runs under the lock, including the actor's reads: the watermarks (`sequenceBeforeInputs`, `sequenceBeforeTickHandler`), the takes and the flushes.
- It fixes the race on main.
- It collides with the move. K1b-5 plan D15.3 (rev 2.6) moves the counter and `syncRequestsByTick` out of the collector into the model, and #892's scope borrows the counter from the model for one synchronous handler run. After the move, an off-actor emit can't take a number at all. Lending the counter across `AfterFinalize`'s awaits would leave the model without it while the actor runs other calls. So (a) would be undone within the stack, and the move would still have to answer `AfterFinalize`.
- It adds a lock to every emit on the hot path (tick handlers), for outputs nobody reads.

**(b) Hop `AfterFinalize`'s outputs to the keeper.** The context's closures start a `Task { await keeper.enqueue… }`.
- Every collector access then runs on the actor, and this survives the move: the hop takes `m.takeNextSequence()` in a segment of its own.
- But the emit returns before it is appended, so its number no longer follows the handler's own order, and a hop can run after the keeper's release (it holds the keeper weakly).
- It does all this to deliver outputs that, by P2, go nowhere.

**(c) The destroy handlers' contexts drop their outputs** (`OnDestroyWhenEmpty`, `OnFinalize`, `AfterFinalize`; rev 1 named only `AfterFinalize`). The keeper builds their contexts with output closures that drop the output and count it, and never call the collector. `ctx.random` still works. The one rule, "a destroy handler has no outputs", is simpler to document than one for `AfterFinalize` alone, and it is the same rule for the same reason: the reader is gone. The prior art is a closed channel: a send whose reader is gone is dropped.
- Nothing reaches the collector off the actor, so the race is gone on main, after #892 and after the move. The counter in the model is never reached from `AfterFinalize`.
- No client sees a difference: by P2, these outputs were never delivered or recorded.
- It frees the events and requests that today stay in the collector until the keeper's release.

**Decision: (c)** (Review GO). It removes the only off-actor writer instead of guarding it, and nothing the move or K2 does reintroduces one. #892 already drops a context's outputs once its handler returns, so every other context's off-actor use is already closed.

## 4. Change (for (c))

1. **The drain's three handler contexts** drop and count their outputs:
   - `runDestroyHandler`'s, for `OnDestroyWhenEmpty` and `OnFinalize`;
   - `shutdownIfIdle`'s, for `AfterFinalize`.

   With #892, each is a `StepScope` opened in a dropping mode: `random` is served, and every output is dropped and counted. The counter is separate from #892's `lateStepOutputs`: `destroyHandlerOutputsDropped`, a `LateStepOutputCounter`-shaped counter on the keeper. The two kinds differ:
   - a late output is a bug in land code (a context kept past its call), so it asserts in debug;
   - a destroy handler's output is legal code that has nowhere to go, so there is no assert.
2. **Docs.**
   - The doc comments of `AfterFinalize`, `OnFinalize` and `DestroyWhenEmpty(after:_:)`'s handler (`LandDSL.swift`) say that a destroy handler's events and sync requests go nowhere, because the land is gone; `ctx.random` works.
   - `docs/core/land-dsl.md` and `.zh-TW.md` get the same sentence in the lifecycle list.
   - The PR body's Behavior section states it.
   - Not a maintainer item: no API, wire or client-visible change, and these outputs are lost today.
   - #892's `StepScope` doc paragraph about #893 is replaced by a pointer to this rule.
3. **Tests.**
   - **#892's `afterFinalizeContextIsScoped` changes.** It pins that an emit after `AfterFinalize`'s internal await reaches the collector. Under (c) that emit is dropped and counted, and the kept-context emit after the close is dropped as before.
   - **New: P1 as a test.** `AfterFinalize`'s emit under the held `CanJoin` segment adds nothing to the collector (the sequences are `[1, 2]`, CanJoin's two). `destroyHandlerOutputsDropped` equals the number of `AfterFinalize` emits (rev 2, Review's nit).
   - **New, per destroy handler** (`OnDestroyWhenEmpty`, `OnFinalize`, `AfterFinalize`):
     - an emit adds no event to `emittedEventTicksForTesting()`;
     - a sync request adds no tick to `syncRequestTicksForTesting()`;
     - each is counted;
     - `ctx.random` still draws: the shared drain generator's sequence is unchanged.

## 5. Order, and what K2 leaves

- **Its own small PR** (decided, rev 2).
- **After #892.** It edits #892's `AfterFinalize` site and its test.
- **Before the K1b-5 move commit**, or folded into it. The move puts the counter in the model (D15.3 rev 2.6). With (c) in place, the move has no off-actor emit to handle. Without it, the move's lending rule has no answer for `AfterFinalize`. Flows 3+4 don't touch the drain, so it doesn't collide with them.
- **K2.** The drain's destroy handlers become `.destroyHandlerResolved` steps (K2 plan §4.3). `AfterFinalize` stays async user code run as an effect, so its context is still used off the core. Under (c), K2 has nothing to route: the context has no outputs. If a later design wants `AfterFinalize` to emit, that is a new feature (delivered where, after the transport is told the land is gone?), not a fix to carry.

## 6. Decided (Review on rev 1)

1. (c), for every destroy handler.
2. A separate counter, `destroyHandlerOutputsDropped`, with no assert.
3. Its own PR, after #892 and before the move.

## Probes

`2026-11-26-afterfinalize-outputs-probe.swift`, run on main at d5868dff (macOS, debug, Swift Testing), with a probe-only accessor `emittedEventSequencesForTesting()` (the collector's sequences in append order) added to `LandKeeper`. Neither is committed in `Sources/` or `Tests/`.

The setup holds three things:
- a join in `CanJoin`'s resolver (a `TestGate`);
- `AfterFinalize` at its await (a `TestGate`), after `forceShutdown`;
- then the join resumes, and `CanJoin`'s handler emits, blocks the actor on a semaphore that only `AfterFinalize`'s emit releases (10 s timeout, which turns a hang into a failure), and emits again.

Output:

```
probe-893 handlerWait=Optional(Dispatch.DispatchTimeoutResult.success)
probe-893 sequences(append order)=[1, 2, 3]
✔ Test "an AfterFinalize emit lands inside CanJoin's synchronous segment" passed after 0.015 seconds.
```

- **P1:** `handlerWait == .success`. The emit ran while the actor was held inside CanJoin's segment, and it took number 2, between that segment's 1 and 3.
- **P2:** after `forceShutdown` returned, `emittedEventTicksForTesting().count == 3`: no step took the events.
- **Rev 2:** no new probe. The widened rule rests on P2 (events emitted after the drain began are never taken), and Review read the adapter path from the code (§2). The tests in §4.3 check it per handler.
- **Limit:** the probe keeper has no transport. That no tick, sync or input turn runs after the drain starts with an adapter attached is read from the code, as listed in §2. The probe doesn't show it.
