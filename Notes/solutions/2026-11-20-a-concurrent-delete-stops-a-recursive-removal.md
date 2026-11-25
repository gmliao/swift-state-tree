---
title: "A concurrent delete stops a recursive removal and leaves the directory"
module: SwiftStateTree tests
date: 2026-11-20
problem_type: testing_practice
component: test-fixtures
symptoms:
  - "an empty record-log-tests-* directory left in the temporary directory after a test run"
  - "removeItem fails with \"The file doesn't exist\" (NSCocoaErrorDomain Code=4) naming a file inside the directory being removed"
  - "a test's `defer { try? FileManager.default.removeItem(at: dir) }` leaves its directory now and then"
root_cause: a_file_deleted_concurrently_makes_a_recursive_removal_stop_and_leave_its_directory
resolution_type: established_pattern
severity: low
tags:
  - testing
  - cleanup
  - filesystem
  - recorder
  - isolation
related:
  - "#669"
  - "#668"
---

# A concurrent delete stops a recursive removal and leaves the directory

## Problem

The one-build isolation proof (#668) found a `record-log-tests-<UUID>` directory left in the temporary directory after a run, and couldn't say which test left it. Every test in `ReevaluationRecordLogTests` removes its spool directory in a `defer`, with `try?`.

## Root cause

`encodeMidRunIsAnIncompleteCopy` ends with its recorder still recording. Releasing a recording `ReevaluationRecorder` discards its spool file (`deinit` → `writer?.discard()`), and the discard runs on the writer's queue, concurrently with the test's `defer`. `FileManager.removeItem(at:)` on a directory lists the contents, removes each entry, then the directory. When the writer unlinks the spool file between the listing and its removal, `removeItem` throws `fileNoSuchFile` for that file and stops: the directory stays, empty. `try?` swallowed the error. On Linux in the pinned image it happened in 2 of 20 runs of that test alone.

## Fix

- Each spool directory carries its test's name (`record-log-tests-<function>-<UUID>`), so a leftover names the test that left it.
- `removeSpoolDirectory` records a failed removal as an issue instead of swallowing it.
- A `fileNoSuchFile` while the directory still exists gets one more removal: the entry it stopped on is already gone, so the second pass removes the rest.

## Prevention

- Don't swallow a cleanup error with `try?` in a test fixture: record it, so a leak fails the test that leaks instead of turning up later, unattributed.
- Name temporary directories after their test (`#function`), so a leftover can be traced.
- When an object that writes files in the background outlives the test's assertions, its own cleanup (a `deinit` or a queue's discard) can race the test's removal. Either end that object's work before removing (save or close it) or treat a file that vanished during removal as removed.
