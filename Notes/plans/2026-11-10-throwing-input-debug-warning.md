# #87 B: validate before mutate, and a debug-only warning when a throwing input wrote state

Status: implemented (see the index). Part of #87; A (undo-log rollback) stays with step 3.

## Behaviour today (unchanged by B)

A handler that throws keeps what it wrote before the throw; the next sync sends it (`docs/core/runtime.md` § Inputs and Turns, and :433 for the in-turn path). B doesn't change this. It tells users to validate before they mutate, and in debug builds it says so when a handler didn't.

## The input paths: one choke point

Every throwing handler runs inside `LandKeeper.withMutableStateSync(_:)` (`LandKeeper.swift:3111`, `return try body(&state)`). There are 9 call sites:

Rule (agreed 2026-11-10): **warn only where the state survives the throw.** The table gives the verdict for each site.

| Site | Function | Input | What happens after a throw | Warn? | Key |
|---|---|---|---|---|---|
| :3359 | `applyPendingItem` | action (`invokeErased`) | Caller gets the error; the other inputs go on; state kept and synced (`applyInputs`) | **yes** | `action <ActionType>` |
| :3410 | `applyPendingItem` | client event (every matching handler, one closure) | Same as an action | **yes** | `event <event.type>` |
| :3440 | `applyPendingItem` | server input (every handler, one closure) | Same as an action | **yes** | `serverInput <typeIdentifier>` |
| :3523 | `applyPendingItem` | `OnJoin` | The join is discarded (`discardIfFailedJoin` removes the player's session), but its state writes stay and are synced to the other players | **yes** | `OnJoin` |
| :3546 | `applyPendingItem` | `OnLeave` | Player gone either way; state kept, broadcast-only sync follows | **yes** | `OnLeave` |
| :1045 | `performInitialization` | `OnInitialize` (live start) | Only logged: the land runs on with that state, and records and syncs it. (Only a `.failLand` *resolver* failure, earlier at :1033, tears the land down, and that happens before the handler runs) | **yes** | `OnInitialize` |
| :3503 | `applyPendingItem` | `OnInitialize` as a lifecycle item | Queued only by reevaluation replay (:4140, from recorded lifecycle events); live paths queue only `.join` and `.leave` (:1472, :1690, :2395) | no (not live) | — |
| :951 | `replayInitializeBeforeTickZero` | `OnInitialize` (reevaluation) | Reevaluation only | no (not live) | — |
| :5191 | `runDestroyHandler` | `OnDestroyWhenEmpty`, `OnFinalize` | Logged; teardown goes on. No sync or record follows, but the state is passed on: `OnFinalize` runs after `OnDestroyWhenEmpty`, and `AfterFinalize` and the deprecated `OnShutdown` get `snapshot = state` (:5128, :5138), typically to persist it | **only when a later destroy-phase handler reads the state:** for `OnDestroyWhenEmpty`, when `OnFinalize`, `AfterFinalize` or `OnShutdown` is defined; for `OnFinalize`, when `AfterFinalize` or `OnShutdown` is defined | `<name>` |

The `mode == .live` guard skips :3503 and :951 by itself. The destroy rule is one Boolean, computed from `definition.lifetimeHandlers` when `runDestroyHandler` is called. A land whose initialization failed skips its destroy handlers (:5101), so it never reaches the check.

`applyPendingItem` serves the legacy pass, the tickless input turn, the tick turn and reevaluation replay alike (`applyInputs`), so the six sites in it cover every path. `Tick` (`tickHandler?(&state, ctx)`, :4195) and the in-turn sync handler (:4373) don't throw, so they're out of scope.

**Proposal:** give `withMutableStateSync` a `check: ThrowWriteKey?` argument (a kind plus a type name) and do the check there, under `#if DEBUG`. Every site passes its key; that's one place to change and nine one-line call-site edits. There are no new paths to remember, and a future throwing handler gets the check by going through the same function.

```swift
private func withMutableStateSync<R>(_ check: ThrowWriteKey?, _ body: (inout State) throws -> R) rethrows -> R {
    #if DEBUG
    guard let check, warnsThrowingInputWrites, mode == .live, !throwWriteWarnedKeys.contains(check) else { return try body(&state) }
    let before = state                       // copy-on-write: O(1) here, see Cost
    do { return try body(&state) } catch {
        warnIfThrowWrote(check, before: before, error: error)
        throw error
    }
    #else
    return try body(&state)
    #endif
}
```

## Detection

On a throw only, compare `before.fullStateSnapshot()` with `state.fullStateSnapshot()`. `StateSnapshot` is `Equatable`, and `fullStateSnapshot` covers every synced field, nested nodes included. If they differ, the handler wrote synced state before it threw: warn. If they're equal (it threw before any write, or wrote back the same values), don't.

Why not the dirty flags (`getDirtyFields()` before and after)? It costs nothing, but it misses a write to a field another input already dirtied in the same turn, and it depends on dirty tracking being on. Use it only as a fallback if the copy's cost (below) turns out too high.

Known limits, documented:
- `@Internal` fields aren't in the snapshot, so writes to them aren't reported. This matches #464, which documents `@Internal` as excluded from the #87 warning.
- A `Float`/`Double` NaN compares unequal to itself, so the warning would fire. Deterministic-math state uses integers.
- A `fullStateSnapshot()` that throws: skip the warning and log at debug level.

## The warning

- **Level and text.** `logger.warning`, with metadata `land`, `kind`, `type`, `sequence` and `error`: "A <kind> handler for <type> threw after writing state; its writes are kept and synced. Validate before you mutate (#87). Logged once per input type in debug builds."
- **Once per input type, per keeper.** `throwWriteWarned: Set<ThrowWriteKey>` is actor state, so it needs no lock. After a key has warned, the copy is skipped for that key, so it costs nothing more. Per keeper rather than per process: a static set would let one parallel test's warning suppress another's, and in a server each land type warns per instance, which is acceptable in debug builds.
- **Live only.** Reevaluation and replay run the same recorded inputs again, so warning there would only repeat what live already said. (`:951` passes `nil`.)
- **Release builds.** The `#if DEBUG` branch is compiled out, so the code is the same as today's `return try body(&state)`.

## Tests (Swift Testing, a recording `LogHandler` like `NIOLandHostLoggerTests`')

1. **A write and then a throw warns once per type.** An action handler sets `score = 5`, then throws:
   - the caller gets the error;
   - the next sync carries `score == 5` (the documented behaviour);
   - exactly one warning names the action type.

   A second throwing call of the same action adds no warning (the count stays 1). A different action type that does the same adds its own warning (the count is 2).
2. **A throw before any write doesn't warn.** The handler validates and throws first: no warning, and the state is unchanged.
3. **A client event whose second handler throws after the first wrote** warns once. That's the multi-handler closure. A server input variant can be a parameterized case of this test, if cheap.

Mutants:
- M1: the compare always reports "equal". Tests 1 and 3 fail.
- M2: warn on every throw, without comparing. Test 2 fails.
- M3: no dedup set. Test 1's count fails.

All three tests are ordinary debug tests. The test target builds debug, so `#if DEBUG` is on there.

## Docs (both languages, same commit)

- `docs/core/runtime.md` § Inputs and Turns, plus `.zh-TW`: add after the bullet list: "Validate before you mutate: check every condition that can throw before the handler's first write. A debug build logs a warning, once per input type, when a handler threw after writing synced state (`@Internal` fields aren't checked)." The in-turn sentence at :433 gets a link to it.
- `docs/core/land-dsl.md`, plus `.zh-TW`: the `HandleAction` example (:126) shows the guard-then-mutate order, with a one-line note.
- Doc comment on `HandleAction` / `HandleEvent` / `HandleServerInput`: one line, "Throwing after a write keeps the write; validate first (#87)."
- `withMutableStateSync`'s own doc comment ("no copying", "no copying overhead") is rewritten: release builds don't copy; debug builds copy for the throw check.
- `docs/core/runtime.md:83` quotes `withMutableStateSync`'s old signature. Update it, or cut it down to the behaviour.

## Cost (debug only)

- **The copy itself is O(1).** `State` is a struct of `@Sync` wrappers, `ReactiveDictionary` and `ReactiveSet` (all value types), so `let before = state` copies inline fields and retains the container buffers.
- **The real cost is the handler's first write to each container after the copy.** The buffer isn't uniquely referenced any more, so that write copies the whole container: O(size of each container the input writes), once per input, for every input type that hasn't warned yet. That includes types that never throw, so a type that never throws pays on every input.
- **On a throw:** two `fullStateSnapshot()` calls (O(state)), at most until that type has warned.
- **Release:** zero.

Measured in debug, base against change, same toolchain and machine:
1. The debug `swift test` wall time on both sync legs. The suite's wall time is the most direct "developer cost" number.
2. A debug micro-run: 10,000 actions, each writing one entry of a 1,000-entry `[PlayerID: …]` dictionary. Compare against the base for the per-input copy cost, and report it as a ratio.

These are debug-build numbers. They describe developer cost only and don't go into any performance docs (benchmark numbers come from release builds).

If the per-input copy proves too costly for big states, there are two fallbacks:
- (a) the dirty-flag check, with no copy (it misses writes to fields already dirty that turn);
- (b) the copy taken only for the first N inputs of each type.

The exact check ships; it was measured first (results below).

**Threshold (agreed 2026-11-10).** If the debug `swift test` wall time or the micro-run grows by more than about 10 % against base, ship (b): copy only for the first N inputs of each key (N = 64 proposed; a write-then-throw past N is no longer reported for that key).

**Off switch.** `EnvKeys.Debug.warnThrowingInputWrites = "DEBUG_WARN_THROWING_INPUT_WRITES"` (named like the other `EnvKeys.Debug` keys), read at keeper init through `ThrowingInputWriteCheck.isEnabled()` (`getEnvBool`, default true). `false` turns off both the copy and the warning, for a large debug game. It's named in both languages in runtime.md, in the same paragraph as the warning. It doesn't exist in release builds, since the check is compiled out there.

Test 4: with the switch off (the keeper's injected environment, not the process's), test 1's scenario logs no warning.


### Results (2026-11-10, macOS arm64, 8 cores, debug, Apple Swift 6.4.2 on both sides)

Base is exp/next f281f12d; change is this branch. Same machine, back to back.

| Measure | Base | Change | Delta |
|---|---|---|---|
| Micro-run, 1,000-entry dictionary: 10k actions, best of 3, median of 3 runs | 0.392 s | 0.411 s | +4.8 % |
| Micro-run, 10,000-entry dictionary | 0.938 s | 0.946 s | +0.9 % |
| `swift test` wall, in-turn, warm (runs 2–3) | 8.58 / 8.56 s | 8.66 / 8.59 s | +0.6 % |
| `swift test` wall, `IN_TURN_SYNC=false`, warm | 8.42 / 8.31 s | 8.51 / 8.40 s | +1.1 % |

Every measure is under the 10 % threshold, so (b) isn't needed. These are debug-build numbers. They describe a developer's cost only and don't go into the performance docs.

## Out of scope

- Rollback (A, step 3).
- Making a throw discard writes.
- Changing what a throwing input sends to its caller.
- `@Internal` coverage.
- Release-build checks.
