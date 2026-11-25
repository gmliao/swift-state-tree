---
module: SwiftStateTree
date: 2026-11-25
problem_type: testing_practice
component: record-replay
symptoms:
  - "an issue marked read from the code, not yet run, is planned as a fix"
  - "the plan's first commit is a known-issue test that turns out to pass on main"
  - "withKnownIssue reports Known issue was not recorded"
root_cause: a_code_reading_premise_was_planned_on_before_a_test_ran_it
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - premise
  - known-issue
  - replay
  - unicode
  - normalization
  - planning
related:
  - "#806"
  - "#700"
---

## Problem

#806 said that a client payload key in another Unicode normalization (NFD against an NFC `CodingKey`) applies live but fails in replay, because replay's canonical decoder matches keys by their bytes. The issue was marked "read from the code, not yet run". The #700 plan (rev 5.3) took it as a bug that K1a fixes, with "#806 lands with K1a" and a known-issue test as K1a's first commit, and shaped one of K1a's conditions around it.

The test, run before any K1a code, passed on main on every encoding. So the known-issue wrapper failed with "Known issue was not recorded". The issue got the run as its evidence and is closed as not reproducible.

## Root cause

The reading was right about the decoder and wrong about the path. `CanonicalMessagePack`'s keyed decoder does match by bytes, but the keeper's replay doesn't use it for client inputs. A recorded action is rebuilt with `PendingActionItem.init(action:)`, and a client event with `AnyClientEvent(type:payload:)`. Both use `AnyCodablePayloadSource`, a JSON round trip that matches keys with `String ==`, as live does. `RecordPayloadSource` reads only server-encoded trees (resolver outputs, the monitor's server events). A premise built from one function's behavior skipped which function the path calls.

## Fix

The test stays, as a regression guard (`RecordKeyNormalizationTests`):
- live applies both spellings on all three encodings;
- the record keeps the client's bytes (pinned, so the replay really reads the NFD spelling);
- replay matches live.

A mutant that builds the replayed action from `RecordPayloadSource` fails the NFD case on all three encodings, so the guard catches the class #806 described, which a byte-matching replay decoder would introduce. The plan (rev 5.4) changed "#806 lands with K1a" to "K1a must keep #806's class out".

## Prevention

- An issue whose symptom is "read from the code, not yet run" gets its failing test run on main before it shapes a plan, a slice or a decision. Until it fails, it is a hypothesis.
- When the test passes, check that it exercises the claimed input (here, that the record really holds the NFD bytes), then find the path that differs from the reading. Keep the test as a guard if a planned change could make the claim true. Prove that with a mutant of that change.
- A known-issue test (`withKnownIssue`) is itself the check: "Known issue was not recorded" means the premise is false, not that the test is broken.
