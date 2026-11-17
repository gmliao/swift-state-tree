#!/usr/bin/env python3
"""Count the sync stream's full-view starts and partial outputs in the sizes runs' records (stdlib only).

  python3 -I sync_marks.py <raw dir>

<raw dir> is run.sh's raw directory: for every sizes run results/<RUN_ID>/<process>.json, its
records <RUN_ID>/<process>/records/*.sstr (the cost runs' records aren't kept). Writes, per record,
its sha256 and the counts of deep-research/syncmarks.py to sync-marks.json. regenerate.py gates and
renders from sync-marks.json alone.
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
    records = {}
    for path in sorted((TOPIC / "results").glob("*/*.json")):
        if json.loads(path.read_text(encoding="utf-8"))["params"]["kind"] != "sizes":
            continue
        files = sorted((raw / path.parent.name / path.stem / "records").glob("*.sstr"))
        if not files:
            print(f"{path.parent.name}/{path.stem}: no records under {raw}", file=sys.stderr)
            return 1
        for f in files:
            data = f.read_bytes()
            records[f"{path.parent.name}/{path.stem}/{f.name}"] = {
                "sha256": hashlib.sha256(data).hexdigest(), **syncmarks.count(data)}
    out = TOPIC / "sync-marks.json"
    out.write_text(json.dumps({"records": records}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {len(records)} records to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
