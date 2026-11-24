# #773: a lint for deterministic handlers and behaviors

**Status:** rev 2, plan only, no code. It follows the maintainer's 2026-11-22 decision on #773 (the follow-up named in #768). Rev 2 answers Review's NOT GO on rev 1 (7428dc06); what changed is in §8. Open questions are in §7.

Code pointers are at main cf7e6e50. **The rules read SwiftSyntax's tree, not text.** They join the parser harness that #772 (PlainData P1 + P2, open, head 77ef4a2d) introduces for its `plain-data` rule: `Tests/SwiftStateTurnsMacrosTests/PlainDataLintTests.swift`. That harness:
- parses each file with `SwiftParser`;
- walks `Sources`, `Tests` and `Examples` from `#filePath`;
- skips a file that holds none of its words, unparsed;
- reports findings by line;
- takes a `lint-allow` marker with a reason;
- pins its behavior with fixture tests.

#772's round 2 moved `plain-data` there because `scripts/lint-turns.sh`'s awk reader is lossy (Review's MF1 on #772 r2): a raw string, a nested comment or an interpolation can hide code from it, or make text look like code. A rule that decides "inside a handler closure" or "a stored property of a behavior" needs the tree, so these two start on it.

## 1. What the compiler doesn't refuse

- **A behavior's reference fields.** A machine's `Behavior` (#768) is `Sendable` and read-only to steps: a write to its stored properties doesn't compile. A call through a reference it holds does. Review of #770 showed it: `turn.behavior.box.bump()` compiles when the behavior holds a `Sendable` class with a `Mutex`.
- **Nondeterministic calls in handlers.** A land handler (`HandleAction`, `HandleEvent`, `Tick`, …) runs in a turn and is replayed from the record. A call in it to `Date()`, `UUID()`, an unseeded random, or a `Task {}` makes the replay diverge. #765 is the RNG case. No type refuses a call to a global function or an initializer.

**Today's count is zero**, by rev 1's text prototype: no such call inside a handler body in the 134 files that declare a `Land("`. L1's repository test counts again on the tree (§5), with the wider scope of §3.1, before the rule lands with an empty allow list.

## 2. Where #769 and #771 make a lint rule unnecessary

Each of these would otherwise need a lint rule; after those plans the compiler refuses it:

| Hazard | Refused by | How |
|---|---|---|
| A resolver reads the keeper's State or casts the payload | #769 | `ResolverContext` is removed; a resolver sees its own fields and its declared capabilities |
| A resolver draws from the land's RNG (#765) | #769 | the land's RNG is never in the land's `Services` |
| A resolver needs a service the land doesn't provide | #769 | `R.Dependencies == Services` at the declaration |
| A builder closure draws randomness | #769 | `ValidateContext` has no `random` (#769 §3.6) |
| A handler declared for another State type, silently dropped | #771 | the builder's typed `buildExpression`; today `LandBuilder` drops it at `default: continue` (LandBuilder.swift:141) |
| A client event handled but not registered, refused at run time | #771 | `HandleEvent` registers its event |
| A handler that awaits | already | every entry takes a synchronous closure |

**What stays lint-only:** a call inside code that runs in a turn (§3.1) and a reference held by a behavior (§3.2). #771 still helps the first rule: every handler is a closure passed to a closed set of entries inside a `LandDSL` block, so the entry names are a complete list of where handler code starts.

**Randomness, the same sentence in this plan, #769's and L-Q2:** handlers draw `ctx.random` (the land's RNG, whose state moves into the model if L-Q2 (a) is decided); builders get none until admission is a recorded turn (K2/K5); resolvers use their own source, recorded.

## 3. The rules

Two rules join the harness beside `plain-data`: `det-handler` and `det-behavior`.
- **Each is a `SyntaxVisitor`,** with its own fixture tests and a repository test.
- **Each has its own allow marker** (`turns-det-handler`, `turns-det-behavior`). The markers are allowed under `Tests/` only and need a reason of at least ten characters. `scripts/lint-turns.sh`'s marker check counts them with the other markers.
- **The tree can't be fooled by text.** Comments, strings, raw strings and nested comments are trivia or literals in the tree, so they can't hide code or look like it. Code inside a string interpolation is code.

### 3.1 `det-handler`: no nondeterminism in code that runs in a turn

**The scope** (where it looks), each defined on the tree:
1. **Handler closures:** a `ClosureExprSyntax` passed to an entry call.
   - The entry call is a `FunctionCallExprSyntax` whose callee is a bare `DeclReferenceExprSyntax` named one of `HandleAction`, `HandleEvent`, `HandleServerInput`, `CanJoin`, `OnJoin`, `OnLeave`, `OnInitialize`, `OnFinalize`, `Tick`, `StateSync`, `DestroyWhenEmpty`, `PersistSnapshot`, `Lifetime`.
   - Its trailing closures and its closure arguments count, labeled ones included: `validate:`, `apply:`, and #769's `resolvers:` builder closure, which runs at admission.
   - The whole closure is in scope, nested closures included.
2. **State types' code:** the bodies of the methods, initializers, subscripts and computed properties of a type declared with `@StateNodeBuilder` (402 declarations today), in its declaration and its extensions. Getters, setters, `didSet` and `willSet` count, and so do `static` members. Handlers call them in the turn: `state.players[id]?.applyDamage(…)` runs State code.
3. **Machine files:** a file that declares a `TurnMachine` conformer, the set `machine-file` uses. Its steps run in turns.
4. **Listed deterministic paths:** `DETERMINISTIC_PATHS`, a list of files or directories whose whole content runs in turns.
   - It is for game logic that handlers call: the rule doesn't follow calls (§3.3).
   - It starts with GameDemo's `Systems/` and `GameHelpers.swift` once checked, each with a reason.
   - It may only grow by review, like `ISOLATED_BOUNDARIES`.

**Out of scope** (nondeterminism is their job):
- a `Resolver`'s `resolve` body: the outside world, whose output is recorded;
- `AfterFinalize` and the deprecated `OnShutdown`: async, after the land's last turn;
- tests' own code outside the scope above.

**What it flags, by token shape.** Each row says which syntax node matches, so a lookalike with another shape passes:

| Group | Shape | Matches | The alternative named in the message |
|---|---|---|---|
| wall clock | **bare callee**: a `FunctionCallExprSyntax` whose callee is a `DeclReferenceExprSyntax` | `Date()`, `Date(timeIntervalSinceNow:)`, `CFAbsoluteTimeGetCurrent()` | `ctx.tickId`, or a time passed in the input |
| wall clock | **type-qualified**: a `MemberAccessExprSyntax` whose base is a `DeclReferenceExprSyntax` naming the type (optionally qualified with `Foundation.`) | `Date.now`, `ContinuousClock.now`, `SuspendingClock.now`, `DispatchTime.now()`, `ProcessInfo.processInfo.systemUptime` | same |
| identity | bare callee with no arguments, or type-qualified `init()` | `UUID()`, `UUID.init()` | an id derived from the input or a counter in State |
| random | **member without `using:`**: a call whose callee is a `MemberAccessExprSyntax` named `random`, `randomElement`, `shuffled` or `shuffle`, with no argument labeled `using` | `Int.random(in: 0...3)`, `xs.randomElement()`, `xs.shuffled()` | `ctx.random` |
| random | bare callee, or the type name in any position | `arc4random()`, `arc4random_uniform(…)`, `drand48()`, `rand()`, `SystemRandomNumberGenerator` | same |
| concurrency | bare callee or a trailing-closure call on the type, and type-qualified members | `Task {`, `Task(…)`, `Task<…>`, `Task.init`, `Task.detached`, `DispatchQueue…`, `Thread(…)`, `OperationQueue(…)` | a resolver (#769), or a server input |
| platform math | **bare callee** only | `sin(`, `cos(`, `tan(`, `atan2(`, `sqrt(`, `pow(`, `exp(`, `log(` (CLAUDE.md's DeterministicMath rule) | `SwiftStateTreeDeterministicMath` |

- **Shapes that pass, by construction:**
  - `logger.log(…)` and `x.sqrt()`: a member call, not a bare callee;
  - `operand(…)` and `brand(…)`: identifiers are whole tokens, so no substring matches `rand`;
  - `let d: Date` and `[Date]`: a type, not a call;
  - `UUID(uuidString: s)`: `UUID` with an argument is deterministic;
  - `.random(in: 0...3, using: &rng)` and `ctx.random.nextInt(in:)`.
- **`using:` is accepted with any generator.** The lint can't tell `ctx.random` from another one, so a reviewer checks it. A seeded generator held in State is deterministic too.
- **Messages** name the group and the alternative: `[det-handler] Date() in a handler: a replay reads another time; use ctx.tickId or pass the time in the input`.

### 3.2 `det-behavior`: a behavior holds values and functions only

- **Which types are behaviors.** In a `TurnMachine` conformer, in its declaration or an extension:
  - the type named by `typealias Behavior = T`;
  - a nested type named `Behavior` (`struct Behavior { … }`). It satisfies the associated type without a typealias: Machine.swift:34 declares `associatedtype Behavior: Sendable = Void`.

  Today that is `TagBehavior` in BehaviorTests.swift:30. After #700's K1b, `KeeperBehavior<State>` too.
- **What it flags:** a stored property of that type. On the tree, that is a `VariableDeclSyntax` at the body's top level whose bindings have no accessor block, or only `didSet`/`willSet` observers. Its declared type is flagged when it contains:
  - a class or actor declared anywhere in the corpus (collected by a first pass over `ClassDeclSyntax` and `ActorDeclSyntax`);
  - a lock or shared cell: `Mutex`, `Atomic`, `ManagedAtomic`, `NSLock`, `NSRecursiveLock`, `OSAllocatedUnfairLock`, `DispatchQueue`;
  - `AnyObject`, `any AnyObject`, or `any Sendable` (an existential can hold a class);
  - a type declared `@unchecked Sendable` in the corpus.
- **One level, then the corpus.** A field whose type is a struct declared in the repository is followed into its stored properties, transitively, within the corpus. A type from another module (`Logger`, `Duration`) isn't followed, apart from the list above.
- **Closures pass.** A stored function (`let handlers: [String: @Sendable (inout S) -> Void]`) is what a behavior is for. What a closure captures can't be seen by a syntactic lint (§3.3).
- **The first finding is K1b's own.** The census puts `services: LandServices` and `logger: Logger` in `KeeperBehavior` (#700 plan, Appendix A.2). `LandServices` is a repository struct whose storage is `[ObjectIdentifier: any Sendable]` (Types.swift:121), so `det-behavior` flags it. It is a real finding: the land's RNG, a class with its own state, is reachable from the behavior, and handlers draw from it. See L-Q2.
- **An exception is tied to its issue.** A finding that has to stay for a while, such as K1b's `services` until L-Q2's slice moves it, goes in the rule's exception list. Each entry has the number of the issue that removes it, and its reason. The list may only shrink:
  - the repository test fails on an entry that no longer matches a finding;
  - a new entry needs review, like `ISOLATED_BOUNDARIES`.

### 3.3 What the lint can't see

Each limit is written in the rule's doc comment and in the docs' Limit line (#772):
- **Calls are not followed.** A handler that calls `GameLogic.step(…)`, which calls `Date()`, passes unless the callee's file is in `DETERMINISTIC_PATHS` or the callee is a State type's method (§3.1, scope 2).
- **Captures are not seen.** A closure in a behavior or a handler that captured a class from outside, at the land's build, isn't caught. The `machine-file` rule already refuses `nonisolated(unsafe)` and `@unchecked Sendable` in machine files; captured `Sendable` classes stay visible to review only.
- **Types aren't resolved.** The rule reads syntax, not the type checker's result, so `let now = Date.self; now.init()` or a typealias for `Date` passes. These are unlikely in handler code, and review sees them.
- **Iteration order.** A handler that iterates a `Dictionary` or `Set` and does order-dependent work (assigns ids, emits events in order) is nondeterministic across processes, since the hash seed differs (`Notes/solutions/2026-11-07-encoded-bytes-vary-with-per-process-hash-order.md`). The rule can't know a value's type.
  - The backstop is the replay check. The E2E replay and the reevaluation runs replay **in another process, with another hash seed**, so an order dependence shows as a mismatch.
  - Setting `SWIFT_DETERMINISTIC_HASHING` in CI would hide exactly that, so CI doesn't set it.
- **The runtime backstop for all of these** is replay itself: a divergence shows as a state hash mismatch.

## 4. In-repo, and what a user could opt into

| Rule | In this repository | A user's project |
|---|---|---|
| `plain-data` (harness), `let-core`, `let-mailbox`, `isolated`, `unchecked-state` | gate (`swift test` for the harness; pre-push and CI "Lint turns" for the script) | no: they guard the library's own invariants, or the compiler covers them for users |
| `machine-file` | gate | useful to a user who writes machines; offered with the two below |
| `det-handler`, `det-behavior` | gate, in `swift test` (the harness) | **opt-in** (L-Q1) |

**In this repository** the rules run where the harness runs, in `SwiftStateTurnsMacrosTests`, so `swift test` and CI's test job gate them. Their fixtures are Swift Testing cases, in `PlainDataLintTests.swift`'s style.

**How a user opts in.** With SwiftSyntax the rules are Swift code, not a script a user can point at a tree. So the visitors move into a small library target, `SwiftStateTreeLint`, which depends on `SwiftParser` only. The repository's tests and a user-facing front end share it:
- **L3a:** an executable, `swift run sst-lint [--only det] <paths>…`, with `--deterministic-paths <file>` for the user's own list. It prints findings in the compiler's `file:line: error:` format, so editors and CI pick them up;
- **L3b (later):** a SwiftPM command plugin (`swift package lint-determinism`) over the same library, once the rules have settled.

The in-repo lists (`ISOLATED_BOUNDARIES`, `ALLOW_MARKERS`, `DETERMINISTIC_PATHS`, the exception list) apply only to the repository's own test, never to a user's run. **SwiftLint's move from SourceKit to SwiftSyntax** is the prior art for both the rules on the tree and the plugin form.

## 5. Tests

**Fixture tests** (Swift Testing, parameterized, in the harness's style). Each case is a source string and the findings expected by line and message. The count must match exactly.

Found (one case per shape):
- each row of §3.1's table, in each shape: `Date()`, `Foundation.Date()`, `Date ()`, `Date/*x*/()`, `Date.now`, `UUID.init()`, `Int.random(in: 0...3)`, `arc4random()`, `Task {` with its `{` on the next line, `Task.detached`, `sqrt(x)`;
- each scope:
  - a trailing closure, a `validate:` closure, a `resolvers:` builder closure, and a nested closure inside a handler;
  - a `@StateNodeBuilder` type's method, its computed property, and a method in its extension;
  - a machine file;
  - a file under a listed deterministic path;
- code inside a string interpolation in a handler;
- for `det-behavior`: a class field, a `Mutex` field, an `any Sendable` field, a field whose repository struct holds a class two levels down, a behavior named by a typealias in an extension, and a nested `struct Behavior`.

Not found (lookalikes):
- `ctx.random.nextInt(in:)`, `.random(in: 0...3, using: &rng)`;
- `logger.log(…)`, `operand(…)`, `x.sqrt()`;
- `let d: Date`, `[Date]`, `UUID(uuidString: s)`;
- `Date()` in a comment, a string, a raw string and a nested comment;
- `Date()` in a `Resolver`'s `resolve`, and in `AfterFinalize`;
- a `Task {}` outside any handler in a test file;
- a behavior holding closures and plain values; a struct field followed into a plain struct;
- a marked line with a reason. The same line without a reason is found.

**The list rules:** a `DETERMINISTIC_PATHS` entry that no longer exists fails, and so does an exception (§3.2) that no longer matches a finding, so neither list can go stale.

**Mutants** (each must fail a fixture case):
- the bare-callee check accepts member calls: fails on `logger.log`;
- `using:` is ignored: fails on the seeded case;
- the nested-`Behavior` case is dropped;
- the State-type scope is dropped.

**Over the repository:** zero findings at landing, or an exception tied to its issue (§3.2).

## 6. Slices

All are core-path PRs: the rules are Swift in `Tests/` and, from L3a, a library target and `Package.swift`.

| Slice | Content | After |
|---|---|---|
| **L1** | `det-handler` (§3.1) in the harness, `DETERMINISTIC_PATHS` with GameDemo's logic files checked, the fixtures and mutants, the repository test, the docs' Limit line linking the rule (EN and zh-TW, the DocC page) | #772 merged (the harness) |
| **L2** | `det-behavior` (§3.2). It lands before #700's K1b, so K1b's `KeeperBehavior` is checked from its first commit | L1; #768 is merged |
| **L3a** | The visitors move to `SwiftStateTreeLint`; the `sst-lint` executable (§4); the user-facing doc section | L1, L2, and L-Q1 |
| **L3b** | The command plugin, a separate issue | L3a, once the rules have settled |

## 7. Questions for the maintainer

| # | Question | Options | Recommendation |
|---|---|---|---|
| L-Q1 | What users get | (a) in-repo only; (b) the `sst-lint` executable over a shared lint library (L3a); (c) (b) plus a SwiftPM command plugin later (L3b) | **(c):** (b) is a small target and a doc section once the visitors exist, and the plugin waits until the rules stop changing |
| L-Q2 | `KeeperBehavior`'s `services` (a struct of `any Sendable`, holding the land's RNG class) | (a) move the land's RNG state into the model: a plain generator state (seed and counter) that `ctx.random` advances in the turn, recorded and replayed with the model; `services` then holds only outside-world services and moves Outside (census A.3); (b) keep it in the behavior, as an exception tied to its issue | **(a):** the RNG's state is turn state, so it belongs to the model. It also ends the only shared mutable class a handler reaches. It is K1b's census call, so the #700 plan records it there |
| L-Q3 | `DETERMINISTIC_PATHS` for GameDemo | (a) list its logic directories now; (b) leave Examples out, since the lint can't follow calls anyway | **(a):** GameDemo is the reference game and its systems run in ticks; the list is short |

## 8. Revisions

**Rev 2** answers Review's NOT GO on rev 1 (7428dc06: 1 must-fix, 4 should, 2 nits):
- **MF1** (both rules sat on the lossy awk reader): they are built on SwiftSyntax in #772's parser harness from the start (header, §3). The consequences:
  - every slice is a core-path PR (§6);
  - L3 becomes a library target with an executable, and a plugin later, so L-Q1's options change (§4, §7);
  - L1 depends on #772's harness.

  SwiftLint's move to SwiftSyntax is the prior art.
- **Should, token shape per group:** §3.1's table names the node each row matches (bare callee, type-qualified, member without `using:`). `logger.log(` and `operand(` are passing fixtures.
- **Should, State types' code:** the methods and computed properties of `@StateNodeBuilder` types are in scope (§3.1, scope 2).
- **Should, nested `struct Behavior`:** a behavior is also a nested type named `Behavior` (§3.2), with a fixture and a mutant (§5).
- **Should, exceptions:** each is tied to the issue that removes it, and the list may only shrink (§3.2, §5).
- **Nits:** replay runs in another process with another hash seed, and CI doesn't set `SWIFT_DETERMINISTIC_HASHING` (§3.3). `[Date]` and `UUID(uuidString:)` are passing fixtures (§3.1, §5).
- **The randomness sentence** is shared with #769 §3.6 and L-Q2 (§2).
