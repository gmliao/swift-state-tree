---
title: "A branch cut from a PR head that was then squash-merged duplicates on merge, with no conflict"
module: git
date: 2026-11-19
problem_type: gotcha
component: branch-workflow
symptoms:
  - "a step appears twice in a workflow after merging main, with no conflict"
  - "the diff against main is larger than the branch's own change"
  - "merging main into a stacked branch after the base PR was squash-merged"
root_cause: squash_merge_leaves_the_stacked_branch_merge_base_before_the_base_pr
resolution_type: design_rule
severity: medium
tags:
  - git
  - merge
  - squash
  - stacked-branches
  - ci
related:
  - "#618"
  - "#620"
---

**Problem.** The branch for #620 was cut from #618's head, because both change `.github/workflows/build-and-test.yml`. #618 was then squash-merged into `main` (7133736e). Merging `main` into the #620 branch reported no conflict, but the `examples` job now had its SwiftPM cache step twice. The diff against `main` came to +48/−15 lines, against the branch's own +33/−13.

**Root cause.** A squash merge puts a new commit on `main` whose parent is the old `main`, not #618's branch. So the merge base of the stacked branch and `main` is still the `main` from before #618. From that base:
- `main`'s side adds the cache step (the squashed #618);
- the branch's side adds the same step (#618's commits, which it carries), and also edits the lines next to it (it removed the checkout's `fetch-depth`).

Identical additions merge into one. But the branch's hunk was no longer identical, so git applied both hunks and kept both copies. Nothing in the text conflicts, so no marker appears.

**Fix.** Found by reading `git diff origin/main` after the merge, before pushing. The second copy was removed in the merge commit (amended, not yet pushed). A workflow parse didn't catch it: two steps with the same name are valid YAML.

**Prevention.**
- **After merging `main` into a branch stacked on a squash-merged PR, read `git diff origin/main` in full.** It must show only the branch's own change. A larger diff, or a block that appears in it as added although `main` already has it, is the duplicate.
- **For a workflow, also count the steps** (`grep -c 'name: <step>'`) against `main`.
- **Or avoid the stack:** once the base PR merges, cut a new branch from `main` and cherry-pick only the stacked branch's own commits (`git cherry-pick <base-head>..<branch>`). This is no rebase of a pushed branch, and the merge base is then the merged `main`.
