---
module: SwiftStateTree, SwiftStateTreeTransport
date: 2026-11-18
problem_type: bug_class
component: inbound-decode-chain
symptoms:
  - "EXC_BAD_ACCESS (SIGBUS) / KERN_PROTECTION_FAILURE in a stack guard on com.apple.root.default-qos.cooperative"
  - "a deeply nested client frame parses, then the process dies in the payload's re-encode"
  - "the depth test passes on Linux and kills the test bundle on macOS"
root_cause: parser_depth_limit_deeper_than_later_recursive_stages_can_walk
resolution_type: design_rule
severity: high
tags:
  - decoding
  - nesting
  - stack-overflow
  - darwin
  - cooperative-pool
  - json
related:
  - "#362"
  - "#528"
  - "#595"
  - "2026-11-18-a-fuzz-harness-is-only-as-good-as-the-mutants-it-kills"
---

# A parser's depth limit isn't the pipeline's: every recursive stage after it needs the bound

## Problem

Linux Foundation's JSON parser refuses data nested deeper than 512 levels (Darwin's accepts 513), and the depth tests (#595) relied on that limit. A frame at 512 levels parsed fine on every platform, and Linux ran the whole chain at that depth. On macOS the test bundle died, in debug and in release.

## Root cause

The parse isn't the only stage that recurses once per level. After it come:
- `AnyCodable`'s decode;
- `InboundPayloadDecoding`, which re-encodes the `AnyCodable` with `JSONEncoder` (`AnyCodable.encode(to:)` → `__JSONEncoder.wrapGeneric` → the container's `encode` → `AnyCodable.encode(to:)`, several frames per level);
- the payload type's own decode;
- the recorder's conversion.

On Darwin, Swift Concurrency's cooperative threads have a 544 KiB stack, and the keeper's decode runs on one. The re-encode at 512 levels needs more than that, so a client action nested that deep could take a macOS server down. Linux's larger thread stacks hid it.

The parser's limit was sized for the parser, not for the stages after it. Their cost per level depends on Foundation's internals and the build mode.

## Fix

- One nesting limit for every client frame and encoding: `PayloadNesting.clientFrameMaxDepth`, 32. A client's MessagePack frames unpack at it too (`TransportCodec.decodeClientFrame`). Frames the server builds keep the unpacker's default of 64 (`serverFrameMaxDepth`): that's the developer's own state, and a lower limit there would restrict what a game can model. A test pins both and their relation.
  - The edge, measured on macOS (Swift 6.3.x, debug, a 544 KiB cooperative-pool stack, one process per depth): the decode chain survives JSON nested 112 deep and overflows at 128. MessagePack at 64 survived. 64 would have left under 2× headroom; 32 leaves about 3.5×.
  - The deepest real frame in the example lands is 7 levels: a 4-level payload in 3 levels of frame.
- JSON from a client is depth-checked before it is parsed, once per decode. `PayloadNesting.checkClientJSON` skips what the parser skips, then `checkJSON` runs a one-pass byte scan that counts `[` and `{` outside strings. It runs at the router's handshake and post-handshake decodes and in the adapter's decode pipeline, so a frame the router forwards is scanned twice, once for each of its two parses. A 2.x JSON record is scanned at the 3.x record limit.
- A payload is checked before its re-encode (`PayloadNesting.check`, a walk that stops past the limit) unless it comes with its frame's bound: a live input's payload sits inside a frame the adapter's pipeline already bounded, so the pipeline hands the keeper a `DepthBounded` value and the walk is skipped. A recorded input replayed (records are bounded only at 128) or a payload handed to the keeper's public API comes without one and is walked. Before this, the live path walked each payload after its frame was already bounded, and the off-path gate's action cells measured #605 at +2.4 % (MessagePack) and +1.7 % (JSON) instructions.

## Prevention

- **Bound depth where the data enters, at a value every later stage can walk on the smallest thread stack it may run on** (Darwin's cooperative pool, 544 KiB), not at the parser's limit. A limit inherited from a library is the library's.
- **Check again at a stage reachable from another source** (a record, a replay), with a check that doesn't itself recurse.
- **Skip a repeated check with a proof type, not a flag.** The stage that enforced the bound builds a value only it can build (`DepthBounded`), and the later stage skips its check only for that type. A `depthChecked: Bool` is a claim any caller can set wrong, and a wrong `true` removes the bound silently. Pin with a test that counts how the live path decoded, so the check can't silently come back or vanish.
- **A pre-scan must read the bytes the parser reads.** The first version ran only when byte 0 was `[` or `{`, and counted escapes byte by byte. Foundation skips leading whitespace and a BOM, and decodes UTF-16 and UTF-32, where an escape spans two bytes and a byte-wise count ends the string early. A frame with a leading space, or in UTF-16 with an escaped quote, passed the scan and reached the recursive decode (review of #605). The scan now skips what the parser skips and refuses what it can't read: client JSON is UTF-8, so a NUL byte or a UTF-16/32 lead is refused. Gate a check on what the parser accepts, not on what valid input looks like.
- **Measure the edge on the smallest stack, then keep headroom:** one process per depth, since an overflow ends the process. A cap at a round number that "seems small" (64 here) was under 2× from the edge.
- **Test past the limit, up to and beyond the parser's own:** the depth tests run every decoder at the limit, one past it, and at 512 and 513 (Linux Foundation's limit and one past it), and require a refusal rather than an overflow. Show the fixtures' depth with an oracle that shares no code with the check: a walk of the parsed tree.
- **Run deep-recursion tests on Darwin as well as Linux,** in debug and release. A pass on Linux says little about a 544 KiB stack.
