# K2 prep: what K2 needs from K1b's end state (#700)

**Status:** a survey, not a plan. Read on 2026-11-25 against `2026-11-22-keeper-on-turncore.md` rev 5.7 (§3.1–§3.6, §5) and the turn core at main (`Sources/SwiftStateTurns`: `Machine.swift`, `Turn.swift`, `TurnActor.swift`), with K1b-3 and K1b-4 as planned (`2026-11-25-k1b-3-land-rng-into-model.md`, `2026-11-25-k1b-4-keeper-model-and-behavior.md`). K2's plan starts from these facts. Nothing here is decided.

## 1. The machine is the model

`TurnMachine` is a value type whose steps are `mutating func handle(_:_:)`, `handleAbandoned`, `handleLateResult`, `answer` and `handleMail` on `self` (`Machine.swift`). `TurnActor` requires `M: TurnMachine & PlainData`. So in K2, `KeeperModel<State>` is the machine, and the step's state is `self`.

**What K1b should leave for that:**
- **K1b-5's turn bodies are `mutating` methods on `KeeperModel`** (an extension: `mutating func applyAction(_:behavior:…)`), not free functions over `inout KeeperModel`. K2's `handle` then switches on the input and calls them, with no change to the bodies.
- **K1b-4's rule "one `inout` access of the model per step"** is exactly the shape `handle` has: inside a step, `self` is the only access, so no second access can overlap. The rule costs nothing in K2. It exists in K1b so that the actor's stored `model` doesn't trap before K2.
- **The K1b-3 RNG helper** becomes a method on the model (`mutating func withHandlerStep(…)`), reading `self.landRandom` and the seed from the behavior. That doesn't change it.

## 2. Behavior: what the core's contract allows

`Machine.swift`'s `Behavior` doc says: functions and fixed configuration, synchronous, deterministic, touching nothing outside the model. Anything that waits or does I/O goes out as an effect. A `Sendable` class with mutable state isn't checked, but it is against the contract.

K1b-4's `KeeperBehavior` holds `definition` (handlers), `LandConfig`, `payloadDecoders` and `logger`, which fit. It also holds `services` and `resolverServices`:
- **`resolverServices` and `services` as resolvers see them:** resolvers are effects (§3.4), so they read services in `perform`, outside a step. That is allowed: the effect captures them.
- **`ctx.services` in handlers:** handlers run inside steps, and today they can reach any service through `ctx.services`, including one that does I/O. That is the one place K2 meets the contract and today's API disagrees.
  - Options for K2's plan: keep `ctx.services` as a documented exception, the same status as `@Internal` holding a class; or narrow it (a handler gets no `services`, so the I/O goes through a resolver). The second is a public break.
  - **This is for the maintainer, through K2's plan.** K1b doesn't need it decided: K1b-4 puts `services` in Behavior as Appendix A.2 says.

## 3. Outputs and staging: how K1b-4's D1 ends

K1b-4 keeps `outputCollector` a class until K2 (D1), because the handler's context closures write it during the step. K2 ends D1 in the way §3.1 and §3.6 describe:
- **The sequence counter** (`nextSequence`, `checksOverflow`, `sequenceExhausted`) and `syncRequestsByTick` move into the model. They are plain, and only the step writes them once the closures stop doing so.
- **A turn's events** are staged in the step, through the scoped emitter: a per-step object holding a lock-protected open flag and the staged list. `LandContext`'s three output closures capture the scope, not the model. When the handler returns, the step moves the staged events into `turn.emit(…)` after its last mail checkpoint (§3.6), and closes the scope. A call after that (a task that outlived the step) finds the scope closed.
- **Why this keeps exclusivity.** The closures write the scope object, which is separate storage. The step reads it only after the handler returns, so nothing touches `self` (the model) during the handler's `inout` access of `self.state`.
- **What K1b-5 can do now to shrink K2:** give each turn body an explicit "staged outputs" value (events, the sync request, the record draft) that it returns, instead of writing the collector and the recorder in place. The collector stays as the sink until K2, but the bodies already have K2's shape. K1b-5's plan should take this up; it is a design choice, not a census one.

## 4. Effects as data

`TurnMachine.Effect` is data, and the adopter's `perform` does it (`TurnActor.perform(_:) async -> M.Input?`). K2 introduces `turn.run(effect)` for each await between K1 segments, and its result comes back as an input (§3.4: "K2: `run` with today's checks in the handler"). Later slices move these to `request` with keys (K5, K6, K7).

**From K1b, each await needs:**
- **Named segments** (K1b-5): the code before the await is one synchronous function, and the code after is another, whose inputs are the await's result plus what the first segment captured. Draft 3's F6 to F8 list (Appendix A) names them.
- **The captured values are plain:** what a segment hands across the await becomes part of the effect (out) or the input (back). Today's captures:
  - `actionJobs`' `ticket` and the entry generation (A.1: plain once `@PD`);
  - the resolver context (a snapshot of `State` and the services: built in the step, carried by the effect);
  - the join's session (plain after K1b-1).

  Anything a segment captures that isn't plain is a K2 finding. K1b-5's plan should list each await's captures.
- **The awaits K2 converts** (§3.4's "K2" column): action resolvers, CanJoin/OnJoin/OnLeave resolvers (as `run`), and waiting for the record (`.awaitRecordTaken`). Destroy handlers, OnInitialize resolvers and the sync follow-ups belong to K7, K5 and K3.

## 5. Replay

§3.10: the replay owner has no core and calls the same bodies. With §1's shape, replay calls the `KeeperModel` methods on its own `KeeperModel`, with the same behavior. K1b-4's D2 (`ReplayFields` struct) is the replay owner's state, which K2 moves into `ReplayLandOwner`.

## 6. Gaps to check in K2's plan (none found blocking)

- **`TurnActor.flush(_:)` is synchronous** (`consuming [M.Output]`). The recorder's serial sink is synchronous at hand-off today (`enqueueRecorderSubmission` returns a task), so it fits §3.4's `.awaitRecordTaken`.
- **`Turn` is `~Copyable`, and a step can lend it `inout` to synchronous helpers.** The K1b-3 RNG helper and the scoped emitter don't hold it, so they fit.
- **G2 (#759, the clock) and G3 (#760)** are K2's listed dependencies (§5). Nothing from K1b changes them.

## 7. Requests for K1b-5's plan (Code-2), from this survey

1. Turn bodies as `mutating` methods on `KeeperModel`, taking the behavior.
2. Each body returns its staged outputs instead of writing the collector and the recorder in place, if Review agrees (§3).
3. For each await between segments, list what crosses it, and flag what isn't plain (§4).
