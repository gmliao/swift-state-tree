---
title: "A test product is a `<target>-test-runner` executable under the swift-build system"
module: Examples/GameDemo
date: 2026-11-24
problem_type: gotcha
component: test-support
symptoms:
  - "ReevaluationRunnerExitTests fails at the products-directory #require: productsDirectory() returned nil"
  - "can't find this test bundle's build products directory in [...]"
  - "No argument of the test process has a .xctest path component after moving to Swift 6.4"
root_cause: products_directory_found_by_a_xctest_argument_but_swift_build_makes_a_test_runner_executable
resolution_type: code_fix
severity: medium
tags:
  - toolchain
  - swift-build
  - testing
  - linux
  - examples
related:
  - "#775"
  - "fa992e64"
---

# A test product is a `<target>-test-runner` executable under the swift-build system

## Problem

`Examples/GameDemo/Tests/ReevaluationRunnerExitTests.swift` runs the built `ReevaluationRunner` executable. To find it, `productsDirectory()` looked through `CommandLine.arguments` for a path with a `.xctest` component and took the directory above it. After the move to Swift 6.4.3 (#775), three of its tests failed in CI's `examples` job at the `#require` on that lookup: `productsDirectory()` returned nil. The root package's tests passed, because the lookup exists only in the example package.

## Root cause

From Swift 6.4, SwiftPM builds with the swift-build system by default. On Linux its layout differs from the previous build system's in two ways that matter here:

- Products land in `.build/out/Products/<Config>-linux-<arch>` (`x86_64` in CI; an arm64 host gets `aarch64`). `.build/debug` and `.build/release` are symlinks to that directory.
- A test target is an executable `<target>-test-runner` in that directory (`GameContentTests-test-runner`), not a `.xctest` bundle. No argument of the test process has a `.xctest` component, so a lookup keyed to one finds nothing.

`ReevaluationRunner` is built in the same directory as the test runner, which is why the directory of the runner argument is the right answer. On macOS, swift-build still produces the `.xctest` bundle (as seen in review of #775), so the old rule keeps working there.

## Fix

`productsDirectory()` keeps the `.xctest` rule and also takes the directory of an argument whose last component ends in `-test-runner`. The `#require` message now prints `CommandLine.arguments`, so a third layout shows what the process was given. This was the only `.xctest`-based lookup in the repository. In `swift:6.4.3-noble`, `swift test --filter ReevaluationRunnerExitTests` passed, and so did all of GameDemo's tests.

## Prevention

- **Don't find the products directory by a bundle name.** Take it from `swift build --show-bin-path` where a script can run it. A test that must find a sibling executable accepts every layout a supported toolchain produces, and its failure message prints the arguments it searched.
- **A toolchain bump needs the example packages' tests run, too.** The root `swift test` doesn't build `Examples/Demo` or `Examples/GameDemo`; the `examples` job does, and it was the one that failed. See [a stricter check missed callers in the example packages](2026-11-22-a-stricter-check-missed-callers-in-the-example-packages.md) for the same gap.
- **Hard-coded `.build/<config>/<binary>` paths still resolve** on 6.4.3 through the symlinks. Check them before assuming they broke: the break here was a lookup by test bundle, not by `.build/<config>`.
