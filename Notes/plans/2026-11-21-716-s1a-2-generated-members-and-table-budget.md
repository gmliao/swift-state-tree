# #716 S1a-2: the budget through generated members and the sync tables

Rev 1, plan for review. Parent: [Deep or cyclic values fail fast](2026-11-21-deep-values-fail-fast.md) (§3.1, §3.1a design 1, §3.3, §4 S1a). Base: main at 397acea0 (#735 merged).

## 1. Why: two paths #735 left unbounded

#735 (S1a-1) carries a `NestingBudget` through `SnapshotValue.make`, `makeFull` and `broadcastView`, and adds budget-aware requirements whose defaults check the result tree afterwards. Two paths still recurse without a bound:

- **Generated members restart the count.** `@StateNodeBuilder`'s `snapshot(for:)`, `broadcastSnapshot`, `snapshotForSync` and `fullStateSnapshot`, and `@SnapshotConvertible`'s `toSnapshotValue` and `toFullSnapshotValue`, convert each field with the root budget. The defaults check the returned tree only after the conversion ran, so a chain of nested nodes recurses to its full depth before it is refused. That is S0's binding row: debug `make` over nodes overflows at 34 levels on a 544 KiB stack (#716, S0 results).
- **The sync tables, the default path, never take the budget.** A row converts through `broadcastView(of: row)` from the root budget, and a diff's descent spends nothing. Measured on #735's head: with tables on, a recursive node type grown one level per tick reached 40 levels (80 containers) and was never refused. With tables off it was refused at 16 levels. A fresh chain shows a constant gap of 2 (#716, comment 7061566268).

There are two further gaps, also named on #735:
- `make`'s typed-collection fast paths (`as? [SnapshotValue]`, `[String]` and so on) cast element by element, so an `Optional<Any>` chain inside an `[Any]` is unwrapped by the runtime before a hop can refuse it.
- `AnyHashable(NSNull())` now throws `unsupportedValue` where it used to convert to `.null`, and no test pins that.

## 2. Proposed split

S1a-2 is two PRs, so each one is reviewable on its own:

- **S1a-2a: generated members, static bounds, fast paths.** Macro and `SnapshotValue` changes. No SyncTables change beyond the `SyncTableField.make` overloads the macro calls.
- **S1a-2b: the sync tables' path budget.** `SyncDiffPosition` carries the budget, and every descent and row conversion spends from it. It builds on 2a's `SyncTableField.make` overloads.

S1a-3 (the refusal path, §3.4) and S1a-4 (frame shapes, `payloadMaxDepth`, R6, the #720 nits) follow, as agreed.

## 3. S1a-2a

1. **`@StateNodeBuilder`** generates the four budget-aware requirements, with today's bodies and every conversion taking the budget:
   - `generateConversionCode` appends `budget: budget` to every `make` call (primitives are unchanged);
   - the `broadcastView(of: node)` lines in `snapshotForSync` pass the budget;
   - `fullStateSnapshot(budget:)` calls `makeFull(from:budget:)`;
   - the old signatures forward with `NestingBudget()`. The root node's own object stays outside the budget. A nested node's object is spent by its caller (`make`'s `enteringContainer()`, `broadcastView(of:budget:)`).
2. **`@SnapshotConvertible`** generates `toSnapshotValue(budget:)` and `toFullSnapshotValue(budget:)`. They take `let inner = try budget.enteringContainer()`, and each property converts within `inner`. The old signatures forward with `NestingBudget()`.
3. **`SyncTableField.make`** gains the budget-taking overloads of §3.3 (`convert: (V, NestingBudget) throws -> SnapshotValue`). The macro's `_syncTableFields` and `_syncTablePerPlayerFields` call them. In 2a the tables still pass the slot's start budget; 2b passes the position's.
4. **Static bounds**, as §3.1a design 1 and §4 S1a list them: `_StaticNestingBound`, `_NestingBound` and `_NestingBoundContext`. Also:
   - the conformances on `Optional`, `Array`, `Set` and `Dictionary`, and the explicit ones on `IVec2`, `IVec3` and the ID types;
   - the generated `_nestingBound(_:)` and `_checkNesting(budget:)`. `@StateNodeBuilder` owns them when both macros are present;
   - the registration diagnostic.
   - `_checkNesting` isn't called by the keeper yet; S1b calls it.
5. **Fast paths match an exact dynamic type.** `make`'s typed-collection fast paths run only when `Swift.type(of: value)` is exactly that collection type. Anything else falls through to the `[String: Any]`, `[PlayerID: Any]` or Mirror paths, whose output is the same.
6. **Docs on the requirements.** Each budget-aware requirement's documentation says that a hand-written override may ignore its budget, so that conversion is bounded only by the result check at its caller (§3.3, "Hand-written nodes").

Tests:
- **Macro expansions.** The goldens in `StateNodeBuilderMacroTests`, `StateNodeBuilderContainerTypeTests`, `StateNodeBuilderSnapshotDecodeTests` and `SnapshotConvertibleMacroTests` gain the budget members and arguments.
- **In process, at the limit.** A node chain at the limit converts, and one level more is refused, through each of the four members and through `toSnapshotValue(budget:)`. The refusal must come from the conversion, not from a result check: a counter on the defaults' result check stays at zero on the generated path.
- **Exit test.** A 100 000-node chain is built iteratively, and the test exits before releasing it. It must be refused with `.containers` through `make`, `makeFull` and `snapshotForSync`. Its removed-guard mutant runs on Linux, through the cloud worker.
- **Static bounds.** Each explicit conformance is checked against its conversion, and `_checkNesting` agrees with the budgeted conversion on every test shape. Mutant: a bound raised by one fails its test.
- **An `Optional<Any>` chain inside an `[Any]`.** It is refused with `.hops`: in process at a small hop budget, and in an exit test at 100 000.
- **`AnyHashable(NSNull())`** throws `unsupportedValue`.

## 4. S1a-2b

1. **`SyncDiffPosition` gains `budget`**: the budget at the value the position addresses, before it is entered. A root field's position starts at `NestingBudget()`.
2. **Every descent spends.** `SyncNodeDiffer.diff` and the node-map differ take `let inner = try position.budget.enteringContainer()` and descend with `inner`. So the descent itself refuses past the limit.
3. **Every conversion takes the position's budget**:
   - row creation and replacement (`SyncTables.swift` :787, :878, :947, :1395);
   - the root slots' `differ.convert` (:1257 to :1352);
   - `lastSentSnapshot`'s cached-value conversions (:1262, :1321), from their slot's start;
   - seeding (first sync, reseed), which walks the same differs and so inherits the bound.
4. **Refusal surfacing.** A `nestingTooDeep` from a diff ends the land with `syncConversion` and the field, as on the path without tables. Where that needs §3.4's mapping, 2b adds only what its own tests need, and S1a-3 does the rest.

Tests, on both legs (the default and `USE_SYNC_TABLES=false`, which CI's `build (variants)` runs):
- **Parity at the boundary.** A fresh chain of 15 levels converts and 16 is refused. `PackDepthTests`' refused case moves from `stateMaxDepth / 2 + 1` (17) to `stateMaxDepth / 2` (16).
- **The grown chain.** Grown a level per tick, it is refused at 16 levels on both legs. Today, with tables on, it isn't refused at 40.
- **A deep row added under a deep path** is refused by the diff's descent, not after a row conversion. A counter on row conversions shows none ran past the limit.

## 5. Benchmark

One EncodingBenchmark A/B, at S1a-2b's head against main at 15f87772 (before #735). It measures S1a-1, S1a-2a and S1a-2b together: the per-call unwrap cast, the budget in the generated members, and the budget in the table descent. It runs through a host brief. If 2b lands more than a day after 2a, Main runs an A/B at 2a's head first (the rule agreed for S1a-1).

## 6. Verification for each PR

- On the Mac, holding the slot: debug and release builds, the touched suites, and the Mac-safe mutants. No overflow runs on the Mac.
- Linux CI, every job green, `build (variants)` included.
- The Linux-only mutants (removed guards, which crash an exit test's child), through the cloud worker.

## 7. Open questions for Review

1. Split S1a-2 into 2a and 2b as above, or one PR?
2. In 2b, carry the budget on `SyncDiffPosition` or as a separate `diff` parameter? `SyncDiffPosition` already travels to every descent, so this plan carries it there. The cost is a 4-`Int` struct copied per descent, which the A/B measures.
3. Is one A/B at 2b's head enough (§5)?
