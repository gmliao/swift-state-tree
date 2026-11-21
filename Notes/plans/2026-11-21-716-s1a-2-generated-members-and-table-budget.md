# #716 S1a-2: the budget through generated members and the sync tables

Rev 2, for review (a37151e7, with §3.3's conformance bullets corrected). Rev 1 (04fff7e8) was NOT GO, with two must-fixes and three shoulds; §8 lists how rev 2 answers each. Parent: [Deep or cyclic values fail fast](2026-11-21-deep-values-fail-fast.md) (§3.1, §3.3, §4 S1a). Base: main at 397acea0 (#735 merged).

## 1. Why: two paths #735 left unbounded

#735 (S1a-1) carries a `NestingBudget` through `SnapshotValue.make`, `makeFull` and `broadcastView`. It also adds budget-aware requirements whose defaults check the result tree afterwards. Two paths still recurse without a bound:

- **Generated members restart the count.** These members convert each field with the root budget:
  - `@StateNodeBuilder`'s `snapshot(for:)`, `broadcastSnapshot`, `snapshotForSync` and `fullStateSnapshot`;
  - `@SnapshotConvertible`'s `toSnapshotValue` and `toFullSnapshotValue`.

  The defaults check the returned tree only after the conversion ran, so a chain of nested nodes recurses to its full depth before it is refused. That is S0's binding row: debug `make` over nodes overflows at 34 levels on a 544 KiB stack (#716, S0 results).
- **The sync tables, the default path, never take the budget.** A row converts through `broadcastView(of: row)` from the root budget, and a diff's descent spends nothing. Measured on #735's head:
  - with tables on, a recursive node type grown one level per tick reached 40 levels (80 containers) and was never refused;
  - with tables off, it was refused at 16 levels;
  - a fresh chain shows a constant gap of 2 (#716, comment 7061566268).

Two further gaps were named on #735:
- `make`'s typed-collection fast paths cast element by element, so an `Optional<Any>` chain inside an `[Any]` is unwrapped by the runtime before a hop can refuse it.
- `AnyHashable(NSNull())` now throws `unsupportedValue` where it used to convert to `.null`, and no test pins that.

## 2. Split and order

S1a-2 is two PRs, 2a then 2b, with 2b following 2a directly:

- **S1a-2a: the budget through the generated members, and the collection fast paths.** Macro and `SnapshotValue` changes only.
- **S1a-2b: the sync tables' path budget.** `SyncDiffPosition` carries the budget, and every descent and row conversion spends from it.

**Why 2a comes first.** 2b alone doesn't bound a row that holds nested nodes. A row converts through `broadcastView(of: row, budget:)`, which calls the node's generated member. Until 2a, that member converts its fields through `make` with the root budget, so the count restarts below every row. 2b's path budget reaches only as deep as the first generated member below it, until 2a has landed.

**The static bounds move out of S1a-2.** These are `_StaticNestingBound`, `_NestingBound`, `_NestingBoundContext`, their conformances, the generated `_nestingBound(_:)` and `_checkNesting(budget:)`, and the registration diagnostic. They go to S1b, with the per-turn preflight that calls them. That leaves 2a's A/B measuring only the budget in the generated members and the fast paths. The parent plan's §4 S1a list is amended accordingly when 2a merges.

S1a-3 follows, as agreed: the refusal path, §3.4. So does S1a-4: frame shapes, `payloadMaxDepth`, R6 and the #720 nits.

## 3. S1a-2a

1. **`@StateNodeBuilder`** generates the four budget-aware requirements. Each keeps today's body, with every conversion taking the budget:
   - every `make` call in `generateConversionCode` takes `budget: budget` (primitives are unchanged);
   - the `broadcastView(of: node)` lines in `snapshotForSync` pass the budget;
   - `fullStateSnapshot(budget:)` calls `makeFull(from:budget:)`.

   The old signatures forward with `NestingBudget()`. The root node's own object stays outside the budget. A nested node's object is spent by its caller: `make`'s `enteringContainer()`, or `broadcastView(of:budget:)`. The typed tables' `convert` closures (`_syncTableFields`, `_syncTablePerPlayerFields`) are unchanged in 2a. They call `make` and `broadcastView` without a budget, which start from the root budget, and 2b changes them.
2. **`@SnapshotConvertible`** generates `toSnapshotValue(budget:)` and `toFullSnapshotValue(budget:)`. Each starts with `let inner = try budget.enteringContainer()` (an empty struct still spends it, as `check` counts its `.object`), and each property converts within `inner`. The old signatures forward with `NestingBudget()`.
3. **The collection fast paths, by conformance.**
   - **The problem.** `make` matches `[PlayerID: SnapshotValueConvertible]`, `[PlayerID: any StateNodeProtocol]` and `[String: SnapshotValueConvertible]` (`SnapshotValue.swift` :346, :355, :369) with an existential collection cast. That cast converts each element, so an `[Any]` or `[String: Any]` holding an `Optional<Any>` chain is unwrapped by the runtime, with no hop counted. Matching only the exact dynamic type would fix that, but a concrete `[PlayerID: PlayerState]` never has exactly that type. Every such field would then go through the `[PlayerID: Any]` cast on each sync, which boxes each value before `make` dispatches it again. The output is the same, but the fast path is lost.
   - **The design.** It follows Codable's `extension Array: Encodable where Element: Encodable`: conditional conformances, checked once on the type's metadata, never element by element.
     - A package `_SnapshotMapKey` gives a key's wire string. `PlayerID` and `String` conform to it.
     - Two package protocols, one per element kind. Swift allows only one conditional conformance of `Dictionary` to a given protocol, so one protocol can't cover both kinds:
       - `_SnapshotConvertibleMap`, on `Dictionary where Key: _SnapshotMapKey, Value: SnapshotValueConvertible`;
       - `_StateNodeMap`, on `Dictionary where Key: _SnapshotMapKey, Value: StateNodeProtocol`.

       Today's node-map fast path takes only `PlayerID` keys (:355). With `String` keys it also catches `[String: N]` of nodes, which today goes through `[String: Any]`; the output is the same, since each value still goes through `make`.
     - Each protocol has one requirement. It converts the collection's elements within a budget, calling `make` on each element, so the `StateNodeProtocol`-first order (#175) holds.
     - `make` tries `value as? any _StateNodeMap` first, and then `value as? any _SnapshotConvertibleMap`. An `[Any]` or `[String: Any]` fails both at once, since `Any` doesn't conform, and falls through to the `[String: Any]` and `[PlayerID: Any]` casts. Those convert each element to `Any`, which never unwraps an `Optional`. A static `[String: any SnapshotValueConvertible]` fails both too, since an existential doesn't conform to its own protocol, and takes the same fallback. `@Sync` refuses `any P`, so that shape comes only from a hand-written conversion.
   - **Concrete element types match the exact dynamic type:** `[SnapshotValue]`, `[String: SnapshotValue]`, `[PlayerID: SnapshotValue]`, `[String]` and `[Int]` (:304 to :338), through `Swift.type(of: value) == [String].self` and the like.
   - **`makeFull`** has only the `[String: Any]` and `[PlayerID: Any]` casts (:622, :631), so it needs no change.
4. **Docs on the requirements.** Each budget-aware requirement's documentation says that a hand-written override may ignore its budget, so that conversion is bounded only by the result check at its caller (parent §3.3, "Hand-written nodes").

Tests:
- **Macro expansions.** The goldens in `StateNodeBuilderMacroTests`, `StateNodeBuilderContainerTypeTests`, `StateNodeBuilderSnapshotDecodeTests` and `SnapshotConvertibleMacroTests` gain the budget members and arguments.
- **In process, at the limit.** A node chain at the limit converts, and one level more is refused, through each of the four members and through `toSnapshotValue(budget:)`. The refusal must come from the conversion, not from a result check: a counter on the defaults' result check stays at zero on the generated path.
- **Exit test.** A 100 000-node chain is built iteratively, and the test exits before releasing it. It must be refused with `.containers` through `make`, `makeFull` and `snapshotForSync`. Its removed-guard mutant runs on Linux, through the cloud worker.
- **Fast-path output equality.** Old and new produce equal output over every shape the old fast paths caught:
  - `[PlayerID: T]` and `[String: T]` of `@SnapshotConvertible` structs;
  - `[PlayerID: N]` of state nodes, with `for:` a player and without (refused when player-dependent, #179);
  - a type that is both node and convertible (`PlayerState`'s shape), converted as a node;
  - `[PlayerID: SnapshotValue]`, `[String: SnapshotValue]`, `[SnapshotValue]`, `[String]` and `[Int]`;
  - NFC keys;
  - colliding keys.

  "Old" is a test-local copy of today's casts.
- **The fast path is taken.** A DEBUG counter on each conformance branch shows that `[PlayerID: PlayerState]` takes `_StateNodeMap`, not the `[PlayerID: Any]` fallback.
- **An `Optional<Any>` chain inside an `[Any]` and a `[String: Any]`.** It is refused with `.hops`: in process at a small hop budget, and in an exit test at 100 000.
- **`AnyHashable(NSNull())`** throws `unsupportedValue`.

## 4. S1a-2b

1. **`SyncDiffPosition` gains `budget`**: the budget at the value the position addresses, before it is entered. A root field's position starts at `NestingBudget()`.
2. **Every descent spends.** `SyncNodeDiffer.diff` and the node-map differ take `let inner = try position.budget.enteringContainer()` and descend with `inner`. So the descent itself refuses past the limit.
3. **Every conversion takes the position's budget**:
   - row creation and replacement (`SyncTables.swift` :787, :878, :947, :1395);
   - the root slots' `differ.convert` (:1257 to :1352);
   - `lastSentSnapshot`'s cached-value conversions (:1262, :1321), from their slot's start;
   - seeding (first sync, reseed), which walks the same differs and so inherits the bound.

   The typed tables' `convert` closures take the budget through the `SyncTableField.make` overloads of parent §3.3: `convert: (V, NestingBudget) throws -> SnapshotValue`. The macro's `_syncTableFields` and `_syncTablePerPlayerFields` call them.
4. **A refusal mid-diff leaves the tables consistent** (fail fast; the #262 and #273 class):
   - no row is left half created: a row is inserted into its table only after its conversion and its descent succeeded;
   - the patches the sync had already emitted are dropped with the land's failure, so no client receives part of a diff;
   - the land ends with `syncConversion` and the field, as on the path without tables. Where that needs parent §3.4's mapping, 2b adds only what its own tests need, and S1a-3 does the rest.

Tests, on both legs (the default and `USE_SYNC_TABLES=false`, which CI's `build (variants)` runs):
- **Parity at the boundary.** A fresh chain of 15 levels converts and 16 is refused. `PackDepthTests`' refused case moves from `stateMaxDepth / 2 + 1` (17) to `stateMaxDepth / 2` (16).
- **The grown chain.** Grown a level per tick, it is refused at 16 levels on both legs. Today, with tables on, it isn't refused at 40.
- **A deep row added under a deep path** is refused by the diff's descent, not after a row conversion. A counter on row conversions shows none ran past the limit.
- **Consistency after a refusal.** A refused deep row leaves no row in its table and sends no patch. This holds on an ordinary diff, on a first sync, and on a reseed.

## 5. Public API

For Main's approval. Each new or changed symbol, with its access level:

| Symbol | PR | Access | Why |
|---|---|---|---|
| Generated `snapshot(for:dirtyFields:budget:)`, `broadcastSnapshot(dirtyFields:budget:)`, `snapshotForSync(playerIDs:dirtyFields:budget:)`, `fullStateSnapshot(budget:)` | 2a | public | They implement `StateNodeProtocol` requirements that are public since #735; generated in the adopter's module |
| Generated `toSnapshotValue(budget:)`, `toFullSnapshotValue(budget:)` | 2a | public | Implement the public requirements added in #735 |
| The generated root-budget forwarders (the old signatures) | 2a | public | Unchanged signatures; only their bodies change |
| `_StateNodeMap`, `_SnapshotConvertibleMap`, `_SnapshotMapKey`, and the conditional conformances of `Dictionary`, `PlayerID` and `String` | 2a | package | Called only by `make`, inside SwiftStateTree. A conformance to a package protocol doesn't extend the public API |
| Documentation of the six budget-aware requirements (the hand-written override note) | 2a | public docs | No signature change |
| `SyncTableField.make` overloads with `convert: (V, NestingBudget) throws -> SnapshotValue` | 2b | public | Called by macro expansions in the adopter's module, like today's four overloads |
| `SyncDiffPosition.budget` | 2b | internal | `SyncDiffPosition` is internal |

No public symbol is removed or renamed. `NestingBudget` stays as #735 made it: public, with a public root initializer and a package `init(containers:hops:)`. The static-bound symbols (`_StaticNestingBound` and the rest) go to S1b's API section.

## 6. Benchmark

| Run | Head | Base | Tier |
|---|---|---|---|
| 2a | 2a's head | main at 2a's base | the small tier (Mac EncodingBenchmark; host only if beyond the noise) |
| 2b | 2b's head | 2a's head | as above |
| Summary row | 2b's head | 15f87772 (before #735) | the combined cost of S1a-1, 2a and 2b |

## 7. Verification for each PR

- On the Mac, holding the slot: debug and release builds, the touched suites, and the Mac-safe mutants. No overflow runs on the Mac.
- Linux CI, every job green, `build (variants)` included.
- The Linux-only mutants (removed guards, which crash an exit test's child), through the cloud worker.

## 8. Review of rev 1: what rev 2 changed

- **MF1, the fast paths.** Exact-type matching is kept only for concrete element types. Typed maps of convertibles and of nodes match by conditional conformance instead (§3.3). The equality and fast-path tests are listed with it.
  - A precision on rev 1's effect: an existential map that missed the exact type would have fallen to the `[PlayerID: Any]` or `[String: Any]` cast, not to Mirror. The output was the same, and the cost was a boxing cast per sync.
  - Two protocols are needed: Swift allows only one conditional conformance of `Dictionary` to a given protocol.
- **MF2, the public API.** §5.
- **Should 1.** The static bounds move to S1b (§2).
- **Should 2.** §2 states why 2a comes first, and that 2b follows directly.
- **Should 3.** §4.4 covers consistency after a refusal, with its test.
- **§7 answers.** Folded in:
  - 2a then 2b;
  - the budget on `SyncDiffPosition`;
  - an A/B per PR plus the summary row (§6).
