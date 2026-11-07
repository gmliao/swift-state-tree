---
module: SwiftStateTreeTransport
date: 2026-11-06
problem_type: gotcha
component: transport-protocol
symptoms:
  - "On Linux CI the client gets the close without the JOIN_DENIED frame that should precede it"
  - "The concrete type's method exists and is correct, but a breakpoint or trace in it never fires from the async caller"
  - "Passes on the Mac, where the timing hides the early close"
root_cause: sync_concrete_method_loses_overload_resolution_to_async_protocol_extension_default
resolution_type: code_fix
severity: medium
tags:
  - swift
  - protocol-extension
  - overload-resolution
  - async
  - linux
related:
  - "#239"
---

# A protocol extension's async default wins over the concrete type's sync method

## Problem

`Transport` requires `func closeSessionAfterQueuedFrames(_ sessionID: SessionID) async`, and its extension provides a default that closes at once (`Sources/SwiftStateTreeTransport/Transport.swift`). `WebSocketTransport` implemented it as a **synchronous** method, which closes only after the queued frames are written. From async code holding the concrete type (the router's lookup timeout in #239), Swift picked the protocol extension's async default instead. The session closed before its drain wrote the `JOIN_DENIED` frame, so on Linux the client got the close without the error.

## Root cause

A synchronous method satisfies an `async` requirement, but in an async context, overload resolution between the concrete type's sync method and an extension's async method with the same name can prefer the async one. The protocol extension's default is statically dispatched there, so the "override" is silently bypassed. Nothing warns.

## Fix

In #239 (squashed into `90fd08b9`; branch commit `3dea437c`): make `WebSocketTransport.closeSessionAfterQueuedFrames(_:)` `async`, matching the requirement exactly. A test in `WebSocketTransportSessionIDTests` pins it with a drain held mid-send.

## Prevention

- Implement a protocol requirement with exactly its signature, including `async` and `throws`. Don't rely on a sync method satisfying an async requirement when the protocol has an extension default with the same name.
- Be wary of protocol extension defaults for behaviour that a conforming type must change (here, "close after queued frames" against "close at once"). A default that is wrong for the real type hides the mismatch.
- Test the behaviour through the call site's static type (the concrete type, from async code), not only through the protocol.
