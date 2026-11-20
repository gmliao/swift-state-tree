---
module: SwiftStateTreeReevaluationMonitor
date: 2026-11-19
problem_type: bug_class
component: replay-record-decode
symptoms:
  - "a recorded server event with a Date field doesn't decode in replay: typeMismatch, Expected to decode Double but found a string"
  - "a recorded Data, URL or Decimal field fails to decode: Expected String but found an array / a dictionary"
  - "a Double of 3.0 read back from the JSON record view fails a strict decode: expected float64"
  - "-0.0 replays as +0.0 from the JSON view"
  - "a replayed handler sees nil for a resolver output with a Date, Data or URL field"
root_cause: a_recorded_payload_was_decoded_with_a_codec_other_than_the_one_that_wrote_it
resolution_type: design_rule
severity: high
tags:
  - replay
  - record-format
  - decode
  - canonical-messagepack
  - anycodable
  - date
  - json
  - resolver-output
related:
  - "#521"
  - "#538"
  - "#628"
  - "#633"
  - "#707"
  - "#709"
  - "#710"
  - "#633"
  - "#713"
---

# Decode a record with the codec that wrote it

## Problem

The typed replay re-emit (#521 PR 1b) first decoded a recorded server event's `AnyCodable` tree with a default `JSONDecoder`, the client-input path's round trip. The record is written with `CanonicalMessagePack`, which has its own rules: a `Date` is an ISO-8601 string at whole seconds, and `Data`, `URL` and `Decimal` go through their own `Codable` (an integer array, `{"relative": …}`, Decimal's keyed form). The default `JSONDecoder` reads a `Date` as a `Double` since 2001 and `Data` as base64, so every one of the four failed on a saved record. Three plan revisions passed review before a probe on a real saved record showed it.

The JSON record view looked like a second format with its own rules, so a second codec (JSON with `.iso8601`) was planned for it. But the view is rendered from frames read back from the log, so its trees are already in the record codec's shape, and only its numbers differ: JSON doesn't keep the float/integer split.

## Root cause

A recorded payload is a tree whose shape is set by the encoder that wrote it, not by the type it came from. Decoding it with another codec applies that codec's rules for the special types (dates, bytes, URLs, decimals) to values written under different rules. The tree type (`AnyCodable`) hides the mismatch: the read succeeds, and the failure appears only when the tree is decoded into the type.

## Fix

- One record codec for both record sources: encode the tree with `CanonicalMessagePack` and decode the type with its strict decoder (`RecordPayloadSource`). In-repo precedent: server inputs already decode this way (`ServerInputCodec.decode`).
- The JSON view's one allowance, an integer into `Double` or `Float` when exact, threaded through the decoder as a flag (`CanonicalMessagePack.decode(_:from:integralFloats:)`) and chosen per source by a package helper.
- A payload whose base is already the type is taken as is (an in-process run's projected events).
- The byte-identity domain is stated, with what lies outside it: a fractional-second `Date` (truncated), an unsigned value above `Int.max` (#628), `-0.0` on the JSON view, canonically equivalent map keys.

## Prevention

- Before decoding stored data, find the writer and use its codec, or name every rule where yours differs. Check the special types first: `Date`, `Data`, `URL`, `Decimal`, signed zero, integers past `Int.max`, non-finite floats.
- Test on what the writer produced (a saved record, then its JSON view), never on a tree built by hand or by a different encoder: the hand-built tree is in the shape you expect, not the shape on disk.
- A comparison of stored against live values has the same trap: normalize both sides through the stored codec first (#633, the offline verifier).
- Every reader of a record needs this rule, not only the one that was fixed. A recorded resolver output was still read back through `JSONEncoder` and `JSONDecoder` (`LandContext`'s dynamic member lookup over `AnyCodableResolverOutput`). An output with a `Date`, `Data` or `URL` field failed that read, so the replayed handler saw `nil` instead of the value (#707). A probe through a saved record showed it. #710 fixed it: the subscript decodes with `RecordPayloadSource`, with the JSON view's allowance, and a decode that still fails logs a warning, because a silent `nil` is how it stayed hidden. A recorded action's own payload still goes through the JSON round trip; a probe shows replay drops an action with a `Date`, `Data` or `URL` field (#709). When the record codec is fixed for one reader, list the others (events, server inputs, actions, client events, resolver outputs, the verifier) and check each one.
- A comparison is a reader too. The offline verifier compared a recorded server event with the replayed one by the JSON of both payloads, a tree in the record's form against a typed value, so a `Date`, `Data`, `URL` or `Float` field reported a mismatch on a correct replay (#633). #713 puts the emitted payload in the record's form (a `CanonicalMessagePack` round trip) before comparing. Put both sides of a comparison in one form, the record's, rather than converting each with a different codec. A value the record itself has lost (the sign of `-0.0` on the JSON view) still differs, and that is the record's stated limit, not the comparison's.
- A byte-identical re-encode doesn't show that a value reads back: a `Decimal` resolver output re-encoded to the same bytes, in Darwin's keyed form, which no JSON read accepts (#597). Test the reader's decode into the type.
