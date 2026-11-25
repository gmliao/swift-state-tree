# K1b-4: `KeeperModel<State>` and `KeeperBehavior<State>`, with the census test (#700)

**Status:** rev 1, plan only, a draft. It was read at #835's head 5baa1887 (K1a), without the LSP, and #834's head 636dd69e (P4-1) for `StateNodeProtocol: PlainData`.
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
    let config: LandConfig        // autoStartLoops, enableLoopPhaseOffset, … , serverInputMaxInFlight, landRandomSeed
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
  private func withHandlerStep<R>(_ ctx: LandContext, _ body: (inout KeeperModel<State>, LandContext) throws -> R) rethrows -> R
  ```
  It gives the body `&model`, and the body calls the handler with `&m.state`. That is the shape K1b-5's turn bodies take anyway.
- **Checked at 5baa1887.** The nine `withMutableStateSync` bodies touch no other keeper field. The handlers' context closures (`emitEventHandler`, `requestSyncNow…`) write `outputCollector`, a separate class, not the actor. Hence §3.3.
- **Test.** Each handler kind runs once under a debug build, which already has dynamic enforcement: `swift test`'s suites cover them. A mutant in §6 moves one read inside the access.

### 3.3 Deviations from Appendix A (for Review)

- **D1: `outputCollector` stays a class until K2.** A.1 splits its plain fields (`nextSequence`, `checksOverflow`, `sequenceExhausted`, `syncRequestsByTick`) into Model.
  - But the handler's context closures write them during the handler, while `&model` is held. Moving them into Model now would turn every `ctx.emit` into an exclusivity trap.
  - K2 stages outputs in the step's output (§3.6), and that is when they can move.
  - K1b-4 lists the collector as Outside with "K2" in the census test's exception list.
- **D2: the replay group.** A.5's fields become one `struct ReplayFields` on the actor (`var replay: ReplayFields?` or non-optional with defaults; rev 2 picks one by reading the replay entry points). `replayPassObserver` is a closure, so `ReplayFields` isn't `PlainData`, and it doesn't have to be (A.5).

### 3.4 The census test (`Tests/SwiftStateTreeTests/KeeperCensusTests.swift`)

- **The names.** `Mirror(reflecting: keeper).children` lists the actor's stored properties. The test also reflects `keeper.model` and `keeper.behavior` through test accessors. A table in the test gives each name exactly one home: Model, Behavior, Outside(K2…K9), Replay or TestHook. The test fails when:
  - a stored name is missing from the table (a new field must be placed);
  - a table name is no longer stored (a stale row);
  - a name appears in two homes.
- **The known exceptions,** each with the slice that ends it: F4's `Instant`s (K2), S3's sync-loop writer (K2), D1's collector (K2).
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
- **D1 and D2** (§3.3).
- The LSP census, and the exact list of the census test's exceptions.
