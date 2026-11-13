#!/usr/bin/env python3
"""The load client's own load in each phase's measured window, and the rule that gates it (stdlib
only). The client must not be the bottleneck it measures
(Notes/solutions/2026-11-05-load-tool-is-the-bottleneck.md); the rule is network-impairment's
(its clientload.py), read here from the ws-loadtest report instead of per-event samples, which at
this topic's 2500 connections would be client work of their own.

Per phase (preflight, steady, postflight), from the report's `measurement`:
- **Workers' CPU demand:** the workers' CPU in the measured window (`clientCpu.totalPct` less the
  orchestrator's `orchestratorPct`, % of one core) over the client's CPUs: the CPUs in run.sh's
  CLIENT_CPUS mask when pinned, else the CPUs the client saw (`clientCpu.cores`, Node's
  availableParallelism), as a percentage. Over 100 % is impossible and reported as broken.
- **Worker ELU:** the largest worker's event-loop utilization in the window (`clientElu.perWorker.max`).

**Every worker counts:** both figures need every configured worker (`meta.runConfig.workers`) to
have covered the window (`clientCpu.workers`, `clientElu.workers`); otherwise, or without the
figures (a client older than `clientElu`), the phase's load is missing.

`failures(load)` is the one rule, used by run.sh (through `check`: the sweep stops) and
regenerate.py (the run is refused): every phase's CPU demand under `CPU_MAX_PCT`, every phase's
worst worker ELU at most `ELU_MAX`, and nothing missing.

Usage: python3 clientload.py check <summary.json> <ws-loadtest dir> <client cpus>
  exit 0: within the bounds; exit 1: the reasons, one per line on stdout; exit 2: the check
  couldn't read its inputs (the error on stdout).
"""
from __future__ import annotations

import json
import os
import sys

CPU_MAX_PCT = 70.0
ELU_MAX = 0.5
PHASES = ("preflight", "steady", "postflight")


def cpu_count(mask: str | None) -> int:
    """The CPUs a taskset list names ("8-11", "0,2-3"); 0 for none."""
    out = set()
    for part in filter(None, (mask or "").strip().split(",")):
        a, _, b = part.partition("-")
        out.update(range(int(a), int(b or a) + 1))
    return len(out)


def client_mask(pin_cpus: str | None) -> str | None:
    """The client's mask from run.json's pinCpus ("server:0-7 client:8-11"); None when unpinned."""
    for part in (pin_cpus or "").split():
        side, _, mask = part.partition(":")
        if side == "client":
            return None if mask in ("", "none") else mask
    return None


def measure(report: dict, client_cpus: str | None) -> dict:
    """Per phase, `{cpuDemandPct, eluMax, missing}` (missing: why a figure can't be read, else
    None), with the configured worker count and the CPUs the demand is over."""
    workers = ((report.get("meta") or {}).get("runConfig") or {}).get("workers")
    out = {"workers": workers, "phases": {}}
    for name in PHASES:
        phase = next((p for p in report.get("phases") or [] if p.get("name") == name), None)
        m = (phase or {}).get("measurement") or {}
        cpu, elu = m.get("clientCpu"), m.get("clientElu")
        missing = []
        if phase is None:
            missing.append("no such phase")
        if not isinstance(workers, int) or workers < 1:
            missing.append(f"configured workers {workers!r}")
        if cpu is None:
            missing.append("no clientCpu")
        elif cpu.get("workers") != workers:
            missing.append(f"clientCpu covers {cpu.get('workers')} of {workers} workers")
        if elu is None:
            missing.append("no clientElu (a client before it was reported)")
        elif elu.get("workers") != workers:
            missing.append(f"clientElu covers {elu.get('workers')} of {workers} workers")
        cpus = cpu_count(client_cpus) or (cpu or {}).get("cores") or 0
        if cpu is not None and not cpus:
            missing.append("no CPU count for the client")
        demand = None
        if not missing:
            worker_pct = cpu["totalPct"] - (cpu.get("orchestratorPct") or 0)
            demand = round(worker_pct / cpus, 1)
        out["phases"][name] = {
            "cpuDemandPct": demand,
            "cpus": cpus or None,
            "eluMax": None if missing else (elu.get("perWorker") or {}).get("max"),
            "missing": "; ".join(missing) or None,
        }
    return out


def failures(load: dict | None) -> list[str]:
    """Why the client's own load makes the run unusable; [] when it doesn't."""
    if load is None:
        return ["client load not measured"]
    out = []
    for name in PHASES:
        p = (load.get("phases") or {}).get(name)
        if p is None:
            out.append(f"{name}: client load not measured")
        elif p["missing"]:
            out.append(f"{name}: client load missing ({p['missing']})")
        else:
            if p["cpuDemandPct"] > 100:
                out.append(f"{name}: workers' CPU demand {p['cpuDemandPct']} % of {p['cpus']} CPUs: over 100 %, the measurement is broken")
            elif p["cpuDemandPct"] >= CPU_MAX_PCT:
                out.append(f"{name}: workers' CPU demand {p['cpuDemandPct']} % of {p['cpus']} CPUs, the limit is under "
                           f"{CPU_MAX_PCT:g} %: the client may be the bottleneck")
            if p["eluMax"] is None or p["eluMax"] > ELU_MAX:
                out.append(f"{name}: worst worker ELU {p['eluMax']}, the limit is {ELU_MAX:g}")
    return out


def report_of(summary_path: str, ws: str) -> dict:
    """The one run's report a scalability summary names (run.sh has checked it exists)."""
    summary = json.load(open(summary_path, encoding="utf-8"))
    path = summary["runs"][0]["reportJson"]
    return json.load(open(path if os.path.isabs(path) else os.path.join(ws, path), encoding="utf-8"))


def main(argv: list[str]) -> int:
    if len(argv) != 4 or argv[0] != "check":
        print(__doc__.split("Usage: ", 1)[1], file=sys.stderr)
        return 2
    _, summary_path, ws, client_cpus = argv
    reasons = failures(measure(report_of(summary_path, ws), client_cpus or None))
    print("\n".join(reasons))
    return 1 if reasons else 0


if __name__ == "__main__":
    # A check that can't read its inputs exits 2 with the error, so run.sh doesn't report it as the
    # rule's verdict (exit 1).
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:  # noqa: BLE001
        print(f"client load check failed: {type(e).__name__}: {e}")
        sys.exit(2)
