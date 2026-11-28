---
title: "A test that asserts a commit is unknown depends on which refs the checkout fetched"
module: deep-research
date: 2026-11-28
problem_type: testing_practice
component: deep-research-wireform
symptoms:
  - "deep-research-tests red on every CI run, main included, with no change to deep-research/"
  - "AssertionError: False is not None : b8e798b is in history"
  - "a git-history test passes in one clone and fails in another"
root_cause: a_test_asserted_reachability_that_any_new_ref_can_change
resolution_type: code_fix
severity: medium
tags:
  - git
  - ci
  - testing
  - deep-research
related:
  - "#56"
---

**Problem.** `wireform.SQUASHED` maps a run commit that a squash merge dropped from main (`b8e798b`) to that squash merge (`c0118d6b`), so the run's wire form can still be told. `test_wireform.py` asserted the key was unknown to the repository: "reachable, the map would override real ancestry". On 2026-11-28 the `artifact/measurements-2026-11` branch made `b8e798b` an ancestor on purpose, so its run commit can be checked out. CI's checkout fetches every branch, so every later run reached the commit and failed, main's included, with no change to `deep-research/`.

**Root cause.** Whether a commit is reachable depends on the refs a clone has, not on the code under test. A new branch, a tag, or a shallow or single-branch clone changes the answer. The test pinned a fact that's true only in some checkouts, and the code made it matter: `resolve()` consulted the map before the real history, so a reachable key was resolved through its merge either way.

**Fix.** `resolve()` takes the commit's own ancestry when the repository knows it, and the squash map only for a commit no ref reaches. The test checks, for each entry, that the merge contains no knob, and that the key's real ancestry, when known, agrees with the merge's. A mocked `contains` pins each path: unknown, where the map decides, and reachable, where the history decides even against the map. Checked in a `--single-branch` clone of main, where `b8e798b` is unknown, and in a clone with the artifact branch.

**Prevention.**
- A test over git history asserts what holds in every checkout: an ancestry that a known commit has. It never asserts that a commit is absent or unreachable, because any new ref can change that.
- Where code falls back on a map for a commit the repository may lack, it consults the real history first. Test both paths with a mock, not with whatever the local clone happens to hold.
- Before adding a branch or tag that reattaches dropped commits, grep the tests for them (`git grep <sha>`).
