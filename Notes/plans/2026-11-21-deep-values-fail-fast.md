# Deep or cyclic values fail fast instead of overflowing the stack (#716)

Rev 4, 2026-11-21. Plan only: no code until Review's GO. Code pointers are at main 8e200729 (none of the cited source files changed since 05c429b5).

Rev 3 answered the parts of Review's NOT GO on rev 2 that don't depend on where the full check runs (the public API facts, prebuilt trees, the hop counter, the typed refusal's path, and the shoulds). Rev 4 adds what the maintainer's order d-716 decided: **one depth preflight per turn, at the end of the apply segment** (§3.1a). That closes rev 2's must-fixes 1 (the fields the check covers), 6 (how replay detects a refusal) and 7 (the hash sites). d-716 also asked for the preflight's cost to be compared across three designs. §3.1a compares them and picks one.

Q1–Q4 and d-716 are maintainer orders, all decided 2026-11-21 (§5).

**Baseline.** The packer bound this plan keeps as the last check is #697's, in PR #720, not merged yet. S0 can run before it. S1 and S2 build on main after #720 merges, and each PR names the main commit it starts from.

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

S0 still places two more before S1: how a land's save encodes state, and the SDK's own patch apply.

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
  - Both paths have one component above the value, so "the slot's path depth" would be off by one for one of them. S1 gives each slot kind its start as a constant, with a fixture each.

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

### 3.1a The per-turn preflight (d-716)

**What it does.** At the end of each turn's apply segment, after the handlers ran, the keeper checks the depth of:
- the full value of every dirty `@Sync` field, regardless of policy;
- every `@Sync` field after OnInitialize, since an initial value is never dirty.

The check comes before the turn's outputs (`runTurnOutputs`, `flushOutputs`) and before `liveStateHash`. A refusal ends the land through `failLand`, with `syncConversion`, the field and the depth reason (§3.4, §3.6), before that turn sends or records anything else.

It runs whether or not:
- a sync is due;
- the land has members;
- the writer has back-pressure;
- recording is on.

So recording on and off fail in the same turn by construction. The turn sites are:
- in-turn sync: OnInitialize (`LandKeeper.swift:1279`), a tick (`runTickTurn`, :4887) and an input turn (`runInputTurn`, :5802);
- legacy, with in-turn sync off: before each `flushOutputs(forTick:)` that follows an apply (:1148, :3938, :4241, :4679).

S1 lists every apply segment again from the code and gives each a test. It also confirms that join and leave handlers and server inputs run as input turns (`runInputTurn`); any that doesn't gets a site of its own.

The shutdown turn (:2840) changes no land state (#382). So the last preflight still holds there, and its hash needs no stop logic.

**It counts, and never builds.** The preflight walks the value with the same counters as the conversion (containers and hops, §3.1), and builds no `SnapshotValue`. It is one more generated member per node and per `@SnapshotConvertible` type, `_checkNesting(budget:)`, which mirrors the conversion's walk. A fixture pins that the two agree: for each test shape, the preflight refuses exactly when the budgeted conversion refuses. Two places can't avoid building:
- a hand-written `toSnapshotValue()` or `snapshot(for:dirtyFields:)`, whose output is the only thing to count: the preflight calls it and walks the result iteratively;
- a prebuilt `SnapshotValue` field, which is walked iteratively as it is.

**Cost: three designs compared.** The preflight is a walk of each dirty field per turn, on the hot path. A per-player map is dirty every tick in most games. So d-716 asked which of three designs keeps that walk small.

1. **Static exemption at registration.** For each `@Sync` field type, compute at registration the most containers any value of that type can have. A field whose bound fits within its budget is never walked at runtime. This is sound for the policy replacements too: `.perPlayer`, `.masked` and `.custom` must return the same `Value` type (`SyncPolicy.swift:21-39`), so a replacement has the same static bound as the stored value.

   What can be known statically:
   - scalars, `String`, and enums without associated values (0 containers);
   - `Optional<T>` (as `T`);
   - `Array<T>`, `Set<T>` and `Dictionary<K, T>` (one more than `T`);
   - a `@StateNodeBuilder` node and a `@SnapshotConvertible` type (one more than its deepest field), when the type isn't recursive.

   What can't:
   - a recursive type, an `indirect` enum, or a type that contains itself through a collection;
   - an enum with associated values, whose case isn't known until runtime;
   - an existential: `Any`, `AnyCodable`, `SnapshotValue`, `any P`;
   - a generic parameter at the macro's expansion site;
   - a plain struct with neither macro;
   - a hand-written `toSnapshotValue()` or `snapshot(for:dirtyFields:)`;
   - a type that converts through its `Codable` conformance.

   Class references are refused at registration already (#464). The bound has to come from the type system, not from a default instance's `Mirror`: through `Mirror`, an existential field looks like the type of its default value, so a bound read that way would be unsound. So the macros generate the bound. A public, underscored protocol `_StaticNestingBound` has a requirement `static func _nestingBound(visiting:) -> Int?`. A `nil` result means "unbounded or unknown", and the `visiting` set ends the recursion of a recursive type with `nil`. The standard library's `Optional`, `Array`, `Set` and `Dictionary` get conditional conformances. A field type that doesn't conform resolves, through an overload, to "unknown". A generic or existential field therefore falls to the runtime walk, which keeps the bound conservative. An adopter who conforms a type by hand is responsible for its bound (documented, as for R4).
2. **Depth stored at assignment.** Compute a new value's depth when the field is set, and let the preflight read the stored number. Rejected:
   - `Sync`'s `_modify` accessor yields the stored value for an in-place write (`items[k].hp -= 1`), so each such write would walk the whole field afterwards. A field written n times in a turn costs n walks instead of one, and the per-player map is the case it is worst for.
   - A write deep inside a nested node goes through every ancestor's accessor, so each ancestor would walk its subtree again.
   - `updateValueWithoutMarkingDirty` and `Sync.init` (clean, `SyncPolicy.swift:174`) bypass the setter, so the stored number would be missing or stale exactly where the check is needed.
   - The setter can't throw, so it could only store, not refuse.
3. **Depth returned by the sync conversion.** Let the conversion that sync already does return its height, `max(children) + 1`, so a field sync converts needs no second walk. Rejected as the design: the preflight runs before the sync phase, and a sync doesn't run every turn (not due, no members, back-pressure). A field checked only by sync would leave the gap that d-716 closes. The conversion keeps its own budget as a second line (§3.3). That is what stops an overflow inside the conversion, because a returned height arrives only after the recursion ran.

**Choice: design 1, with the runtime walk for the rest.** Fields whose type is statically bounded within their budget are exempt: no walk, at initialize or after. In-repo game state is mostly per-player maps of plain `@SnapshotConvertible` structs and node trees without recursion, which are bounded. The remaining fields, the "can't" list above, get the count-only walk each turn they are dirty, and every field at initialize. A registration diagnostic lists the fields left to the runtime walk, so an adopter can see the cost and bound a type. In all three designs the descending budget (Q4) stays in every conversion, since it is what prevents the overflow.

**A/B tier.** The preflight is keeper work per turn, so EncodingBenchmark doesn't measure it. S1 runs:
- `ServerLoadTest` (`Examples/GameDemo`), release, on the Mac, A/B against the S1 base. Two scenarios: the game land as it is, where every field is expected to be exempt and the cost should be zero; and a variant added for this A/B with a per-player map of an unbounded type that is dirty every tick, the worst case.
- A host A/B (the 7600X, `ws-loadtest`) when the Mac A/B moves beyond its noise.

Both sides are built with the same toolchain, as CLAUDE.md requires.

**Replay.** The keeper is shared by live and re-evaluation, so replay runs the same preflight at the same point of the same turn. That covers both runners (`ReevaluationEngine` and `ReevaluationRunnerImpl`), and it is the one shared verifier. In re-evaluation mode, `failLand` logs and returns (`LandKeeper.swift:5610`). So the preflight's refusal is kept on the keeper for the runner to read (`replayDepthRefusal`), and compared as in §3.6. The hash and the sync-output driver never see a too-deep state: the preflight refused it first.

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

**Payloads** get the same treatment, with their own budget: `PayloadNesting.payloadMaxDepth` is `serverFrameMaxDepth` minus the deepest event or response frame's overhead, in the convention above. S1 defines the constant and its fixtures, since the event digests (R6) use it. S2 makes the encoders (R5) consume it.

### 3.3 How the budget is carried (Q4: an explicit budget, decided 2026-11-21)

A protocol requirement can't take a default argument, and an extension-only overload doesn't dispatch through `any StateNodeProtocol`. Several entry points are public, so the macro expansions in an adopter's module can call them. So every public entry point keeps its current signature, and gains a budget-aware form:

- **`StateNodeProtocol`** (`StateNodeProtocol.swift:115-170`): new requirements `snapshot(for:dirtyFields:budget:)`, `broadcastSnapshot(dirtyFields:budget:)`, `snapshotForSync(playerIDs:dirtyFields:budget:)`, `fullStateSnapshot(budget:)`. Each extension default calls the old requirement, then walks the returned tree iteratively against the budget. The macro generates the budget-aware requirements and makes the old ones forward with the root budget.
- **`@SnapshotConvertible`** (`SnapshotConvertibleMacro.swift`; `SnapshotValue.swift:171`, :498): `toSnapshotValue(budget:)` and `toFullSnapshotValue(budget:)`, live and full, in the same pattern: generated, with defaults that check the old method's output.
- **`SnapshotValue.make(from:for:)`, `makeFull(from:)`, `broadcastView(of:)`**: these are public (`public extension SnapshotValue`, `SnapshotValue.swift:182`, :501), not internal as rev 2 said. Each gains a `budget:` overload. The old signature stays and forwards the root budget.
- **`SyncTableField.make`**: the four overloads (`SyncTables.swift:73`, :112, :127, :142) are `public static`, because macro expansions in adopter modules call them. Each gains an overload whose `convert` closure takes the budget: `(V, NestingBudget) throws -> SnapshotValue`. The old overloads stay. They wrap the old closure so that its result goes through the iterative check against the budget left at the slot (§3.1). The differs take the budget from `SyncDiffPosition`. The row and fallback paths have no position today, so they take their slot kind's start.
- `NestingBudget` is a public struct, used by the generated code in an adopter's module. It holds the containers and hops left. Its only public initializer is the root budget. Its descend operations throw `SyncError.nestingTooDeep`.

**Hand-written nodes.** A hand-written conformer implements only the old requirements. Its default budget-aware form forwards to them, so the count restarts at the root for everything beneath that node. The returned-tree check catches the depth, but only after the hand-written recursion ran. So a recursive hand-written node type is unbounded on the stack. That is the adopter's, documented with R4: a hand-written node that nests its own type implements the budget-aware requirement.

Benchmark: S1 measures the budget on the hot path. The tier is the EncodingBenchmark A/B on the Mac, then a host A/B if the Mac A/B moves beyond its noise.

### 3.4 How a too-deep state fails (Q2: `syncConversion`, decided 2026-11-21)

`nestingTooDeep` is a conversion failure and ends the land with `LandFailure.Kind.syncConversion`, before commit. The failure names the field and carries a structured reason (§3.6), not only a detail string. `syncEncode` stays for a frame that doesn't encode.

**The typed refusal reaches the failure on every path.** Today it can be lost or renamed in five places. Each gets a mapping:
- **`ExtractionDrops`** keeps only `firstError: String?` and `firstField` (`SyncEngine.swift:1474-1511`). S1 makes it keep the first error itself (`firstFailure: (any Error)?`, kept with the string for logs), so `noteExtractionDrops` (`SwiftStateTreeTransport/SyncPhaseTypes.swift:171`) can map a `SyncError.nestingTooDeep` to `syncConversion` with its reason. The single-field retry starts at the same budget (§3.1), so the deep field throws again and is noted although the fallback has a cached value. A test covers it: one-pass throw, fallback, the land still ends with `syncConversion` and the field named.
- **`SyncTables.viewPatches`** (:1755) uses `try?` and leaves out a field whose rows don't convert. S1 makes it note the slot's field and error into `drops`, so its callers don't have to throw. That covers `planFullViewUpdate` (`TransportAdapter.swift:4557-4595`), which doesn't throw, and its callers at :4448 and :4468. Other errors keep today's fallback. That holds on a first sync and on a resync, each with a test.
- **The adapter's generic catches**: the in-turn sync phase (`TransportAdapter.swift:2911-2922`) and the joiner's first sync (:5255-5266) map any error that isn't a `LandFailure` to `syncPlan`. S1 maps `SyncError.nestingTooDeep` to `syncConversion` with its field and reason in both, through one helper.
- **`planFirstSync`** (:5273) is a separate entry point. It goes through the same helper, with a test that a joiner whose first view is too deep ends the land with `syncConversion`.
- **The bulk `try?`**: `SyncEngine` tries `snapshotForSync` in one pass first (`SyncEngine.swift:1611`) and falls back to the separate methods. A custom `snapshotForSync` can throw where the separate methods succeed, and the `try?` erases that error. S1 keeps a `nestingTooDeep` from the bulk pass: it fails the land, as the separate methods would have done at the same budget.

**The first failure stays.** If a later encode fault follows in the same turn, the depth refusal stays the land's failure. `failLand`'s first cause already wins (`drainFlag.setFailed`), so S1 only has to make sure the refusal is reported first.

**The hash sites.** The preflight (§3.1a) runs before `liveStateHash` in every turn, so the hash never finds a too-deep state. Its four sites (:2840, :4671, :4864, :4966) need no new stop logic. Every hash error keeps today's unavailable-hash semantics. Review's three cases are covered that way: the shutdown turn changes no state after the last preflight; in `runTick` and `runTickTurn` the preflight ends the land before the turn's outputs; and the preflight names the field, which `fullStateSnapshot()` doesn't. `LandFailurePosition.Stage.stateHash` is not needed and is dropped.

### 3.5 Cycles and class fields in payloads (Q3: refuse at registration, decided 2026-11-21)

- **Registration:** refuse a class-typed field at every level of the declared type of an event, an action, a response and a **server input** (`serverInputHandlers`, which are recorded; `LandRegistration.swift:201-203` already walks them for decimal fields). It is the same rule #464 applies to synced state (`SyncValueSemantics`), in one validator for both.
  - Its reach is what the metadata describes. `@Payload` exposes each type's immediate field metatypes, and the validator descends through those. A payload has no general default instance, so there is no Mirror descent as for state nodes.
  - The check stops at: an existential (`Any`, `AnyCodable`, a protocol type); a type-erased generic; a field hidden by a hand-written `encode(to:)`; and **a nested plain `Codable` struct without `@Payload`**, which exposes no field metatypes.
  - A grep of `Examples/` and `Tests/` finds no statically class-typed `@Payload` field, so today's in-repo break is none.
  - Behavior change: a land with such a payload no longer registers. Listed in §6, with a docs line in en and zh-TW.
- **Runtime bound** for what registration can't see: the direct encoder and `MessagePackValueEncoder` (both directions), and the record codec (R9), count depth against `payloadMaxDepth` (§3.2). The count is carried across the value encoder's re-entry into the direct encoder, so a boxed value doesn't restart it. That also stops a cycle.
  - The canonical encoder's `container(keyedBy:)` (`CanonicalMessagePack.swift:380`), `unkeyedContainer()` (:385), `nestedContainer` and `superEncoder` (:457, :462, :515) can't throw. Setting `deferredError` (:336, :413) records the refusal but doesn't stop the recursion. So the check also stops on entry to the throwing `encode` calls: past the limit, an `encode` returns at once without descending, and the deferred error is thrown at the end (:350).
- **Event digests (R6):** both use `try?` today. The sync-stream canonical form (`SyncStreamCanonical.swift:12`) drops the event's entry. The output verifier (`SyncOutputVerifier.swift:300`) leaves its canonical payload nil. With the count, a `nestingTooDeep` there is the event's failure: on the live side the land ends with `eventEncode`, the event named; in the verifier it is a mismatch. Other conversion errors keep today's handling.
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
  - The refusal is before commit, so that turn has no committed sync output. Replay already stops at the recorded failure (`setReplayFailureEnd`, `ReevaluationEngine.swift:321-326`).
- **A structured reason.** `LandFailure` today has only `kind` and a free-text `detail`, so replay can't tell a depth refusal from colliding keys. S1 adds an optional `reason: LandFailure.Reason?` with the case `nestingTooDeep(counter:limit:where:)`. The counter is containers, hops or payload. The `where` is the preflight or a view (§3.1a), so a view refusal can be told apart. `LandFailure`'s `Codable` is synthesized, so an older record decodes with `reason == nil`.
- **How it is compared.** When the recorded failure has a depth reason from the preflight, replay's preflight refuses at that turn, and the runner compares counter, field and tick/pass with the recorded one. A recorded view refusal is reported as not reproducible (§3.1a). A match verifies. Replay refusing where the record has no failure, or not refusing where it has one, is a mismatch, except in the next case.
- **A record from another limit, both ways.** The record's metadata gains the effective limits: `stateMaxDepth`, `stateMaxHops` and `payloadMaxDepth`. The not-comparable report sits alongside `hashIncomparability`. Replay reports a run as not comparable, not as a mismatch, when the recorded limits differ from this build's and either:
  - replay refuses where the record has no failure (the record was made under a looser limit, or before the field existed); or
  - the record has a depth refusal that replay, under a looser limit, doesn't reproduce.
- **Versions.** There are two contracts. The record metadata is `3.6` (`ActionRecorder.swift:235`, `current = "3.\(fingerprintMinor)"`), and `isReadable` (:360) rejects a newer minor. The binary log preamble is `3.5` on its own (`ReevaluationRecordLog.swift:27`). The plan:
  - The metadata moves 3.6 → 3.7 for the limits field and the terminal reason.
  - `stampedWithCurrentVersion` (:118) stamps the limits.
  - The binary preamble stays 3.5. The reason is an optional key inside an existing entry, so the log's framing doesn't change. S1 checks that with a 3.5 log holding a 3.7 entry, read by today's reader.
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
  - The preflight: a deep value in a nested `.serverOnly` sub-field of a `.broadcast` node, and a deep initial value, each ending the land in that turn with recording on and off. Every turn site is covered (initialize, tick, input turn, legacy tick). No output is sent and no hash is recorded in the failing turn. The preflight and the budgeted conversion refuse the same shapes. A statically bounded field is never walked; S1 counts the walks in a debug probe, as `FullStateConversionProbe` does for full conversions.
  - Static bounds: each "can" type gets its bound, each "can't" type gets nil, and a recursive node ends with nil.
  - The refusal's path: `ExtractionDrops`, `viewPatches`, both adapter catches, `planFirstSync`, the bulk pass, and a later encode fault in the same turn.
  - Payloads (S2): a class field refused at registration, a server input included; a cycle in an `AnyCodable` refused by the encoder, also through a boxed value and through the canonical encoder's containers; an event digest past the payload budget.
  - R9 (S2): a record nested past 128.
  - Replay (S1): a match, a mismatch, a record from a looser and from a tighter limit, an initialize refusal, and a view refusal reported as not reproducible.
- Frame shapes: one fixture per shape (§3.2).
- Run on macOS debug and release locally, and on Linux in CI.
- Mutants: the preflight skipped at one turn site, a static bound raised by one, each guard removed and each off by one, each slot kind's start off by one, the hop counter merged into the container count, the typed error replaced by its string, and the prebuilt check skipped.

## 4. Steps

Each step ends with an exit condition and a revert check: the test that fails when that step's guard is reverted.

- **S0, measure (no library change).**
  - On the Mac (slot): bytes per level by instrumentation, without overflowing. The stack address at the deepest frame is compared with the entry, per stage and per shape: nodes and containers alternating, row updates and full-row seeds, prebuilt trees, wrapper-only recursion. Measure on main and with a prototype of the thin dispatcher (§5 Q1) in a scratch branch. Overflow runs crash a child process, and every crash raises a macOS crash-reporter dialog, so S0 doesn't overflow on the Mac.
  - On the Linux host: the runs that find each overflow point, one child process per depth, on the real keeper, adapter and recorder contexts. The exact-limit and one-over cases run through the throw and the unwind. A clean refusal and stack exhaustion count as different outcomes. The 544 KiB Darwin pool figure comes from the Mac's measured bytes per level.
  - Record per run: platform, toolchain, optimization mode, usable stack, bytes per level.
  - Place the save path, the SDK patch apply and schema extraction (§2).
  - Exit: a table in this plan and values for `stateMaxDepth` and `stateMaxHops`. No revert check (no guard).
- **S1, the state count.**
  - The budget through R1–R3, the typed tables and the public overloads (§3.3), with `SyncError.nestingTooDeep`.
  - The prebuilt check and the hop counter (§3.1), and the failure mapping (§3.4).
  - The per-turn preflight (§3.1a), at every turn site, with `_checkNesting(budget:)` generated; the static bounds (`_StaticNestingBound`, generated, with the standard library's conformances) and the registration diagnostic for the fields left to the runtime walk.
  - `payloadMaxDepth` and its fixtures, and the event digests (R6).
  - `LandFailure.Reason`, the record limits and the replay comparison (§3.6).
  - The thin dispatcher, if S0 supports it.
  - Three nits carried from #720's review (GO at 8a066991, merged without them):
    - the failure-handling row, en and zh-TW: "at the first broadcast event" becomes "when the deep state update and the events share one opcode 107 frame";
    - `EncodingPipeline.mergeEvents`' `.data` branch: `try? unpack(…, maxDepth: 63) == nil` treats bytes that don't decode as a state exactly 64 deep; it should note the state only when the unpack fails on depth;
    - `CoreConcepts.md` and both turns READMEs: "steps later in that batch" becomes "is admitted later in that batch, by the same rules".
  - The frame-shape fixtures (§3.2), the tests per §3.7 that S1 owns, the EncodingBenchmark A/B (the budget in the conversion), and the `ServerLoadTest` A/B (the preflight, §3.1a).
  - Exit: every S1 test green on macOS debug and release, and on Linux CI; both A/Bs within the noise, or their cost accepted by the maintainer.
  - Revert checks: skipping the preflight fails the nested `.serverOnly` test with recording off; removing the container guard fails the R1 exit test; removing the prebuilt check fails the short-circuit test; dropping the typed error fails the `ExtractionDrops` test.
- **S2, payloads.**
  - The payload validator at registration, server inputs included.
  - The encoders' count against `payloadMaxDepth`, the canonical encoder's entry check and the record codec's in-build check (§3.5).
  - The terminal entry surviving a payload refusal. Docs.
  - Exit: every S2 test green as above.
  - Revert checks: removing the validator fails the registration test; removing the encoder count fails the `AnyCodable` cycle exit test; removing the codec's in-build check fails the 128 test.
- **S3, docs.**
  - The state limit in `docs/core/failure-handling.md` and `sync.md` (en and zh-TW), replacing the #697 Limit sentence.
  - The narrowed payload guarantee; the hand-written-node and prebuilt-release limits.
  - The TS SDK test at the limit; the solutions entry updated.
  - Exit: the docs rot checks pass and the SDK test is green.

S1 and S2 are independent PRs, except that S2 consumes S1's `payloadMaxDepth`. Each touches `Sources/`, so each goes through a PR and Review.

## 5. Decisions (maintainer orders q1-716 to q4-716)

All four were decided 2026-11-21, as Review recommended.

- **Q1, the limit (decided 2026-11-21):** measured, not taken from the wire. S0 prototypes the thin dispatcher: `SnapshotValue.make` with its slow paths moved out (`@inline(never)`), so each level's frame is small. The limit is then the largest value that leaves about 2× measured headroom on the smallest stack in the worst path, capped at `serverFrameMaxDepth` minus the deepest frame shape's overhead (§3.2). If S0 leaves it between two values, take the lower one: loosening later never breaks an adopter, and tightening does. 32 containers is a reasonable measured candidate.
- **Q2, the kind (decided 2026-11-21):** `syncConversion` (§3.4). The docs row says that the wire's 64 is why the state limit exists.
- **Q3, class payload fields (decided 2026-11-21):** refused at registration, paired with the runtime bound in the framework's own traversals (§3.5). A hand-written `encode(to:)` and JSON payloads are documented as the adopter's.
- **Q4, the carrier (decided 2026-11-21):** an explicit budget in the compatible shape of §3.3, not a per-thread counter. Its cost is measured in S1.

- **d-716, where the full value is checked (decided 2026-11-21):** one preflight per turn at the end of the apply segment (Review's D), with the cost to be compared across three designs. The comparison picks static exemption at registration plus the count-only walk for the rest (§3.1a).

**Phase fit.** The count runs in conversion (sync phase and recording) and in the preflight. No mutation is refused. A conversion's refusal ends the land through the existing path where a throw in the sync plan happens before commit; the preflight's goes through `failLand` before the turn's outputs. The preflight (§3.1a) sits at the end of the apply segment: still in the synchronous turn, before any output, and it only reads state.

## 6. Public API

Additions:
- `NestingBudget` (public struct; root initializer only).
- New requirements with extension defaults:
  - on `StateNodeProtocol`: `snapshot(for:dirtyFields:budget:)`, `broadcastSnapshot(dirtyFields:budget:)`, `snapshotForSync(playerIDs:dirtyFields:budget:)`, `fullStateSnapshot(budget:)`;
  - on the `@SnapshotConvertible` protocols: `toSnapshotValue(budget:)`, `toFullSnapshotValue(budget:)`.
- Overloads, the old signatures kept: `SnapshotValue.make(from:for:budget:)`, `makeFull(from:budget:)`, `broadcastView(of:budget:)`, and the four `SyncTableField.make` overloads with a budget-taking `convert`.
- `SyncError.nestingTooDeep(counter:limit:)`. A new case of a public enum: an adopter's exhaustive `switch` over `SyncError` no longer compiles without a `default`. Listed as source-breaking.
- `LandFailure.reason` and `LandFailure.Reason` (optional; older records decode with nil).
- `PayloadNesting.stateMaxDepth`, `stateMaxHops`, `payloadMaxDepth`.
- The record metadata's limits field, at version 3.7.
- `_StaticNestingBound` (public, underscored, for generated code) and its conformances on `Optional`, `Array`, `Set` and `Dictionary`; the generated `_nestingBound(visiting:)` and `_checkNesting(budget:)` members.
- A registration diagnostic (log, not an error) listing the fields the preflight walks at runtime.

Behavior:
- A state past the limit ends the land with `syncConversion` instead of overflowing.
- A land whose event, action, response or server-input type has a class-typed field no longer registers.
- A payload past `payloadMaxDepth` ends the land with `eventEncode` / `responseEncode` from the encoders, before the wire.
