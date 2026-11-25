---
title: "A new refusal at an input boundary breaks every fixture that skipped the step"
module: SwiftStateTreeNIO
date: 2026-11-25
problem_type: testing_practice
component: websocket-session-handler
symptoms:
  - "after a new protocol check lands, dozens of existing tests fail with a close frame they never expected"
  - "test fixtures build inbound frames with no mask key, which the decoder passes on and the handler never read"
root_cause: fixtures_built_inputs_a_real_peer_cannot_send_and_the_code_never_checked
resolution_type: design_rule
severity: low
tags:
  - testing
  - fixtures
  - websocket
  - rfc6455
  - refusal
related:
  - "#843"
---

**Problem.** RFC 6455 §5.1 makes a client mask every frame. The handler read payloads through `unmaskedData`, which returns the data unchanged when the key is nil, so an unmasked frame was accepted. About 45 test fixtures across 8 files built inbound frames with `WebSocketFrame(fin:opcode:data:)`, which has no mask key: inputs no real client sends, which passed only because nothing refused them.

**Root cause.** A boundary that accepted more than the protocol allows lets fixtures drift from what a peer really sends. The first refusal then fails every one of them at once, and nothing separates a fixture that skipped the step from a behavior the test means to keep.

**Fix.** Before the source change:
- list the fixtures by grep (the census: `WebSocketFrame(` constructions and `writeInbound` calls per file);
- switch them to a helper that does what a real peer does (`WebSocketFrame.client(...)`: a fixed non-zero key, the payload stored masked);
- grep again and say why each remaining direct construction stays;
- only then add the refusal and its tests.

The fixture commit passes on the old code, and the new tests are the only ones that fail until the check lands.

**Prevention.** A test that turns red after the refusal and isn't one of the new tests is a fixture that was missed, not a behavior to keep. A fixture that means to send the refused input builds it directly and says so. Pin `== nil` against "key is zero": an all-zero key is a masked frame.
