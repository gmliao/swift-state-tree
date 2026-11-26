# AfterFinalize's outputs off the keeper's actor (#893)

**Status:** rev 1, for Review. Plan and probe only. The code comes after Review's GO, and after #892 (K2-E) and the K1b-5b stack land. #893 stays open until then.

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

## 3. Options

**(a) Synchronize the collector: one lock for the whole structure.** Every member runs under the lock, including the actor's reads: the watermarks (`sequenceBeforeInputs`, `sequenceBeforeTickHandler`), the takes and the flushes.
- It fixes the race on main.
- It collides with the move. K1b-5 plan D15.3 (rev 2.6) moves the counter and `syncRequestsByTick` out of the collector into the model, and #892's scope borrows the counter from the model for one synchronous handler run. After the move, an off-actor emit can't take a number at all. Lending the counter across `AfterFinalize`'s awaits would leave the model without it while the actor runs other calls. So (a) would be undone within the stack, and the move would still have to answer `AfterFinalize`.
- It adds a lock to every emit on the hot path (tick handlers), for outputs nobody reads.

**(b) Hop `AfterFinalize`'s outputs to the keeper.** The context's closures start a `Task { await keeper.enqueue… }`.
- Every collector access then runs on the actor, and this survives the move: the hop takes `m.takeNextSequence()` in a segment of its own.
- But the emit returns before it is appended, so its number no longer follows the handler's own order, and a hop can run after the keeper's release (it holds the keeper weakly).
- It does all this to deliver outputs that, by P2, go nowhere.

**(c) `AfterFinalize`'s context drops its outputs.** The keeper builds `AfterFinalize`'s context with output closures that drop the output and count it, and never call the collector. `ctx.random` still works.
- Nothing reaches the collector off the actor, so the race is gone on main, after #892 and after the move. The counter in the model is never reached from `AfterFinalize`.
- No client sees a difference: by P2, these outputs were never delivered or recorded.
- It frees the events and requests that today stay in the collector until the keeper's release.

**Recommendation: (c).** It removes the only off-actor writer instead of guarding it, and nothing the move or K2 does reintroduces one. #892 already drops a context's outputs once its handler returns, so every other context's off-actor use is already closed.

## 4. Change (for (c))

1. **`LandKeeper.shutdownIfIdle`** builds `AfterFinalize`'s context with output handlers that drop and count. With #892, this is a `StepScope` opened in a dropping mode (or closed for outputs from the start, with `random` kept). There is no debug assert: an emit in `AfterFinalize` is legal user code today. The counter is `lateStepOutputs` if Review accepts that one counter for both kinds (late outputs, and outputs with nowhere to go). Otherwise it is a separate `afterFinalizeOutputsDropped`.
2. **Docs.**
   - `AfterFinalize`'s doc comment (`LandDSL.swift`) says its context's events and sync requests go nowhere, because the land is gone.
   - `docs/core/land-dsl.md` and `.zh-TW.md` get the same sentence in the lifecycle list.
   - #892's `StepScope` doc paragraph about #893 is replaced by a pointer to this rule.
3. **Tests.**
   - **#892's `afterFinalizeContextIsScoped` changes.** It pins that an emit after `AfterFinalize`'s internal await reaches the collector. Under (c) that emit is dropped and counted, and the kept-context emit after the close is dropped as before.
   - **New: P1 as a test.** It asserts that `AfterFinalize`'s emit under the held `CanJoin` segment adds nothing to the collector (the sequences are `[1, 2]`, CanJoin's two) and counts one dropped output.
   - **New: a sync request** from `AfterFinalize` adds no tick to `syncRequestTicksForTesting()`.

## 5. Order, and what K2 leaves

- **After #892.** It edits #892's `AfterFinalize` site and its test.
- **Before the K1b-5 move commit**, or folded into it. The move puts the counter in the model (D15.3 rev 2.6). With (c) in place, the move has no off-actor emit to handle. Without it, the move's lending rule has no answer for `AfterFinalize`. Flows 3+4 don't touch the drain, so it doesn't collide with them.
- **K2.** The drain's destroy handlers become `.destroyHandlerResolved` steps (K2 plan §4.3). `AfterFinalize` stays async user code run as an effect, so its context is still used off the core. Under (c), K2 has nothing to route: the context has no outputs. If a later design wants `AfterFinalize` to emit, that is a new feature (delivered where, after the transport is told the land is gone?), not a fix to carry.

## 6. Open for Review

1. (c) over (a) and (b), given P2.
2. One counter (`lateStepOutputs`) or a separate one.
3. The PR's place: its own PR between #892 and the move, or folded into the move commit.

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
- **Limit:** the probe keeper has no transport. That no tick, sync or input turn runs after the drain starts with an adapter attached is read from the code, as listed in §2. The probe doesn't show it.
