---
title: "A version gate added to one checker must be reached by every admission path"
module: SwiftStateTree, SwiftStateTreeNIO
date: 2026-11-25
problem_type: bug_class
component: reevaluation-record-admission
symptoms:
  - "an admin replay start returns 200 and a ticket for a record that replay then refuses"
  - "a new refusal error code is mapped but never returned"
  - "RECORD_PAYLOADS_NOT_REPLAYABLE is unreachable"
root_cause: version_gate_added_to_one_checker_not_the_shared_helper
resolution_type: design_rule
severity: medium
tags:
  - replay
  - record-version
  - admission
  - admin-routes
  - validation
related:
  - "#835"
  - "#700"
---

# A version gate added to one checker must be reached by every admission path

## Problem

Record format 3.7 (#700 K1a, #835) stores input payloads as bytes, so a 3.6 record can't be replayed. The refusal (`ReevaluationRecordFingerprintError.payloadsNotReplayable`) was added to `ReevaluationSchemaFingerprint.checkRecord`, which the replay engine, the runner and the keeper call. The admin start routes (`/admin/reevaluation/start` and `/admin/reevaluation/replay/start`) don't call `checkRecord`. They call `recordedFingerprint(of:)` and compare the fingerprint with the land server's. That helper checks only that the record is 3.6 or later and has a fingerprint.

So a 3.6 record with a matching fingerprint passed the route's admission. The request got a 200 and a ticket, and the run failed later inside the monitor's runner. The route's new mapping to `RECORD_PAYLOADS_NOT_REPLAYABLE` (409) was unreachable. 3.6 records are what deployments hold right after an upgrade, so this is the common case, not an edge.

## Root cause

There were two admission paths for one rule, and they share a lower helper (`recordedFingerprint`), not the checker. The new gate went into the higher checker, and only one path reaches it. The tests covered the version refusal through the engine and the runner, and the route's tests had only a `"2.5"` case, which the lower helper already refused.

## Fix

In #835 (commit 9bce0418 on its branch), the gate moved into the helper both paths call: `recordedFingerprint(of:)` throws `payloadsNotReplayable` for a record below `payloadBytesMinor` after its fingerprint check, and `checkRecord` no longer repeats it. `NIOAdminRoutesReplayStartTests` gained a `"3.6"` case on both start URIs, which expects 409 and the code. A mutant that leaves the gate in `checkRecord` only fails it on both URIs.

GameDemo's `--convert` writes a JSON record as a current-version binary one, so it needs the version part of the gate but not the fingerprint. It checks the version itself.

## Prevention

- When a validation rule is added, list every admission path for the thing it validates (engine, runner, keeper, HTTP routes, CLI), and find the lowest function they all call. Put the rule there, not in the checker you happened to read.
- A new error mapping is a claim that the error can reach that caller. Add a test at that caller that produces it. A mapping without such a test is how this one stayed unreachable.
- Each version boundary gets a test at every entry point, not only at one: here, `"3.6"` on both start URIs as well as in the engine's tests.
