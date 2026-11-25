---
module: SwiftStateTreeNIO
date: 2026-11-25
problem_type: bug_class
component: type-system
symptoms:
  - "An `as?` cast against an imported type compiles silently but never matches at runtime"
  - "An `errorCaught` branch intended to catch NIO's error type is dead code"
  - "The fallback path runs where the specialized path was expected"
root_cause: module_type_shadows_imported_type_same_name
resolution_type: design_rule
severity: high
tags:
  - swift
  - name-shadowing
  - type-casting
  - imports
  - websocket
related:
  - "#827"
---

# A module's own type shadows an imported one in an `as?` cast

## Problem

`SwiftStateTreeNIO` declares `NIOWebSocketError` (`.connectionClosed`, `.writeFailed`).  `NIOWebSocket` also exports `NIOWebSocketError` (`.invalidFrameLength`, `.fragmentedControlFrame`, `.multiByteControlFrameLength`).  Inside `SwiftStateTreeNIO`, the bare name `NIOWebSocketError` resolves to the **module's own type**, shadowing NIO's.

The cast `error as? NIOWebSocketError` compiles without warning but matches only the module's error values.  NIO's decoder errors — which carry NIO's type — never match, so the branch is unreachable dead code.

## Symptoms

- A branch added to handle NIO's frame-decoder errors runs no more often than before the fix.
- Tests that fire NIO's errors through the pipeline find the fallback cause (`.connectionLost` or `.error` with no code) instead of the expected one.

## Fix

Spell the imported type **module-qualified**: `error as? NIOWebSocket.NIOWebSocketError`.  The module prefix breaks the shadowing.  Also add a test case that fires this module's `NIOWebSocketError.connectionClosed` and asserts it takes the generic path — this pins the boundary between the two types and will fail if the names drift.

## Prevention

Whenever a module-local type shares a name with an imported one, always use the module prefix at every use site in the same module, even where the local type is intended, so the distinction is visible and auditable.

The same rule applies to any `as?` cast, `is` check, or switch-on-type: compile-time silence does not mean runtime correctness.
