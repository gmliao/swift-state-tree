#!/usr/bin/env python3
"""Summarize the replayed records' sync-output verdicts into sync-output.json (stdlib only).

  python3 -I sync_output.py <raw dir>

<raw dir> holds the raw run directories that results/*.json name in `meta.source_dir`
(<RUN_ID>/<cell>), each with collect.py's input records.json: per room, whether it was replayed and,
if so, the runner's "Sync Output:" line (`syncOutput`). Writes, per result, the replayed records'
verdicts and summed counts (deep-research/syncoutput.py) and the sha256 of the records.json read.
regenerate.py gates and renders from sync-output.json alone.
"""
import hashlib
import json
import pathlib
import sys

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC.parent))
import syncoutput  # noqa: E402


def main(argv):
    if len(argv) != 1:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    raw = pathlib.Path(argv[0])
    runs = {}
    for path in sorted((TOPIC / "results").glob("*.json")):
        result = json.loads(path.read_text(encoding="utf-8"))
        source = result["meta"]["source_dir"]
        data = (raw / source / "records.json").read_bytes()
        records = json.loads(data)
        entries = [syncoutput.parse(v["syncOutput"]) for _, v in sorted(records.items()) if v["replayed"]]
        runs[path.stem] = {"source_dir": source, "records_json_sha256": hashlib.sha256(data).hexdigest(),
                           **syncoutput.total(entries)}
    out = TOPIC / "sync-output.json"
    out.write_text(json.dumps({"runs": runs}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {len(runs)} runs to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
