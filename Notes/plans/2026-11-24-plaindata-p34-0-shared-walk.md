# PlainData P3/4-0: one field walk for both macro targets

**Status:** rev 2, plan only. Rev 1 (2af72dd2) was NOT GO on one must-fix, §2.0, which waits for the maintainer; the rest of the review is folded in. The branch sits on #772's head and is merged forward: #772's fix round (3cd3a65c) is merged in now, and `main` will be merged in after #772 merges. The branch is never force-pushed. A slice of [PlainData all the way](2026-11-22-plaindata-all-the-way.md) (§4), added so that P3 (payloads) and P4 (`State`) can run in parallel: it lands what both of them need, once.

## 1. Why a slice before P3 and P4

P3 makes `@Payload` emit `_plainDataCheck`, and P4 makes `@StateNodeBuilder` emit it, each with the same field checks as `@PlainData` (parent plan §3.2). Those checks are built by the type walk in `Sources/SwiftStateTurnsMacros/PlainDataMacro.swift`. Both macros live in another macro target, `SwiftStateTreeMacros`, which has its own refusal list (`RefusedFieldTypes.swift`: `Any`, `AnyObject`, `AnyHashable`, `AnyCodable`, `Decimal`). If P3 and P4 each brought the walk across, they would write two copies, or collide in `RefusedFieldTypes.swift`. Both slices also need the DeterministicMath types to be `PlainData`, because those types appear in `State` and in payloads.

## 2. Scope

### 2.0 How an expansion in a `SwiftStateTree`-only file names `PlainData` (open: the maintainer decides)

P3 and P4 put `_plainDataCheck` into `@Payload` and `@StateNodeBuilder`. A user file that imports only `SwiftStateTree` then holds an expansion that names `SwiftStateTurns.PlainData` and `SwiftStateTurns.PlainDataCheck`. `SwiftStateTree` doesn't re-export `SwiftStateTurns`, so that file fails with "cannot find type" (Review's probe). The same gap makes a user add `import SwiftStateTurns` for `@PlainData` on their own types today (docs/core/sync.md). There are two options:
- **(a)** `@_exported import SwiftStateTurns` in `SwiftStateTree`. Every `SwiftStateTree` user sees the turn core's public names, and expansions keep naming `SwiftStateTurns.PlainDataCheck`, as #772's do.
- **(b)** Narrow typealiases plus a `@PlainData` macro declaration in `SwiftStateTree`. The expansions in `SwiftStateTree`'s macros would name `SwiftStateTree.…` aliases instead. Two declarations of one macro would point at one implementation.

Main recommends (a). This slice applies the decision. It is the only part of the slice that changes a public import, so it goes in its own commit, and its Public API entry is in §5.

### 2.1 One walk, used by both macro targets

- A new regular target, `PlainDataMacroSupport` (`Sources/PlainDataMacroSupport`), depending on `SwiftSyntax`, `SwiftDiagnostics` and `SwiftSyntaxMacros`. Both `SwiftStateTurnsMacros` and `SwiftStateTreeMacros` depend on it. It isn't a product.
- It takes from `PlainDataMacro.swift`, moved unchanged as #772 merges it, with #772's fixes kept, not redone: the identity check for wrappers spelled by name, the module-qualified names, the witness access from an enclosing extension, and the closure form of the existential check:
  - the member walk (`checkLines`, including `#if` clauses, `var a, b: T`, computed and observed properties);
  - the type walk (`checks`, `pair`: existentials inside `Optional`, `Array`, `ContiguousArray` and a `Dictionary` value);
  - `RefusedTypeVisitor`, `foundationReplacement` and the diagnostics.
- `PlainDataMacro` keeps only the extension it builds (conformance, generic `where`, witness access).
- `RefusedFieldTypes.swift` goes. Its names (`Any`, `AnyObject`, `AnyHashable`, `AnyCodable`) and its `Decimal` case move into the shared target's refusal classifier, next to the Foundation list. `diagnoseRefusedFieldTypes` becomes a thin adapter in `SwiftStateTreeMacros` over that classifier. It keeps today's scope:
  - synced fields only for `@StateNodeBuilder`, with the `@Sync(.serverOnly)` exemption for `Decimal`;
  - `Decimal` only for `@Payload`;
  - the diagnostic IDs `refusedSyncFieldType` and `refusedDecimalFieldType`.

`@Payload` and `@StateNodeBuilder` behave as before in this slice, apart from the `Decimal` message (§2.2). Emitting `_plainDataCheck` from them is P3's and P4's work, which then only call the shared walk.

**Risk: SwiftPM and the swift-syntax prebuilt.** A macro target that depends on a regular target is supported. CI's 6.2.4 uses the prebuilt swift-syntax 602.0.0, and an extra host target between a macro and swift-syntax must not make SwiftPM build swift-syntax from source. Step 0 checks the first CI run's build log for the prebuilt, and the `build (variants)` and `release` job times against #772's run on 06ce5f99 (14m15s, 20m44s). If SwiftPM falls back to a source build, stop and report to Main with the numbers before choosing another way to share the code.

The same stop rule holds if the toolchain bump to 6.4.3 lands on `main` before this PR. In that case, `main` is merged in, and the comparison base becomes the latest green `main` run on the bumped toolchain, not #772's run: the check is then whether the extra host target changes how SwiftPM uses the prebuilt on that toolchain.

### 2.2 Q2: the Foundation diagnostics, one copy

`@PlainData` already refuses `Date`, `UUID`, `URL` and `Decimal`, and names the replacement (#772). After §2.1 that text is the only copy. `@StateNodeBuilder`'s and `@Payload`'s `Decimal` diagnostic uses it, and keeps its #597 reason (no wire form).

Refusing `Date`, `UUID` and `URL` in payloads, server inputs, resolver outputs and `State` turns on in P3 and P4, when those macros switch to the shared walk. Doing it here would break, before their slice, the resolver outputs and server inputs that hold them today: `Tests/SwiftStateTreeTests/ResolverOutputReplayTests.swift`, `ServerInputTests.swift`, `ReplayTypedEventDecodeTests.swift`, and `Examples/GameDemo/Sources/GameContent/Resolvers/AsyncTestResolver.swift` (`resolvedAt: Date`). P3 moves those.

### 2.3 Q3: a diagnostic for a nested type without `@PlainData`

A syntactic macro can't see whether a field's type has `@PlainData`. The compiler sees it when it checks the emitted `PlainDataCheck.field(T.self)`, and today says only "requires that 'T' conform to 'PlainData'". Two changes give the error a fix and a field name:
- `PlainDataCheck` gains an unconstrained overload, `@available(*, unavailable, message: …)`. Overload resolution picks the constrained `field<T: PlainData>` whenever it applies, so the unavailable one is chosen only for a type that isn't `PlainData`, and its message is the error. Proposed message: "this field's type isn't PlainData: add @PlainData to your struct or enum; a class, closure or Any can't be stored".
- Each emitted check passes the field's name: `SwiftStateTurns.PlainDataCheck.field((Position).self, "position")`. The error sits on that line of the expansion, so the field is named where the error points. An associated value passes `"case.index"`.

Probe (one file, `swiftc -typecheck -swift-version 6`): the constrained overload wins for `Int`, a `PlainData` struct and `[PlainData struct]`, which compile. The unavailable message is the error for a nested struct without the conformance, `[that struct]`, a class, and an unconstrained generic `T`. The results are the same on Swift 6.4.2 (macOS) and 6.2.4 (`swift:6.2.4-noble`). The probe doesn't cover the error's position inside a macro expansion. The must-not-compile snippets below pin that.

`existential` keeps its current error ("to closure result type 'any PlainData'"). Its failure is a closure conversion, not overload resolution, so the same trick doesn't apply. That error is already specific to `any P`.

The must-not-compile snippets whose `expect-error` matches the old field text move to the new message where the failing check is a `field` call: `turns/plaindata-withdraw-token`, `turns/plaindata-class-in-dictionary`, `turns/plaindata-clock-instant` and #772's `turns/plaindata-namesake-check`, each confirmed when it runs. Snippets that fail elsewhere keep theirs:
- `internal-not-plain` and `internal-decimal`: `Internal`'s generic constraint, not a `field` call;
- a machine without `PlainData`, and a class through a refining protocol;
- an `any NotPlain`;
- the shadowed wrapper, which fails at the `same` check.

### 2.4 `@PlainData` on the DeterministicMath types

`SwiftStateTreeDeterministicMath` adds `SwiftStateTurns` to its dependencies.

**The module graph.** DeterministicMath isn't a leaf today. It depends on `SwiftStateTree` and `SwiftStateTreeMacros` (`Package.swift`, for `@SnapshotConvertible`), and `SwiftStateTree` depends on `SwiftStateTurns`. So `SwiftStateTurns` is already in its dependency closure, and the new entry adds no module to it. It only makes explicit an import the module now makes itself (`import SwiftStateTurns` for `@PlainData`), instead of relying on a transitive one.

**Why not a conformance-only shim.** A shim would write the conformances in another module, for example `SwiftStateTree` or a new module between the two. That doesn't work:
- `@PlainData` is an attached macro. It goes on the type's declaration, which is in DeterministicMath.
- A conformance written in an extension elsewhere has to write `_plainDataCheck` by hand. Outside `SwiftStateTurns`, the lint refuses that (parent plan §3.2), and the hand-written checks would drift from the fields.
- A retroactive conformance of another module's type is also what Swift warns about (`@retroactive`).

`@PlainData` goes on its value types with stored fields:
- `IVec2`, `IVec3`, `Position2`, `Velocity2`, `Acceleration2`, `Angle`;
- `IAABB2`, `ICircle`, `ILineSegment`, `IRay`, `Grid2`;
- `OverflowPolicy`.

Several already carry `@SnapshotConvertible`, and the two extension macros sit side by side. `FixedPoint` and `OverflowHandler` have no stored state, which is checked at implementation: a type with none is left alone. Any type found to hold a non-plain field stops the slice and is reported; none is known.

## 3. Tests and mutants

Holds and events, never timing. Nothing here is concurrent.
- The `SwiftStateTurnsMacrosTests` expansions stay green with one change: the `field` lines gain the name argument, on top of what #772's final round emits (module-qualified names, `same` lines, the existential closure form). That is the only expected diff, and the test diff shows it.
- The `SwiftStateTreeMacros` tests stay green unchanged, apart from the `Decimal` message text.
- New compile test: `PlainDataCheck.field(T.self)` for each DeterministicMath type from §2.4, in `SwiftStateTreeDeterministicMathTests`.
- New must-not-compile snippets:
  - a `@PlainData` struct holding a nested struct without `@PlainData` (`expect-error` is the new message, and the line names the field);
  - the same inside `[T]` and `[String: T]`.
- Mutants:
  - (a) the unavailable overload deleted: the new snippets fail on their `expect-error`;
  - (b) the name argument dropped from the emitted line: the expansion tests fail;
  - (c) `@PlainData` removed from `IVec2`: the compile test fails;
  - (d) `AnyCodable` dropped from the classifier's names: the existing `refusedSyncFieldType` tests fail.

## 3a. The lint and the new paths

`scripts/lint-turns.sh` refuses any code use of `_plainDataCheck` outside `Sources/SwiftStateTurns/` and `Sources/SwiftStateTurnsMacros/` (#772). It strips comments and string literals first. For the paths this slice and P3/P4 add:
- **`Sources/PlainDataMacroSupport/`.** The walk names `_plainDataCheck` only inside string literals, the generated code, so it needs no exemption. If a check of its own ever needs the word in code, the exemption is added then, with the path in the lint's core list.
- **`Sources/SwiftStateTreeMacros/`.** The same: emission is in string literals.
- **The macro declarations in `Sources/SwiftStateTree/`.** In P3 and P4, `@Payload` and `@StateNodeBuilder` gain `names: named(_plainDataCheck)` in their `@attached(…)` declarations. That is code, and the lint would refuse it. P3 (the first of the two to land) adds one narrow exemption: `named(_plainDataCheck)` inside an `@attached(` attribute, anywhere under `Sources/`. A role declaration names the member; it writes nothing. A self-test pins it: allowed in `@attached(extension, names: named(_plainDataCheck))`, refused in a `func`. Under option (b) of §2.0, the `@PlainData` declaration in `SwiftStateTree` needs the same exemption, so it lands with this slice instead.

## 4. Verification

- On the Mac, holding the slot:
  - `swift build`;
  - `swift test --filter` for `SwiftStateTurnsMacrosTests`, `SwiftStateTreeMacrosTests` and `SwiftStateTreeDeterministicMathTests`;
  - `scripts/check-must-not-compile.sh`, `scripts/lint-turns.sh` and the mutants above.
- On CI: the full `swift test` and E2E, plus step 0's prebuilt check (§2.1).

A/B: none. The slice is compile time only: `_plainDataCheck` is never called, and the conformances add no code to a hot path. The PR body says so.

## 5. Public API

§2.0's decision adds an entry: under (a), `SwiftStateTree` re-exports `SwiftStateTurns` (additive, but every public name of the turn core becomes visible to `SwiftStateTree` users, and a user type that shares a name with one of them becomes ambiguous where both are visible); under (b), new typealiases and a second `@PlainData` declaration in `SwiftStateTree`. The rest is additive and source compatible:
- `PlainData` conformances on the DeterministicMath types in §2.4;
- `PlainDataCheck.field` gains a defaulted `StaticString` name parameter and an unavailable unconstrained overload. `PlainDataCheck` is public but documented "not for direct use".

The new target isn't a product.

## 6. After this slice

P3 (Code-1) and P4 (Code-2) both start from this slice's merge. Each switches its macro to the shared walk and turns on the full refusals there (§2.2). The recorded raw bytes (parent plan Q4, P5) are not in P3: they go with #700 K1.
