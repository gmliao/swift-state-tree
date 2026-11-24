# #773: a lint for deterministic handlers and behaviors

**Status:** rev 1, plan only, no code. It follows the maintainer's 2026-11-22 decision on #773 (the follow-up named in #768). Open questions are in §7.

Code pointers are at main 1ee8b88f. The rules join `scripts/lint-turns.sh` and follow the shape #772 (PlainData P1 + P2, open at 06ce5f99) gives it: the word matched anywhere in code, whatever its spelling around it, and self-test fixtures that list lookalikes beside each finding.

## 1. What the compiler doesn't refuse

- **A behavior's reference fields.** A machine's `Behavior` (#768) is `Sendable` and read-only to steps: a write to its stored properties doesn't compile. A call through a reference it holds does. Review of #770 showed it: `turn.behavior.box.bump()` compiles when the behavior holds a `Sendable` class with a `Mutex`.
- **Nondeterministic calls in handlers.** A land handler (`HandleAction`, `HandleEvent`, `Tick`, …) runs in a turn and is replayed from the record. A call in it to `Date()`, `UUID()`, an unseeded random, or a `Task {}` makes the replay diverge. #765 is the RNG case. No type refuses a call to a global function or an initializer.

**Today's count is zero.** A prototype of §3.1's scoping over the 134 files that declare a `Land("` found no such call inside a handler body. So the rule can land with an empty allow list, and it guards what is there.

## 2. Where #769 and #771 make a lint rule unnecessary

Each of these would otherwise need a lint rule; after those plans the compiler refuses it:

| Hazard | Refused by | How |
|---|---|---|
| A resolver reads the keeper's State or casts the payload | #769 | `ResolverContext` is removed; a resolver sees its own fields and its declared capabilities |
| A resolver draws from the land's RNG (#765) | #769 | the land's RNG is never in the land's `Services` |
| A resolver needs a service the land doesn't provide | #769 | `R.Dependencies == Services` at the declaration |
| A handler declared for another State type, silently dropped | #771 | the builder's typed `buildExpression`; today `LandBuilder` drops it at `default: continue` (LandBuilder.swift:141) |
| A client event handled but not registered, refused at run time | #771 | `HandleEvent` registers its event |
| A handler that awaits | already | every entry takes a synchronous closure |

**What stays lint-only:** a call inside a body (§3.1) and a reference held by a behavior (§3.2). #771 still helps the first rule: every handler is a closure passed to a closed set of entries inside a `LandDSL` block, so the entry names are a complete list of where handler code starts.

## 3. The rules

Two rules join `RULES` (`plain-data|let-core|machine-file|isolated`): `det-handler` and `det-behavior`. They use the existing machinery:
- `strip()`: comments and string literals removed, and since #772 a removed `/* */` comment leaves a space, so it can't glue two tokens;
- `headers()`: a declaration's header joined over its lines;
- `lint-allow` markers: under `Tests/` only, with a reason of at least ten characters, counted in `ALLOW_MARKERS`;
- the may-only-shrink lists.

### 3.1 `det-handler`: no nondeterminism in code that runs in a turn

**The scope** (where it looks):
1. **Handler closures:** the closure passed to an entry, by brace depth from the entry's first `{` to its close. Labeled closures (`validate:`, `apply:`) count, as does #769's `resolvers:` builder closure, which runs in the turn. The entries are `HandleAction`, `HandleEvent`, `HandleServerInput`, `CanJoin`, `OnJoin`, `OnLeave`, `OnInitialize`, `OnFinalize`, `Tick`, `StateSync`, `DestroyWhenEmpty` and `PersistSnapshot`'s closures. `Lifetime(_ configure:)`'s closure form counts as a whole.
2. **Machine files:** a file that declares a `TurnMachine`, the set `machine-file` already uses. Its steps run in turns.
3. **Listed deterministic paths:** `DETERMINISTIC_PATHS`, a list of files or directories whose whole content runs in turns. It is for game logic that handlers call: the lint doesn't follow calls (§3.3). It starts with GameDemo's `Systems/` and `GameHelpers.swift` once checked, each with a reason. It may only grow by review, like `ISOLATED_BOUNDARIES`.

**Out of scope** (nondeterminism is their job):
- a `Resolver`'s `resolve` body: the outside world, whose output is recorded;
- `AfterFinalize` and the deprecated `OnShutdown`: async, after the land's last turn;
- tests' own code outside handler closures.

**What it flags** in scope, as a word anywhere in code (an `x.` prefix or a space before `(` doesn't hide it; `Foundation.` qualification counts):

| Group | Calls | The deterministic alternative named in the message |
|---|---|---|
| wall clock | `Date()`, `Date.now`, `Date(timeIntervalSinceNow:`, `ContinuousClock.now`, `SuspendingClock.now`, `DispatchTime.now`, `CFAbsoluteTimeGetCurrent`, `ProcessInfo…systemUptime` | `ctx.tickId`, or a time passed in the input |
| identity | `UUID()`, `UUID.init()` | an id derived from the input or a counter in State |
| random | `.random(` / `.randomElement(` / `.shuffled(` / `.shuffle(` without `using:`, `SystemRandomNumberGenerator`, `arc4random`, `drand48`, `rand(` | `ctx.random` |
| concurrency | `Task {`, `Task(`, `Task<`, `Task.init`, `Task.detached` (the `machine-file` pattern), `DispatchQueue`, `Thread(`, `OperationQueue` | a resolver (#769), or a server input |
| platform math | `sin`, `cos`, `tan`, `atan2`, `sqrt`, `pow`, `exp`, `log` as free functions (CLAUDE.md's DeterministicMath rule) | `SwiftStateTreeDeterministicMath` |

- **`using:` is accepted with any generator.** The lint can't tell `ctx.random` from another one, so a reviewer checks it. A seeded generator held in State is deterministic too.
- **Messages** name the group and the alternative: `[det-handler] Date() in a handler: a replay reads another time; use ctx.tickId or pass the time in the input`.

### 3.2 `det-behavior`: a behavior holds values and functions only

- **Which types:** a type named by `typealias Behavior = T` in a `TurnMachine` conformer, in its declaration or an extension. The `headers()` pass collects them, the way it collects `TurnActor` conformers for `let-core`. Today: `TagBehavior` in BehaviorTests.swift:30. After #700's K1b: `KeeperBehavior<State>`.
- **What it flags:** a stored property of that type (a `let` or `var` member at the body's top level, not computed) whose declared type contains:
  - a class or actor declared anywhere in the corpus (collected from `headers()`, kind `class` or `actor`, `final` or not);
  - a lock or shared cell: `Mutex`, `Atomic`, `ManagedAtomic`, `NSLock`, `NSRecursiveLock`, `OSAllocatedUnfairLock`, `DispatchQueue`;
  - `AnyObject`, `any AnyObject`, or `any Sendable` (an existential can hold a class);
  - a type declared `@unchecked Sendable` in the corpus.
- **One level, then the corpus.** A field whose type is a struct declared in the repository is followed into its stored properties, transitively, within the corpus. A type from another module (`Logger`, `Duration`) isn't followed, apart from the list above.
- **Closures pass.** A stored function (`let handlers: [String: @Sendable (inout S) -> Void]`) is what a behavior is for. What a closure captures can't be seen by a lexical lint (§3.3).
- **The first finding is K1b's own:** the census puts `services: LandServices` and `logger: Logger` in `KeeperBehavior` (#700 plan, Appendix A.2). `LandServices` is a repository struct whose storage is `[ObjectIdentifier: any Sendable]` (Types.swift:121), so `det-behavior` flags it. It is a real finding: the land's RNG, a class with its own state, is reachable from the behavior, and handlers draw from it. See L-Q2.

### 3.3 What the lint can't see

Each limit is written in the script's header and in the docs' Limit line (#772):
- **Calls are not followed.** A handler that calls `GameLogic.step(…)`, which calls `Date()`, passes unless the callee's file is in `DETERMINISTIC_PATHS`.
- **Captures are not seen.** A closure in a behavior or a handler that captured a class from outside, at the land's build, isn't caught. The `machine-file` rule already refuses `nonisolated(unsafe)` and `@unchecked Sendable` in machine files; captured `Sendable` classes stay visible to review only.
- **Iteration order.** A handler that iterates a `Dictionary` or `Set` and does order-dependent work (assigns ids, emits events in order) is nondeterministic across processes, since the hash seed differs (`Notes/solutions/2026-11-07-encoded-bytes-vary-with-per-process-hash-order.md`). A lexical lint can't know a value's type. The backstop is the replay check: the E2E replay and the reevaluation runs replay in another process.
- **The runtime backstop for all of these** is replay itself: a divergence shows as a state hash mismatch.

## 4. In-repo only, and what a user could opt into

| Rule | In this repository | A user's project |
|---|---|---|
| `plain-data`, `let-core`, `let-mailbox`, `isolated`, `unchecked-state` | gate (pre-push, CI "Lint turns") | no: they guard the library's own invariants, or the compiler covers them for users |
| `machine-file` | gate | useful to a user who writes machines; offered with the two below |
| `det-handler`, `det-behavior` | gate | **opt-in** (L-Q1) |

**How a user opts in:** the script already takes a root (`scripts/lint-turns.sh [--self-test] [repo root]`). Rev 1 proposes:
- `--only det` runs just `machine-file`, `det-handler` and `det-behavior`;
- `--paths <dir>…` replaces the fixed `Sources Tests Examples` walk;
- `--deterministic-paths <file>` supplies the user's own list.

So a user can run the repository's script against their tree, unchanged. The in-repo lists (`ISOLATED_BOUNDARIES`, `ALLOW_MARKERS`, `DETERMINISTIC_PATHS`) apply only without `--only`. A SwiftPM command plugin (`swift package lint-determinism`) would be the packaged form. It is a separate issue, after the rules have settled (L-Q1).

## 5. Tests

**Self-test fixtures** (`--self-test`, in #772's style). Each finding line is listed with its expected message, and the count of findings must match exactly.

The passing fixture (lookalikes) holds:
- `ctx.random.nextInt(in:)`;
- `.random(in: 0...3, using: &rng)`;
- `let d: Date`;
- `Date()` in a comment and in a string;
- `Date()` in a `Resolver`'s `resolve`, and in `AfterFinalize`;
- a `Task {}` outside any handler in a test file;
- a behavior holding closures and plain values;
- a struct field followed into a plain struct.

The failing fixture holds one line per call group:
- the spellings: `Foundation.Date()`, `Date ()`, `UUID.init()`, `Date/*x*/()`, and `Task` with its `{` on the next line;
- a `validate:` closure and a `resolvers:` builder closure;
- a file under a listed deterministic path, and a machine file;
- for `det-behavior`: a class field, a `Mutex` field, an `any Sendable` field, a field whose repository struct holds a class two levels down, and a behavior declared in an extension;
- an `--only det` run over a tree without `ALLOW_MARKERS` files, which must report only the det rules.

**The list rules:** a `DETERMINISTIC_PATHS` entry that no longer exists fails, so the list can't go stale.

**Over the repository:** zero findings at landing (§1). If K1b's `KeeperBehavior` hasn't moved `services` out by then, it has a listed exception with its reason and L-Q2's slice.

## 6. Slices

| Slice | Content | After |
|---|---|---|
| **L1** | `det-handler` with its scope (§3.1), `DETERMINISTIC_PATHS` with GameDemo's logic files checked, the self-test, the script header, the docs' Limit line linking the rule (EN and zh-TW, the DocC page) | #772 merged (its `strip()` change and fixture style) |
| **L2** | `det-behavior` (§3.2). It lands before #700's K1b, so K1b's `KeeperBehavior` is checked from its first commit | L1; #768 is merged |
| **L3** | `--only det`, `--paths` and `--deterministic-paths` (§4), the user-facing doc section. The command plugin is a separate issue | L1 |

No Swift code changes; each slice is `scripts/` and docs, a direct change (`scripts/` isn't a core path). CI runs the self-test before the lint, as it does today (build-and-test.yml:85–86).

## 7. Questions for the maintainer

| # | Question | Options | Recommendation |
|---|---|---|---|
| L-Q1 | What users get | (a) in-repo only; (b) the script's `--only det` mode on their tree (L3); (c) (b) plus a SwiftPM command plugin later | **(c):** (b) costs a flag and a doc section, and the plugin waits until the rules stop changing |
| L-Q2 | `KeeperBehavior`'s `services` (a struct of `any Sendable`, holding the land's RNG class) | (a) move the land's RNG state into the model: a plain generator state (seed and counter) that `ctx.random` advances in the turn, recorded and replayed with the model; `services` then holds only outside-world services and moves Outside (census A.3); (b) keep it in the behavior with a listed exception | **(a):** the RNG's state is turn state, so it belongs to the model. It also ends the only shared mutable class a handler reaches. It is K1b's census call, so the #700 plan records it there |
| L-Q3 | `DETERMINISTIC_PATHS` for GameDemo | (a) list its logic directories now; (b) leave Examples out, since the lint can't follow calls anyway | **(a):** GameDemo is the reference game and its systems run in ticks; the list is short |
