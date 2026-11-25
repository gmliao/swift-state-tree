# PlainData P4-2: the registration walks become a debug-build guard

**Status:** rev 1.2, plan only (rev 1.2: §1's boundaries as of #834 round 4). Review ruled Q1 = (a) on 2026-11-25, provided the PR maps each removed group-A test to the kept test that covers its branch and shape. This is slice P4-2 of `2026-11-24-plaindata-p4-state.md` (rev 3, §3.6 and §7), under P4-Q4 (b), which the maintainer decided on 2026-11-24. It builds on P4-1 (#834). Code pointers were re-checked at #834's round-1 head 41e7c7ee; round 1 moved none of them.

## 1. Goal

Since P4-1, the compiler refuses a class, `Any`, an existential or a `Decimal` anywhere in a state field. In this repository the lint refuses a hand-written `PlainData` witness, so the registration walks that looked for these find nothing here. Outside the repository four things get past the compiler (`sync.md` § "At registration and conversion", as of #834 round 4):
- a hand-written witness;
- a bare namesake of one of this project's macros (a user macro named `SnapshotConvertible`) beside `@StateNodeBuilder`;
- a peer macro on a member of a state type (#102 = B);
- a nested `@PlainData`/`@Payload` type, which doesn't run the allow list (#102 = B).

The walks reach only fields in the state type's field metadata and the values nested in them. So they guard the hand-written witness and the nested type's members. They never saw the members a macro adds to the state type itself (the bare namesake's, a member peer macro's).

With the walks debug-only, the hand-written witness and the nested-type case are guarded in debug builds only. The member-macro cases have no runtime check in either build. #837 closes two of the four at compile time: the member peer macro, and the nested `@PlainData`/`@Payload` type. After #837, the walks are the only check for the hand-written witness, and nothing checks the bare namesake.

P4-Q4 (b) settles it this way:
- **Debug builds** keep the walks, as the guard for a user's project during development.
- **Release builds** drop them, so production registration doesn't pay for a walk that can't fire here.
- The public error cases stay in both builds, so the API doesn't differ by configuration.

## 2. What changes (the † rows of P4 §3.6)

| Item | Where (41e7c7ee) | P4-2 |
|---|---|---|
| `SyncValueSemantics.validate`, the #464 Mirror walk over a default instance | `Sync/SyncValueSemantics.swift` (138 lines); called at `Land/SyncRegistration.swift:89` | the call and the walk go under `#if DEBUG` |
| `TypeWalker.visitValue`'s `Decimal` branch (the state half of #597) | `SyncRegistration.swift:215–216` | `#if DEBUG` |
| `TypeWalker`'s open-type branches: the value at `:217` and the dictionary key at `:226` | same file | `#if DEBUG`. The key's `.unsupportedKey` check next to them runs in both builds |
| `SyncValueSemanticsError`, and `Problem.valueSemantics`, `.existentialField`, `.decimalField` | `SyncRegistration.swift:14, :30, :35` | stay public in both builds; produced in debug only |
| `isOpenType` (package) | `SyncRegistration.swift:173` | stays: `DecimalFields`/payload code may read it (check during code) |

Both callers, `LandRegistration.swift:204` (registration) and `LandKeeper.swift:1394` (a keeper built without a host), go through `SyncRegistration.cachedProblems`. Both get the same per-build behavior, and neither call site changes.

What stays in both builds:
- `.policyNesting`, `.unsupportedKey` and `.typeNameCollision`;
- `DecimalFields.payloadPaths` (P3's);
- the sync table's "is or holds a reference type" fallback (`Sync/SyncTables.swift:86, :228`);
- `SnapshotValue`'s `.class`/`classRefusal` conversion backstop.

These aren't value-semantics walks of the state, or they guard the payload path (P3/P5).

In release, the `TypeWalker` still needs a default instance for `.unsupportedKey`, and `SyncPolicyNesting` needs one too. What release saves is `SyncValueSemantics`'s own `rootType.init()` and its Mirror walk.

**Configuration boundary.** SwiftPM builds a package dependency in the root's configuration. A user's `swift build` (debug) gets the guard, and `swift build -c release` doesn't. A prebuilt binary distribution would freeze one choice, but none exists. Xcode's Debug configuration also defines `DEBUG` for package dependencies, so an app built from Xcode in Debug gets the guard too, and an archive (Release) doesn't.

## 3. Tests

**The guard, in debug only (`#if DEBUG`).** Three tests, one per walk, in a new `Tests/SwiftStateTreeTests/RegistrationDebugGuardTests.swift`:
- `debugRegistrationRefusesHandWrittenClassWitness`: a hand-witnessed class in a `@Sync` field is refused with `.valueSemantics`.
- `debugRegistrationRefusesHandWrittenAny`: a hand-witnessed plain struct holding `AnyCodable?`/`[AnyObject]` is refused with `.existentialField`.
- `debugRegistrationRefusesHandWrittenDecimal`: a hand-witnessed struct holding `Decimal` is refused with `.decimalField`.

**The existing group-A tests** (#834 comment: `SyncValueSemanticsTests` ×9 markers, `SyncRegistrationTests` ×2, `DecimalRegistrationTests` ×1, `LandTypeRegistryTests` ×1, `NestedNodePolicyTests` ×1; 14 markers in all):
- **(a) Fold to about 3 (recommended; ruled by Review).** Keep the tests that pin a walk's coverage (enum payloads, optionals, dictionary keys, convertible holders) under `#if DEBUG` in their files. Fold the plain duplicates into the three guard tests. Lower `ALLOW_MARKERS` to what is left. The PR gives the exact counts, and a table that maps each removed test to the kept test covering its branch and shape.
- **(b) Keep them all.** Keep every test under `#if DEBUG`, with their markers unchanged. This is the smaller change, but the list doesn't shrink.

**Release: no walk.** `releaseRegistrationRunsNoValueWalk` (`#if !DEBUG`):
- A package-only counter, incremented once per entry into `SyncValueSemantics.validate` and once per visit of the two `TypeWalker` branches, is read before and after registering a land of a new state type. The cache is per type, so a fresh type is needed. The test asserts that the difference is exactly 0. The test is a count, never a timing.
- The same test in debug (`#if DEBUG`, in the guard file) asserts the difference is at least 1, so the counter is shown to move at all.
- The same hand-witnessed class registers without error.
- CI runs it in `turns-release` (`.github/workflows/build-and-test.yml:257`): `swift test -c release --filter "LandKeeper|Transport"` widens to include the new suite's name.

**Cost.** Registration time of a land with a large default State, release, base against head, one toolchain, on the Mac (a magnitude check). It is reported, not gated.

**Mutants:**
- `#if DEBUG` dropped from the value walk's call: the release counter test fails.
- the walk compiled out of debug too (`#if false`): the debug class test fails.
- the `Decimal` branch kept in release: the release counter fails.
- the open-type branch dropped in debug: `debugRegistrationRefusesHandWrittenAny` fails.

## 4. Docs (en + zh-TW)

- `docs/core/sync.md` § "At registration and conversion": say these two checks run in debug builds only, and what a release build does with a hand-written witness or a bare namesake macro's members. The conversion backstop and the first-send `Decimal` refusal still catch it, so the land ends at its first failing conversion.
- The registration table's three rows: "debug builds only".
- `docs/core/failure-handling.md` rows 41/44/46: the same.
- The error types' own doc comments (`SyncValueSemanticsError`, `Problem.valueSemantics`, `.existentialField`, `.decimalField`) say "debug builds only": a release build never produces them.

## 5. Public API

- No signature change. `SyncValueSemanticsError` and the three `Problem` cases stay.
- Behavior change in release builds: those problems are never produced, and a hand-witnessed class, `Any` or `Decimal` in state registers. The same holds for members a bare namesake macro adds.
- A package-only test counter is added.

## 6. Questions

- Q1 (Review rules on it with this plan): (a) fold to about 3, recommended, or (b) keep them all, as in §3.
- The 5 group-B markers stay, as decided by #99 (= A, maintainer 2026-11-25): ALLOW_MARKERS may grow when the same change adds the rule or runtime path the markers witness, each marker mapped to the code it guards, and a marker goes when that code goes. Group B goes when the sync table's class fallback and `SnapshotValue`'s class backstop go.

## 7. Order

- Review rules on this plan, and on Q1, while #834 is in review.
- The code needs P4-1 merged, because it edits files #834 changes (`SyncRegistration.swift`, the group-A test files, `scripts/lint-turns.sh`, `sync.md`). The branch is cut from main after #834 merges.
- Verification: the debug suite, plus `swift test -c release --filter` for the release counter test, and one release build per side for the cost check.
