# Deep or cyclic values fail fast instead of overflowing the stack (#716)

Rev 2, 2026-11-21. Plan only: no code until Review's GO. Code pointers are at main 05c429b5.

Rev 2 answers Review's NOT GO on rev 1 (5 must-fix, 4 should). It defines the counted tree (§3.1), gives frame overhead per frame shape (§3.2), specifies the protocol migration (§3.3), decides the hash path's failure semantics (§3.4) and the replay contract (§3.6), and widens the stage table (§2). Q1–Q4 are maintainer orders. Q1–Q3 were **decided 2026-11-21** as Review recommended; Q4 follows Review's recommendation, **pending maintainer** (§5). Where a decision rests on one of them, the text says so.

**Baseline.** The packer bound this plan keeps as the last check is #697's, in PR #720, not merged at 05c429b5. S0 can run before it. S1 and S2 build on main after #720 merges, and each PR names the main commit it starts from.

## 1. Problem

A value that nests too deep, or a cycle through a class, overflows the thread's stack in a recursive stage before any bound refuses it. The process dies (SIGBUS) and every land on it goes with it. The rule this plan applies (`Notes/solutions/2026-11-18-a-parsers-depth-limit-isnt-the-pipelines.md`): every recursive stage needs a bound it can walk on the smallest stack it runs on (Darwin's cooperative pool, 544 KiB), and a value past the bound fails the land, never the process.

Measured in #697 (issue comment on #716): a chain of nested `@StateNodeBuilder` nodes, 2 containers per level, overflows in `SnapshotValue.make` at 28 levels in a debug build on macOS (26 syncs). In release, 28 syncs and 34 reaches the packer (`syncEncode`). The packer's 64 (#697) is never reached by nested-node state in debug.

## 2. The recursive stages

Each stage is either bounded by the count (§3.1: its input is a value the count already accepted, so its recursion is at most the limit deep), bounded by its own guard, or out of scope. S0 measures the bytes per level of every stage marked "count", so the limit leaves room for the deepest of them.

| # | Stage | Where | Runs on | Bound after this plan |
|---|---|---|---|---|
| R1 | Client view of state | `SnapshotValue.make(from:for:)` (`SnapshotValue.swift:227`), `broadcastView(of:)` (:455), the macro's `snapshot(for:dirtyFields:)`, `broadcastSnapshot`, `snapshotForSync` | keeper, sync phase (also a joiner's first sync and a resync) | the count |
| R2 | Typed sync diff | `SyncNodeDiffer`, `SyncOptionalNodeDiffer`, `SyncNodeMapDiffer.diffRows`, the row and fallback paths of `SyncTables` (their `convert` closures), `SyncTables.viewPatches` (:1755) | keeper, sync phase | the count |
| R3 | Full state | `SnapshotValue.makeFull` (:509), `fullStateSnapshot()`, `toFullSnapshotValue()` (`@SnapshotConvertible`); the hash in `LandKeeper.liveStateHash` (:4977) and `ReevaluationEngine.calculateStateHashAndSnapshot` (:534) | keeper (recording), replay, the monitor runner | the count |
| R3a | Set ordering inside `makeFull` (:562) | JSON-encodes each converted element to sort | as R3 | the count (it encodes the converted `SnapshotValue`, which the count accepted) |
| R4 | Hand-written `toSnapshotValue()` / `snapshot(for:dirtyFields:)` | the adopter's code | as R1 | its returned tree is checked by an iterative walk (§3.3); recursion inside the adopter's code is the adopter's, documented |
| R5 | Payload fallback encode | `MessagePackDirectEncoder`, `MessagePackValueEncoder` boxing (re-enters the direct encoder), `AnyCodable.encode(to:)` | keeper / adapter | a depth count through both encoders, carried across the re-entry (§3.5) |
| R5j | JSON payload encode | `JSONEncoder` (`TransportCodec.swift:58`) | adapter | registration only (§3.5); a cycle hidden from registration is out of scope, documented |
| R6 | Event digest when recording | `SnapshotValue.make` on an event payload, before the wire encoder | keeper (recording) | the count, with the payload's budget (§3.2) |
| R7 | Value walks after conversion | `SnapshotValue` → `MessagePackValue` (and the atomic positional conversion), the JSON state encoders through `SnapshotValue.encode(to:)`, the sync-digest hash walk, the replay `SnapshotPatchApplier` | adapter, keeper, replay | the count (inputs are counted values; the patch applier's tree is the full tree, §3.1) |
| R8 | Wire | the packer and unpackers | adapter | 64 (#697), 32 for client frames (#595) |
| R9 | Record codec | `CanonicalMessagePack` (`Support/CanonicalMessagePack.swift`, `maxDepth` 128) | recorder, replay | today it builds its tree recursively before its own 128 check; S2 makes the check run while it builds, and S0 measures its stack at 128 |
| R10 | Client decode | `AnyCodable` decode of client input | adapter | the unpacker's 32 (#595) runs first |
| — | Schema extraction | type metadata, not values | build/registration | out of scope (types, not values); S0 confirms it ends on a recursive type |
| — | TS SDK | its recursive value decode and resync reconcile | browser / Node | out of scope for the Swift change. The client tree is the full tree, so the count bounds it too (§3.1); S3 adds an SDK test at the limit |

S0 still places two more before S1: how a land's save encodes state, and the SDK's own patch apply.

## 3. Design

### 3.1 The counted tree

**The limit is on the full value of each `@Sync` field, regardless of its policy.** Every view (broadcast, per player, a diff's patch, a typed-table row) is a part of that value at the same path. No view is deeper than the full value at the same path. So a refusal anywhere means the full value is too deep, and a full value within the limit passes every view. The client's tree is built from patches at paths, so it too is never deeper than the full value. That includes a short patch at a long path.

Definitions:
- A field's depth is the number of containers (objects and arrays of the converted value, as the unpacker counts them) on the deepest path of its full value, counting the field's own value as level 1 when it is a container. A scalar field has depth 0.
- **The synthetic root** (the snapshot object holding the fields) is not counted. It belongs to every frame shape's overhead (§3.2). So a whole-snapshot pass and `SyncEngine`'s single-field retry (`extractDroppingThrowingFields`, `SyncEngine.swift:1526`) start each field at the same budget and refuse the same values.
- A conversion that starts below the field (a row, a patch at a path, an optional node) starts with the budget left at its path: the limit minus the containers above it.
- **Recursion that adds no container** is bounded too. An optional unwrap, a property wrapper or a `Mirror` hop through `Any` costs no container but costs a stack frame. The carrier (§3.3) counts calls as well as containers, and a path with more than `4 × stateMaxDepth` calls is refused with the same error. A prebuilt multi-level `SnapshotValue` returned by a conversion the count didn't walk (a hand-written hook, a `@SnapshotConvertible` type's own code) is checked by an iterative walk with an explicit stack, against the budget left at its path (§3.3).

**Where the full value is checked.** A conversion refuses only what it walks. For a field whose sync view is its full value (broadcast policy), the sync phase's conversion is the check. That leaves two cases where no view walks the deep part: a server-only field, and a branch that a per-player or custom policy filters out. Without a further check, such a field would end the land only when recording hashes it. A land would then behave differently with recording on and off. So in each turn's sync phase, before any view is built, every dirty field whose policy isn't plain broadcast gets a budgeted full conversion (`makeFull` with the budget, result discarded). S1 confirms that a server-only field's dirty bit is tracked like any other `@Sync` field's. If it isn't, that field is checked on every sync. When recording already converted the same turn's full state for the hash, the check reuses that result and doesn't convert again. The S1 benchmark covers this cost.

### 3.2 The limit, per frame shape

`PayloadNesting.stateMaxDepth` is the wire's limit minus the deepest state frame's own levels, capped by the measured stack (Q1, §5). Overhead differs by frame shape, so each shape gets a fixture. The fixture builds the frame around a shallow field value and measures its nesting the way the unpacker counts it (as `PackDepthTests.stateFrameBound` does in #720). Then a test pins `stateMaxDepth + overhead(shape) ≤ serverFrameMaxDepth` for every shape. The shapes:

- a patch in an opcode 103 state update (diff), on the broadcast and the per-player path;
- a row-column value from a typed table (one more level: the values array);
- a joiner's first sync (full snapshot), and a resync;
- the opcode 107 merged frame `[107, state, events]`, which nests the state one level deeper than its own frame. That is #720's must-fix: there a state frame exactly 64 deep ends the land with `eventEncode` when an event rides along. With the state limit derived from this shape, that case no longer arises from converted state;
- JSON object framing (`json`, `opcodeJsonArray`). JSON has no wire limit (#715), so this shape doesn't set the limit. Its fixture pins that a state at the limit encodes and decodes in both JSON encodings.

The limit is set by the deepest of these shapes. The packer's guard (#697) stays as the last check, for frames built from other sources.

A payload gets the same treatment, with its own budget: `serverFrameMaxDepth` minus the deepest event or response frame's levels (4 in the merged 107 frame, 2 in an event's own frame, per #720's tests). The recording digest (R6) and the encoders (R5) use that budget.

### 3.3 How the budget is carried (Q4: an explicit budget, pending maintainer)

A protocol requirement can't take a default argument, and an extension-only overload doesn't dispatch through `any StateNodeProtocol`. So each entry point keeps its current requirement, and gains a budget-aware requirement whose extension default keeps old conformers correct:

- **`StateNodeProtocol`** (`StateNodeProtocol.swift:115-170`): new requirements `snapshot(for:dirtyFields:budget:)`, `broadcastSnapshot(dirtyFields:budget:)`, `snapshotForSync(playerIDs:dirtyFields:budget:)`, `fullStateSnapshot(budget:)`. Each extension default calls the old requirement, then walks the returned tree iteratively against the budget. A hand-written node in a chain therefore doesn't restart the count: its output is checked against the budget left at its path. The macro generates the budget-aware requirements and makes the old ones forward with the root budget.
- **`@SnapshotConvertible`** (`SnapshotConvertibleMacro.swift`; `SnapshotValue.swift:171`, :498): `toSnapshotValue(budget:)` and `toFullSnapshotValue(budget:)`, live and full. The same pattern: generated, with defaults that check the old method's output.
- **`SnapshotValue.make` / `makeFull` / `broadcastView`**: internal, so they take the budget directly.
- **Typed tables**: the `convert` closures (`SyncTables.swift:78`, :117) become `(V, NestingBudget) throws -> SnapshotValue`. They are package-internal, so nothing breaks outside. The differs take the budget from `SyncDiffPosition`. The row and fallback paths have no position today, so they take it from the slot's path depth.
- `NestingBudget` is a public struct (the generated code in an adopter's module uses it) with no public initializer beyond the root. It holds the containers and calls left. Its descend operation throws `SyncError.nestingTooDeep(limit:)` (a new case).

**The typed error survives the retry paths.** `extractDroppingThrowingFields` retries a throwing pass field by field and notes each field that throws again (`drops.note`). A depth refusal is deterministic, and the single-field retry starts at the same budget (§3.1). So the deep field throws again, keeps the typed error, and `noteExtractionDrops` (`SwiftStateTreeTransport/SyncPhaseTypes.swift:171`) ends the land, although the fallback has a cached value. A test covers that: a one-pass throw, then a fallback, then the land still ends with `syncConversion` and the field named.

**`viewPatches`** (`SyncTables.swift:1755`) uses `try?` and leaves out a field whose rows don't convert. With a shared count that fallback would refuse too, but the error would be lost. S1 changes it to rethrow `nestingTooDeep` and keep the fallback for other errors. Then a depth refusal from a row-addressed full view reaches the terminal failure before commit, on a first sync and on a resync. Both get a test.

Benchmark: S1 measures the budget on the hot path (EncodingBenchmark A/B on the Mac; a host A/B if beyond noise), as rev 1 said.

### 3.4 How a too-deep state fails (Q2: `syncConversion`, decided 2026-11-21)

- **Sync phase (R1, R2, and §3.1's full check):** `nestingTooDeep` is a conversion failure. It ends the land through `ExtractionDrops` and `noteExtractionDrops` with `LandFailure.Kind.syncConversion`, before commit. The field is named, and the detail gives the limit. `syncEncode` stays for a frame that doesn't encode.
- **Hash (R3), decided:** today `liveStateHash` absorbs a conversion error: it records `unavailableHash`, counts it and goes on (`liveStateHash`, `LandKeeper.swift:4977`, documented at :4974; by design since #180). Under this plan `nestingTooDeep` found by the hash **ends the land** with `syncConversion` and the field, at its first occurrence. That covers every live recording site of `liveStateHash`: initialize (`makeInitializeRecord`, :4966), the legacy tick (`runTick`, :4671), the in-turn tick (`runTickTurn`, :4864) and a tick land's shutdown turn (:2840). S1 lists whether a tickless pass records a hash anywhere else; §3.1's sync-phase check covers a tickless land either way. A keeper with no transport attached has no sync phase, so its state is first converted at a joiner's first sync or by the hash, and the land ends at whichever comes first: a later turn than with a transport, but the same outcome, and replay compares against the turn recorded. `calculateStateHashAndSnapshot` gains a throwing sibling that the live sites use. **Every other hash error keeps today's unavailable-hash semantics**, unless the maintainer extends the change.
- With §3.1's full check in the sync phase, the hash and the sync refuse in the same turn. Which one reports depends on their order in that turn. The failure's kind, field and tick are the same either way; its stage says which. `LandFailurePosition.Stage` gains `stateHash` for the hash site, a public addition listed under Public API.
- **Replay and the monitor runner:** a depth refusal found while replaying fails the run (§3.6). It is not an unverifiable tick.

### 3.5 Cycles and class fields in payloads (Q3: refuse at registration, decided 2026-11-21)

- **Registration:** refuse a class-typed field at every level of an event's, action's or response's declared type, as #464 does for synced state (`SyncValueSemantics`). One validator for both. Its reach is what the metadata describes. `@Payload` exposes each type's immediate field metatypes, and the validator descends through those. A payload has no general default instance, so there is no Mirror descent as for state nodes. The check stops at an existential (`Any`, `AnyCodable`, a protocol type), a type-erased generic, and a field hidden by a hand-written `encode(to:)`. A grep of `Examples/` and `Tests/` finds no statically class-typed `@Payload` field, so today's in-repo break is none. Behavior change: a land with such a payload no longer registers. It goes under Public API with a docs line, in en and zh-TW.
- **Runtime bound** for what registration can't see: the direct encoder and `MessagePackValueEncoder` (both directions), and the record codec (R9), count depth against the payload budget (§3.2). The count is carried across the value encoder's re-entry into the direct encoder, so a boxed value doesn't restart it. That also stops a cycle.
- **What stays the adopter's:** a hand-written `encode(to:)` that walks a cycle, and JSON payloads (`JSONEncoder` can't be bounded from outside; for them registration is the guard). The docs say so, narrowing rev 1's stated guarantee.
- The value trees (`SnapshotValue`, `MessagePackValue`) are enums, so they can't hold a cycle.

### 3.6 Replay and the record (#612)

Today's replay verifier runs full R1 extraction in a shadow `SyncEngine`, never the adapter's typed-table R2 path, and doesn't run the final frame encoder. #612 still gates R3 on recorded hashes. The count is in the conversion entry points, which the shadow engine and the hash both use, so replay refuses at the same input as live. What this plan adds to the record contract:

- **How a refusal is recorded.** It already has a place: `failLand` submits the terminal entry, `ReevaluationTickRecord(landFailure:)` (`LandKeeper.swift:5632-5635`), into the failing tick's frame (frame 0 on a tickless land), with kind, field and position. That entry doesn't depend on hash recording, so a refusal is recorded with hash recording off too. The refusal is before commit, so that turn has no committed sync output. Replay already stops there (`setReplayFailureEnd`, `ReevaluationEngine.swift:321-326`).
- **How it is compared.** Today replay reports the recorded failure (`result.liveFailure`) but doesn't check that replay fails the same way. With this plan, when the recorded failure is a depth refusal, replay records its own refusal at that tick (in re-evaluation mode `failLand` logs and returns, `LandKeeper.swift:5610`; S1 keeps the first one for the result). Replay then compares kind, field and tick/pass with the recorded one. A match verifies. Replay refusing where the record has no failure, or not refusing where it has one, is a mismatch, except in the next case.
- **A record from another limit.** The record's metadata gains `stateMaxDepth` (a record minor version, with the bump rules in `ActionRecorder.swift`). Suppose a record was made under another limit, or before the field existed, and replay refuses where it recorded no failure. Replay then reports the run as not comparable because the limits differ (alongside `hashIncomparability`), not as a state mismatch.
- **The record codec's 128** (R9) covers more than the state tree. The envelope, the payloads and the patch lists add levels around it. So the claim is narrowed: a fixture pins that the deepest recorded entry around a state at `stateMaxDepth`, and around a payload at its budget, stays within 128. The codec's recursive tree build gets its own in-build check (R9).
- #612's rev 5 picks this contract up. It is a contract change there, not a pointer.

### 3.7 Tests that can't overflow the runner

- Every over-the-limit value is built iteratively (a reduce, as `PackDepthTests.stateFrameBound` does), so the test itself never recurses.
- Every case that would overflow if its guard regressed runs as an exit test (a child process, as the 100,000-level leaf test in #697 does). A regression then fails one test instead of killing the test bundle and hiding the rest.
- In-process cases stay shallow: at the limit and one past it, refused by the count before the recursion is deep.
- Per stage:
  - R1: `make`, `broadcastView`, a land's sync. Expect `syncConversion` with the field, on a first sync and a resync.
  - R2: a row replaced at depth, and the row-addressed full view.
  - §3.1's full check: a server-only field and a filtered branch, recording off. The land ends in the same turn as with recording on.
  - R3: each recording site.
  - The retry path: one-pass throw, fallback, the land still ends.
  - Zero-container recursion: nested optionals through `Any`, and a prebuilt tree from a hand-written hook.
  - R5: a class field refused at registration; a cycle in an `AnyCodable` refused by the encoder, also through a boxed value.
  - R9: a record nested past 128.
  - Replay: a match, a mismatch, and a record from another limit.
- Frame shapes: one fixture per shape (§3.2).
- Run on macOS debug and release locally, and on Linux in CI.
- Mutants: each guard removed and each off by one, the full check skipped, and the retry path dropping the typed error.

## 4. Steps

- **S0, measure (slot, no library change).** A stack-budget matrix with one child process per depth, run on the real keeper, adapter and recorder contexts, on the smallest stack.
  - Record per run: platform, toolchain, optimization mode, usable stack, and the bytes from entry to peak per level.
  - Cover: nodes and containers alternating, row updates and full-row seeds, prebuilt trees, wrapper-only recursion (§3.1), and the exact-limit and one-over cases through the throw and the unwind.
  - Count a clean refusal and stack exhaustion as different outcomes.
  - Run it once on main and once with a prototype of the thin dispatcher (§5 Q1) in a scratch branch.
  - Place the save path, the SDK patch apply and schema extraction (§2).
  - Output: a table in this plan and the limit for Q1.
- **S1:**
  - the budget through R1–R3, R6 and the typed tables (§3.3);
  - `SyncError.nestingTooDeep`, the full check (§3.1) and the failure mapping (§3.4), with `Stage.stateHash`;
  - the replay comparison and the record field (§3.6);
  - the thin dispatcher, if S0 supports it;
  - the frame-shape fixtures (§3.2), and the tests per §3.7;
  - EncodingBenchmark A/B.
- **S2:** the payload validator at registration, the encoders' count (§3.5) and the record codec's in-build check (R9), with docs.
- **S3:** docs: the state limit in `docs/core/failure-handling.md` and `sync.md` (en and zh-TW), replacing the #697 Limit sentence; the narrowed payload guarantee; the TS SDK test at the limit; the solutions entry updated.

S1 and S2 are independent PRs. Each touches `Sources/`, so each goes through a PR and Review.

## 5. Decisions (maintainer orders q1-716 to q4-716)

Q1–Q3 were decided 2026-11-21, as Review recommended. Q4 is Review's recommendation, pending maintainer.

- **Q1, the limit (decided 2026-11-21):** measured, not taken from the wire. S0 prototypes the thin dispatcher: `SnapshotValue.make` with its slow paths moved out (`@inline(never)`), so each level's frame is small. The limit is then the largest value that leaves about 2× measured headroom on the smallest stack in the worst path, capped at `serverFrameMaxDepth` minus the deepest frame shape's overhead (§3.2). If S0 leaves it between two values, take the lower one: loosening later never breaks an adopter, and tightening does. 32 containers is a reasonable measured candidate.
- **Q2, the kind (decided 2026-11-21):** `syncConversion` (§3.4). The docs row says that the wire's 64 is why the state limit exists.
- **Q3, class payload fields (decided 2026-11-21):** refused at registration, paired with the runtime bound in the framework's own traversals (§3.5). A hand-written `encode(to:)` and JSON payloads are documented as the adopter's.
- **Q4, the carrier (pending maintainer):** an explicit budget in the compatible shape of §3.3, not a per-thread counter. A budget is auditable: every row, fallback and custom conversion visibly gets the budget left at its path. A throw unwinds it for free, and there is no hidden thread state. A per-thread counter needs a lookup and a write per container, a `defer` on every level and a rule for synchronous re-entry, and still can't see recursion inside a hand-written hook.

**Phase fit.** The count runs in the sync phase (conversion) and in recording. Nothing moves into apply, and the failure ends the land through the existing path where a throw in the sync plan happens before commit. Refusing at mutation time would be earlier, but it would cost a walk per mutation.
