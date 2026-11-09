---
module: deep-research
date: 2026-11-09
problem_type: measurement_pitfall
component: network-impairment-analysis
symptoms:
  - "srsmoke: 0 resyncs, not 1, for every slow reader, while the client's own close record says resyncs 1"
  - "the SR profile row fails: resyncs per reader {0: n}"
  - "not rebuilt by a firstSync after the lift, though the reader reconnected with a firstSync"
  - "srpause.py: refused: ...-SR-CAL: <key>: 0 resyncs before its 4010, not exactly 1 (every slow reader; the smoke had passed)"
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

After that fix, the 300-room SR-CAL was refused by `srpause.py` with "0 resyncs before its 4010" for all 150 slow readers. The SR smoke passed: `srsmoke.py` counts through `outage_sessions`, which was fixed, but `srpause.py` had its own copy of the same bound and wasn't.

## Root cause

`analysis.outage_sessions` counted a session's resyncs by the client's arrival time and bounded them by the server's close time: `applied <= t <= server_t`. Both times come from the same host's wall clock, but they're seen from different places. A reader that has stopped reading processes its buffered frames only when its connection closes. So its resync "arrives" 0.1–0.7 s after the server's close, and the bound dropped it every time.

The smoke's rebuild check made a second, unrelated mistake: it required the firstSync after the lift. The client reconnects about 1 s after the 4010, inside the pause, by design (`worker.ts`: the new connection pauses for what is left of the window). The design's criterion (§ 7) is "reconnects with a firstSync" by the end of recovery, and `regenerate.py` already checked that.

## Fix

- `outage_sessions` counts a session's resyncs on the client's side: within the connection open at the apply, up to that connection's close as the client logged it. Over the whole connection the count must equal the close record's own per-connection `resyncs`; a difference raises `ValueError` naming both numbers.
- `srsmoke.py` checks the rebuild on the client's side too: a firstSync after the client's close of the connection, by the end of recovery. It reports a refused count as a FAIL line.
- Tests: the smoke fixture now logs the resync as a paused reader does (after the server's close, before the client's) and reconnects inside the pause. A resync count that disagrees with the close record is refused. The exported smoke run fails before the fix and passes after.
- `srpause.py` (the second fix) counts each slow reader's resync through `outage_sessions` too, and refuses when its first 4010 in the pause isn't that of its connection open at the apply. The SR-CAL data showed the shape: each resync line came 54–977 ms after the server's 4010 and 2–12 ms before the client's own close. The server's profile counted all 150 resyncs about 3 s into the pause, and all 150 4010s about 10 s later. It no longer reports the "pause → first resync (client arrival)" figure, because for a paused reader that is the drain at close, not a delivery time. Its fixture logs the SR-CAL the same way, including the reconnects that cycle through the pause (each with its own resync and 4010, about every 16 s).

## Prevention

- When a check puts two event times in one inequality, both must be observed from the same side: client with client, or server with server. A server-side time and a client-side time differ by at least the delivery delay, and a stalled reader can make that delay as long as its stall. An impairment timeline (apply, lift) is a schedule, so it can bound either side's events.
- When the observer keeps its own count (here the close record's `resyncs`), cross-check the derived count against it and refuse on a difference. That turns a wrong window into an error instead of a silent 0.
- Test fixtures should log events where the real observer would, not at the moment the other side sent them.
- Grep the siblings. When you fix a cross-clock comparison, search every script that reads the same records (here: sample `t` and client close records against lifecycle `wallMs`, `serverT` and the profile's `ts`) for the same pairing, and fix or argue each one in the same change. A fixed helper doesn't protect a script that kept its own copy of the rule.
- Other cross-side pairings that are safe as written: `_session_of_join` matches the nearest server join to a client join (a nearest match, not a bound); `pair_by_code` pairs closes within a 5 s tolerance; the sync-lag cross-check compares whole-run totals.
