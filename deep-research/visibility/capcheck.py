#!/usr/bin/env python3
"""Checks and counts over visibility-test `--capture-views` directories (stdlib only).

  capcheck.py stats <capture-dir> <out.json>
  capcheck.py consistency <radius-capture-dir> <all-capture-dir> <out.json>
  capcheck.py broadcast-consistency <broadcast-capture-dir> <all-capture-dir> <out.json>

``stats`` writes, per run (its cell suffix), the entities in one recipient's projection (mean over
recipients and measured syncs) and the view changes per recipient and sync: the growth of the
broadcast `viewEntries` + `viewExits` from checkpoint 0 to the last, over recipients × measured
syncs. Checkpoint 0 (the joins and the initial sync) is outside the measured window, as in
time-decode's `roomBytes`.

``consistency`` compares a `radius` capture with the `all` capture of the same cell, room by room,
sync by sync, recipient by recipient:
  - the broadcast fields (tick, counters, viewers, motion) are equal, so both runs share the motion;
  - the radius projection's entity ids are exactly the all projection's entities the land's rule
    admits: quantized positions, `dx² + dy² <= q(radius)²` in integers (inclusive), `q` the
    land's quantization (Float32 × 1000, rounded to nearest, ties away from zero);
  - each visible entity's fields are equal in both projections.
It exits non-zero on the first run that fails, after writing the report.
"""
import json, math, pathlib, re, struct, sys

SCALE = 1000
BROADCAST = ("motion", "tickCount", "viewEntries", "viewExits", "viewers")


def f32(x):
    return struct.unpack("f", struct.pack("f", x))[0]


def quantize(value):
    """`FixedPoint.quantize`: Float32 value × Float32 scale, rounded to nearest, ties away from zero."""
    scaled = f32(f32(value) * f32(SCALE))
    return int(math.copysign(math.floor(abs(scaled) + 0.5), scaled))


def admits(viewer, entity, threshold_q):
    """`Position2.isWithinDistance`: Int64 squared distance against the squared quantized threshold."""
    dx = entity["v"]["x"] - viewer["v"]["x"]
    dy = entity["v"]["y"] - viewer["v"]["y"]
    return dx * dx + dy * dy <= threshold_q * threshold_q


def runs(capture):
    found = {}
    for run in sorted(p for p in pathlib.Path(capture).iterdir() if p.is_dir()):
        match = re.search(r"-visibility-test-(r\d+-p\d+-k\d+-serial)$", run.name)
        if not match:
            sys.exit(f"{run}: not a visibility-test capture run")
        found[match.group(1)] = run
    if not found:
        sys.exit(f"{capture}: no runs")
    return found


def read_room(path):
    lines = [l for l in path.read_text().splitlines() if l]
    return json.loads(lines[0]), [json.loads(l) for l in lines[1:]]


def stats(capture, out):
    """Visible entities and view changes per recipient and measured sync.

    `viewEntries` and `viewExits` are room-wide counters (every viewer's transitions), carried
    unchanged in every player's projection, so each room's growth is counted once. Each
    recipient's entering and leaving ids between consecutive checkpoints check the counters
    (radius): with one tick per sync they must add up to the room's growth; with more, a
    transition undone within one sync isn't seen in the projections, so the ids may only add up to
    less. In the all control every recipient sees every entity at every sync, so its ids never
    change while the counters still count the radius transitions.
    """
    result = {}
    for key, run in runs(capture).items():
        visible = recipients_syncs = changes = observed = 0
        rooms = sorted(run.glob("room-*.ndjson"))
        for room in rooms:
            header, checkpoints = read_room(room)
            players = sorted(set(header["sessions"].values()))
            tps = header["cell"]["ticksPerSync"]
            filter_, entity_count = header["cell"]["visibility"]["filter"], header["cell"]["visibility"]["entityCount"]
            measured = checkpoints[1:]
            if not measured:
                sys.exit(f"{room}: no measured syncs")
            first, last = checkpoints[0]["projections"], checkpoints[-1]["projections"]
            growth = {p: last[p]["viewEntries"] + last[p]["viewExits"] - first[p]["viewEntries"] - first[p]["viewExits"]
                      for p in players}
            if len(set(growth.values())) != 1:
                sys.exit(f"{room}: the room-wide view counters differ between players: {growth}")
            room_changes = growth[players[0]]
            room_observed = 0
            for player in players:
                previous = set(first[player]["entities"])
                for checkpoint in measured:
                    current = set(checkpoint["projections"][player]["entities"])
                    if filter_ in ("all", "broadcast") and len(current) != entity_count:
                        sys.exit(f"{room}: {player} sees {len(current)} of {entity_count} entities under the {filter_} filter")
                    visible += len(current)
                    room_observed += len(current ^ previous)
                    previous = current
                recipients_syncs += len(measured)
            if filter_ in ("all", "broadcast"):
                if room_observed:
                    sys.exit(f"{room}: the {filter_} projections changed {room_observed} times")
            elif room_observed > room_changes or (tps == 1 and room_observed != room_changes):
                sys.exit(f"{room}: the projections show {room_observed} view changes, the counters {room_changes} "
                         f"({tps} tick(s) per sync)")
            changes += room_changes
            observed += room_observed
        result[key] = {
            "rooms": len(rooms),
            "visiblePerRecipient": visible / recipients_syncs,
            "viewChangesPerRecipientSync": changes / recipients_syncs,
            "observedViewChangesPerRecipientSync": observed / recipients_syncs,
        }
    pathlib.Path(out).write_text(json.dumps(result, indent=1, sort_keys=True) + "\n")


def compare_room(radius_path, all_path):
    """The first inconsistency between a radius room and its all twin, or None, and the checks made."""
    rh, rlines = read_room(radius_path)
    ah, alines = read_room(all_path)
    rv, av = rh["cell"]["visibility"], ah["cell"]["visibility"]
    if rv["filter"] != "radius" or av["filter"] != "all":
        return f"filters {rv['filter']}/{av['filter']}, expected radius/all", 0
    if (rv["entityCount"], rv["viewRadius"]) != (av["entityCount"], av["viewRadius"]):
        return f"settings differ: {rv} vs {av}", 0
    if rh["sessions"] != ah["sessions"]:
        return "sessions differ", 0
    if len(rlines) != len(alines):
        return f"{len(rlines)} checkpoints against {len(alines)}", 0
    threshold_q = quantize(rv["viewRadius"])
    checks = 0
    for index, (r, a) in enumerate(zip(rlines, alines)):
        rp, ap = r["projections"], a["projections"]
        if sorted(rp) != sorted(ap):
            return f"checkpoint {index}: recipients differ", checks
        for player in sorted(rp):
            mine, theirs = rp[player], ap[player]
            for field in BROADCAST:
                if mine.get(field) != theirs.get(field):
                    return f"checkpoint {index} {player}: broadcast {field} differs", checks
            viewer = mine["viewers"].get(player)
            if viewer is None:
                return f"checkpoint {index} {player}: no viewer", checks
            expected = {eid for eid, e in theirs["entities"].items() if admits(viewer["position"], e["position"], threshold_q)}
            got = set(mine["entities"])
            if got != expected:
                extra, missing = sorted(got - expected), sorted(expected - got)
                return f"checkpoint {index} {player}: visible set differs (extra {extra[:5]}, missing {missing[:5]})", checks
            for eid in got:
                if mine["entities"][eid] != theirs["entities"][eid]:
                    return f"checkpoint {index} {player}: entity {eid} differs", checks
            checks += 1
    return None, checks


def compare_broadcast_room(broadcast_path, all_path):
    """The first difference between a broadcast room and its all twin, or None, and the checks made.

    The twin syncs its entities through one broadcast field, so every player's view of it must
    equal the all variant's per-player view of that player, field by field."""
    bh, blines = read_room(broadcast_path)
    ah, alines = read_room(all_path)
    bv, av = bh["cell"]["visibility"], ah["cell"]["visibility"]
    if bv["filter"] != "broadcast" or av["filter"] != "all":
        return f"filters {bv['filter']}/{av['filter']}, expected broadcast/all", 0
    if (bv["entityCount"], bv["viewRadius"]) != (av["entityCount"], av["viewRadius"]):
        return f"settings differ: {bv} vs {av}", 0
    if bh["sessions"] != ah["sessions"]:
        return "sessions differ", 0
    if len(blines) != len(alines):
        return f"{len(blines)} checkpoints against {len(alines)}", 0
    checks = 0
    for index, (b, a) in enumerate(zip(blines, alines)):
        bp, ap = b["projections"], a["projections"]
        if sorted(bp) != sorted(ap):
            return f"checkpoint {index}: recipients differ", checks
        for player in sorted(bp):
            if bp[player] != ap[player]:
                fields = sorted(k for k in set(bp[player]) | set(ap[player]) if bp[player].get(k) != ap[player].get(k))
                return f"checkpoint {index} {player}: view differs in {fields}", checks
            checks += 1
    return None, checks


def consistency(radius_capture, all_capture, out, compare=None):
    compare = compare or compare_room
    radius_runs, all_runs = runs(radius_capture), runs(all_capture)
    if sorted(radius_runs) != sorted(all_runs):
        sys.exit(f"runs differ: {sorted(radius_runs)} vs {sorted(all_runs)}")
    result, failed = {}, False
    for key in sorted(radius_runs):
        rooms = sorted(p.name for p in radius_runs[key].glob("room-*.ndjson"))
        if rooms != sorted(p.name for p in all_runs[key].glob("room-*.ndjson")) or not rooms:
            sys.exit(f"{key}: captured rooms differ or are missing")
        report = {"rooms": len(rooms), "checks": 0, "failure": None}
        for room in rooms:
            failure, checks = compare(radius_runs[key] / room, all_runs[key] / room)
            report["checks"] += checks
            if failure:
                report["failure"] = f"{room}: {failure}"
                failed = True
                break
        result[key] = report
    pathlib.Path(out).write_text(json.dumps(result, indent=1, sort_keys=True) + "\n")
    if failed:
        sys.exit("consistency check failed: " + "; ".join(f"{k}: {v['failure']}" for k, v in result.items() if v["failure"]))


def main(argv):
    if argv[:1] == ["stats"] and len(argv) == 3:
        stats(argv[1], argv[2])
    elif argv[:1] == ["consistency"] and len(argv) == 4:
        consistency(argv[1], argv[2], argv[3])
    elif argv[:1] == ["broadcast-consistency"] and len(argv) == 4:
        consistency(argv[1], argv[2], argv[3], compare_broadcast_room)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
