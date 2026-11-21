# Deep or cyclic values fail fast instead of overflowing the stack (#716)

Rev 6, 2026-11-21. Plan only: no code until Review's GO. Code pointers are at main 7170a8e3, the current code; no source file changed since a7ed4d2b. Where the plan describes the code after L2d-3, it says so: that shape is projected, not current.

Rev 3 answered the parts of Review's NOT GO on rev 2 that don't depend on where the full check runs (the public API facts, prebuilt trees, the hop counter, the typed refusal's path, and the shoulds). Rev 4 adds what the maintainer's order d-716 decided: **one depth preflight per turn, at the end of the apply segment** (§3.1a). That closes rev 2's must-fixes 1 (the fields the check covers), 6 (how replay detects a refusal) and 7 (the hash sites). d-716 also asked for the preflight's cost to be compared across three designs. §3.1a compares them and picks one.

Review on rev 3 and 4 returned NOT GO, with 6 must-fixes. Rev 5 answers them:
- The preflight is called right after each apply returns, in one keeper function, at every apply segment (§3.1a).
- A check bit, not the dirty flag, selects the fields it walks (§3.1a).
- The static bound is a pair of containers and hops, and proves the conversion that runs (§3.1a, design 1).
- Replay stops at the refusal (§3.6).
- The remaining refusal sites are mapped, and the error names its root field (§3.4).
- The preflight's failure has a stage of its own (§3.4).

Rev 5 also folds in two other inputs:
- The roadmap fit: S1 is split into S1a, which can land any time, and S1b, which lands after L2d-3 (§4). It also states the rule #700 must keep (§4).
- Two items from Review's verdict on the #696/#704 plan: the end-of-apply function runs the noted transport failure first, and one rule covers the callers of a turn that ends after its apply (§3.1a, Q5).

Review on rev 5 returned NOT GO, with 5 must-fixes. Rev 6 answers them:
- An initialize refusal still records a replayable initialize (§3.1a).
- In `runInputTurn`, `finishApply()` runs after the pass ordinal is taken, so a refusal's position names its pass (§3.1a).
- Replay stops inside the keeper, and each runner checks at its own points; `finishApply()` returns an enum (§3.1a, §3.6).
- The nesting limits get a record minor of their own; the oldest replayable record stays 3.6 (§3.6).
- The callers of a turn that ends get `landClosed`, as the maintainer decided (§3.1a, §5 Q5).

It also takes the shoulds and nits of that verdict, which are listed where they apply.

Q1–Q5 and d-716 are maintainer orders, all decided 2026-11-21 (§5).

**Baseline.** #697's packer bound, which this plan keeps as the last check, merged as af666b40 (#720). S0 can run now. S1a and S2 build on main any time. S1b builds on main after L2d-3 (#546) has merged. Each PR names the main commit it starts from.

## 1. Problem

A value that nests too deep, or a cycle through a class, overflows the thread's stack in a recursive stage before any bound refuses it. The process dies (SIGBUS) and every land on it goes with it. The rule this plan applies (`Notes/solutions/2026-11-18-a-parsers-depth-limit-isnt-the-pipelines.md`): every recursive stage needs a bound it can walk on the smallest stack it runs on (Darwin's cooperative pool, 544 KiB), and a value past the bound fails the land, never the process.

Measured in #697 (issue comment on #716): a chain of nested `@StateNodeBuilder` nodes, 2 containers per level, overflows in `SnapshotValue.make` at 28 levels in a debug build on macOS (26 syncs). In release, 28 syncs and 34 reaches the packer (`syncEncode`). The packer's 64 (#697) is never reached by nested-node state in debug.

## 2. The recursive stages

Each stage is either bounded by the count (§3.1: its input is a value the count already accepted, so its recursion is at most the limit deep), bounded by its own guard, or out of scope. S0 measures the bytes per level of every stage marked "count", so the limit leaves room for the deepest of them.

| # | Stage | Where | Runs on | Bound after this plan |
|---|---|---|---|---|
| R1 | Client view of state | `SnapshotValue.make(from:for:)` (public, `SnapshotValue.swift:227`), `broadcastView(of:)` (public, :455), the macro's `snapshot(for:dirtyFields:)`, `broadcastSnapshot`, `snapshotForSync` | keeper, sync phase (also a joiner's first sync and a resync) | the count |
| R2 | Typed sync diff | `SyncNodeDiffer`, `SyncOptionalNodeDiffer`, `SyncNodeMapDiffer.diffRows`, the row and fallback paths of `SyncTables` (the `convert` closures that `SyncTableField.make` takes), `SyncTables.viewPatches` (:1755) | keeper, sync phase | the count |
| R3 | Full state | `SnapshotValue.makeFull` (public, :509), `fullStateSnapshot()`, `toFullSnapshotValue()` (`@SnapshotConvertible`); the hash in `LandKeeper.liveStateHash` (:4977) and `ReevaluationEngine.calculateStateHashAndSnapshot` (:534) | keeper (recording), replay, the monitor runner | the count |
| R3a | Set ordering inside `makeFull` (:562) | JSON-encodes each converted element to sort | as R3 | the count (it encodes the converted `SnapshotValue`, which the count accepted) |
| R4 | Hand-written `toSnapshotValue()` / `snapshot(for:dirtyFields:)` | the adopter's code | as R1 | its returned tree is checked by an iterative walk (§3.3); recursion inside the adopter's code is the adopter's, documented (§3.3) |
| R5 | Payload fallback encode | `MessagePackDirectEncoder`, `MessagePackValueEncoder` boxing (re-enters the direct encoder), `AnyCodable.encode(to:)` | keeper / adapter | a depth count through both encoders, carried across the re-entry (§3.5) |
| R5j | JSON payload encode | `JSONEncoder` (`TransportCodec.swift:58`) | adapter | registration only (§3.5); a cycle hidden from registration is out of scope, documented |
| R6 | Event digests | `SnapshotValue.make` on an event payload: the sync-stream canonical form (`SyncStreamCanonical.swift:12`) and the output verifier (`SyncOutputVerifier.swift:300`), both `try?` today | keeper (recording), replay | the count, with the payload budget (§3.2, §3.5) |
| R7 | Value walks after conversion | `SnapshotValue` → `MessagePackValue` (and the atomic positional conversion), the JSON state encoders through `SnapshotValue.encode(to:)`, the sync-digest hash walk, the replay `SnapshotPatchApplier` | adapter, keeper, replay | the count (inputs are counted values) |
| R8 | Wire | the packer and unpackers | adapter | 64 (#697), 32 for client frames (#595) |
| R9 | Record codec | `CanonicalMessagePack` (`Support/CanonicalMessagePack.swift`, `maxDepth` 128) | recorder, replay | today it builds its tree recursively before its own 128 check; S2 makes the check run while it builds (§3.5), and S0 measures its stack at 128 |
| R10 | Client decode | `AnyCodable` decode of client input | adapter | the unpacker's 32 (#595) runs first |
| — | Schema extraction | type metadata, not values | build/registration | out of scope (types, not values); S0 confirms it ends on a recursive type |
| — | TS SDK | its recursive value decode and resync reconcile | browser / Node | out of scope for the Swift change; S3 adds an SDK test at the limit |

S0 still places two more before S1a: how a land's save encodes state, and the SDK's own patch apply.

## 3. Design

### 3.1 The counted tree

**The limit is on the full value of each `@Sync` field, regardless of its policy, and on every value a conversion produces.** Rev 2 claimed that no view is deeper than the full value. That is false. `.custom((PlayerID, Value) -> Value?)` (`SyncPolicy.swift:39`), `.perPlayer` and `.masked` return a replacement value, and it can be deeper than the stored one. So the guarantee rests on two rules:
- every conversion counts what it walks, the view's replacement value included, and refuses past the limit;
- a full check covers what no view walks (the per-turn preflight, §3.1a).

Definitions:
- A field's depth is the number of containers (objects and arrays of the converted value, as the unpacker counts them) on the deepest path of its value. The field's own value counts as level 1 when it is a container. A scalar field has depth 0.
- **The synthetic root** (the snapshot object holding the fields) is not counted. It belongs to every frame shape's overhead (§3.2). So a whole-snapshot pass and `SyncEngine`'s single-field retry (`extractDroppingThrowingFields`, `SyncEngine.swift:1526`) start each field at the same budget and refuse the same values.
- A conversion that starts below the field starts with the budget left at its value: the limit minus the containers above that value. Which containers those are is fixed per slot kind, not read from the path's component count:
  - A root fallback slot (`SyncSnapshotRootSlot`, `SyncTables.swift:1482`, path `/field`) converts the field's value itself, so it starts at the full limit.
  - A row of a root node map (`viewPatches`' row loop, `SyncTables.swift:1389-1397`, path `/field/key`) converts a value inside the map object, so it starts at limit − 1.
  - Both paths have one component above the value, so "the slot's path depth" would be off by one for one of them. S1a gives each slot kind its start as a constant, with a fixture each.

**Hops that add no container** get their own counter. Some recursion costs a stack frame but no container:
- an optional unwrap through `Mirror`;
- a property wrapper;
- a hop through `Any`;
- a node's `snapshot` calling `make` on the node's own value.

A chain of `Optional<ChildNode>` costs about four calls per container level: node `snapshot` → `make(Optional)` → Mirror unwrap → `make(Child)` → child `snapshot`. So a single call count would refuse a legal tree at the limit. The carrier (§3.3) therefore counts:
- containers, against `stateMaxDepth`;
- separately, the hops that add no container, against `stateMaxHops`.

S0 sizes `stateMaxHops` from its wrapper-only stack measurement. A value past it is refused with the same error, `SyncError.nestingTooDeep`, whose reason says which counter ran out (§3.4). A fixture with `Optional<Node>` at every level up to `stateMaxDepth` must pass.

**Prebuilt trees.** `make` and `makeFull` return early when the value is already a `SnapshotValue`, a `StateSnapshot`, a `[SnapshotValue]`, or a `[String: SnapshotValue]` / `[PlayerID: SnapshotValue]`. The branches are at `SnapshotValue.swift:229-234`, :260-281 and :510-515. A `@Sync` field of such a type never reaches a protocol default, so those branches run the same iterative check (an explicit stack, against the budget left) before they return. Limit, documented: when the last reference to a very deep indirect tree goes away, releasing it recurses in its deinit. A prebuilt tree deep enough to overflow on release is outside what the count can save. A child-process test pins the release of a tree just past the limit, after its refusal.

**A non-depth error in a full conversion** (colliding keys, for example) can stop `makeFull` before it reaches a deep branch. It fails the land as today, with `syncConversion`, through the same path (§3.4). A refused value stays refused whichever error comes first, so the outcome is deterministic. The reason in the failure names the first error.

**Where the full value is checked:** the per-turn preflight (§3.1a). Rev 2's rule is withdrawn: a budgeted full conversion in the sync phase of every dirty field whose policy isn't plain broadcast. It missed two cases:
- a `.broadcast` root node holding a nested `.serverOnly`, per-player or masked sub-field, whose broadcast view leaves out the deep part;
- an initial value, because `Sync.init` starts clean (`SyncPolicy.swift:174`, `_isDirty = false`), so it is never dirty.

Rev 4 then selected the fields by their dirty flag, which misses more (§3.1a). Rev 5 selects them by a check bit.

### 3.1a The per-turn preflight (d-716)

**One keeper function at the end of apply.** `finishApply() -> ApplyEnd` runs once, right after each apply segment returns. That is before anything of the turn goes out: its events, its sync phase, and its record entry with the hash. `ApplyEnd` has two cases, `.proceed` and `.ended`, and the #696/#704 plan uses the same signature. It runs only when the apply hasn't already failed the land: a land that failed at an input takes today's failure branch. It does two things, in this order, and returns `.ended` when the turn must end:
1. `applyPendingTransportFailure()`, from the #696/#704 plan (`2026-11-21-closed-gate-replies-and-pending-failure.md`). A failure that an adapter noted outside the turn ends the land first.
2. `preflightNesting()`, the depth check described below.

The first `failLand` wins (`drainFlag.setFailed`), so when both apply, the noted transport failure stays the cause. Whichever of the two plans lands first adds the function, and the other adds its step to it.

Live, a refusal ends the land through `failLand`, with `syncConversion`, the field and the depth reason (§3.4, §3.6). In re-evaluation, `failLand` logs and returns (`LandKeeper.swift:5610`). So the preflight keeps its refusal on the keeper (`replayDepthRefusal`), and the function returns `.ended` there too. The callers branch on the value it returns, not on `failure`, so live and replay take the same branch.

The check runs whether or not:
- a sync is due;
- the land has members;
- the writer has back-pressure;
- recording is on.

So recording on and off fail in the same turn by construction.

**The apply segments.** The line numbers are current (7170a8e3). The set of segments is projected: it is the set left once L2d-3 (#546) has deleted the live legacy paths, live `runTick`, `processPendingActions` and `finishTicklessLegacyPass`. Each segment calls `finishApply()` unconditionally, whatever the transport, the mode or the recording. Each has its own test (§3.7).

**The off mode stays uncovered until L2d-3 deletes it.** S1b lands after L2d-3, so it adds no call to code that L2d-3 removes. Until then, a land in the off mode has no preflight.

| Segment | The call | When it returns `.ended` |
|---|---|---|
| Live initialize (LK:1193–1320) | After OnInitialize (:1255). The call moves out of `if mode == .live, let handler = onInitialize`, so a land without OnInitialize is checked too | The replayable part of the initialize is still recorded (below), with no events and no hash, then the terminal entry. No `runTurnOutputs` (:1279) and no loops started (`autoStartLoops`, :1325) |
| Replay initialize (`replayInitializeBeforeTickZero`, LK:1120) | After OnInitialize, which it runs from the recorded initialize as today. Also on the paths where today's `guard` returns early (:1121–1127): a land without OnInitialize, or a record without an initialize | No `flushOutputs` (:1148), and the replay stops (§3.6) |
| Tick turn (`runTickTurn`, LK:4827) | After `handler(&state, ctx); lastCommittedTickId = tickId` (:4858–4859), before the hash (:4864) | As the input-failure branch (:4837–4847): the events and the sync request are taken and dropped; the record keeps the inputs and both watermarks, and has no hash |
| Replay tick (`runTick`, LK:4359, which L2d keeps for replay) | After the tick handler (:4657–4663), before the hash (:4671) | As its failure branch (:4630–4638). That branch's guard (:4631) gains `replayDepthRefusal != nil`, for a tickless land too, since a refusal in a pass must also end the tick that holds it |
| Input turn (`runInputTurn`, LK:5779) | After `takePassOrdinal` (:5790), before `if failure != nil` (:5795). Called earlier, `failLand` would see no pass in progress and use the last pass (`lastPass`, LK:5596), so the position wouldn't name the refusing pass | That branch: no events and no sync. This also covers replay passes (`replayRecordedPasses` calls `runInputTurn`, LK:4218) and headless keepers, which today skip the output call under `let transport, usesInTurnSync` |
| Replay initialize items (`replayRecordedPasses`, LK:4194) | After its `applyInputs(initializeItems, …)` | The tick's passes don't run, and the replay stops (§3.6) |
| Sync-only turn (`runSyncOnlyTurn`, LK:5162) | No apply, so no `finishApply()`. It reads the noted transport failure first (#696/#704 plan) | Its phase doesn't run |

S1b lists the segments again from the code at its base. It also confirms two things there, and gives a row of its own to any path that doesn't hold:
- after L2d-3, join and leave handlers and server inputs apply only through `runInputTurn`;
- L2d-2 has moved a headless tick land onto `runTickTurn`.

The shutdown turn (:2840) changes no land state (#382), so it needs no call. `OnDestroyWhenEmpty` and `OnFinalize` run after the land's last output and aren't followed by a sync, so they are outside the guarantee. S0 decides whether either can still reach a recursive stage (the final hash), and so whether it needs a call.

**What a turn that ends here records:**
- its inputs, with their resolver outputs and its watermarks;
- the terminal entry (`failLand`, LK:5632–5635).

It records no events, no sync output and no state hash. That is what the input-failure branches record today, so replay can apply exactly that turn again.

**An initialize that ends here** still records what replay needs to run OnInitialize again. Replay runs OnInitialize only when the record holds an initialize record and an `.initialize` lifecycle entry (`replayInitializeBeforeTickZero`, LK:1121-1127). So a refused initialize records:
- the `.initialize` lifecycle entry, with its sequence and resolver outputs (as LK:1282-1300 records it today);
- an initialize record with that sequence, no server events and no state hash;
- the terminal entry, with stage `initialStateCheck`.

Replay then runs OnInitialize and calls `finishApply()`, which refuses as live did. Tests cover an OnInitialize that writes the deep value, and one that writes it and then throws (the keeper logs the throw and keeps the write, LK:1257-1261).

**The callers of a turn that ends** (maintainer decision, 2026-11-21). A turn ends the land when `finishApply()` returns `.ended` (a noted transport failure or a depth refusal), when its in-turn sync phase fails the land, or when its batch holds a transport-reported failure item (`.landFailure`, #535): `applyInputs` stops at that item and fails the land (LK:4076-4080, :4118). Then every caller whose input is in that turn's consumed batch gets `landClosed`, not its handler's outcome, and that includes a caller whose handler threw. The failure item itself has no caller: `submitLandFailure` (LK:5541) registers no waiter. No output of that turn is sent, replies included.
- **Where.** On `.ended`, the turn sets every consumed item's result to `landClosed` before `resumeInputTurnWaiters` (LK:5818-5826) resumes the callers. That covers the three places that resume them: the input drain (:5750), the replay passes (:4238), and the turn's own outcome store (:5803-5806). A tickless action job's slot (`ticklessJobTurns`, `fillActionSlot`) is filled from the same result.
- **Today's in-turn sync failure follows the rule.** A turn whose `runTurnOutputs` (:5802) fails the land keeps its outcomes today (:5806). From this change on, its callers get `landClosed` too, with a test.
- **Scope limit.**
  - A tick land acknowledges an action at submit (LK:2339). That reply belongs to the admission, not to the turn that later applies the action, so it stays.
  - A tick land's waiting join gets `landClosed` through the drain (LK:5701).
  - A turn whose batch holds a failure item is under the rule too (Main's call, 2026-11-21, for the maintainer to confirm). The inputs before the item have applied: today they keep their outcomes (:5806), and from this change on they get `landClosed`. The inputs behind it aren't consumed, and the drain drops them with `landClosed`, as today. That turn doesn't call `finishApply()`, because its apply has already failed the land; it takes the existing failure branch, which sets the results the same way.
  - This branch matters more after #704. The adapter's submit queues the failure item behind the note, so when the item is in a turn's batch, `applyInputs` reaches it before `finishApply()` reads the note. A noted failure then often ends its turn through this branch, not through `.ended`.
- **The record.** It keeps those inputs as applied, with the rejected list. A recorded input has no outcome field (`ReevaluationRecordedAction`, `ActionRecorder.swift:741-750`), so replay has no caller outcome to compare, and no mismatch can arise.
- **The test.** An input whose handler returned success, in a turn that ends, answers `landClosed`, and no frame of that turn reaches the transport. In a batch [A, a failure item, B], where A's handler returned success, A and B answer `landClosed`, and no frame of that turn reaches the transport. That test runs on a tickless land and on a tick land; on the tick land, A and B are lifecycle or server-input callers, because an action there is acknowledged at submit.

**Which fields it walks: a check bit, not the dirty flag.** The dirty flag doesn't show every new value:
- A handler gets `inout State`, and can replace a node, or the whole root, with a new value. Its `Sync`s start clean (`SyncPolicy.swift:174`).
- `updateValueWithoutMarkingDirty` (:203) and `clearDirty` (:187) are public.

So `Sync` gains a second bit, "needs a depth check":
- it is set by `Sync.init`, the setter, `_modify` and `updateValueWithoutMarkingDirty`;
- it is cleared only by the preflight, never by `clearDirty`;
- it shares one `UInt8` with the dirty flag, so `Sync` grows by no byte, and each write sets both in one store.

The preflight reads and clears the bits of the root's fields. In release builds it skips an exempt field (design 1) without touching its bit. Nodes are structs, so any write below a root field goes through that field's setter or `_modify`, which sets the root's bit too. A bit set in a nested `Sync` is never read.
- The bit `Sync.init` sets covers the initial values and a replaced subtree, so initialize needs no "every field" case.
- The macro's dirty-clearing code calls `updateValueWithoutMarkingDirty` to store a nested node back after clearing its flags (`StateNodeBuilderMacro.swift:878`). That would set the bit on every node field after every sync. So S1b gives the generated code an underscored public `_storeAfterClearingDirty(_:)`, which leaves the bit as it was, and the macro calls it instead. The value it stores is the same one, with its flags cleared.
- `_storeAfterClearingDirty` is a trust boundary. A caller that stored a different, deeper value through it would skip the check. It is documented as for generated code only, with that consequence.

**It counts, and builds only where it must.** The preflight walks the value with the same counters as the conversion (containers and hops, §3.1), and builds no `SnapshotValue` for generated types. It is one more generated member per node and per `@SnapshotConvertible` type, `_checkNesting(budget:)`, which mirrors the conversion's walk. A fixture pins that the two agree: for each test shape, the preflight refuses exactly when the budgeted conversion refuses. Two cases differ:
- **A hand-written type.** Its output is the only thing to count, so the preflight builds it and walks the result iteratively. It builds the full conversion, the one the hash runs: `fullStateSnapshot(budget:)` for a node, `toFullSnapshotValue(budget:)` for a convertible type, falling back to `toSnapshotValue(budget:)` as `makeFull` does. It doesn't use `snapshot(for:)`, which is a player's view.
- **A prebuilt `SnapshotValue` field.** It is already built, so it is walked iteratively as it is.

**Cost: three designs compared.** The preflight walks each field whose check bit is set, every turn, on the hot path. A per-player map is dirty every tick in most games. So d-716 asked which of three designs keeps that walk small.

1. **Static exemption at registration.** For each `@Sync` field type, compute at registration a bound on the conversion that actually runs: the most containers and the most hops (§3.1) that any value of the type can produce in it. A field whose bound fits its budget, on both counters, is never walked at runtime.
   - The bound counts both because wrapper-only descent (an `Optional` chain, a property wrapper) adds hops and no container. A field bounded by containers alone would be exempt and could then throw `.hops` in the sync phase or the hash, and recording on and off would no longer fail in the same turn.
   - It holds for the policy replacements too: `.perPlayer`, `.masked` and `.custom` must return the same `Value` type (`SyncPolicy.swift:21-39`), so a replacement has the stored value's bound.

   What can be known statically:
   - scalars and `String` (0 containers);
   - `Optional<T>` (as `T`, plus its hop);
   - `Array<T>`, `Set<T>` and `Dictionary<K, T>` (one more container than `T`);
   - a `@StateNodeBuilder` node and a `@SnapshotConvertible` type (one more than its deepest field), when the type isn't recursive and its conversions are generated.

   What can't:
   - an enum, unless it conforms by hand: even one without associated values converts through its own conformance (a raw value, or `Codable`), which the macro doesn't see;
   - a stored property declared without a type annotation, whose type the macro can't read: its bound is `nil`;
   - a recursive type, an `indirect` enum, or a type that contains itself through a collection;
   - an enum with associated values, whose case isn't known until runtime;
   - an existential: `Any`, `AnyCodable`, `SnapshotValue`, `any P`;
   - a generic parameter at the macro's expansion site;
   - a plain struct with neither macro;
   - a type whose live or full conversion is written by hand;
   - a type that converts through its `Codable` conformance.

   Class references are refused at registration already (#464). The bound has to come from the type system, not from a default instance's `Mirror`: through `Mirror`, an existential field looks like the type of its default value, so a bound read that way would be unsound. So the macros generate the bound:
   - **The protocol.** The public, underscored `_StaticNestingBound` has one requirement, `static func _nestingBound(_ context: inout _NestingBoundContext) -> _NestingBound?`. `_NestingBound` holds the containers and the hops. `nil` means unbounded or unknown.
   - **How a type gets it.** `StateNodeProtocol` refines `_StaticNestingBound`, with a default that returns `nil`, so a hand-written node is unknown without any work. `@StateNodeBuilder` generates the member that overrides it. `@SnapshotConvertible` already attaches an extension that adds its conformance, and adds `_StaticNestingBound` to it in the same way.
   - **Recursion and shared types.** `_NestingBoundContext` holds the current path and a memo. A type is inserted into the path before its fields are bounded and removed after. A type met on its own path is recursive and gives `nil`. A type met twice on different branches is not recursive: `Position2` appears twice in `PlayerState`, and the graph of field types there is a DAG. The memo keeps each type's result, so a deep DAG is bounded in linear time.
   - **The bound follows the conversion that runs.** `make` and `makeFull` check `StateNodeProtocol` first (`SnapshotValue.swift:238`, :516), then the convertible protocols, and `makeFull` prefers `fullStateSnapshot` and `toFullSnapshotValue`. A type whose live or full conversion is written by hand is unknown, even when its stored fields are bounded. So a macro that finds a hand-written conversion requirement in the type's body generates `nil`. A requirement that the macro leaves to a protocol default can still be overridden in an extension, which the macro can't see. The DEBUG walk below catches that case. The docs say that such an override must also override `_nestingBound` to return `nil`.
   - **One macro owns the members.** `PlayerState` carries both `@StateNodeBuilder` and `@SnapshotConvertible` (`Examples/GameDemo/Sources/GameContent/States/PlayerState.swift:8-9`). If both macros generated the members, the conformance would be declared twice. So `@StateNodeBuilder` owns `_StaticNestingBound` and `_checkNesting(budget:)` whenever it is present. `@SnapshotConvertible` generates them only on a type without `@StateNodeBuilder`, which it sees among the declaration's attributes. On a type with both, `make` runs the node conversion, but a typed table may convert the type through `toSnapshotValue`. So that type's bound is taken over every stored property, which covers the fields of both conversions.
   - **Hand-written conformers get explicit bounds.** `IVec2` and `IVec3` conform to `SnapshotValueConvertible` by hand (`Core/IVec2.swift:645`, `Core/IVec3.swift:247`). Without a bound of their own, `Position2` (`@SnapshotConvertible(atomic: true)` over `IVec2`) would be unknown, and so would every map that holds it, so they would be walked each tick. S1a adds explicit `_StaticNestingBound` conformances to `IVec2`, `IVec3` and the ID types (`PlayerID`, `ClientID`, `SessionID`, `LandID`). A test checks each against its conversion.
   - **The standard library.** `Optional`, `Array`, `Set` and `Dictionary` get conditional conformances. A field type that doesn't conform resolves, through an overload, to unknown. A generic or existential field therefore falls to the runtime walk.
   - **A hand-written bound is a trust boundary.** In DEBUG builds the preflight also checks every exempt field whose check bit is set. It runs the conversion that really runs, with its budget: the budgeted `makeFull`, and the typed tables' conversion for a field they convert. It then asserts that what that conversion counted stays within the claimed bound, naming the type. Tests run in debug, so a wrong bound in the repository fails them. Release builds trust the bound.
2. **Depth stored at assignment.** Compute a new value's depth when the field is set, and let the preflight read the stored number. Rejected:
   - `Sync`'s `_modify` accessor yields the stored value for an in-place write (`items[k].hp -= 1`), so each such write would walk the whole field afterwards. A field written n times in a turn costs n walks instead of one, and the per-player map is the case it is worst for.
   - A write deep inside a nested node goes through every ancestor's accessor, so each ancestor would walk its subtree again.
   - `updateValueWithoutMarkingDirty` and `Sync.init` (clean, `SyncPolicy.swift:174`) bypass the setter, so the stored number would be missing or stale exactly where the check is needed.
   - The setter can't throw, so it could only store, not refuse.
3. **Depth returned by the sync conversion.** Let the conversion that sync already does return its height, `max(children) + 1`, so a field sync converts needs no second walk. Rejected as the design: the preflight runs before the sync phase, and a sync doesn't run every turn (not due, no members, back-pressure). A field checked only by sync would leave the gap that d-716 closes. The conversion keeps its own budget as a second line (§3.3). That is what stops an overflow inside the conversion, because a returned height arrives only after the recursion ran.

**Choice: design 1, with the runtime walk for the rest.** A field whose type is statically bounded within its budget, on both counters, is exempt: it is never walked, at initialize or after. In-repo game state is mostly per-player maps of plain `@SnapshotConvertible` structs and node trees without recursion, which are bounded once S1a's explicit conformances are in. The remaining fields, the "can't" list above, get the count-only walk in each turn that sets their check bit. A registration diagnostic lists the fields left to the runtime walk, so an adopter can see the cost and bound a type. In all three designs the descending budget (Q4) stays in every conversion, since it is what prevents the overflow.

**A/B tier.** The preflight is keeper work per turn, so EncodingBenchmark doesn't measure it. S1b runs, in this order:
- **A precondition.** The debug walk probe must show zero walks for the game land as it is, once S1a's explicit bounds are in. If it doesn't, that cell is reported as "partly walked", with the walked fields listed, not as zero cost.
- **`ServerLoadTest`** (`Examples/GameDemo`), release, on the Mac, A/B against the S1b base. It has two cells:
  - the game land as it is;
  - the worst case: a variant with a per-player map of an unbounded type that is dirty every tick.

  It reports the keeper's turn time, not only the end-to-end numbers, and counts the check-bit writes per turn.
- **A host A/B** (the 7600X, `ws-loadtest`), when the Mac A/B moves beyond its noise.

Both sides are built with the same toolchain, as CLAUDE.md requires.

**Replay.** The keeper is shared by live and re-evaluation, so replay runs the same `finishApply()` at the same point of the same turn. That covers both runners (`ReevaluationEngine` and `ReevaluationRunnerImpl`), and it is the one shared verifier. The hash and the sync-output driver never see a too-deep state, because the preflight refused it first. §3.6 says how the runners stop and what they compare.

**Two guarantees, stated apart:**
- The preflight's refusal: nothing of that turn goes out, and nothing of it is hashed.
- A view's refusal in the sync phase (below): it stops the state commit. But the adapter handles a cycle's events before its state plan, so standalone events of that cycle can already be enqueued when the plan refuses. The docs say so. Staging those events with the plan is left out: it is the sync phase's order, which L2d and #700 own.

**A view's replacement.** For a field whose type isn't statically bounded, a `.perPlayer`, `.masked` or `.custom` replacement can be deeper than the stored value. The preflight doesn't run the policy closures, since that is per-player sync work. So the sync conversion's budget refuses such a replacement in the sync phase, before commit. The hash never sees views, so recording on and off still agree. Replay's shadow extraction runs only on committed outputs (`SyncOutputReplayDriver`), and the failing turn has none. So a recorded view refusal (reason `view`) is reported as not reproducible, which is not a mismatch. Statically bounded types can't hit this case.

### 3.2 The limit, per frame shape

`PayloadNesting.stateMaxDepth` is the wire's limit minus the deepest state frame's own levels, capped by the measured stack (Q1, §5).

**Convention.** A frame shape's overhead is the number of containers above the value's root. A fixture measures it with a scalar sentinel in place of the value (overhead = the frame's nesting depth with the sentinel), and counts the value's own containers separately. A state frame then fits when `overhead + depth(value) ≤ serverFrameMaxDepth`. The payload overheads #720's tests use (2 in an event's own frame, 4 in a merged frame) count the payload's root as one of the payload's own levels. In this convention they are 1 and 3, so the fixtures restate them.

**The shapes**, each with a fixture and a test that pins `stateMaxDepth + overhead(shape) ≤ serverFrameMaxDepth`:
- a state update frame, `[StateUpdateOpcode, …]` (`StateUpdateEncoderProtocol.swift:15`: `noChange` 0, `firstSync` 1, `diff` 2), with a diff patch on the broadcast path and on the per-player path. Opcode 103 is `event` (`TransportMessageEncoder.swift:10`), not a state update; rev 2's list had that wrong;
- a row-column value from a typed table (one more level, the values array);
- a joiner's first sync (full snapshot), and a resync;
- the opcode 107 merged frame `[107, state, events]` (`MessageKindOpcode.stateUpdateWithEvents`), which nests the state one level deeper than its own frame (#720's must-fix);
- **a row-column value inside a 107 merged frame with a real event**, which is likely the deepest state shape. Its fixture is the one expected to set the limit;
- JSON object framing (`json`, `opcodeJsonArray`). JSON has no wire limit (#715), so this shape doesn't set the limit; its fixture pins that a state at the limit encodes and decodes in both JSON encodings.

The limit is set by the deepest shape. The packer's guard (#697) stays as the last check, for frames built from other sources.

**Payloads** get the same treatment, with their own budget: `PayloadNesting.payloadMaxDepth` is `serverFrameMaxDepth` minus the deepest event or response frame's overhead, in the convention above. S1a defines the constant and its fixtures, since the event digests (R6) use it. S2 makes the encoders (R5) consume it.

### 3.3 How the budget is carried (Q4: an explicit budget, decided 2026-11-21)

A protocol requirement can't take a default argument, and an extension-only overload doesn't dispatch through `any StateNodeProtocol`. Several entry points are public, so the macro expansions in an adopter's module can call them. So every public entry point keeps its current signature, and gains a budget-aware form:

- **`StateNodeProtocol`** (`StateNodeProtocol.swift:115-170`): new requirements `snapshot(for:dirtyFields:budget:)`, `broadcastSnapshot(dirtyFields:budget:)`, `snapshotForSync(playerIDs:dirtyFields:budget:)`, `fullStateSnapshot(budget:)`. Each extension default calls the old requirement, then walks the returned tree iteratively against the budget. The macro generates the budget-aware requirements and makes the old ones forward with the root budget.
- **`@SnapshotConvertible`** (`SnapshotConvertibleMacro.swift`; `SnapshotValue.swift:171`, :498): `toSnapshotValue(budget:)` and `toFullSnapshotValue(budget:)`, live and full, in the same pattern: generated, with defaults that check the old method's output.
- **`SnapshotValue.make(from:for:)`, `makeFull(from:)`, `broadcastView(of:)`**: these are public (`public extension SnapshotValue`, `SnapshotValue.swift:182`, :501), not internal as rev 2 said. Each gains a `budget:` overload. The old signature stays and forwards the root budget.
- **`SyncTableField.make`**: the four overloads (`SyncTables.swift:73`, :112, :127, :142) are `public static`, because macro expansions in adopter modules call them. Each gains an overload whose `convert` closure takes the budget: `(V, NestingBudget) throws -> SnapshotValue`. The old overloads stay. They wrap the old closure so that its result goes through the iterative check against the budget left at the slot (§3.1). The differs take the budget from `SyncDiffPosition`. The row and fallback paths have no position today, so they take their slot kind's start.
- `NestingBudget` is a public struct, used by the generated code in an adopter's module. It holds the containers and hops left. Its only public initializer is the root budget. Its descend operations throw `SyncError.nestingTooDeep`.

**Hand-written nodes.** A hand-written conformer implements only the old requirements. Its default budget-aware form forwards to them, so the count restarts at the root for everything beneath that node. The returned-tree check catches the depth, but only after the hand-written recursion ran. So a recursive hand-written node type is unbounded on the stack. That is the adopter's, documented with R4: a hand-written node that nests its own type implements the budget-aware requirement.

Benchmark: S1a measures the budget on the hot path. The tier is the EncodingBenchmark A/B on the Mac, then a host A/B if the Mac A/B moves beyond its noise.

### 3.4 How a too-deep state fails (Q2: `syncConversion`, decided 2026-11-21)

`nestingTooDeep` is a conversion failure and ends the land with `LandFailure.Kind.syncConversion`, before commit. The failure names the field and carries a structured reason (§3.6), not only a detail string. `syncEncode` stays for a frame that doesn't encode.

**The typed refusal reaches the failure on every path.** Today it can be lost or renamed in eight places. Each gets a mapping:
- **`ExtractionDrops`** keeps only `firstError: String?` and `firstField`: its `note(_:field:scope:)` stores the error as a string (`SyncEngine.swift:1500-1510`). S1a makes `note` keep the first error itself (`firstFailure: (any Error)?`, kept with the string for logs), so `noteExtractionDrops` (`SwiftStateTreeTransport/SyncPhaseTypes.swift:171`) can map a `SyncError.nestingTooDeep` to `syncConversion` with its reason. The single-field retry starts at the same budget (§3.1), so the deep field throws again and is noted although the fallback has a cached value. A test covers it: one-pass throw, fallback, the land still ends with `syncConversion` and the field named.
- **`SyncTables.viewPatches`** (:1755) uses `try?` and leaves out a field whose rows don't convert. S1a makes it note the slot's field and error into `drops`, so its callers don't have to throw. That covers `planFullViewUpdate` (`TransportAdapter.swift:4558-4596`), which doesn't throw, and its callers at :4449 and :4469. Other errors keep today's fallback. That holds on a first sync and on a resync, each with a test.
- **The adapter's generic catches**: the in-turn sync phase (`TransportAdapter.swift:2911-2922`) and the joiner's first sync (:5256-5267) map any error that isn't a `LandFailure` to `syncPlan`. S1a maps `SyncError.nestingTooDeep` to `syncConversion` with its field and reason in both, through one helper.
- **`planFirstSync`** (:5274) is a separate entry point. It goes through the same helper, with a test that a joiner whose first view is too deep ends the land with `syncConversion`.
- **The bulk `try?`**: `SyncEngine` tries `snapshotForSync` in one pass first (`SyncEngine.swift:1611`) and falls back to the separate methods. A custom `snapshotForSync` can throw where the separate methods succeed, and the `try?` erases that error. S1a keeps a `nestingTooDeep` from the bulk pass: it fails the land, as the separate methods would have done at the same budget.
- **The cached-value conversions.** `lastSentSnapshot` uses `try?` in both typed table kinds (`SyncTables.swift:1262`, :1321). They convert the value last sent, which passed the same budget when it was sent. S1a gives them their slot's start budget. `lastSentSnapshot` has no `drops` of its own, so a `nestingTooDeep` there takes the slot's drop path: the slot's path is dropped from the view and its field is noted, as `viewPatches` does. Other errors keep today's nil.
- **The debug freeze settle's catch** (`TransportAdapter.swift:6257-6262`) maps any error that isn't a `LandFailure` to `syncPlan`. L2d-1 replaces that path with a sync-only turn, whose phase goes through the in-turn catch above. If S1a lands before L2d-1, the settle's catch maps through the same helper.

**The error names its root field.** The error is `SyncError.nestingTooDeep(counter:limit:field:)`, where `field` is optional. A conversion below a root field throws with `field: nil`. The root-field boundary rethrows the error with its field filled in. There are three such boundaries:
- `ExtractionDrops.note`, which already gets the field;
- the preflight's loop over the root fields;
- a typed-table slot, for its field.

The adapter's catches, which have no field of their own, then name the field from the error.

**Which refusal wins.** `noteExtractionDrops` (`SwiftStateTreeTransport/SyncPhaseTypes.swift:171`) ends the land with the first dropped field, and the fields are noted in a fixed order. So the first dropped field wins, whether its error is a depth refusal or another error. A depth refusal carries its reason in `LandFailure.reason`; another error doesn't. The outcome is deterministic.

A bulk pass can fail while the single-field retry succeeds. For a generated `snapshotForSync`, a depth refusal can't do that, since the retry starts each field at the same budget (§3.1). For a hand-written one, the bulk refusal is kept (the bulk `try?` bullet above).

**The stage.** No `LandFailurePosition.Stage` (`LandFailure.swift:50-61`) fits a check after apply. So S1b adds two cases, which replay compares with the rest of the position:
- `stateCheck`: after a turn's apply, with the turn's tick or pass;
- `initialStateCheck`: after OnInitialize, or in its place, with no tick and no pass.

They are new cases of a public enum (§6).

**The first failure stays.** If a later encode fault follows in the same turn, the depth refusal stays the land's failure. `failLand`'s first cause already wins (`drainFlag.setFailed`), so S1a only has to make sure the refusal is reported first.

**The hash sites.** The preflight (§3.1a) runs before `liveStateHash` in every turn, so the hash never finds a too-deep state. Its four sites (:2840, :4671, :4864, :4966) need no new stop logic. The hash's budgeted conversion stays as a backstop: a depth error there is a preflight bug, so it asserts in DEBUG, and release keeps the unavailable hash. Every other hash error keeps today's unavailable-hash semantics. Review's three cases are covered that way: the shutdown turn changes no state after the last preflight; in `runTick` and `runTickTurn` the preflight ends the land before the hash and the turn's outputs; and the preflight names the field, which `fullStateSnapshot()` doesn't. `LandFailurePosition.Stage.stateHash` is not needed and is dropped.

### 3.5 Cycles and class fields in payloads (Q3: refuse at registration, decided 2026-11-21)

- **Registration:** refuse a class-typed field at every level of the declared type of an event, an action, a response and a **server input** (`serverInputHandlers`, which are recorded; `LandRegistration.swift:201-203` already walks them for decimal fields). It is the same rule #464 applies to synced state (`SyncValueSemantics`), in one validator for both.
  - Its reach is what the metadata describes. `@Payload` exposes each type's immediate field metatypes, and the validator descends through those. A payload has no general default instance, so there is no Mirror descent as for state nodes.
  - The check stops at: an existential (`Any`, `AnyCodable`, a protocol type); a type-erased generic; a field hidden by a hand-written `encode(to:)`; and **a nested plain `Codable` struct without `@Payload`**, which exposes no field metatypes.
  - A grep of `Examples/` and `Tests/` finds no statically class-typed `@Payload` field, so today's in-repo break is none.
  - Behavior change: a land with such a payload no longer registers. Listed in §6, with a docs line in en and zh-TW.
- **Runtime bound** for what registration can't see: the direct encoder and `MessagePackValueEncoder` (both directions), and the record codec (R9), count depth against `payloadMaxDepth` (§3.2). The count is carried across the value encoder's re-entry into the direct encoder, so a boxed value doesn't restart it. That also stops a cycle. The direct encoder's branch for a prebuilt `SnapshotValue` recurses on its own (`encodeSnapshotValue`, `MessagePackDirectEncoder.swift:242-257`, :339-354), so it is counted too.
  - The canonical encoder's `container(keyedBy:)` (`CanonicalMessagePack.swift:380`), `unkeyedContainer()` (:385), `nestedContainer` and `superEncoder` (:457, :462, :515) can't throw. Setting `deferredError` (:336, :413) records the refusal but doesn't stop the recursion. So the check runs in two places:
  - On entry to the throwing `encode` calls: past the limit, an `encode` returns at once without descending.
  - When a container or a `superEncoder` is created. A `superEncoder` chain never enters a throwing `encode`, so past the limit the new encoder starts refused, and its `encode` calls return at once.

  In both cases the deferred error is thrown at the end (:350).
- **Event digests (R6):** both use `try?` today. The sync-stream canonical form (`SyncStreamCanonical.swift:12`) drops the event's entry. The output verifier (`SyncOutputVerifier.swift:300`) leaves its canonical payload nil. The digests run only when the land records, so a refusal there must not be what ends the land: then recording on and off would fail differently. The live failure comes from the encoders' count (S2), which runs whether or not the land records, and ends the land with `eventEncode`, the event named. A `nestingTooDeep` in a digest is for verification only: the digest notes it, and the verifier reports a mismatch. Other conversion errors keep today's handling.
- **The terminal entry survives a payload that fails framing.** `failLand` submits the terminal entry as its own record submission (`LandKeeper.swift:5632-5635`), apart from the turn's events. S2 makes the recorder refuse the offending payload as an error of its own, without losing the frame's other entries or the terminal one. A test reads the record back and finds the terminal entry. S2 confirms how the record log merges a frame's submissions (`ReevaluationRecordLog.swift:163`) before relying on it.
- **What stays the adopter's:** a hand-written `encode(to:)` that walks a cycle, and JSON payloads (`JSONEncoder` can't be bounded from outside; for them registration is the guard). The docs say so, narrowing rev 1's stated guarantee.
- The value trees (`SnapshotValue`, `MessagePackValue`) are enums, so they can't hold a cycle.

### 3.6 Replay and the record (#612)

Facts any design must handle (Review, checked against the code):
- The replay keeper has no transport and no recorder.
- `failLand` in re-evaluation logs and returns (`LandKeeper.swift:5610`).
- The replay runners catch every hash error as an unavailable hash: `ReevaluationEngine.stateHashAndSnapshot` and `verifyInitialize` (`ReevaluationEngine.swift:110`), and `ReevaluationRunnerImpl`'s initialize and `step` (`ReevaluationRunnerImpl.swift:360`).
- `SyncOutputReplayDriver` (`ReevaluationEngine.swift:296`) runs only on committed outputs, and the failing turn has none.

**Where replay detects a refusal:** in the keeper's preflight, at the same point of the same turn as live, in both runners (§3.1a). The contract:

- **How a refusal is recorded.** `failLand` submits the terminal entry, `ReevaluationTickRecord(landFailure:)` (`LandKeeper.swift:5632-5635`), into the failing tick's frame (frame 0 on a tickless land), with kind, field and position. That doesn't depend on hash recording.
  - An initialize refusal sits in tick 0 with `tickId: nil`, and has its own replay test.
  - The refusal is before commit, so that turn has no committed sync output. What the failing turn records is in §3.1a: its inputs, resolver outputs, watermarks and the terminal entry, with no events and no hash.
- **Inside the keeper, the replay stops at the refusal.** The keeper's own replay loop would otherwise go on past it:
  - `replayRecordedPasses` stops right after the `runInputTurn` that returned `.ended`, and right after its initialize items' apply when that ends. It doesn't flush the pass's outputs (:4241), doesn't call the pass observer (:4242), and runs no later pass. The refusing pass keeps its ordinal.
  - `runTick`'s early exit (:4631) takes the refusal too (§3.1a's table).
- **How the runners stop.** Each runner reads `replayDepthRefusal` at its own points, before anything else of that step:
  - `ReevaluationEngine.run`: right after `awaitInitialization()` (:274), before `verifyInitialize`, the sync-output driver's `begin` and the tick loop; then after each `stepTickOnce()` (:348), before its hash (:356).
  - `ReevaluationRunnerImpl`: after `awaitInitialization()` (:320); then in `step()`, after `stepTickOnce()` and before its hash (:391).

  With a refusal, the step doesn't hash, doesn't flush, doesn't call the pass observer and doesn't step again. The run compares the refusal with the record (below) and ends.
- **`step()` latches the refusal.** The first `step()` that finds it returns a result that carries the comparison's verdict (a new optional `depthRefusal` on `ReevaluationStepResult`). Every later `step()` returns nil, so the run ends there. A test calls `step()` twice.
- **An initialize refusal.** It is recorded in frame 0 with stage `initialStateCheck` and no tick, next to the replayable initialize (§3.1a). Today `lastTickId = min(maxTickId, landFailure.tickId)` (`ReevaluationEngine.swift:326`) would still step tick 0. With that stage, the run steps no tick: both runners find the refusal right after `awaitInitialization()`.
- **A structured reason.** `LandFailure` today has only `kind` and a free-text `detail`, so replay can't tell a depth refusal from colliding keys. S1b adds an optional `reason: LandFailure.Reason?` with the case `nestingTooDeep(counter:limit:where:)`. The counter is containers, hops or payload. The `where` is the preflight or a view (§3.1a), so a view refusal can be told apart. `LandFailure`'s `Codable` is synthesized, so an older record decodes with `reason == nil`.
- **How it is compared, with equal limits.** When the recorded failure has a depth reason from the preflight, the runner compares counter, field and position (stage, and tick or pass) with replay's refusal. A match verifies. Replay refusing where the record has no failure, or not refusing where it has one, is a mismatch. A recorded view refusal is reported as not reproducible (§3.1a).
- **A record from another limit.** The record's metadata gains the effective limits: `stateMaxDepth`, `stateMaxHops` and `payloadMaxDepth`. The not-comparable report sits alongside `hashIncomparability`.
  - A different limit can move the first refusal to another field or another turn. So when the recorded limits differ from this build's, replay compares only the prefix before the earlier of the two refusals. It reports the rest as not comparable, not as a mismatch, and names the direction: the record's limit looser or tighter than this build's.
  - A record without limits (before 3.7) has an unknown limit. A depth refusal on replay is then not comparable, and the prefix before it is compared.
- **Versions.** There are two contracts. The record metadata is `3.6` (`ActionRecorder.swift:235`, `current = "3.\(fingerprintMinor)"`), and `isReadable` (:360) rejects a newer minor. The binary log preamble is `3.5` on its own (`ReevaluationRecordLog.swift:27`). The plan:
  - The metadata moves 3.6 → 3.7 for the limits field and the terminal reason. The limits get a minor of their own, `nestingLimitsMinor = 7`, and `current` becomes `"3.\(nestingLimitsMinor)"` (`ActionRecorder.swift:235-246`). `minimumReplayable` stays `"3.\(fingerprintMinor)"`, 3.6: a 3.6 record has no limits, which reads as an unknown limit (above), and it replays as today. A test replays a real 3.6 record through both runners.
  - `stampedWithCurrentVersion` (:118) stamps the limits.
  - The binary preamble stays 3.5. The reason is an optional key inside an existing entry, so the log's framing doesn't change. S1b checks that with a 3.5 log holding a 3.7 entry, read by today's reader. That test checks the framing reader only: a 3.6 build still rejects 3.7 metadata (`isReadable`, :360), as for any newer minor.
- **The record codec's 128** (R9) covers more than the state tree. The envelope, the payloads and the patch lists add levels around it. A fixture pins that the deepest recorded entry stays within 128, around a state at `stateMaxDepth` and around a payload at `payloadMaxDepth`. The codec's recursive tree build gets its own in-build check (S2).
- #612's rev 5 picks this contract up. It is a contract change there, not a pointer.

### 3.7 Tests that can't overflow the runner

- Every over-the-limit value is built iteratively (a reduce, as `PackDepthTests.stateFrameBound` does), so the test itself never recurses.
- Every case that would overflow if its guard regressed runs as an exit test (a child process). A regression then fails one test instead of killing the test bundle. Those that overflow on purpose run on the Linux host, not the Mac (§4 S0).
- In-process cases stay shallow: at the limit and one past it, refused by the count before the recursion is deep.
- Per stage:
  - R1: `make`, `broadcastView`, a land's sync, a joiner's first sync and a resync, each ending with `syncConversion` and the field. A `.custom` view deeper than the stored value is refused.
  - R2: a row replaced at depth, the row-addressed full view, and each slot kind's start budget.
  - Prebuilt trees: each short-circuit type at the limit and one past it; release of a refused deep tree in a child process.
  - Hops: `Optional<Node>` at every level up to `stateMaxDepth` passes; wrapper-only recursion past `stateMaxHops` is refused.
  - The preflight (S1b). Each of these ends the land in that turn, with recording on and with it off:
    - a deep value in a nested `.serverOnly` sub-field of a `.broadcast` node;
    - a deep initial value, also on a land without OnInitialize;
    - a whole node replaced with a new deep value, and the root replaced;
    - a deep value written with `updateValueWithoutMarkingDirty`;
    - a deep write followed by `clearDirty`, which must not clear the check;
    - an OnInitialize that writes the deep value, and one that writes it and then throws; each records a replayable initialize, and its replay refuses again.

    Every apply segment in §3.1a's table has its own test. In an input turn, the refusal's position names the refusing pass. In the failing turn, no output is sent and no hash is recorded, and its record holds its inputs. A noted transport failure and a depth refusal in the same turn: the transport failure is the cause. The preflight and the budgeted conversion refuse the same shapes. A statically bounded field is never walked: S1b counts the walks in a debug probe, as `FullStateConversionProbe` does for full conversions. A wrong hand-written bound fails the DEBUG assert.
  - Static bounds (S1a):
    - each "can" type gets its pair and each "can't" type gets nil;
    - a recursive node gives nil, and a DAG (`Position2` twice in one type) is bounded;
    - `IVec2`, `IVec3` and the ID types are bounded, each checked against its conversion;
    - a type with both macros is bounded once, over every stored property;
    - a type with a hand-written conversion gives nil;
    - a wrapper-only chain is bounded on hops.
  - The refusal's path (S1a): `ExtractionDrops.note`, `viewPatches`, the two `lastSentSnapshot` conversions, both adapter catches, `planFirstSync`, the bulk pass, the debug settle's catch (if S1a lands before L2d-1), the root field named from the error, the first dropped field winning, and a later encode fault in the same turn.
  - Payloads (S2): a class field refused at registration, a server input included; a cycle in an `AnyCodable` refused by the encoder, also through a boxed value and through the canonical encoder's containers; an event digest past the payload budget.
  - R9 (S2): a record nested past 128.
  - Replay (S1b):
    - a match and a mismatch;
    - the stop before the hash, the flush, the pass observer and the next step, in both runners;
    - a refusing pass, which keeps its ordinal while no later pass runs;
    - an initialize refusal, after which no tick runs;
    - a record from a looser limit, one from a tighter limit, and one without limits, each with its prefix compared;
    - a view refusal, reported as not reproducible;
    - a repeated `step()` after a refusal, which returns nil;
    - a real 3.6 record, replayed through both runners.
  - The callers (S1b): in a turn that ends, an input whose handler returned success answers `landClosed`, and no frame of that turn reaches the transport. A turn whose in-turn sync phase fails the land answers `landClosed` the same way.
- Frame shapes: one fixture per shape (§3.2).
- Run on macOS debug and release locally, and on Linux in CI.
- Mutants:
  - the preflight skipped at one apply segment;
  - a static bound raised by one, a bound without its hops, and `visiting` used as a set of types already seen;
  - each guard removed, and each off by one;
  - each slot kind's start off by one;
  - the hop counter merged into the container count;
  - the typed error replaced by its string;
  - the prebuilt check skipped;
  - `clearDirty` clearing the check bit, and the macro's clear path using `updateValueWithoutMarkingDirty`;
  - replay hashing before it reads the refusal;
  - an emit moved before `finishApply()` (the rule #700 must keep, §4).

## 4. Steps

Each step ends with an exit condition and a revert check: the test that fails when that step's guard is reverted.

- **S0, measure (no library change).**
  - On the Mac (slot): bytes per level by instrumentation, without overflowing. The stack address at the deepest frame is compared with the entry, per stage and per shape: nodes and containers alternating, row updates and full-row seeds, prebuilt trees, wrapper-only recursion. Measure on main and with a prototype of the thin dispatcher (§5 Q1) in a scratch branch. Overflow runs crash a child process, and every crash raises a macOS crash-reporter dialog, so S0 doesn't overflow on the Mac.
  - On the Linux host: the runs that find each overflow point, one child process per depth, on the real keeper, adapter and recorder contexts. The exact-limit and one-over cases run through the throw and the unwind. A clean refusal and stack exhaustion count as different outcomes. The 544 KiB Darwin pool figure comes from the Mac's measured bytes per level.
  - Record per run: platform, toolchain, optimization mode, usable stack, bytes per level.
  - Place the save path, the SDK patch apply and schema extraction (§2).
  - Exit: a table in this plan and values for `stateMaxDepth` and `stateMaxHops`. No revert check (no guard).
- **S1a, the count in every conversion (any time).**
  - The budget through R1–R3, the typed tables and the public overloads (§3.3), with `SyncError.nestingTooDeep(counter:limit:field:)`.
  - The prebuilt check and the hop counter (§3.1), and the refusal mapping at every site (§3.4).
  - The static-bound members, in the same macro change as the budget-aware requirements. That change is unit-tested on its own, and includes:
    - `_StaticNestingBound` with the containers-and-hops pair and its context;
    - the standard library's conformances, and the explicit ones for `IVec2`, `IVec3` and the ID types;
    - `_checkNesting(budget:)`, generated and tested against the conversion, but not called by the keeper yet;
    - the registration diagnostic.
  - `payloadMaxDepth` and its fixtures, and the event digests (R6).
  - The thin dispatcher, if S0 supports it.
  - Three nits carried from #720's review (merged as af666b40 without them):
    - the failure-handling row, en and zh-TW: "at the first broadcast event" becomes "when the deep state update and the events share one opcode 107 frame";
    - `EncodingPipeline.mergeEvents`' `.data` branch: `try? unpack(…, maxDepth: 63) == nil` treats bytes that don't decode as a state exactly 64 deep. It should note the state only when the unpack fails on depth;
    - `CoreConcepts.md` and both turns READMEs: "steps later in that batch" becomes "is admitted later in that batch, by the same rules".
  - The frame-shape fixtures (§3.2), the tests in §3.7 marked S1a, and the EncodingBenchmark A/B (the budget in the conversion).
  - Exit: every S1a test green on macOS debug and release, and on Linux CI; the A/B within the noise, or its cost accepted by the maintainer.
  - Revert checks:
    - removing the container guard fails the R1 exit test;
    - removing the prebuilt check fails the short-circuit test;
    - dropping the typed error fails the `ExtractionDrops` test;
    - raising a static bound by one fails its bound test.
- **S1b, the preflight (after L2d-3 has merged).**
  - `finishApply()` at every apply segment (§3.1a). It includes the #696/#704 step if that plan has landed first.
  - The check bit, and the macro's `_storeAfterClearingDirty(_:)`.
  - The DEBUG walk of exempt fields.
  - `LandFailure.Reason`, the two stages, the record limits at 3.7, and the replay stop and comparison (§3.6).
  - The callers' rule (§3.1a), today's in-turn sync failure included.
  - At its base: confirm the segment list, and that L2d-2 moved headless tick lands onto `runTickTurn` (§3.1a).
  - The tests in §3.7 marked S1b, and the `ServerLoadTest` A/B with its precondition (§3.1a).
  - Exit: every S1b test green on macOS debug and release, and on Linux CI; the A/B within the noise, or its cost accepted by the maintainer.
  - Revert checks:
    - skipping `finishApply()` at one segment fails that segment's test;
    - `clearDirty` clearing the check bit fails the clean-write test;
    - replay hashing before it reads the refusal fails the replay stop test.
- **The rule #700 must keep.** On `TurnCore`, `finishApply()` is the last act of a step's apply. `Turn` can't discard what a step has already emitted: `emit` appends to the core's outputs (`SwiftStateTurns/Turn.swift:248-256`), and `close` and `endAll` don't drop them. So the keeper keeps buffering handler emits in its collector, and calls `turn.emit` and `turn.run` only after `finishApply()`. S1b pins that with a mutant: an emit moved before the call fails the "no output in the failing turn" test. The test keeps failing that way after #700 moves the turns. No core change is needed.
- **S2, payloads.**
  - The payload validator at registration, server inputs included.
  - The encoders' count against `payloadMaxDepth`, the direct encoder's prebuilt branch included; the canonical encoder's entry, container and `superEncoder` checks; and the record codec's in-build check (§3.5).
  - The terminal entry surviving a payload refusal. Docs.
  - Exit: every S2 test green as above.
  - Revert checks: removing the validator fails the registration test; removing the encoder count fails the `AnyCodable` cycle exit test; removing the codec's in-build check fails the 128 test.
- **S3, docs.**
  - The state limit in `docs/core/failure-handling.md` and `sync.md` (en and zh-TW), replacing the #697 Limit sentence.
  - The narrowed payload guarantee; the hand-written-node and prebuilt-release limits.
  - The TS SDK test at the limit; the solutions entry updated.
  - Exit: the docs rot checks pass and the SDK test is green.

S1a, S1b and S2 are separate PRs. S1b needs S1a and L2d-3. S2 consumes S1a's `payloadMaxDepth`. Each touches `Sources/`, so each goes through a PR and Review.

## 5. Decisions (maintainer orders q1-716 to q4-716)

Q1–Q4 were decided 2026-11-21, as Review recommended, and Q5 by the maintainer the same day.

- **Q1, the limit (decided 2026-11-21):** measured, not taken from the wire. S0 prototypes the thin dispatcher: `SnapshotValue.make` with its slow paths moved out (`@inline(never)`), so each level's frame is small. The limit is then the largest value that leaves about 2× measured headroom on the smallest stack in the worst path, capped at `serverFrameMaxDepth` minus the deepest frame shape's overhead (§3.2). If S0 leaves it between two values, take the lower one: loosening later never breaks an adopter, and tightening does. 32 containers is a reasonable measured candidate.
- **Q2, the kind (decided 2026-11-21):** `syncConversion` (§3.4). The docs row says that the wire's 64 is why the state limit exists.
- **Q3, class payload fields (decided 2026-11-21):** refused at registration, paired with the runtime bound in the framework's own traversals (§3.5). A hand-written `encode(to:)` and JSON payloads are documented as the adopter's.
- **Q4, the carrier (decided 2026-11-21):** an explicit budget in the compatible shape of §3.3, not a per-thread counter. Its cost is measured in S1a.

- **d-716, where the full value is checked (decided 2026-11-21):** one preflight per turn at the end of the apply segment (Review's D), with the cost to be compared across three designs. The comparison picks static exemption at registration plus the count-only walk for the rest (§3.1a).

- **Q5, the callers of a turn that ends (decided 2026-11-21):** `landClosed` for every caller in that turn's consumed batch, handler errors included; no output of that turn is sent, replies included (§3.1a). The #696/#704 plan states the same rule in the same words.

**Phase fit.** The count runs in conversion (sync phase and recording) and in the preflight. No mutation is refused. A conversion's refusal ends the land through the existing path where a throw in the sync plan happens before commit; the preflight's goes through `failLand` before the turn's outputs. The preflight (§3.1a) sits at the end of the apply segment: still in the synchronous turn, before any output, and it only reads state.

## 6. Public API

Additions:
- `NestingBudget` (public struct; root initializer only).
- New requirements with extension defaults:
  - on `StateNodeProtocol`: `snapshot(for:dirtyFields:budget:)`, `broadcastSnapshot(dirtyFields:budget:)`, `snapshotForSync(playerIDs:dirtyFields:budget:)`, `fullStateSnapshot(budget:)`;
  - on the `@SnapshotConvertible` protocols: `toSnapshotValue(budget:)`, `toFullSnapshotValue(budget:)`.
- Overloads, the old signatures kept: `SnapshotValue.make(from:for:budget:)`, `makeFull(from:budget:)`, `broadcastView(of:budget:)`, and the four `SyncTableField.make` overloads with a budget-taking `convert`.
- `SyncError.nestingTooDeep(counter:limit:field:)`. A new case of a public enum: an adopter's exhaustive `switch` over `SyncError` no longer compiles without a `default`. Listed as source-breaking.
- `LandFailurePosition.Stage.stateCheck` and `.initialStateCheck`. New cases of a public enum, source-breaking in the same way.
- `ReevaluationStepResult.depthRefusal` (optional) and `ReevaluationRecordVersion.nestingLimitsMinor`.
- `LandFailure.reason` and `LandFailure.Reason` (optional; older records decode with nil).
- `PayloadNesting.stateMaxDepth`, `stateMaxHops`, `payloadMaxDepth`.
- The record metadata's limits field, at version 3.7.
- `_StaticNestingBound`, `_NestingBound` and `_NestingBoundContext` (public, underscored, for generated code). The conformances on `Optional`, `Array`, `Set` and `Dictionary`, and the explicit ones on `IVec2`, `IVec3`, `PlayerID`, `ClientID` and `SessionID`. The generated `_nestingBound(_:)` and `_checkNesting(budget:)` members.
- `Sync._storeAfterClearingDirty(_:)` (public, underscored, for generated code). `Sync`'s check bit is internal. `updateValueWithoutMarkingDirty` now selects the field for the next preflight: a behavior change, documented.
- A registration diagnostic (log, not an error) listing the fields the preflight walks at runtime.

Behavior:
- A state past the limit ends the land with `syncConversion` instead of overflowing.
- The callers of a turn that ends the land get `landClosed` instead of their handler's outcome: a turn that ends after its apply, one whose in-turn sync phase fails the land, and one whose batch holds a transport-reported failure item (that item has no caller).
- A land whose event, action, response or server-input type has a class-typed field no longer registers.
- A payload past `payloadMaxDepth` ends the land with `eventEncode` / `responseEncode` from the encoders, before the wire.
