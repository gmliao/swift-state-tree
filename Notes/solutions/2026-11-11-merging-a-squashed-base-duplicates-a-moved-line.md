---
module: repository workflow
date: 2026-11-11
problem_type: workflow_issue
component: git-merge
symptoms:
  - "After merging main into a stacked branch whose base PR was squash-merged, a declaration appears twice"
  - "git reports an add/add conflict on a file the base PR created, or merges cleanly with a duplicate"
  - "The branch's diff against main has the line's addition but not its removal"
root_cause: three_way_merge_without_shared_history_after_squash
resolution_type: established_pattern
severity: medium
tags:
  - git
  - merge
  - squash
  - stacked-prs
related:
  - "#505"
---

# Merging a squashed base into a stacked branch duplicates a moved line

## Problem

A stacked branch moved a line that its base PR added: the base added a test getter just above a setter, and the follow-up moved it below the setter. The base PR was then squash-merged into `main` (#505, `2d0dd175`). Merging `main` into the follow-up gave a file with the getter twice: once where the squash commit put it, once where the follow-up moved it.

## Root cause

A squash commit shares no history with the branch commits it replaces. For the merge, the base PR's lines are an addition on `main`'s side, and the follow-up's moved copy is an addition on its own side, both against a merge base that has neither. Git can't see a move, only two additions in different places, so it keeps both. A file the base PR created at all is an add/add conflict for the same reason.

## Fix

Run the exact check after every merge of `main` into a stacked branch: for each file, the branch's added and removed lines against `main` must equal its own change against its old base:

```bash
for f in $(git diff --name-only OLD_BASE OLD_HEAD); do
  a=$(git diff origin/main HEAD -- "$f" | grep -E '^[+-]' | grep -v '^+++\|^---' | git hash-object --stdin)
  b=$(git diff OLD_BASE OLD_HEAD -- "$f" | grep -E '^[+-]' | grep -v '^+++\|^---' | git hash-object --stdin)
  [ "$a" = "$b" ] || echo "DIFF $f"
done
```

The duplicate showed up as a missing removal: the branch's diff against `main` had the moved line's addition, but not the deletion of the old copy. Delete the old copy by hand, then rerun the check.

## Prevention

- After a base PR is squash-merged, merge `main` into each branch stacked on it and compare per file against the branch's own change, not only the file list. A clean merge isn't evidence: the duplicate here merged without a conflict marker in that file.
- A duplicate declaration fails the build, but a duplicated statement or doc line doesn't. The check catches both.
