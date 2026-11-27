---
title: "Two PRs green on their own bases can break main together: a PR cut before a newer test in its area merges main and reruns it before merging"
module: repository workflow
date: 2026-11-27
problem_type: testing_practice
component: merge-order
symptoms:
  - "main fails a test right after two PRs merged, and each PR's own CI was green"
  - "a test added by one PR hangs or fails under a behavior change from another PR merged after it"
  - "the failing test isn't in the diff of the PR whose change breaks it"
root_cause: a_pr_never_ran_a_test_added_on_main_after_its_base
resolution_type: established_pattern
severity: medium
tags:
  - merge
  - ci
  - semantic-conflict
  - test-coverage
related:
  - "#956"
  - "#958"
  - "#943"
---

# Two PRs green on their own bases can break main together

## Problem

#956 (`183489c1`) added `StandaloneJoinSupersededTests.supersededAtTheKick`: a direct join that arrives while an adapter's join kicks the player's entry finds the slot empty and joins at once. #958 (`6ba487c8`, #943) changed exactly that: a join that arrives while the player's leave is in flight waits for it. #958 was cut from `bc93da6f`, before #956 merged, and its branch merged clean (no textual conflict) and was green; so was #956. On `main` with both, the test's direct join waits behind the held kick, and the test hangs until its time limit. #958 had updated the routed twin of the same test (`fencedAtTheKickClosesWith4017`), which existed on its base; the standalone one didn't.

## Root cause

A PR's CI runs the tests of its own base plus its change. A test added on `main` after that base never runs against the change, and GitHub's mergeability check only looks for textual conflicts. Two behaviors meeting in one test, each added by a different PR, are a semantic conflict that neither PR's CI can see.

## Fix

The standalone test takes the routed twin's shape: the direct join runs in its own task, the test waits until it is parked behind the kick's leave (`waitForLeaveEndWaitersForTesting`), releases the kick, bounds the direct join's end with an `EventLog`, and expects the superseded answer with joins `[c-a, c-direct]`.

## Prevention

- Before merging a PR that changes a behavior, check whether `main` gained tests in the same area since the PR's base (`git log <base>..origin/main -- <test dirs>`, or the merged PRs touching the same component). If it did, merge `main` into the PR and rerun the touched suites before the merge; a clean merge is not that check.
- When a PR updates one test of a pair (a routed and a standalone twin, a tick and a tickless variant), search for the other members of the pair on current `main`, not only on the PR's base.
- See [Merging a squashed base into a stacked branch duplicates a moved line](2026-11-11-merging-a-squashed-base-duplicates-a-moved-line.md) for the textual side of merging `main` late.
