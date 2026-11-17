#!/usr/bin/env python3
"""Summarize the replayed records' seeds against their players into sync-marks.json (stdlib only).

  python3 -I sync_marks.py <raw dir>

<raw dir> holds the raw run directories that results/*.json name in `meta.source_dir`
(<RUN_ID>/<cell>), each with collect.py's input records.json: per room, whether it was replayed and,
if so, the runner's "Sync Output:" line. The records themselves aren't kept, so the counts come
from that line (deep-research/syncmarks.py `verify_line`): per replayed room its seeds (a full view
sent to a player), its key scope resets, and its skipped and unverifiable comparisons. Later seeds
are derived: each player has exactly one first seed, so a room's seeds minus its players are the
seeds after a player's first. Writes per result the sums, the rooms whose seeds differ from their
players, and the sha256 of the records.json read. regenerate.py gates and renders from
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
        source, players = result["meta"]["source_dir"], result["params"]["players"]
        data = (raw / source / "records.json").read_bytes()
        rooms = [syncmarks.verify_line(v["syncOutput"]) for _, v in sorted(json.loads(data).items()) if v["replayed"]]
        runs[path.stem] = {
            "source_dir": source, "records_json_sha256": hashlib.sha256(data).hexdigest(),
            "rooms": len(rooms), "players_per_room": players,
            "seeds": sum(r["seeds"] for r in rooms),
            "seeds_later_derived": sum(r["seeds"] - players for r in rooms),
            "rooms_seeds_not_players": sum(r["seeds"] != players for r in rooms),
            "key_scope_resets": sum(r["key_scope_resets"] for r in rooms),
            "skipped": sum(r["skipped"] for r in rooms),
            "unverifiable": sum(r["unverifiable"] for r in rooms),
        }
    out = TOPIC / "sync-marks.json"
    out.write_text(json.dumps({"runs": runs}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {len(runs)} runs to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
