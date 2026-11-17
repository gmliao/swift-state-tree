#!/usr/bin/env python3
"""Summarize the replayed rooms' seeds against their players into sync-marks.json (stdlib only).

  python3 -I sync_marks.py <raw dir>

<raw dir> holds the sweep directories that results/*.json name in `meta.source_file`
(<sweep>/<cell>-<variant>.json); for every result with replayed rooms, <sweep>/<cell>-<variant>.replay.json
holds per room the runner's "Sync Output:" line. The records themselves aren't kept, so the counts
come from that line (deep-research/syncmarks.py `verify_line`): per replayed room its seeds (a full
view sent to a player), its key scope resets, its skipped and unverifiable comparisons, and the
broadcast and per-player scopes' compared, unverifiable and skipped counts. Later
seeds are derived: each player has exactly one first seed, so a room's seeds minus its players are
the seeds after a player's first. Writes per result the sums, the rooms whose seeds differ from
their players, and the sha256 of the replay.json read. regenerate.py gates and renders from
sync-marks.json alone.
"""
import hashlib
import json
import pathlib
import sys

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC.parent))
import syncmarks  # noqa: E402


def main(argv):
    if len(argv) != 1:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    raw = pathlib.Path(argv[0])
    runs = {}
    for path in sorted((TOPIC / "results").glob("*.json")):
        result = json.loads(path.read_text(encoding="utf-8"))
        if not result["metrics"].get("replay_rooms"):
            continue
        p = result["params"]
        source = pathlib.Path(result["meta"]["source_file"])
        replay = raw / source.parent / f"{source.stem}.replay.json"
        data = replay.read_bytes()
        key = f"r{p['rooms']}-p{p['players']}-k{p['ticks_per_sync']}-serial"
        hits = [v for k, v in json.loads(data).items() if k == key or k.endswith(f"-visibility-test-{key}")]
        if len(hits) != 1:
            print(f"{replay}: expected one run {key}, found {len(hits)}", file=sys.stderr)
            return 1
        rooms = [syncmarks.verify_line(v["syncOutput"]) for _, v in sorted(hits[0].items())]
        players = p["players"]
        runs[path.stem] = {
            "source": str(source.parent / replay.name), "replay_json_sha256": hashlib.sha256(data).hexdigest(),
            "rooms": len(rooms), "players_per_room": players,
            "seeds": sum(r["seeds"] for r in rooms),
            "seeds_later_derived": sum(r["seeds"] - players for r in rooms),
            "rooms_seeds_not_players": sum(r["seeds"] != players for r in rooms),
            "key_scope_resets": sum(r["key_scope_resets"] for r in rooms),
            "skipped": sum(r["skipped"] for r in rooms),
            "unverifiable": sum(r["unverifiable"] for r in rooms),
            **{key: {col: sum(r["scopes"][scope][col] for r in rooms) for col in ("compared", "unverifiable", "skipped")}
               for key, scope in (("broadcast", "broadcast"), ("per_player", "per-player"))},
        }
    out = TOPIC / "sync-marks.json"
    out.write_text(json.dumps({"runs": runs}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {len(runs)} runs to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
