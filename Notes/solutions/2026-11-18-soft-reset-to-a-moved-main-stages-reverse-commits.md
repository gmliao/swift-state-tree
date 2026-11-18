---
module: repository workflow
date: 2026-11-18
problem_type: workflow_issue
component: git-reset
symptoms:
  - "A commit on a PR branch deletes files the branch never touched"
  - "`git diff origin/main...HEAD --stat` lists deletions of work that landed on main after the branch was cut"
  - "A review asks why the PR removes a plan, a doc or an index row"
root_cause: soft_reset_against_a_ref_that_moved_past_the_branch_base
resolution_type: established_pattern
severity: medium
tags:
  - git
  - reset
  - squash
  - local-main
related:
  - "#600"
---

# A soft reset to a moved main stages the reverse of every commit in between

## Problem

To turn a WIP commit into proper commits, a branch was reset with `git reset --soft main`, then re-committed. Local `main` had been fast-forwarded after the branch was cut, and now held two plan commits the branch didn't have. The new commit on #600 deleted that plan and its index row; review caught it.

## Root cause

`git reset --soft <ref>` moves the branch to `<ref>` and keeps the working tree and index as they are. The next commit records the difference between `<ref>` and the branch's old tree. When `<ref>` is the branch's base, that difference is the branch's own work. When `<ref>` has moved past the base, it also includes every commit in between, reversed: what landed on `main` meanwhile is missing from the branch's tree, so it is staged as deleted, or as reverted lines.

## Fix

Restore the files from the commit that has them, in a new commit (no force-push): `git checkout <main-commit> -- <paths>`. Then confirm `git diff --stat origin/main...HEAD` lists only the branch's own files.

## Prevention

- Reset against the merge base, never against a branch name: `git reset --soft "$(git merge-base HEAD origin/main)"`.
- Before every commit that follows a reset, check `git diff --cached --stat`, and `git diff --stat origin/main...HEAD` after it: a file the change didn't touch is the sign.
