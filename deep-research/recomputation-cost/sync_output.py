#!/usr/bin/env python3
"""Summarize the verify runs' sync-output verdicts into sync-output.json (stdlib only).

  python3 -I sync_output.py <raw dir>

<raw dir> is run.sh's raw directory, <RUN_ID>/<process>/ for every results/<RUN_ID>/<process>.json:
the sizes runs' verify-<record>.txt (one per replayed record) and the recording-on cost runs'
verify.txt (record_check's first record). Writes, per verify output, its verdict and counts
(deep-research/syncoutput.py) and its sha256. regenerate.py gates and renders from sync-output.json alone.
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
    outputs = {}
    for path in sorted((TOPIC / "results").glob("*/*.json")):
        process = raw / path.parent.name / path.stem
        for verify in sorted(process.glob("verify*.txt")):
            data = verify.read_bytes()
            outputs[f"{path.parent.name}/{path.stem}/{verify.name}"] = {
                "sha256": hashlib.sha256(data).hexdigest(), **syncoutput.parse(data.decode("utf-8"))}
    out = TOPIC / "sync-output.json"
    out.write_text(json.dumps({"outputs": outputs}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {len(outputs)} verify outputs to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
