---
module: SwiftStateTreeNIO
date: 2026-11-09
problem_type: bug_class
component: reevaluation-replay
symptoms:
  - "an authenticated endpoint returns an ID, and the resource is created later when a client uses that ID"
  - "the server never checks that it issued the ID it is creating a resource for"
root_cause: authorization_checked_where_the_id_is_issued_not_where_it_is_used
resolution_type: architectural_fix
severity: high
tags:
  - security
  - authorization
  - replay
  - auto-create
related:
  - "#366"
---

# An ID a client can build is not an authorization

## Problem

The admin replay start checked the admin key and the record, then returned a replay land ID. The land itself was created later, by the client's join through the router's auto-create. The ID was a random UUID followed by the record path in base64url. Nothing on the creating side checked that the server had issued it: the UUID part was never read, and the path part was only checked to be inside the records directory. So the admin key guarded the step that *computed* the ID, not the step that *used* it, and anyone who could compute the ID skipped the guard.

## Root cause

Authorization was checked where the ID was issued, and creation trusted any ID that looked right. That holds whenever a protected step hands back something the client later redeems, and the redeeming side accepts anything with the right shape. Here that meant every wiring that creates a replay land: the runner bootstrap, both keeper-mode resolvers, and a fallback inside the replay land that started a run from its own ID.

## Fix

The ID is now a ticket the admin start signs (`ReplayTicketSigner`, `Sources/SwiftStateTreeNIO/ReplayTicket.swift`):
- **The ticket:** an HMAC-SHA256 over the replay land type, a random nonce, an expiry and the record path token, under a random per-process key held only in memory.
- **Creation:** every path that creates a replay land verifies the ticket first, with a constant-time compare, and requires it unexpired. The records-directory check stays behind it.
- **Rejoining:** an existing land is joined by its exact ID, which carries the MAC, so reconnects work for the land's lifetime.
- **The fallback:** the replay land no longer starts a run from its own ID.

## Prevention

- **Verify where it is used.** When a protected step returns something a client redeems later, verify on the redeeming side that it was issued: a signature or MAC, or a server-side record of what was issued. Never rely on the protected step alone.
- **Parse strictly.** A ticket must have one spelling. If parsing is lenient (a sign, a leading zero, a hex digit in uppercase), one ticket gives several IDs, and with them several resources.
- **Tests:** `ReplayTicketJoinTests` drives the join through the router. Every forged form (no ticket, no MAC, a bad MAC, another key, another land type) and an expired ticket create no land and start no runner. A valid ticket creates the land, and the same ID joins it again after the creation window.
