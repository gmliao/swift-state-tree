---
module: SwiftStateTree
date: 2026-11-24
problem_type: testing_practice
component: land-registration
symptoms:
  - "a mutant that drops a term from a guard survives, and the guarded call re-runs the same check"
  - "a registration error loses one of its parts when two checks fail together"
  - "a surviving mutant was called equivalent because the single-failure case throws the same error"
root_cause: an_aggregating_validators_early_guard_decides_which_parts_of_the_error_survive
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - mutants
  - registration
  - aggregation
  - fingerprint
related:
  - "#794"
  - "#521"
---

# An "equivalent" mutant needs the combined-failure case checked

## Problem

`validateForRegistration` collects every check a land definition fails and throws them in one `LandRegistrationError`. For a land recorded for replay, it also computes the schema fingerprint, but only when every other check passes. #794 added two terms to that guard: `clientEventMismatches.isEmpty` and `unrecognizedNodes.isEmpty`. A mutant that dropped the first term survived. It was reported as equivalent: the fingerprint's schema walk (`SchemaExtractor.extract`) re-runs `validateForRegistration`, which throws the same mismatch error, so a land with a mismatch is refused either way. Review found it isn't equivalent.

## Root cause

The fingerprint call catches only its own error types. Any other error, including the `LandRegistrationError` thrown by the nested re-run, propagates out of `validateForRegistration` at once. The checks after the guard never run. One of them is EV8, the server events without a decoder. So a land with a mismatch **and** a decoder-less server event reports both today, and only the mismatch under the mutant. The mutant also computes and caches the fingerprint attempt. The single-failure test can't tell the two apart; the combined-failure case can.

## Fix

`ClientEventRegistrationTests.refusalUnderReplayKeepsTheDecoderRow` registers two lands with `recordsForReplay: true`. One has an unregistered `HandleEvent`, the other a node the builder doesn't recognize, and each also has a server event without a decoder. Each case expects both parts in the error and no fingerprint error. Dropping either term from the guard fails its case at the decoder row.

## Prevention

- **Before calling a mutant equivalent, check the combined failure.** In a validator that aggregates its checks, an early guard or an early throw decides which parts of the error survive. Equal output for one failing check doesn't mean equal output for two. Write the case where the mutated check fails together with a check that runs after the mutated site.
- **An equivalence argument names every observable difference.** Here that's the error's parts and the side effect, the cached fingerprint attempt. Either one is enough to kill the mutant.
- Related: [a surviving mutant is a coverage gap or an equivalent site](2026-11-13-a-surviving-mutant-is-a-coverage-gap-or-an-equivalent-site.md), which checks the mutant's site against the order of the state it changes. This entry adds the order of the checks after it.
