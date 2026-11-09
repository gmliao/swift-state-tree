---
module: deep-research
date: 2026-11-09
problem_type: measurement_pitfall
component: network-impairment-analysis
symptoms:
  - "srsmoke: 0 resyncs, not 1, for every slow reader, while the client's own close record says resyncs 1"
  - "the SR profile row fails: resyncs per reader {0: n}"
  - "not rebuilt by a firstSync after the lift, though the reader reconnected with a firstSync"
root_cause: client_arrival_time_bounded_by_server_side_time
resolution_type: code_fix
severity: high
tags:
  - deep-research
  - measurement
  - clocks
  - slow-reader
  - sync-lag
  - testing
related:
  - "deep-research/network-impairment-2026-11"
---

# Compare event times on one clock

## Problem

The network-impairment SR smoke failed on every slow reader with "0 resyncs, not 1; not rebuilt by a firstSync after the lift". The server had resynced each one once, closed it with 4010 about 13 s into the pause, and each had reconnected with a firstSync. The real SR row in `regenerate.py` would have failed the same way: its "exactly one resync" check reads the same count.

## Root cause

`analysis.outage_sessions` counted a session's resyncs by the client's arrival time and bounded them by the server's close time: `applied <= t <= server_t`. Both times come from the same host's wall clock, but they're seen from different places. A reader that has stopped reading processes its buffered frames only when its connection closes. So its resync "arrives" 0.1–0.7 s after the server's close, and the bound dropped it every time.

The smoke's rebuild check made a second, unrelated mistake: it required the firstSync after the lift. The client reconnects about 1 s after the 4010, inside the pause, by design (`worker.ts`: the new connection pauses for what is left of the window). The design's criterion (§ 7) is "reconnects with a firstSync" by the end of recovery, and `regenerate.py` already checked that.

## Fix

- `outage_sessions` counts a session's resyncs on the client's side: within the connection open at the apply, up to that connection's close as the client logged it. Over the whole connection the count must equal the close record's own per-connection `resyncs`; a difference raises `ValueError` naming both numbers.
- `srsmoke.py` checks the rebuild on the client's side too: a firstSync after the client's close of the connection, by the end of recovery. It reports a refused count as a FAIL line.
- Tests: the smoke fixture now logs the resync as a paused reader does (after the server's close, before the client's) and reconnects inside the pause. A resync count that disagrees with the close record is refused. The exported smoke run fails before the fix and passes after.

## Prevention

- When a check puts two event times in one inequality, both must be observed from the same side: client with client, or server with server. A server-side time and a client-side time differ by at least the delivery delay, and a stalled reader can make that delay as long as its stall. An impairment timeline (apply, lift) is a schedule, so it can bound either side's events.
- When the observer keeps its own count (here the close record's `resyncs`), cross-check the derived count against it and refuse on a difference. That turns a wrong window into an error instead of a silent 0.
- Test fixtures should log events where the real observer would, not at the moment the other side sent them.
- Other cross-side pairings that are safe as written: `_session_of_join` matches the nearest server join to a client join (a nearest match, not a bound); `pair_by_code` pairs closes within a 5 s tolerance; the sync-lag cross-check compares whole-run totals.
