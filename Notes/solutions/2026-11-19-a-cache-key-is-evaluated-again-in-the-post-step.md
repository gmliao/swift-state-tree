---
module: CI
date: 2026-11-19
problem_type: gotcha
component: github-actions-cache
symptoms:
  - "hashFiles('**/Package.resolved') failed. Fail to hash files under directory"
  - "Post SwiftPM shared cache failed while every test step passed"
  - "the cache is never saved, so every run is a miss"
root_cause: actions_cache_post_step_reevaluates_the_key_after_the_build_filled_the_workspace
resolution_type: code_fix
severity: medium
tags:
  - ci
  - github-actions
  - cache
  - swiftpm
  - container
related:
  - "#618"
---

**Problem.** #618 added an `actions/cache@v4` step that caches SwiftPM's shared cache (`~/.cache/org.swift.swiftpm`) in each Swift job. Its key ended in `hashFiles('**/Package.resolved')`. On the first run every test step passed, but every job that used the cache failed in its post step:

```
##[error]The template is not valid. .github/workflows/build-and-test.yml (Line: 51, Col: 14): hashFiles('**/Package.resolved') failed. Fail to hash files under directory '/home/runner/work/swift-state-tree/swift-state-tree'
```

The cache was never saved, so the next run would have missed again.

**Root cause.** `actions/cache` evaluates its inputs twice: once in the main step, at the start of the job, and again in its post step, which saves the cache. At the start, the checkout holds three `Package.resolved` files. By the post step the build has filled the workspace with `.build` (dependency checkouts with their own `Package.resolved`, build products, symlinks), written as root by the container. The `**` walk runs on the host side over the same directory and fails there. The restore succeeded, so the key looked right until the job's last step.

**Fix.** Name the tracked files instead of globbing the tree: `hashFiles('Package.resolved', 'Examples/*/Package.resolved')`. Those patterns don't descend into `.build`, and they hash the same files at both evaluations. At 75fc4021 every job saved its cache, and a rerun logged `Cache hit for: swiftpm-…` and `Fetching https://github.com/… from cache` (#618).

**Prevention.**
- **A cache key is evaluated again at the end of the job.** Don't let it depend on anything the job writes: no `**` glob over a directory a build writes into, and no file a step generates.
- **Name the tracked inputs, or compute the key once.** Either name the files (`git ls-files '*Package.resolved'` lists them) or compute the key in a step and pass it as that step's output.
- **A green job's first run with a new cache proves nothing.** Check that the post step saved ("Cache saved with key"), and that a rerun restores it.
