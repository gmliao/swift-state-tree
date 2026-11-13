---
module: Notes
date: 2026-11-13
problem_type: gotcha
component: plans
symptoms:
  - "the plan on the feature branch is an older revision than the one that got approval"
  - "a decision in the approved revision isn't in the plan the implementation followed"
root_cause: plans_land_on_main_while_the_branch_was_cut_from_an_older_commit
resolution_type: design_rule
severity: low
tags:
  - git
  - stacked-prs
  - plans
  - review
related:
  - "#514"
---

# A stacked branch carries a stale plan

## Problem

#514's implementation branch was cut from the base of the PR it stacks on, an older commit than the plan's approval. The plan was revised on `main` three more times (revisions 4 to 6, with the decisions on failure outputs). The branch's own `Notes/plans/2026-11-13-per-player-sync-tables.md` was revision 3, and it was read first.

## Root cause

Plans are `Notes/` changes, which land on `main` directly, while a stacked branch starts from its base PR's commit. Its working tree holds whatever plan existed then, and nothing marks it as old.

## Fix

The approved revision was read from `origin/main` (`git show origin/main:Notes/plans/<plan>.md`), and the work checked against it before the PR.

## Prevention

- **Read the plan from `origin/main`, not from the branch's working tree,** when the branch was cut from anything older than `main`. Compare the plan's revision line with the one the approval names.
- **Don't edit a plan on a feature branch.** Plan changes go to `main`; a branch copy is a snapshot.
