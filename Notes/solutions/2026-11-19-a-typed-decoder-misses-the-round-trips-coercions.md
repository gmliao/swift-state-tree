---
module: SwiftStateTreeMessagePack
date: 2026-11-19
problem_type: bug_class
component: inbound-payload-decode
symptoms:
  - "a payload with a Decimal field decodes over JSON but never over MessagePack: typeMismatch, Expected KeyedDecodingContainer, found double"
  - "a Float field accepts 1e39 or Double.greatestFiniteMagnitude and holds +inf, where the old path refused it"
  - "an AnyCodable field holds a Double where it used to hold an Int, or binary bytes where it used to hold base64 text"
root_cause: typed_decoder_skips_the_coercions_the_json_round_trip_applied
resolution_type: code_fix
severity: high
tags:
  - testing
  - differential
  - decode
  - messagepack
  - decimal
  - float
  - anycodable
related:
  - "#521"
  - "#537"
---

# A typed decoder that replaces a JSON round trip misses the round trip's coercions

## Problem

#521 PR 2 decodes a MessagePack action or client-event payload straight into its type (`MessagePackValueDecoder`), replacing today's path: the payload became an `AnyCodable` tree, then went through `JSONEncoder` and `JSONDecoder` (`InboundPayloadDecoding`). The plan expected a few differences: an integral float into an integer field, binary into a string. A differential test against the old path, run on every fixture type field by field, found three more that no one had listed:

- **Decimal.** `Decimal`'s own `Codable` form is a keyed container, not a number. `JSONDecoder` special-cases `Decimal` and reads it from a number, but `MessagePackValueDecoder` didn't. A client sends a number, so a payload with a `Decimal` field never decoded.
- **Float range.** `Float(double)` turns a finite double past `Float`'s range into `+inf`, and a nonzero subnormal into `0`. `JSONDecoder` refuses both. The typed decode accepted them, so a non-finite value could reach handler state, which the whole-tree check was meant to rule out.
- **`AnyCodable` fields.** After the round trip, an integral float in an `AnyCodable` field is an `Int` (`3.0` is written `3`), and binary is base64 text. Decoded from the value, it was a `Double` and failed. Canonical-JSON comparison doesn't show the `Int`/`Double` split; a handler's `base as? Int` does.

## Root cause

The old path's semantics weren't only the type's `Codable`: they included what `JSONEncoder` writes (shortest decimal text, base64 for `Data`, integral doubles without a fraction) and what `JSONDecoder` special-cases (`Decimal`, range checks). A decoder that reads the type's `Codable` exactly drops all of these.

## Fix

In `MessagePackValueDecoder` (`Sources/SwiftStateTreeMessagePack/MessagePackValueDecoder.swift`):

- `Decimal` decodes from an int, uint, float or double, read from the number's shortest decimal text as the round trip read it. Its keyed form still decodes, for the frames the server builds.
- A `Float` refuses a finite double that would become infinite and a nonzero one that would become zero.
- For a client payload only (`clientPayload`, set by `MessagePackPayloadSource`), an `AnyCodable` field is built as the round trip built it: the value's tree through `JSONEncoder` and `JSONDecoder`.

## Prevention

- When a decoder replaces another path, run a differential against that path before review. Cover every fixture type, field by field, with numeric kinds at their limits, `Decimal`, `Date`, `Data`, `AnyCodable`, binary and strings. List each remaining difference with its direction, and fail on any difference that isn't listed (`Tests/SwiftStateTreeTransportTests/PayloadDecodeDifferentialTests.swift`).
- Compare the decoded values on their types too, not only on their canonical JSON, wherever a field is type-erased (`AnyCodable`). Pin those with a direct test.
- A related lesson on matching the old implementation's quirks: [A diff replacement must match the old diff's quirks](2026-11-10-a-diff-replacement-must-match-the-old-diffs-quirks.md).
