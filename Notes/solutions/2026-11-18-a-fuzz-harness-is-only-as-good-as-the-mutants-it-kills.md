---
title: "A fuzz harness is only as good as the mutants it kills"
module: SwiftStateTreeTransport
date: 2026-11-18
problem_type: testing_practice
component: client-frame-fuzz
symptoms:
  - "a fuzz suite passes with a force cast planted in a wire decoder"
  - "removing a MessagePack container-count check changes no test result"
  - "a fuzz target passes while every input stops at the same early error"
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
  2^32 − 1 elements succeeded lazily on the Linux host the mutant ran on (memory overcommit), and
  the read loop then threw at the end of the data. "Decode or throw" can't tell the two errors
  apart. Whether that reservation succeeds depends on the host's overcommit setting: where it is
  refused, it traps. So the guard matters in production even where this run didn't see it.
- **Vacuous targets.** Review found that a target can pass while never reaching its decoder.
  The payload decode into the fixture types (T5) had no seed with those types' field names, so
  every input stopped at `keyNotFound` on the first field. A target that counts only "decoded
  or threw" can't see that.

## Fix

- A structure-aware mutator, `FrameMutator` case 13/14: it replaces the text between two adjacent
  JSON separators (`,` `:` `[` `]` `{` `}`) with a token from the token list (a fraction, a huge
  number, a string, `null`, a container). It reaches each field of a positional frame directly.
  With it, the force-cast mutant traps the suite at 2,000 iterations ("Unable to bridge NSNumber
  to Int").
- The count check is tested through its own error: `unpack(Data([0xDC, 0x00, 0x02, 0xC0]))`,
  an array claiming 2 elements with 1 byte left, must throw `invalidData("Container count 2
  exceeds the 1 bytes left")`. The same goes for a map. With the guard removed it throws a
  different error, on every platform and with no large allocation.
- Each fixture payload type has a seed holding a valid value of it, in all three encodings.
  Each target counts its outcomes per entry point and per payload type, and requires both
  outcomes to occur.

## Prevention

- Verify a fuzz harness with mutants before trusting a clean run: a force cast or a force unwrap
  planted in a field reader, a removed bounds check, a removed depth check. Each mutant it
  doesn't kill means a mutator class is missing.
- For positional formats (opcode arrays), mutate at the element level as well as at the byte
  level.
- A guard that throws is tested by expecting its own error, not "any error": "decode or throw"
  passes with the guard gone whenever a later check throws instead.
- Count each entry point's outcomes, and require that each decoded some inputs and refused
  others. A target whose inputs all stop at one early error passes "decode or throw" without
  testing anything. Seed each typed decode with a valid value of its type: byte mutations don't
  invent field names.
- Count the seeds and the mutations apart. Replayed unmutated, the seeds alone make "decoded
  and refused" hold: a type's own seed decodes, every other seed fails as `keyNotFound`. What
  shows that a fuzzed value reached a field is, among the mutations, a refusal from the field's
  own decoder (`typeMismatch`, `dataCorrupted`). For a type whose seed is one frame among many,
  mutate from its seeds alone, or few mutations reach it.
- Print the seed before the first input. With a random seed, a trap or a hang ends the process
  before a summary line, and then nothing names the seed to replay.
- Writing each input to a file before decoding it, so a crasher is kept, made a 10^6-iteration
  run I/O-bound: 18% CPU for an hour on a container volume, against 135 s for the whole run
  without it. Keep that switch for replaying a known seed. The seed and the target name are
  enough to reproduce a trap.
