# Per-player visibility under movement

Design: [`Notes/plans/2026-11-08-visibility-experiment-design.md`](../../Notes/plans/2026-11-08-visibility-experiment-design.md).

## Question

When each player receives only the entities within its view, and entities enter and leave that view every tick:

1. Is every recipient's reconstructed state equal to its server projection at every sync?
2. Does re-evaluation of the record reproduce every per-player sync output?
3. How many bytes does each recipient receive per sync, against a control that sends every entity to every player, and what does visibility cost the server per room: computing it in the tick, and the per-player output in the sync?

## Environment

The measurement host, release build, CPUs 0-7 pinned. Each result records the git commit, `swift --version`, `node --version` and whether the tree was clean (`meta`); The Results section opens with the measured commit, dirty flag, Swift and Node versions and build, which `regenerate.py` writes from that `meta` (`--check` verifies the line); it refuses results from more than one commit, a debug build, a dirty tree, and a result not in the intended wire form: the path index and field merge on (the defaults since #308), read from the EncodingBenchmark metadata and resolved with `deep-research/wireform.py`: a result that didn't record them counts as off only if its commit predates the knob, otherwise it is refused as missing.

## Command(s)

```bash
cd deep-research/visibility
REPEAT=1 bash run.sh              # every cell, all three variants, with the capture passes
REPEAT=2 ORDER=all-first CAPTURE=0 bash run.sh        # timing repeats; each order puts
REPEAT=3 ORDER=broadcast-first CAPTURE=0 bash run.sh  # every variant in every position once
python3 collect.py
python3 regenerate.py --markdown  # paste under Results; then --check
python3 test_topic.py             # no build needed
```

`DRY_RUN=1 REPEAT=1 bash run.sh` prints every command. A smoke run off the host: `CELLS="default tps2" ROOMS=2 ITERATIONS=20 PIN_CPUS= ALLOW_UNVERIFIED=1 REPEAT=1 RUN_ID=smoke bash run.sh`; `collect.py` skips such a sweep and `regenerate.py` refuses its values.

Per cell and variant, `run.sh` runs:

1. the measured pass: `EncodingBenchmark --scalability --game-type visibility-test` with 10 rooms and 200 iterations, the land's knobs in the environment (`VISIBILITY_TEST_FILTER`, `_ENTITY_COUNT`, `_VIEW_RADIUS`), serial, delta sync, messagepack-pathhash, server events off, the shipped sync path (every server variable unset; see "The sync path" below);
2. the capture pass: the same run with `--capture-views --capture-rooms 2 --record-dir` (its timings are discarded: capture and live state-hash recording add work to both tick and sync);
3. over the 2 captured rooms: `verify-views` (the gate), `time-decode` (client decode, bytes before and after deflate), `capcheck.py stats` (visible entities, view changes) and `replay.py` (`ReevaluationRunner --verify` on each record, with the cell's knobs);
4. once every variant is captured, `capcheck.py consistency` (radius against all) and `capcheck.py broadcast-consistency` (broadcast against all).

**The sync path.** `run.sh` unsets every server variable (`deep-research/serverenv.py`), so a run takes the shipped sync path (`USE_SNAPSHOT_FOR_SYNC` unset); `run.json` records them and `regenerate.py` refuses a run with any set. The sync path doesn't change what is sent: with `USE_SNAPSHOT_FOR_SYNC=false` and unset, every frame's length and every recipient's projection after every sync were equal, and both captures passed `verify-views` (at e8692a37, one cell per variant: snapshot-baseline monster cap 4 delta and full-snapshot and 10 rooms delta, entity-delta-baseline monster cap 4 sst-events, sst and b2, visibility default cell radius and all; 1,005 to 10,015 frames per cell; as negative controls, sst vs sst-events and delta vs full-snapshot differ in frame lengths). Frames aren't byte-identical, nor are two runs of either path: the order of entries within a frame varies between processes (#314).

## Parameter matrix

| Cell | Entities | View radius | Viewers per room | Ticks per sync |
|---|---:|---:|---:|---:|
| default | 40 | 15 | 4 | 1 |
| radius8 | 40 | 8 | 4 | 1 |
| radius30 | 40 | 30 | 4 | 1 |
| entities160 | 160 | 15 | 4 | 1 |
| entities640 | 640 | 15 | 4 | 1 |
| viewers16 | 40 | 15 | 16 | 1 |
| tps2 | 40 | 15 | 4 | 2 |

Each cell runs three variants:
- `radius`: each player gets the entities within its view;
- `all`: the control, the same `perPlayer` policy whose filter returns every entity. The land still computes visibility, so state and tick work are the same;
- `broadcast` (`VISIBILITY_TEST_FILTER=broadcast`): the twin state `VisibilityTestBroadcastState`, whose `entities` is a `@Sync(.broadcast)` field, run by the same land rules (`VisibilityTest.makeLand(_:)`). It has the same entities, motion and visibility work as `all`, without the per-player projection. `all` against `broadcast` is what the per-player projection machinery itself costs. The twin is for the benchmark and re-evaluation only; GameServer refuses the filter.

The variants' order within a cell rotates over the repeats (`ORDER`: radius, all, broadcast; all, broadcast, radius; broadcast, radius, all), so each variant runs first, second and third once. Fixed: 10 rooms (2 captured), 200 iterations, serial, delta, messagepack-pathhash, server events off, motion on, viewers don't move. Three repeats; the first captures.

Metric semantics (one unit of each):

- `bytes_per_recipient_sync`: the bytes of every frame one recipient receives in one sync, over every room: the benchmark's total over iterations × rooms × viewers. A frame to `*` counts once per recipient. The broadcast twin's sync sends one frame per session (`all` sends two, the broadcast fields and the per-player ones), so its bytes are per recipient in the same way. `all` − `broadcast` therefore includes one frame's envelope per recipient and sync, not only the projection's payload. The deflate figure is over the captured rooms (`roomBytes`: `ws` defaults, each recipient's stream compressed in order, checkpoint 0 compressed and not counted), divided by the viewers.
- `visible_per_recipient`: entities in one recipient's projection, mean over recipients and measured syncs of the captured rooms.
- `view_changes_per_recipient_sync`: the growth of the room-wide counters `viewEntries` + `viewExits` (every viewer's transitions) over the measured syncs, counted once per room, divided by viewers × syncs. `capcheck.py stats` checks the counters against the projections: with `radius` and one tick per sync, each recipient's entering and leaving ids add up to them exactly (with two, a transition undone within one sync is invisible, so the ids may add up to less); with `all`, every recipient sees every entity at every sync.
- `sync_us_per_room_sync`: `syncNow()` per room and sync (the per-player diff, encode and `visibleTo.contains`, not the computation of visibility). For `broadcast`, the same sync with the entities in the broadcast diff.
- `tick_us_per_room_tick`: `stepTickOnce` per room and tick (the motion and `updateVisibility`). All three variants run the same tick; a ratio far from 1 means a control didn't keep the tick the same.
- `gate_comparisons`, replayed rooms, `consistency_checks`: how much each check covered; every one must have passed.

## Gates

`regenerate.py` refuses the results unless every result is a release build from a clean tree with its Swift version, has its cell's parameters and the matrix constants, every cell of the matrix has repeats 1, 2 and 3 (a partial matrix isn't rendered) with all three variants in each, and at least one captured repeat where every variant passed `verify-views` and the replay, the cell passed both consistency checks, and the decode figures come from a verified `time-decode` run.

The consistency check (`capcheck.py consistency`), per captured room, sync and recipient: the broadcast fields are equal in both variants (they share the motion), the `radius` projection's entities are exactly the `all` projection's entities within the radius by the land's rule (quantized positions, `dx² + dy² <= q(radius)²` in integers, inclusive), and each visible entity's fields are equal.

The broadcast consistency check (`capcheck.py broadcast-consistency`), per captured room, sync and recipient: the broadcast twin's view equals the `all` variant's per-player view of that player, every field. Each variant's own capture also passes `verify-views`, and `capcheck.py stats` requires every recipient of `broadcast` to see every entity, as for `all`.

Mutation checks, run on the Mac before the first host run:

1. A filter that also sends one out-of-view entity to one player: `verify-views` passes (the projection leaks the same way), and the consistency check fails at the first checkpoint, naming the entity.
2. A capture that drops one frame: `verify-views` fails.
3. A replay with another view radius: `ReevaluationRunner --verify` refuses or mismatches on the per-player scope, and `replay.py` fails.
4. A broadcast view that differs from one player's `all` view in one entity's position or one counter: the broadcast consistency check fails, naming the player and the field (`test_topic.py`). A twin whose state starts with motion off: the GameDemo test comparing the twin's state with the per-player state's after the same inputs fails.

## Results

Provenance, from the results' meta: commit `ca904c8c0690d62695f9a5a14e24c35ad953466e`, clean tree; Swift 6.2.4; Node v24.22.2; build release.

Medians over 3 repeat(s) (1, 2, 3). `radius` sends each player the entities within its view; `all` is the control, the same per-player path sending every entity; `broadcast` is the twin state with its entities in one broadcast field, the same entities, motion and visibility work as `all` without the per-player projection. Wire form: messagepack-pathhash, pathIndex on, fieldMerge on (checked per run).

### View radius (40 entities, 4 viewers, 1 tick per sync)

Bytes per recipient per sync (every room, measured window), and over the captured rooms after permessage-deflate:

| Cell | Visible per recipient | View changes per recipient per sync | radius | all | broadcast | radius / all | radius deflate | all deflate | broadcast deflate | radius / all deflate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| radius 8 | 0.9 | 0.16 | 28.3 | 508.4 | 506.4 | 0.06 | 17.2 | 272.2 | 269.2 | 0.06 |
| radius 15 | 2.9 | 0.26 | 56.5 | 509.7 | 507.7 | 0.11 | 32.7 | 273.1 | 270.3 | 0.12 |
| radius 30 | 8.8 | 0.25 | 128.0 | 509.6 | 507.6 | 0.25 | 70.0 | 272.9 | 270.5 | 0.26 |

Server time per room (µs, serial; sync: `syncNow()`, tick: `stepTickOnce`, which computes visibility; never summed). `all / broadcast` is what the per-player projection itself costs at the same entities and motion:

| Cell | radius sync | all sync | broadcast sync | sync all / broadcast | radius tick | all tick | broadcast tick | tick radius / all |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| radius 8 | 96.5 | 1,243.1 | 351.5 | 3.54 | 72.3 | 74.2 | 70.1 | 0.97 |
| radius 15 | 162.0 | 1,258.8 | 348.6 | 3.61 | 74.2 | 76.3 | 72.6 | 0.97 |
| radius 30 | 339.1 | 1,247.5 | 348.8 | 3.58 | 75.8 | 78.0 | 73.4 | 0.97 |

Checks over the captured rooms (every one passed; the counts say how much was checked):

| Cell | Gate comparisons radius | Gate comparisons all | Gate comparisons broadcast | Replayed rooms | Consistency checks radius | Consistency checks broadcast |
|---|---:|---:|---:|---:|---:|---:|
| radius 8 | 1,608 | 1,608 | 1,608 | 6 | 1,608 | 1,608 |
| radius 15 | 1,608 | 1,608 | 1,608 | 6 | 1,608 | 1,608 |
| radius 30 | 1,608 | 1,608 | 1,608 | 6 | 1,608 | 1,608 |

Client decode per frame (µs, Node, SDK; apply after #303):

| Cell | radius decode | radius decode + apply | all decode | all decode + apply | broadcast decode | broadcast decode + apply |
|---|---:|---:|---:|---:|---:|---:|
| radius 8 | 0.64 | 1.66 | 5.84 | 24.82 | 11.38 | 48.80 |
| radius 15 | 0.89 | 2.72 | 5.95 | 24.87 | 11.31 | 50.36 |
| radius 30 | 1.68 | 6.20 | 5.74 | 24.79 | 11.54 | 50.23 |

### Entity count (radius 15, 4 viewers, 1 tick per sync)

Bytes per recipient per sync (every room, measured window), and over the captured rooms after permessage-deflate:

| Cell | Visible per recipient | View changes per recipient per sync | radius | all | broadcast | radius / all | radius deflate | all deflate | broadcast deflate | radius / all deflate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 40 entities | 2.9 | 0.26 | 56.5 | 509.7 | 507.7 | 0.11 | 32.7 | 273.1 | 270.3 | 0.12 |
| 160 entities | 11.5 | 1.08 | 185.5 | 2,033.3 | 2,031.3 | 0.09 | 99.0 | 1,063.9 | 1,059.9 | 0.09 |
| 640 entities | 46.4 | 4.35 | 723.2 | 8,835.0 | 8,833.0 | 0.08 | 359.9 | 4,655.1 | 4,650.5 | 0.08 |

Server time per room (µs, serial; sync: `syncNow()`, tick: `stepTickOnce`, which computes visibility; never summed). `all / broadcast` is what the per-player projection itself costs at the same entities and motion:

| Cell | radius sync | all sync | broadcast sync | sync all / broadcast | radius tick | all tick | broadcast tick | tick radius / all |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 40 entities | 162.0 | 1,258.8 | 348.6 | 3.61 | 74.2 | 76.3 | 72.6 | 0.97 |
| 160 entities | 449.4 | 4,799.8 | 1,251.4 | 3.84 | 864.5 | 877.3 | 842.9 | 0.99 |
| 640 entities | 1,607.4 | 19,475.9 | 4,879.4 | 3.99 | 12,839.9 | 12,759.1 | 12,522.5 | 1.01 |

Checks over the captured rooms (every one passed; the counts say how much was checked):

| Cell | Gate comparisons radius | Gate comparisons all | Gate comparisons broadcast | Replayed rooms | Consistency checks radius | Consistency checks broadcast |
|---|---:|---:|---:|---:|---:|---:|
| 40 entities | 1,608 | 1,608 | 1,608 | 6 | 1,608 | 1,608 |
| 160 entities | 1,608 | 1,608 | 1,608 | 6 | 1,608 | 1,608 |
| 640 entities | 1,608 | 1,608 | 1,608 | 6 | 1,608 | 1,608 |

Client decode per frame (µs, Node, SDK; apply after #303):

| Cell | radius decode | radius decode + apply | all decode | all decode + apply | broadcast decode | broadcast decode + apply |
|---|---:|---:|---:|---:|---:|---:|
| 40 entities | 0.89 | 2.72 | 5.95 | 24.87 | 11.31 | 50.36 |
| 160 entities | 2.15 | 8.47 | 23.66 | 100.34 | 43.35 | 195.08 |
| 640 entities | 7.14 | 30.66 | 90.55 | 405.65 | 183.76 | 811.73 |

### Viewers per room (radius 15, 40 entities, 1 tick per sync)

Bytes per recipient per sync (every room, measured window), and over the captured rooms after permessage-deflate:

| Cell | Visible per recipient | View changes per recipient per sync | radius | all | broadcast | radius / all | radius deflate | all deflate | broadcast deflate | radius / all deflate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 4 viewers | 2.9 | 0.26 | 56.5 | 509.7 | 507.7 | 0.11 | 32.7 | 273.1 | 270.3 | 0.12 |
| 16 viewers | 2.9 | 0.23 | 59.9 | 515.7 | 513.7 | 0.12 | 35.4 | 276.6 | 273.5 | 0.13 |

Server time per room (µs, serial; sync: `syncNow()`, tick: `stepTickOnce`, which computes visibility; never summed). `all / broadcast` is what the per-player projection itself costs at the same entities and motion:

| Cell | radius sync | all sync | broadcast sync | sync all / broadcast | radius tick | all tick | broadcast tick | tick radius / all |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 4 viewers | 162.0 | 1,258.8 | 348.6 | 3.61 | 74.2 | 76.3 | 72.6 | 0.97 |
| 16 viewers | 513.5 | 4,791.0 | 369.9 | 12.95 | 90.8 | 99.6 | 87.5 | 0.91 |

Checks over the captured rooms (every one passed; the counts say how much was checked):

| Cell | Gate comparisons radius | Gate comparisons all | Gate comparisons broadcast | Replayed rooms | Consistency checks radius | Consistency checks broadcast |
|---|---:|---:|---:|---:|---:|---:|
| 4 viewers | 1,608 | 1,608 | 1,608 | 6 | 1,608 | 1,608 |
| 16 viewers | 6,432 | 6,432 | 6,432 | 6 | 6,432 | 6,432 |

Client decode per frame (µs, Node, SDK; apply after #303):

| Cell | radius decode | radius decode + apply | all decode | all decode + apply | broadcast decode | broadcast decode + apply |
|---|---:|---:|---:|---:|---:|---:|
| 4 viewers | 0.89 | 2.72 | 5.95 | 24.87 | 11.31 | 50.36 |
| 16 viewers | 0.91 | 2.77 | 5.64 | 24.48 | 10.93 | 48.85 |

### Ticks per sync (radius 15, 40 entities, 4 viewers)

Bytes per recipient per sync (every room, measured window), and over the captured rooms after permessage-deflate:

| Cell | Visible per recipient | View changes per recipient per sync | radius | all | broadcast | radius / all | radius deflate | all deflate | broadcast deflate | radius / all deflate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 tick(s) per sync | 2.9 | 0.26 | 56.5 | 509.7 | 507.7 | 0.11 | 32.7 | 273.1 | 270.3 | 0.12 |
| 2 tick(s) per sync | 2.9 | 0.52 | 63.9 | 518.7 | 516.7 | 0.12 | 35.5 | 270.6 | 267.0 | 0.13 |

Server time per room (µs, serial; sync: `syncNow()`, tick: `stepTickOnce`, which computes visibility; never summed). `all / broadcast` is what the per-player projection itself costs at the same entities and motion:

| Cell | radius sync | all sync | broadcast sync | sync all / broadcast | radius tick | all tick | broadcast tick | tick radius / all |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 tick(s) per sync | 162.0 | 1,258.8 | 348.6 | 3.61 | 74.2 | 76.3 | 72.6 | 0.97 |
| 2 tick(s) per sync | 164.6 | 1,255.8 | 351.0 | 3.58 | 71.3 | 72.1 | 69.7 | 0.99 |

Checks over the captured rooms (every one passed; the counts say how much was checked):

| Cell | Gate comparisons radius | Gate comparisons all | Gate comparisons broadcast | Replayed rooms | Consistency checks radius | Consistency checks broadcast |
|---|---:|---:|---:|---:|---:|---:|
| 1 tick(s) per sync | 1,608 | 1,608 | 1,608 | 6 | 1,608 | 1,608 |
| 2 tick(s) per sync | 1,608 | 1,608 | 1,608 | 6 | 1,608 | 1,608 |

Client decode per frame (µs, Node, SDK; apply after #303):

| Cell | radius decode | radius decode + apply | all decode | all decode + apply | broadcast decode | broadcast decode + apply |
|---|---:|---:|---:|---:|---:|---:|
| 1 tick(s) per sync | 0.89 | 2.72 | 5.95 | 24.87 | 11.31 | 50.36 |
| 2 tick(s) per sync | 0.93 | 2.90 | 5.72 | 24.90 | 11.56 | 49.95 |

## Conclusion

_Pending the host run._

## Caveats

- Viewers don't move in the offline cells; churn comes from entity motion only.
- The records' settings check: the benchmark's records carry the `VISIBILITY_TEST_*` settings and the replay refuses others. A live server's record carries none and is replayed only with the defaults, so a live run with other knobs replayed at the defaults isn't caught; the live check runs at the defaults.
- The capture and record pass's timings aren't kept: capture and live state-hash recording add work to the tick and the sync.
- The client decode figures are the SDK's, with its apply cost cut by #303.
