---
title: "A tests-only first commit must pass every gate before the one it pins"
module: SwiftStateTree
date: 2026-11-25
problem_type: testing_practice
component: client-event-intake
symptoms:
  - "a tests-first commit meant to be green on today's code fails, because an earlier check refuses the input"
  - "a test expects a drop counted at apply, but the payload is refused at intake or by the frame decoder"
root_cause: a_pin_test_written_against_one_gate_ignores_the_gates_in_front_of_it
resolution_type: design_rule
severity: medium
tags:
  - testing
  - tests-first
  - payload
  - intake
related:
  - "Notes/plans/2026-11-25-k1b1-plain-forms.md"
  - "#700"
---

**Problem.** The K1b-1 plan (rev 1) put one test in its tests-only first commit, which had to be green on today's code: a client event registered through the public descriptor init, too deep or malformed, on json and MessagePack, with recording on and off, "dropped and counted once at apply".

**Root cause.** A payload meets several gates before apply, and each refuses a different case:
- the frame decoders refuse a too-deep frame before the keeper sees it;
- with recording on, intake's byte preparation (`RecordedPayloadBytes(of:)`) refuses a too-deep or non-finite payload with an error to the client, and queues nothing;
- a too-deep recorded MessagePack value fails to unpack with `invalidData`, which maps to `.undecodable`, so replay doesn't count it as too deep.

The test described only the last gate, apply's drop, so it would have failed on today's code at the earlier gates.

**Fix.** Split the test into one case per gate (K1b-1 plan rev 2, MF3):
- a shallow malformed payload whose bytes can be made: no error, recorded, dropped;
- a payload that byte preparation refuses: an error to the client, nothing queued;
- an apply-time depth drop: recording off with a direct source, or a recorded JSON fixture, counted once.

**Prevention.** Before writing a pin for a check at one stage, list every check the input meets before it: frame decoder, intake, byte preparation, decode. Choose the input so that it passes all of them and reaches the stage under test. Add a separate case for each earlier gate that changes what the client sees.
