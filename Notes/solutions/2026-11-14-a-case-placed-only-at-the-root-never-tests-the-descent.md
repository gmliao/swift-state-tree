---
module: SwiftStateTree
date: 2026-11-14
problem_type: testing_practice
component: typed-sync-diff
symptoms:
  - "a mutant in the per-step check survives although a fixture has the special case"
  - "the special case only appears at a root field, where the state is built by an initializer"
  - "a property checked when a position is created and again at each step down"
root_cause: case_only_where_the_entry_point_builds_the_state
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - mutants
  - fixtures
  - path-trie
  - sync-tables
related:
  - "#392"
  - "Notes/solutions/2026-11-13-a-surviving-mutant-is-a-coverage-gap-or-an-equivalent-site.md"
---

# A case placed only at the root never tests the descent

## Problem

#392's typed diff walks a `SyncDiffPosition`. It holds no path string while its trie cursor is lossless: every literal component so far has its trie label's bytes, not merely a `String`-equal spelling. The rule is checked in two places. `init(path:cursor:)` builds a root field's position, and `descending(_:)` builds each position below it.

Every lossy fixture named a root field (`Kunits`, `Kboss`, labelled with U+212A KELVIN SIGN). The mutant "descending treats a lossy cursor as lossless" survived all of them. No fixture reached a lossy literal through `descending`.

## Root cause

**A root position and a child position are built by different code.** A fixture with the special case only at the root tests the initializer's check. The per-step check in the descent runs only on lossless parents in those fixtures, so dropping it changed nothing.

## Fix

The fixtures gained a lossy literal below lossless ancestors: `boss.inner.Kdeep`, and `units.*.inner.Kdeep` under a row's wildcard, each labelled with U+212A. The DEBUG oracle, which checks every emit against today's concatenation byte for byte, then kills the mutant at `/boss/inner/Kdeep`.

## Prevention

- **When a property is set at construction and updated at each step, place each special case at the root and below it,** under a literal parent and under a wildcard. One placement tests one code path.
- **Run a mutant per site of the check,** not one per rule: a mutant at the initializer and one at the step tell you whether both placements exist.
- **After a mutant run, rebuild before any `--skip-build` test run.** The mutant script restores the source, but the build directory still holds the last mutant's binary.
