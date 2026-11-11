---
module: SwiftStateTreeMessagePack
date: 2026-11-09
problem_type: bug_class
component: transport-message-codec
symptoms:
  - "a joinResponse decoded from MessagePack has nil playerSlot, encoding or stateUpdateFeatures"
  - "a field added to a payload struct round-trips in JSON but not in MessagePack"
root_cause: hand_written_codec_forms_list_fields_by_name_and_miss_new_ones
resolution_type: established_pattern
severity: medium
tags:
  - codec
  - messagepack
  - serialization
  - testing
related:
  - "#312"
---

# A hand-written codec form drops a field added later

## Problem

`TransportJoinResponsePayload` gained `playerSlot`, `encoding` and later `stateUpdateFeatures`. The JSON path is synthesized `Codable` and carried them at once. The MessagePack map form (`MessagePackDirectEncoder` / `MessagePackDirectDecoder`, used by `MessagePackTransportCodec` for a whole `TransportMessage`) lists each field by hand, and both sides kept the old list. The MessagePack decoder of the opcode array also stopped at `reason` and never read `stateUpdateFeatures` at index 8, although the opcode encoder writes it. No test noticed: the existing round-trip tests built messages with only the old fields set.

## Root cause

A hand-written form (a direct encoder, a positional array, a second-language SDK) is a second list of the struct's fields. Adding a field to the struct compiles without touching that list, and a round-trip test whose fixture leaves the new field nil passes, because nil round-trips as nil.

## Fix

Both MessagePack sides now carry every `TransportJoinResponsePayload` field (#312). `MessagePackTransportMessageRoundTripTests` encodes one fixture per payload shape through the codec and compares the decoded message with the original by canonical JSON (sorted keys).

## Prevention

- A round-trip test of a hand-written form uses fixtures with every field set, and checks that this is so: `MessagePackTransportMessageRoundTripTests` walks each payload struct with `Mirror` and fails on a nil optional, so a new field fails until the fixture sets it, and then fails again until the codec carries it.
- Compare the whole decoded value (canonical JSON, or `Equatable`), not a few chosen fields.
- Build the fixtures with an exhaustive `switch` over the message kind, so a new kind doesn't compile without one.
- When a field is added to a wire struct, grep for the struct's other forms (`encode…Payload`, `decode…Payload`, the SDK's `decode…Array`) in the same change.
