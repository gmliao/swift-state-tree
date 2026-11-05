# ServerLoadTest

In-process load test: `Examples/GameDemo/Sources/ServerLoadTest` drives `WebSocketTransport` with in-process connections (no sockets), so it measures the server's land, sync and encoding work without network effects. Run it with `swift run -c release ServerLoadTest --help`; debug-build numbers are not comparable.

## Pacing

`--pacing` sets how the generator places joins and actions in each second:

- **`spread`** (default): second `t` starts on its own deadline `origin + t s`, whether or not the previous second's sends have finished. Joins are evenly spaced over the second, and each session's actions sit at a stable per-session offset (a hash of the session id), so the server sees no once-per-second burst.
- **`aligned`**: the same deadline-based seconds, but every send at the second's start. Not comparable with earlier runs.
- **`legacy`**: legacy generator, deadline sampler — rows are not comparable with old reports. It keeps the earlier generator: joins through a worker pool capped at `max(20, 1.5 × rate)`, each round of actions sent to every session and awaited before the next, and a full second's sleep after the work, so each second lasts 1 s + work time. The sampler is deadline-based in every mode, so the per-second rows differ from reports made before deadline pacing.

In `spread` and `aligned`, joins and actions share an in-flight cap (`--max-in-flight`, default 10000). A send over the cap is skipped and counted, not deferred, so a slow server never gets a catch-up burst larger than the cap.

## What a result records

- Per second (`results.seconds[t]`):
  - `actionsSentThisSecond`, counted when a send starts;
  - `actionsCompletedThisSecond`, counted when the transport call returns;
  - in `spread` and `aligned`, `pacing`: `startLagMs` (issuing start minus the deadline), `inFlightAtDeadline`, `planned`, `started`, `skippedByCap` and `late` (start lag > 100 ms).
- Summary (`results.summary`):
  - `totalActionsSent` and `totalActionsCompleted`;
  - `pacing`: `mode`, plus in `spread` and `aligned` the `lateSeconds`, `skippedByCap`, `maxStartLagMs`, `peakInFlight` and `maxInFlight`.
- After the run, ServerLoadTest logs one pacing line with late seconds, skipped sends, the cap, peak in-flight and max start lag. Each progress line carries the running late and skipped totals and the sends in flight. Both lines are warnings once a second was late or a send was skipped.
