---
module: SwiftStateTree
date: 2026-11-22
problem_type: gotcha
component: land-keeper
symptoms:
  - "A new DEBUG assertion passes the root package's swift test, then crashes tests in Examples/ in CI's examples job"
  - "A caller search printed `zsh: no matches found: --include=*.swift` and nothing else, and was read as 'no callers'"
root_cause: caller_search_did_not_run_and_skipped_the_separate_example_packages
resolution_type: code_fix
severity: medium
tags:
  - testing
  - shell
  - examples
  - assertion
related:
  - "#751"
  - "#593"
---

# A stricter check missed callers in the example packages

## Problem

In #751 (#593), `LandKeeper.setLandID(_:)` became strict: a call after the keeper's initialization has started stops the process in DEBUG. Every caller that set the ID after construction had to pass `landID:` to the init instead. The 40 callers in `Tests/` and `Examples/GameDemo/Sources/` were converted, and the root package's `swift test` passed on both legs. Review then found eight more, in `Examples/Demo/Tests/` and `Examples/GameDemo/Tests/`. CI's examples job would have crashed on them.

## Root cause

Two gaps added up.

- **The search that would have found them never ran.** In zsh, `grep -rn setLandID Sources Tests Examples --include=*.swift` stops before running grep: zsh expands the unquoted `*.swift` itself, finds no match, and prints `no matches found: --include=*.swift`. The command printed nothing else, and that was read as "no callers in Examples".
- **The root package doesn't build the examples.** `Examples/Demo` and `Examples/GameDemo` are separate packages. The root `swift test` never compiles or runs their tests, so it can't catch a caller there.

## Fix

The eight callers pass `landID:` at construction. A repo-wide search with the pattern quoted (`--include='*.swift'`) finds no `setLandID` call left except the test that checks the report. `swift test` was run in `Examples/Demo` and `Examples/GameDemo` too.

## Prevention

- When a check gets stricter (an assertion, a refusal, a new requirement), search the whole repository for every caller: `Examples/` and `Tools/` too, not only `Sources/` and `Tests/`.
- Quote glob patterns in grep's options (`--include='*.swift'`). A shell error is not an empty result: rerun the search before you rely on it.
- Run `swift test` in each package the change can reach. `Examples/Demo` and `Examples/GameDemo` are built only by CI's examples job, unless you build them yourself.
