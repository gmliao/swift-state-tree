---
title: "Compare instants by their order, never by the sign of a wrapped difference"
module: SwiftStateTurns
date: 2026-11-24
problem_type: bug_class
component: turn-clock
symptoms:
  - "a sleep until a far deadline lasts about 292 years and every later timer stalls behind it"
  - "a sleep returns at once for an instant far in the future"
  - "an instant that orders as past makes the computed remaining time huge and positive"
root_cause: wrapping_int64_arithmetic_on_instants_read_by_sign
resolution_type: design_rule
severity: medium
tags:
  - clock
  - overflow
  - instant
  - wrapping-arithmetic
  - sleep
related:
  - "#759"
  - "#789"
  - "#791"
---

## Problem

`SystemTurnClock.sleep(until:)` first computed the remaining time as `instant - now` and returned if it was not positive. `TurnInstant` stores signed `Int64` nanoseconds, and its `+` and `-` use `&+` and `&-`, which wrap. A duration converts to nanoseconds with saturation, so the pair can disagree with the instants' own order:

- `now + .seconds(.max)` saturates the duration to `Int64.max`, and the `&+` then wraps the sum to a very negative instant. The core orders that instant as past. But `instant &- now` wraps back to about `Int64.max`, so the clock slept about 292 years. It was the earliest deadline, so no later arm replaced it (the core only replaces a sleeper for an earlier instant), and every later timer and deadline stalled behind it. The hand-written example clock it replaced returned at once for the same instant.
- The first `now` a process reads can be slightly negative (`TurnInstant(ContinuousClock.now)` samples the clock before `processOrigin`'s lazy initializer runs). An instant within that margin of `Int64.max` then makes the difference wrap negative, and the sleep returns at once, which breaks the contract of never returning early.

Both need extreme instants. They are cheap to trigger by accident: a "never" deadline written as `now + .seconds(.max)`.

## Root cause

The sign of a wrapped difference is read as an order. With `&-` on `Int64`, `a &- b > 0` doesn't mean `a > b` once the true difference doesn't fit. The order of `TurnInstant` (`<`, compares the stored values) and the sign of its `-` can disagree.

## Fix

Order first, then subtract the ordered pair. `SystemTurnClock` reads `now` once per loop; if `now >= instant` it returns. Only then does it compute the remaining nanoseconds, with `subtractingReportingOverflow`: `instant > now` makes the true difference positive, and it overflows `Int64` only when `now` is negative and `instant` is large. Each sleep is at most one hour, so an overflow, or a huge but valid difference, sleeps a bounded chunk, and the loop reads the clock again. `TurnInstant`'s own `+` and `-` were left unchanged then; since #991 (for #791) they clamp at `Int64`'s range instead of wrapping. The order rule still applies: a clamped difference near the range's end no longer measures the gap.

Update (#791): `TurnInstant`'s `+` and `-` now saturate at `Int64`'s range. Each takes the sum or the difference in `Int128` and clamps it. `now + .seconds(.max)` is `TurnInstant(nanoseconds: .max)`, a deadline that never fires, and the difference of two instants never has the wrong sign. Two hand-written workarounds now call the operator: `TurnCore.saturatingDeadline` (the barrier's budget) and `KeeperModel.freezeDeadline` (a freeze caller's timer). The clock's order-first loop stays: a clock written by an adopter still gets instants at either end of the range.

## Prevention

- Compare instants with `<`, `>=` and `==`, never by the sign of `a - b`, wherever the type's `-` can wrap. Take a difference only of a pair that is already ordered, and with overflow reporting if the span can exceed half the range.
- Give a wait a bound. A sleep given a duration near the end of its range is an unbounded wait for practical purposes; sleep in chunks and re-read the clock.
- Test the extremes with no wall-clock assertions: `TurnInstant(nanoseconds: .min)` must return at once, and `TurnInstant(nanoseconds: .max)` must stay asleep until its task is cancelled. Before #791, `clock.now + .seconds(Int64.max)` ordered as past and also had to return at once. It now saturates to `.max`. See `Tests/SwiftStateTurnsTests/SystemTurnClockTests.swift`. Before the clock's order-first fix, the past-instant cases ran into the suite's one-minute time limit.
- Saturate at the source. A value type whose arithmetic wraps leaves every caller to write its own saturation, and a caller that forgets gets a deadline in the past. Before #791 two callers had hand-written their own. `Tests/SwiftStateTurnsTests/TurnInstantSaturationTests.swift` pins both ends, a negative instant plus a duration just past the range (exact, not saturated first), and a core timer armed at `now + .seconds(.max)` that never fires.
- Prior art: POSIX `clock_nanosleep` with `TIMER_ABSTIME` compares the clock against the absolute deadline instead of a computed remainder; Rust's `Instant` offers `checked_add` and `saturating_duration_since`, so a caller picks overflow behaviour on purpose.
