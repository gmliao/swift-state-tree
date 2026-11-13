---
module: SwiftStateTreeTransport
date: 2026-11-13
problem_type: testing_practice
component: message-encoders
symptoms:
  - "the server process traps on the first action queued on a tick land, with TRANSPORT_ENCODING=opcode"
  - "Fatal error: Payload type '()' must conform to PayloadCompression and use @Payload macro for compression support"
  - "a crash on one encoding config while the E2E passes in all three encodings"
root_cause: copied_function_lost_a_branch_and_the_e2e_leg_name_hid_the_gap
resolution_type: code_fix
severity: high
tags:
  - encoding
  - opcode-json
  - payload-compression
  - e2e
  - coverage
  - crash
related:
  - "#541"
  - "#542"
  - "#543"
  - "#521"
---

# An E2E leg named for a path it doesn't run

## Problem
With `TransportEncodingConfig.opcode` (opcode JSON messages, payload compression on), the first action queued on a land with a tick handler ended the server process.
- The keeper answers such an action at once with an empty ACK, `.completed(AnyCodable(()))`.
- The opcode JSON `encodePayloadAsArray` cast `()` to `PayloadCompression` and hit its `fatalError`.

The E2E ran "in all three encodings" and passed.

## Root cause
Two things together:
- **A copied function lost a branch.** The MessagePack and opcode JSON encoders each have their own `encodePayloadAsArray`. The MessagePack copy writes `Void` as an empty array before the cast; the opcode JSON copy never had that branch.
- **The E2E leg's name suggested coverage it didn't have.** The three E2E encodings are `json`, `jsonOpcode` and `messagepack`. `jsonOpcode` is JSON **object** messages with opcode **state updates** only (`TransportEncodingConfig.jsonOpcode`), so its message encoder never compresses a payload. The config that does, `.opcode` (`TRANSPORT_ENCODING=opcode`), is in no E2E leg.

Ten in-package test files build `.opcode` adapters, but none queues an action on a tick land, so nothing reached the trap.

## Fix
The opcode JSON copy gets the same `Void` branch: the ACK is `[102, requestID, []]`, which the TypeScript SDK and the Swift decoder already accept. `PayloadVoidAckTests` pins the form per encoding, and an adapter test on `.opcode` queues actions on a tick land (#542).

## Prevention
- **"Every encoding" means every encoder path, not every E2E leg name.** Before relying on an encoding matrix, list what each leg configures: the message encoding, the state-update encoding, and whether payloads are compressed. A leg named after a format may use it for only one message kind. **Enforcement:** #543 adds an E2E leg on `.opcode` to CI, so the compressed opcode JSON message path runs on every PR.
- **Parallel copies of one function** (one per encoder, one per platform) are compared branch by branch when either changes. Where they must agree, a test runs the same input through each and pins each output: here, the `Void` response through both compressed encoders.
- **A `fatalError` on a path an input can reach** ends every land in the process, which the failure rule forbids (`docs/core/failure-handling.md`). Search for them on encode paths when a new config or encoder is added.
