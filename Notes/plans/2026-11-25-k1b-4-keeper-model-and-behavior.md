# K1b-4: `KeeperModel<State>` and `KeeperBehavior<State>`, with the census test (#700)

**Status:** rev 1.2, plan only, a draft. Rev 1.2 takes Appendix A's F5–F8 (#700 plan rev 5.8, 589d553b) into the census test, and K1b-3's implementation (PR #853); §10. Rev 1.1 settled D2, took K1b-3's GO'd helper (rev 2.1, d7e41fcc) and the K2 survey's shape (1ebd7ddb); §9. Rev 1 It was read at #835's head 5baa1887 (K1a), without the LSP, and #834's head 636dd69e (P4-1) for `StateNodeProtocol: PlainData`.
- K1b-4 needs K1b-1 (the plain forms), K1b-2 (`FailureID` and the side tables) and K1b-3 (the RNG), and P4-1 (K1b-Q3). So this plan names their results by their planned shapes, and rev 2 re-checks them on K1b-4's base with the LSP.
- The census is Appendix A of `2026-11-22-keeper-on-turncore.md` (draft 3 and A.7).

## 1. Goal

`LandKeeper`'s stored state splits by home, with no behavior change:
- `var model: KeeperModel<State>`: `@PlainData`, the core's machine;
- `let behavior: KeeperBehavior<State>`: fixed at init (the definition and `LandConfig`);
- the Outside, replay and K2–K9 fields stay on the actor. The replay fields are grouped in one struct, which K2 moves into `ReplayLandOwner`.

A census test makes each stored property's home a checked fact. `@PlainData` on `KeeperModel` makes "the model is plain" a compile-time fact.

K1b-5 (turn bodies over `(inout KeeperModel, KeeperBehavior)`) builds on it.

## 2. The census at 5baa1887

A mechanical pass over the actor body (LK:117–6327) found 126 stored instance properties. Each one is named in Appendix A (A.1–A.5 and A.7). None is unplaced, and every name in a table's first column still exists. The pass skipped computed properties and `static`. Rev 2 repeats it on the base with the LSP's `documentSymbol`, which catches a declaration the regex pass misread.

## 3. Shape

### 3.1 The types (SwiftStateTree, `Runtime/KeeperModel.swift`, internal)

```swift
@PlainData
struct KeeperModel<State: StateNodeProtocol> {
    var state: State
    var players: [PlayerID: InternalPlayerSession]   // without `services` (A.1)
    var pendingItems: [PendingItem]
    // … every A.1 row, after K1b-1 to K1b-3 (each field keeps its name)
}

struct KeeperBehavior<State: StateNodeProtocol>: Sendable {
    let definition: LandDefinition<State>
    let config: LandConfig        // autoStartLoops, enableLoopPhaseOffset, … , landRandomSeed (K1b-3)
    let services: LandServices    // outside-world services only, after K1b-3
    let resolverServices: any Sendable
    let payloadDecoders: RecordPayloadDecoders
    let logger: Logger
}
```

- `StateNodeProtocol` refines `PlainData` after P4-1. So the macro's conditional conformance (`where State: PlainData`) always holds, and `KeeperModel<State>` is `PlainData` for every land.
- **Field names don't change.** `model.players` reads the same as `players` does today, so the diff is a prefix and a reader can follow it.

### 3.2 Exclusivity: one inout access of the model per step

- **The trap.** `model` is a stored property of an actor, so Swift enforces exclusive access to it dynamically, also in release builds. Today a handler runs on `&state`, a property of its own, so the keeper can read `players` while the handler holds `state`. After the move, `&model.state` holds an access to all of `model`. Any read of `model.players` during that access, through the keeper or through a closure that reaches it, is a runtime "simultaneous accesses" trap.
- **The rule (prior art: SE-0176, Law of Exclusivity).** A step takes `inout KeeperModel` once and reaches every field through that binding. The K1b-3 helper becomes:
  ```swift
  private func withHandlerStep<R>(_ ctx: LandContext, random: HandlerRandom = .step,
                                  _ body: (inout KeeperModel<State>, LandContext) throws -> R) rethrows -> R
  ```
  It gives the body `&model`, and the body calls the handler with `&m.state`. That is the shape K1b-5's turn bodies take anyway.
  - **K1b-3's RNG write-back** becomes `defer { model.landRandom = service.generator }`. A `defer` runs after the body returns, so the body's `&model` access has ended, and the write-back is its own access: no overlap.
  - **K1b-5 and K2** (K2 survey, 1ebd7ddb): the core's `TurnMachine.handle` is `mutating` on the machine itself, so K1b-5's bodies are best written as `mutating` methods on `KeeperModel` taking `KeeperBehavior`. That is the same one-access rule, with `self` as the binding. K1b-4 only adds the types and moves the fields, and the methods come in K1b-5.
- **Checked at 5baa1887.** The nine `withMutableStateSync` bodies touch no other keeper field. The handlers' context closures (`emitEventHandler`, `requestSyncNow…`) write `outputCollector`, a separate class, not the actor. Hence §3.3.
- **Test.** Each handler kind runs once under a debug build, which already has dynamic enforcement: `swift test`'s suites cover them. A mutant in §6 moves one read inside the access.

### 3.3 Deviations from Appendix A (for Review)

- **D1: `outputCollector` stays a class until K2.** A.1 splits its plain fields (`nextSequence`, `checksOverflow`, `sequenceExhausted`, `syncRequestsByTick`) into Model.
  - But the handler's context closures write them during the handler, while `&model` is held. Moving them into Model now would turn every `ctx.emit` into an exclusivity trap.
  - K2 stages outputs in the step's output (§3.6), and that is when they can move.
  - K1b-4 lists the collector as Outside with "K2" in the census test's exception list.
- **D2: the replay group.** A.5's fields become one `struct ReplayFields` on the actor, **non-optional, with today's defaults**: the setters (`setReplayPassObserver`, `setReplayRecordsPassOrdinals`, `setReplayRecordsRejected`, `setReplayFailureEnd`) run on a keeper that already exists, after init (`ReevaluationEngine`:351, `ReevaluationRunnerImpl`:350–358), and a live keeper reads the defaults today. An optional group would add an unwrap at every read for no gain.
  - **`ReplayFields` stays non-plain.** `replayPassObserver` is a closure that captures the engine's sinks or the runner. Review suggested moving it to Behavior so the group could be `PlainData`, then agreed to decline (2026-11-25): Behavior is fixed at init and must hold no mutable reference, and the observer and its three siblings are set after init, from the record header and from state read off the running keeper. A.5 doesn't need the group plain (the replay owner has no core). **Revisit at #612**, which can build the replay keeper after reading the header.

### 3.4 The census test (`Tests/SwiftStateTreeTests/KeeperCensusTests.swift`)

- **The names.** `Mirror(reflecting: keeper).children` lists the actor's stored properties. The test also reflects `keeper.model` and `keeper.behavior` through test accessors. A table in the test gives each name exactly one home: Model, Behavior, Outside(K2…K9), Replay or TestHook. The test fails when:
  - a stored name is missing from the table (a new field must be placed);
  - a table name is no longer stored (a stale row);
  - a name appears in two homes.
- **The known exceptions,** each with the slice that ends it:
  - F4's `Instant`s (K2);
  - S3's sync-loop writer: `runSync` writes `foldedSyncs`, `overdueFoldedSyncs` and `inTurnSyncDue` outside a turn (F8; K2's `.syncDue` step);
  - D1's collector (K2).
- **F8's offsets are Outside, not Model.** `appliedTickPhaseOffset` and `appliedSyncPhaseOffset` go with `tickLoopConfiguredAt` and `tickLoopClock` in the loop driver's group. K1b-4 checks first, with `findReferences` on its base, that no turn reads them. If one does, that offset stays in Model and joins S3's exception.
- **K1b-3's fields** (PR #853): `landRandom` is Model, so the RNG group moves in commit 2. `landRandomSeed` is Behavior (`config`). K1b-3 removed `withMutableStateSync`, so the test-hook row A.6 names for it goes; `landRandomForTesting` is a computed accessor, not a stored field.
- **What the census test doesn't check: F6 and F7.**
  - F6 lists the turn-shaped entries: §2's four, plus `applyShutdownTurnBetweenTicks`, `syncTurnNow`, `runInputDrain`'s turn end, and `performInitialization`'s output segment.
  - F7 lists the async segments that write Model after an `await`.
  - Both are K1b-5's, which turns each one into a body over `(inout KeeperModel, KeeperBehavior)`.
  - K1b-4 only moves fields. It doesn't make the census test assert who writes, because `Mirror` sees fields, not writers. The writer list stays a plan table that K1b-5 checks off.
- **The side tables.** S4's key-set assertion comes from K1b-2. The census test runs a job through admitted, resolved, abandoned and cancelled, and checks it.
- **Must-not-compile pin** (CI runs it; the Mac doesn't): `scripts/must-not-compile/keeper-model-not-plain.swift` is a `@PlainData` struct shaped like `KeeperModel` that holds an `AnyCodable`. It expects the PlainData diagnostic for `AnyCodable`, with the text taken from P4-1's snippets.

## 4. How the change is made

The change is mechanical but wide: about 126 fields, and thousands of references in a 6,300-line file. Commits:
1. **Add the types; move Behavior's `let`s.** They are read-only, so this is a pure rename.
2. **Move Model's fields in groups** (counters and flags; queues; the player table; the RNG; state last), each group building green.
   - Use the LSP's `findReferences` per field, and a script that prefixes `model.` at exactly those references. No textual replace: names like `state` and `players` also appear as locals and parameters.
3. **The replay group.**
4. **The census test and the snippet.**

Each commit runs the touched suites. The full debug `swift test` runs before the push.

## 5. Behavior and performance

- **No behavior change.** Goldens, the differential harness and replay stay byte-identical.
- **Performance.** A field read becomes a read through `model`; the dynamic exclusivity checks stay one per access, as today. The plan's K1b row asks for the small A/B: the default production cell and `rows-mp`. Off-path is judged by windowed `instructions:u` (#517 (a)).

## 6. Mutants (cloud worker)

| # | Mutant | Killed by |
|---|---|---|
| M-1 | a new stored property on the actor, not in the census table | census test (unplaced) |
| M-2 | a field deleted from the actor but left in the table | census test (stale row) |
| M-3 | `AnyCodable` added to `KeeperModel` | does not compile (the snippet's check is CI's) |
| M-4 | one handler call site reads `model.players` inside the step's access | that handler kind's suite (exclusivity trap in debug) |
| M-5 | S4's side-table removal skipped on abandonment | census test's job-life check |

## 7. Public API

None. All the new types are internal. `LandKeeper`'s public members keep their signatures; the bodies read through `model` and `behavior`.

## 8. Open for rev 2 (on the base)

- K1b-1's final forms (F9 to F11, F3, `LandFailure`) and K1b-2's `FailureID` and side tables. The Model rows in §3.1 copy them.
- **D1** (§3.3): Review's early read agreed. D2 is settled in rev 1.1.
- The LSP census, and the exact list of the census test's exceptions.

## 9. Rev 1 → rev 1.1

| Change | Where |
|---|---|
| Review's early read: the one-inout rule, D1 and D2 fine | §3.2, §3.3 |
| D2: non-optional with defaults; `replayPassObserver` stays off Behavior (Review's nit, declined and agreed), revisit at #612 | §3.3 |
| K1b-3 rev 2.1's helper (`random:`), with the write-back in `defer` after the model access | §3.2 |
| K2 survey: K1b-5's bodies as `mutating` methods on `KeeperModel` | §3.2 |

## 10. Rev 1.1 → rev 1.2

| Change | Where |
|---|---|
| F8: the loops' phase offsets are Outside (checked with `findReferences` first); `runSync`'s fold writes are S3's named exception until K2 | §3.4 |
| K1b-3 landed as PR #853: `landRandom` is Model, `landRandomSeed` is Behavior, the `withMutableStateSync` test-hook row goes | §3.1, §3.4 |
| F6 and F7 are K1b-5's writer lists; the census test checks homes, not writers | §3.4 |
| F5 (K1-Q7 (d)) is K1b-1's: the held resolver output is plain bytes before K1b-4 moves `pendingItems` | (no change; K1b-4 needs K1b-1) |
