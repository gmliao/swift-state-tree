---
module: build
date: 2026-11-09
problem_type: gotcha
component: swiftpm
symptoms:
  - "-dump-macro-expansions prints only some expansions"
  - "frontend dump flag output missing from swift build log"
  - ".build/debug is a symlink into .build/out"
  - "deleting .build/<triple> does not make the next build cold"
root_cause: swiftbuild_prints_task_output_only_with_diagnostics
resolution_type: tool_fix_and_method_rule
severity: low
tags:
  - swiftpm
  - toolchain
  - build
  - macros
  - measurement
related:
  - "#248"
---

# The default SwiftPM build system hides frontend dump output and moves the build directory

## Problem

The swift-syntax upgrade (#248) has to show that every macro expansion is unchanged. The plan was to compile with `-Xswiftc -Xfrontend -Xswiftc -dump-macro-expansions` and diff the logs before and after. With the Swift 6.4 toolchain, the log held only some of the expansions: the root package showed most of them, GameDemo 4 of 42 uses, and Demo none of its 10.

A cold-build timing on the same toolchain looked too fast. It had deleted `.build/arm64-apple-macosx` and left the real build products in place.

## Root cause

On the Swift 6.4 toolchain (6.4.2 here), `swift build` uses the Swift Build system ("swiftbuild") by default, and `--build-system native` prints a deprecation warning.

- Swift Build prints a compile task's output only when the task has diagnostics. The dump goes to the same stream, so a file that compiles cleanly prints none of its expansions.
- Swift Build writes to `.build/out`. `.build/debug` and `.build/release` are symlinks to `.build/out/Products/...`. The native build system writes to `.build/<triple>/`.

## Fix

- Run the dumps with `--build-system native`. The native system prints all frontend output.
- To clean before a timing, delete `.build/out` as well as `.build/<triple>` and the `debug`/`release` links. Check the first timing against a second cold run.

## Prevention

- Before using a log as evidence, check that the count is right. Count the macro uses in the source, then compare that count with the number of expansions in the dump.
- On toolchains whose default is swiftbuild, say in a measurement's README or PR which build system ran. Comparisons with CI's 6.2 builds (native) are only valid when both sides use the same system.
