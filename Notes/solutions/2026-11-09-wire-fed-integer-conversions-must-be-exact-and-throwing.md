---
title: "Wire-fed integer conversions must be exact and throwing"
module: SwiftStateTreeMessagePack
date: 2026-11-09
problem_type: bug_class
component: wire-decoders
symptoms:
  - "the server process crashes on one MessagePack frame with a large integer"
  - "Fatal error: Not enough bits to represent the passed value"
  - "EXC_BAD_ACCESS or SIGBUS while unpacking a deeply nested MessagePack value"
  - "Fatal error: Index out of range on an empty JSON array frame"
root_cause: narrowing_conversions_index_reads_and_recursion_fed_by_wire_data
resolution_type: design_rule
severity: high
tags:
  - codec
  - messagepack
  - security
  - decoding
  - crash
  - record
  - replay
related:
  - "#312"
  - "#639"
  - "#640"
  - "#641"
---

# Wire-fed integer conversions must be exact and throwing

## Problem

The MessagePack decoders turned wire integers into narrower types with trapping initializers:
- `Int(uint)` in `MessagePackDirectDecoder.extractInt`, used for the client-sent event `direction`;
- `Int8(…)`, `UInt8(…)`, `Int32(…)` and the like in `MessagePackValueDecoder`;
- `Int32(…)` for `playerSlot` in the JSON opcode-array decoder;
- `UInt32(…)` for path hashes in the JSON state-update decoder.

An out-of-range value (`UInt64.max`, a negative number for an unsigned field) crashed the process instead of failing the frame. So one crafted frame from any MessagePack peer could stop a server with every land on it.

Two more wire-fed traps of the same kind:
- **Container counts.** The unpacker reserved capacity for a declared array or map count (up to 2³² − 1) before reading any element.
- **Nesting.** It recursed once per nesting level without a limit; a debug build overflows a 512 KiB thread stack at about 200 levels.

The JSON state-update decoder also read `payload[0]` of an empty array.

## Root cause

Swift's integer initializers trap on values they can't represent, and array subscripts trap out of range. That is right for values the program computes and wrong for values a peer sends: a decode error belongs to the frame, but a trap takes down the process. Each of these sites looked safe in isolation because the encoder on our side never produces such values.

## Fix

Every conversion of a wire value is now `T(exactly:)` and throws when it returns nil:
- `extractInt`;
- `MessagePackValueBox.decodeInteger`, which every typed integer decode goes through;
- the JSON `playerSlot` and `uint32Value` conversions.

The unpacker rejects a count above the bytes left before reserving, and nesting deeper than 64 (`messagePackMaxNestingDepth`). The empty-array read is guarded. `WireIntegerConversionTests` sends each out-of-range value; with the old code each test crashes the test process instead of failing.

## Prevention

- **Exact conversions only.** A value that came from the wire is converted with `T(exactly:)` (or a range check) and a thrown error, never with `T(_:)`, `truncatingIfNeeded` (a silent wrong value), `!` or `as!`.
- **Bound counts before allocating.** A count read from the wire is checked against the bytes left before anything is reserved.
- **Limit recursion depth.** A recursive decoder has a depth limit set well below what a debug build's thread stack holds.
- **Guard index reads.** A wire array's elements are read through `first`, a count check, or an `indices` check.
- **A record is wire data too.** A replay record is uploaded through the admin start or handed to a runner, so the same rules hold for what is read from it:
  - `Dictionary(uniqueKeysWithValues:)` over keys read from a record traps on a duplicate (#639). Index with `updateValue(_:forKey:)` and throw on a duplicate.
  - Arithmetic on a recorded value traps on overflow, as `maxTickId + 1` did (#640). Check the range when the record is opened, or use `addingReportingOverflow`.
- **A default is a silent wrong value too.** A recorded value outside its domain throws. Mapping it to a default widens what the data says: an unknown event target replayed as `.all` sent a targeted event to every client (#641).
- **Test it as a crash.** A test of such a site sends the out-of-range value and expects an error. On a trapping decoder it crashes the run, which is the failure we want. On a Mac every crash raises the crash reporter's dialog, so run the failing-first run of a trapping site on Linux, and keep only the passing `#expect(throws:)` form on the Mac.
