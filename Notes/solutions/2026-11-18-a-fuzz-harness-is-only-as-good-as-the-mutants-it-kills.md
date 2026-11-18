---
module: SwiftStateTreeTransport
date: 2026-11-18
problem_type: testing_practice
component: client-frame-fuzz
symptoms:
  - "a fuzz suite passes with a force cast planted in a wire decoder"
  - "removing a MessagePack container-count check changes no test result"
  - "a long fuzz run sits at low CPU for an hour"
root_cause: byte_mutations_rarely_reach_a_typed_field
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - fuzzing
  - mutants
  - decoding
  - messagepack
  - json
related:
  - "#528"
  - "#362"
---

# A fuzz harness is only as good as the mutants it kills

## Problem

The client-frame fuzz tests (#528) feed mutations of real client frames to every decoder a
client reaches, and pass if each call returns or throws. Run at 2,000 iterations per target,
and then at 10^6, they found no trap. That said nothing about whether they could find one, so
the harness was checked with mutants planted in the decoders:

- a force cast (`value as! Int`) in place of the throwing check in
  `OpcodeTransportMessageDecoder.intValue`. **The suite passed;**
- removing the MessagePack unpacker's "count above the bytes left" check. **The suite passed;**
- removing the unpacker's nesting check. The depth test failed, as it should.

## Root cause

- **The force cast.** `intValue` reads one field, an event's `direction`, the second element of
  `[103, 0, "Chat", {...}]`. Byte mutations (flips, boundary bytes, inserted ranges, splices)
  seldom turn exactly that element into a well-formed non-integer while leaving the rest of the
  frame parseable. In 2,000 iterations spread over every seed, none did.
- **The count check.** With the check removed, `reserveCapacity` of a claimed count of
  2^32 − 1 elements succeeds lazily under Linux memory overcommit. The read loop then throws at
  the end of the data. Nothing a test can observe changes, short of measuring memory.

## Fix

- A structure-aware mutator, `FrameMutator` case 13/14: it replaces the text between two adjacent
  JSON separators (`,` `:` `[` `]` `{` `}`) with a token from the token list (a fraction, a huge
  number, a string, `null`, a container). It reaches each field of a positional frame directly.
  With it, the force-cast mutant traps the suite at 2,000 iterations ("Unable to bridge NSNumber
  to Int").
- The count-check mutant is recorded as unobservable on Linux. The check still matters where
  allocation isn't lazy, and for the time a reservation can take.

## Prevention

- Verify a fuzz harness with mutants before trusting a clean run: a force cast or a force unwrap
  planted in a field reader, a removed bounds check, a removed depth check. Each mutant it
  doesn't kill means a mutator class is missing.
- For positional formats (opcode arrays), mutate at the element level as well as at the byte
  level.
- Don't count an allocation guard as tested by "decode or throw": overcommit hides it.
- Writing each input to a file before decoding it, so a crasher is kept, made a 10^6-iteration
  run I/O-bound: 18% CPU for an hour on a container volume, against 135 s for the whole run
  without it. Keep that switch for replaying a known seed. The seed and the target name are
  enough to reproduce a trap.
