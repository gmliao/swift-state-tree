#!/usr/bin/env python3
"""Summarize the Part B re-run at record format 3.1 into results/perturb-3.1/.

  python3 -I scripts/perturb_collect.py <run dir> <records dir> [<out dir>]

<run dir> holds the run's logs and its chain log:
  logs/<name>.log, logs/<name>.exit   one process each: control-s<N> (runner at 022d8fdb),
                                      control2-s<N> (runner at dc6f85e7), perturb-s<N>-<cell>
  chain.log                           its "runners:" lines give both runners' sha256
<records dir> holds the recordings replayed, s1.sstr ... s10.sstr.
<out dir> defaults to results/perturb-3.1 next to this script's topic.

Writes one JSON per perturbed run (perturb-s<N>-<cell>.json) and controls.json. The reading rule is
the runner's at 022d8fdb: exit 5 with "Verification failed: mismatched ticks vs recorded=<n>" is
detected, its first "tick <t>:" line the first mismatching tick; exit 0 with both "Verified state
hashes" lines is not detected; any other exit is recorded as it is (regenerate.py refuses it).
"""
import hashlib
import json
import pathlib
import re
import sys

TOPIC = pathlib.Path(__file__).resolve().parent.parent
SEEDS = range(1, 11)
PERTURB_TICK = 600
# The run's environment (one container, one date); the logs print only the CPU model and "6.2".
DATE = "2026-11-17"
HOST = "AMD Ryzen 5 7600X, Linux (WSL2, Docker swift:6.2.4-noble)"
SWIFT = "6.2.4"
RECORD_FORMAT = "3.1"
# Cell name in the log file names: (mode, the HERO_PERTURB_EPS value as passed, runner).
CELLS = {
    "float1e-7": ("float", "1e-07", "rr"),
    "fixed1": ("fixed", "1.0", "rr"),
    "fixed1000": ("fixed", "1000.0", "rr"),
    "serveronly1": ("serveronly", "1", "rr2"),
}
CONTROLS = {"rr": "control", "rr2": "control2"}
RUNNERS_LINE = re.compile(r"runners: rr\((?P<rr>[0-9a-f]{7,40})\) (?P<rr_sha>[0-9a-f]{64}); "
                          r"rr2\((?P<rr2>[0-9a-f]{7,40})\) (?P<rr2_sha>[0-9a-f]{64})")
MISMATCH = re.compile(r"Verification failed: mismatched ticks vs recorded=(\d+)")
TICK = re.compile(r"^\s+tick (\d+): computed=", re.M)
VERIFIED = "Verified state hashes"


def runners(chain):
    """{"rr": (commit, sha256), "rr2": (...)}; every runners line must agree."""
    found = {(m["rr"], m["rr_sha"], m["rr2"], m["rr2_sha"]) for m in RUNNERS_LINE.finditer(chain)}
    if len(found) != 1:
        sys.exit(f"chain.log: {len(found)} distinct runners lines, expected 1")
    rr, rr_sha, rr2, rr2_sha = found.pop()
    return {"rr": (rr, rr_sha), "rr2": (rr2, rr2_sha)}


def read(logs, name):
    """(exit, metrics) for one process's log, by the reading rule above."""
    code = int((logs / f"{name}.exit").read_text(encoding="utf-8").strip())
    text = (logs / f"{name}.log").read_text(encoding="utf-8", errors="replace")
    verified = text.count(VERIFIED)
    m = MISMATCH.search(text)
    ticks = [int(t) for t in TICK.findall(text)]
    detected = code == 5 and m is not None and bool(ticks)
    first = ticks[0] if detected else None
    return {
        "exit": code,
        "detected": detected,
        "first_mismatch_tick": first,
        "detection_latency_ticks": first - PERTURB_TICK if detected else None,
        "mismatch_ticks": int(m.group(1)) if detected else None,
        "verified_lines": verified,
    }


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    run_dir, records = pathlib.Path(argv[0]), pathlib.Path(argv[1])
    out = pathlib.Path(argv[2]) if len(argv) == 3 else TOPIC / "results" / "perturb-3.1"
    logs = run_dir / "logs"
    bins = runners((run_dir / "chain.log").read_text(encoding="utf-8"))
    recording = {n: hashlib.sha256((records / f"s{n}.sstr").read_bytes()).hexdigest() for n in SEEDS}
    out.mkdir(parents=True, exist_ok=True)
    for cell, (mode, eps, runner) in CELLS.items():
        commit, sha = bins[runner]
        for n in SEEDS:
            name = f"perturb-s{n}-{cell}"
            doc = {
                "meta": {
                    "date": DATE, "git_sha": commit, "runner_sha256": sha, "swift_version": SWIFT,
                    "build_config": "release", "host": HOST, "record_format": RECORD_FORMAT,
                    "command": f"HERO_PERTURB_TICK={PERTURB_TICK} HERO_PERTURB_MODE={mode} HERO_PERTURB_EPS={eps} "
                               f"ReevaluationRunner --input s{n}.sstr --verify",
                    "source_log": f"{name}.log",
                },
                "params": {"seed": n, "perturb_tick": PERTURB_TICK, "mode": mode, "eps": eps,
                           "recording_sha256": recording[n], "workload": "perturbed-replay"},
                "metrics": read(logs, name),
            }
            (out / f"{name}.json").write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    controls = {"meta": {"date": DATE, "host": HOST, "swift_version": SWIFT, "build_config": "release",
                         "record_format": RECORD_FORMAT,
                         "command": "env -u HERO_PERTURB_TICK -u HERO_PERTURB_MODE -u HERO_PERTURB_EPS "
                                    "ReevaluationRunner --input s<N>.sstr --verify"},
                "runners": []}
    for runner, prefix in CONTROLS.items():
        commit, sha = bins[runner]
        controls["runners"].append({
            "git_sha": commit, "runner_sha256": sha,
            "runs": [dict(seed=n, recording_sha256=recording[n], source_log=f"{prefix}-s{n}.log",
                          **{k: v for k, v in read(logs, f"{prefix}-s{n}").items() if k in ("exit", "verified_lines")})
                     for n in SEEDS],
        })
    (out / "controls.json").write_text(json.dumps(controls, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(CELLS) * len(SEEDS)} runs and controls.json to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
