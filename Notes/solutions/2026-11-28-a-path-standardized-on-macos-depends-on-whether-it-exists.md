---
title: "On macOS a standardized path depends on whether it exists: spell and compare it in the same state"
module: SwiftStateTreeNIO
date: 2026-11-28
problem_type: gotcha
component: replay-ticket-record-path
symptoms:
  - "a valid replay ticket's join answers JOIN_ROOM_NOT_FOUND invalidSessionDescriptor under a full swift test, and passes alone"
  - "await replayLands() == 1 fails once in a fresh checkout under /private/tmp, never again in the same checkout"
  - "a containment check refuses a path that is inside the directory, spelled /private/tmp/… against /tmp/…"
root_cause: standardized_file_url_drops_private_only_for_existing_paths
resolution_type: established_pattern
severity: low
tags:
  - path
  - macos
  - foundation
  - flaky-test
  - shared-directory
related:
  - "#428"
  - "#682"
  - "#281"
---

## Problem

`RegisterWithGenericReplayTicketTests` failed about once in ten full `swift test` runs on macOS (#428). After #682 named the join's answer, the failure was `invalidSessionDescriptor` for a ticket the process signer had just issued.

The test spelled the ticket's record path from `URL(fileURLWithPath: recordsDir, isDirectory: true).standardizedFileURL.path + "/match.json"`. Here `recordsDir` is the default `./reevaluation-records`, resolved against the shared cwd. `ReevaluationReplaySessionDescriptor.decode` standardizes the records directory again when the land is built, and checks that the record path lies inside it.

## Root cause

On macOS, `standardizedFileURL` drops the `/private` of `/private/tmp` and `/private/var` only for a path that exists. With a checkout under `/private/tmp` and no records directory yet, the test spelled `/private/tmp/…/reevaluation-records/match.json`. A concurrent test (`NIOAdminRoutesReplayStartTests`' record helper) then created the directory. `decode` spelled the directory `/tmp/…`, while the record path (`match.json` never exists) kept `/private/tmp/…`, so the prefix compare refused it. A small Foundation program shows it directly: spelled while missing, compared once present, `contained: false`.

It fails only in a fresh checkout under a `/private` path, and only when the creation lands between the issue and the build. Once the directory exists, both sides drop `/private` and agree, which is why the suite passes alone. Production spells the token from the record it opens, which exists, so both sides agree there.

## Fix

The tests that spell a ticket's record path use one helper, `ticketRecordPath(recordsDir:file:)` (`Tests/SwiftStateTreeNIOTests/Support/TicketRecordPath.swift`). It creates the records directory before spelling the path. `TicketRecordPathTests` spells a path under the temporary directory's `/private` spelling while the directory is missing, creates it as the concurrent test did, and expects `decode` to accept. It is red without the `createDirectory`.

## Prevention

- Don't compare two spellings of a path that were standardized at different times, unless the path existed (or was missing) at both moments. `standardizedFileURL`, `resolvingSymlinksInPath` and `realpath` all read the file system. For a path that may not exist yet, create what it names first, or compare lexically on both sides.
- A test that writes into a shared directory (the cwd, a default records directory) changes what every other test's standardized path looks like. Prefer a per-test directory. Where the code under test reads a process-wide default, create that directory before spelling any path in it.
- On macOS, pin it with a path under `"/private" + FileManager.default.temporaryDirectory.standardizedFileURL.path`, which exists on macOS and is stripped once the path exists. `ReevaluationRecordPathTests.Fixture` uses the same spelling.
