---
title: "A typed decoder that replaces a JSON round trip misses the round trip's coercions"
module: SwiftStateTreeMessagePack
date: 2026-11-19
problem_type: bug_class
component: inbound-payload-decode
symptoms:
  - "a payload with a Decimal field decodes over JSON but never over MessagePack: typeMismatch, Expected KeyedDecodingContainer, found double"
  - "a Float field accepts 1e39 or Double.greatestFiniteMagnitude and holds +inf, where the old path refused it"
  - "an AnyCodable field holds a Double where it used to hold an Int, or binary bytes where it used to hold base64 text"
  - "a recorded input that was applied live is dropped by replay as undecodable, and the state hash diverges from that tick"
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

Review then found a gap in the other direction, which the first differential didn't check. A `Decimal` or a `URL` sent in its keyed `Codable` form decoded live, because the decoder fell through to the type's own `init(from:)`. Replay decodes the recorded tree with the JSON round trip, which refuses both. So an input applied live was dropped at replay, and the state hash diverged. Two container behaviours also differed from `JSONDecoder`, invisible to synthesized `Codable` but not to a hand-written `init(from:)`:
- `decodeNil(forKey:)` answered true for a missing key, where `JSONDecoder` throws;
- the unkeyed container moved past an element whose decode threw, so a fallback read saw the next one.

## Root cause

The old path's semantics weren't only the type's `Codable`: they included what `JSONEncoder` writes (shortest decimal text, base64 for `Data`, integral doubles without a fraction) and what `JSONDecoder` special-cases (`Decimal`, range checks). A decoder that reads the type's `Codable` exactly drops all of these.

## Fix

In `MessagePackValueDecoder` (`Sources/SwiftStateTreeMessagePack/MessagePackValueDecoder.swift`):

- `Decimal` decodes from an int, uint, float or double, read from the number's shortest decimal text as the round trip read it. In a client payload, nothing else. Frames the server builds may also carry its string or keyed form.
- `URL` decodes from a string, as `JSONDecoder` reads it. In a client payload, nothing else.
- A `Float` refuses a finite double that would become infinite and a nonzero one that would become zero. It takes an integer straight, and a double that doesn't convert exactly from the double's shortest text, each rounded once as `JSONDecoder` rounds a number's text. `Float(double)` rounds the exact double, which goes the other way on a Float midpoint whose shortest text isn't exact (`1 + 2^-24` is `1.0000000596046448`).
- In a client payload, `decodeNil(forKey:)` throws for a missing key and unkeyed `decodeNil()` throws past the end. The unkeyed container moves past an element only when its decode succeeds, and `superDecoder()` reads `"super"` whatever the key type.
- For a client payload only (`clientPayload`, set by `MessagePackPayloadSource`), an `AnyCodable` field is built as the round trip built it: the value's tree through `JSONEncoder` and `JSONDecoder`.

## Prevention

- Start from the reference decoder's boundary table: here swift-foundation's `JSONDecoder` (`unwrapFixedWidthInteger`, `unwrapFloatingPoint`, `unwrapDecimal`, `unwrapURL`, `unwrapData`, its keyed `decodeNil(forKey:)` and its unkeyed `decode`), and the MessagePack spec for the wire types (ext codes, float 32/64, bin against str). Each row of the table is a differential case, and each departure is a planned refusal with its reason.
- When a decoder replaces another path, run a differential against that path before review. Cover every fixture type, field by field and one level down, with numeric kinds at their limits, `Decimal`, `URL`, `Date`, `Data`, `AnyCodable`, binary, extension values and strings, and each special type's keyed `Codable` form. Fail on any difference outside the planned classes, and pin each class's count (`Tests/SwiftStateTreeTransportTests/PayloadDecodeDifferentialTests.swift`).
- A planned difference may only refuse what the old path accepted. A refusal holds only while the field's error reaches the top: a hand-written `init(from:)` that falls back with `try?` turns it into a different value, so name such types or test them directly. Where another path reads the same input later, check that as well: replay decodes what live recorded, so every input the new decoder accepts must replay to the same value.
- Probe the container behaviours a hand-written `init(from:)` relies on (`decodeNil(forKey:)` on a missing key, unkeyed `decodeNil()` past the end, a failed unkeyed decode followed by a fallback, `superDecoder()` reading `"super"`). Synthesized fixtures never call them.
- Compare the decoded values on their types too, not only on their canonical JSON, wherever a field is type-erased (`AnyCodable`). Pin those with a direct test.
- A related lesson on matching the old implementation's quirks: [A diff replacement must match the old diff's quirks](2026-11-10-a-diff-replacement-must-match-the-old-diffs-quirks.md).
