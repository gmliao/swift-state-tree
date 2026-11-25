---
title: "Raising a platform floor moves every manifest that depends on the package"
module: Package
date: 2026-11-25
problem_type: gotcha
component: package-manifests
symptoms:
  - "the root package builds on macOS, but an example or tool package that depends on it fails with a deployment-target error"
  - "Linux CI is green after a platform floor raise, and a Mac build of Examples/ fails"
root_cause: a_dependent_manifest_kept_the_old_platform_floor_after_the_root_raised_it
resolution_type: design_rule
severity: medium
tags:
  - swiftpm
  - platforms
  - macos
  - ci-gap
related:
  - "#700"
  - "#847"
---

## Problem

K1b-3 (#700) raised `Package.swift`'s floor from `.macOS(.v14)` to `.macOS(.v15)` for `Synchronization.Mutex`. The first plan raised only the root. Every package that depends on the root names its own `platforms`, and SwiftPM refuses a dependency whose floor is above the dependent's.

## Root cause

A floor is declared per manifest, not inherited. Linux ignores `.macOS(...)`, so Linux CI builds every dependent package unchanged and stays green. Only a macOS build of a dependent package fails.

## Fix

The floor moves in the same change in every manifest that depends on the root package:
- `Package.swift`;
- `Examples/Demo/Package.swift`;
- `Examples/GameDemo/Package.swift`;
- `Tools/AutobahnEcho/Package.swift`;
- the consumer manifest `scripts/check-must-not-compile.sh` generates.

Manifests that build only their own sources (`Examples/GameDemo/ws-loadtest/poc`, the inlinable control in `scripts/check-turns-inlinable.sh`) don't depend on the root and keep their floor. The docs that state the requirement (`docs/quickstart.md`, `docs/FAQ.md`, both languages, and `AGENTS.md`) move too.

## Prevention

- Before raising a floor, list the dependents: `git grep -n "package(path:" -- '*Package.swift' scripts`, and every script that writes a manifest. Each one that reaches the root moves with it.
- The macOS CI job (#847) builds the root; a dependent's macOS build is checked on a Mac before merge.
