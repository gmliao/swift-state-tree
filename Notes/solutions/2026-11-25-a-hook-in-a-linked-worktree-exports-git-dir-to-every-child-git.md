---
title: "A hook in a linked worktree exports GIT_DIR to every child git"
module: scripts, deep-research
date: 2026-11-25
problem_type: trap
component: pre-push-checks
symptoms:
  - "a push from a linked worktree fails in the deep-research tests, which pass when run by hand"
  - "after a push attempt, git in the main checkout says 'this operation must be run in a work tree'"
  - "core.bare is true in the clone's config"
  - "the worktree's HEAD has commits named 't' by author 't <t@t>'"
root_cause: inherited_git_dir_in_hook_environment
resolution_type: environment_guard
severity: high
tags:
  - git
  - hooks
  - worktree
  - pre-push
  - test-isolation
related:
  - "#835"
---

# A hook in a linked worktree exports GIT_DIR to every child git

## Problem

A push of a Notes and deep-research change ran from a temporary linked worktree (`git worktree add`). The pre-push hook runs `scripts/pre-push-checks.sh`, which ran the deep-research tests because a deep-research file changed. 7 of the 27 test files failed. The same tests passed when run by hand.

The failed run also changed the repository:
- `core.bare=true` was set in the clone's shared config, so every git command in the main checkout failed with "this operation must be run in a work tree";
- the worktree's detached HEAD gained 10 commits by `t <t@t>`, and its index and files were replaced by the tests' fixtures.

## Root cause

git runs a hook from a linked worktree with `GIT_DIR` set to that worktree's git directory (`.git/worktrees/<name>`). From the main checkout it doesn't, which is why pushes from there never showed this. A probe with a throwaway repo and a hook that prints `env` shows both cases.

Every child process of the hook inherits the variable. Several deep-research tests create a repository in a temporary directory and run `git init`, `git add` and `git commit` there. With `GIT_DIR` set, those commands don't use the temporary directory. They use the worktree's repository:
- `git init` re-initializes it, and with `GIT_DIR` set and no work tree it records `core.bare=true` in the shared config;
- the tests' commits land on the worktree's HEAD.

If the worktree had been on a branch, the commits would have moved that branch.

## Fix

Both entry points drop git's repository variables before anything else runs:

```bash
unset $(git rev-parse --local-env-vars)
```

They are `scripts/pre-push-checks.sh`, which the hook calls, and `deep-research/run-tests.sh`, which runs every deep-research test. `git rev-parse --local-env-vars` is git's own list of the variables that locate a repository (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`, `GIT_COMMON_DIR` and others). git's own shell scripts use it for the same purpose. Each script then finds the repository from its working directory, which it already sets.

`scripts/test-pre-push-checks.sh` has an `inherited-git-dir` case. It runs the checks with `GIT_DIR` naming an empty repository, where a check that used the variable would find no merge base and exit 2. A mutant without the `unset` fails that case.

Repair after the incident: run `git config core.bare false`, check that no branch ref moved (`git for-each-ref`, the reflog), and reset the worktree to its last real commit.

## Prevention

- A script a git hook can call must not trust the environment's `GIT_*` variables. Unset them at the entry point, not in each test.
- A test that creates its own repository should not rely on the caller's environment. Passing `env` without `GIT_*` to its `git` calls, or running under a runner that clears them, keeps it from reaching the outer repository.
- When a push fails in a hook but the same check passes by hand, compare the hook's environment with the shell's (`env | grep '^GIT_'` inside the hook) before reading the failures.
