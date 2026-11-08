#!/usr/bin/env python3
"""The load client's own load per segment, and the rule that gates it (stdlib only).

The client must not be the bottleneck it measures (design § 2;
Notes/solutions/2026-11-05-load-tool-is-the-bottleneck.md). Two figures per segment (baseline,
impaired, recovery, analysis.py's segments from the run's timeline), from every client
instance's `loop` spans (ws-loadtest samples: one span of about 1 s per worker, with the worker
process's event-loop utilization `elu` and its own CPU time `cpuMs`):

- **CPU demand on the pinned client CPUs:** the instances' workers' CPU time in the segment over
  the segment's length times the number of CPUs in the recorded client mask, as a percentage.
  Workers are forked processes, so each span's `cpuMs` is that worker's own and they add up. A
  span crossing a segment edge counts by its overlap, prorated. Over 100 % is impossible on the
  mask and is reported as broken.
- **Worker ELU:** each worker's time-weighted mean span ELU over the segment, the largest over
  workers.

`failures(meta)` is the one rule, used by stopcheck.py (stop the sweep) and regenerate.py
(refuse the run): the CPU demand's largest segment must be under `CPU_MAX_PCT`, each worker's
ELU at most `ELU_MAX`, and a missing figure (an unpinned run, spans without CPU time, no spans
in a segment) fails as missing.
"""
from __future__ import annotations

import pathlib
import sys

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import analysis  # noqa: E402

CPU_MAX_PCT = 70.0
ELU_MAX = 0.5
SEGMENTS = analysis.SEGMENTS


def cpu_count(mask: str | None) -> int:
    """The CPUs a taskset list names ("8-11", "0,2-3"); 0 for none."""
    out = set()
    for part in filter(None, (mask or "").strip().split(",")):
        a, _, b = part.partition("-")
        out.update(range(int(a), int(b or a) + 1))
    return len(out)


def measure(run_dir: pathlib.Path, instances: list[str], client_cpus: str | None) -> tuple[dict | None, dict | None]:
    """`(clientCpu, clientElu)` for run.json's meta, or `None` for a figure that can't be measured."""
    try:
        timeline = analysis.read_timeline(run_dir / "impairment-timeline.json")
    except (OSError, ValueError, KeyError):
        return None, None
    segments = timeline.segments
    spans = [(f"{inst}/{r['worker']}", r) for inst in instances
             for r in analysis.read_samples(run_dir / "samples" / inst) if r.get("r") == "loop"]
    cpu_ms = {seg: 0.0 for seg in SEGMENTS}
    elu_sum: dict[tuple[str, str], float] = {}
    elu_ms: dict[tuple[str, str], float] = {}
    cpu_known = bool(spans)
    for worker, r in spans:
        length = r["to"] - r["from"]
        if length <= 0:
            continue
        for seg, (start, end) in segments.items():
            overlap = min(end, r["to"]) - max(start, r["from"])
            if overlap <= 0:
                continue
            if r.get("cpuMs") is None:
                cpu_known = False
            else:
                cpu_ms[seg] += r["cpuMs"] * overlap / length
            elu_sum[(seg, worker)] = elu_sum.get((seg, worker), 0.0) + r["elu"] * overlap
            elu_ms[(seg, worker)] = elu_ms.get((seg, worker), 0.0) + overlap
    covered = {seg for seg, _ in elu_ms}
    elu = None
    if covered == set(SEGMENTS):
        per = {seg: max(elu_sum[k] / elu_ms[k] for k in elu_ms if k[0] == seg) for seg in SEGMENTS}
        elu = {"segments": {s: round(v, 3) for s, v in per.items()}, "max": round(max(per.values()), 3)}
    cpus = cpu_count(client_cpus)
    cpu = None
    if cpus and cpu_known and covered == set(SEGMENTS):
        pct = {seg: cpu_ms[seg] * 100 / ((segments[seg][1] - segments[seg][0]) * cpus) for seg in SEGMENTS}
        cpu = {"cpus": cpus, "mask": client_cpus, "segments": {s: round(v, 1) for s, v in pct.items()},
               "max": round(max(pct.values()), 1)}
    return cpu, elu


def failures(meta: dict) -> list[str]:
    """Why the client's own load makes the run unusable; [] when it doesn't."""
    out = []
    cpu, elu = meta.get("clientCpu"), meta.get("clientElu")
    if cpu is None:
        out.append("client CPU demand missing (an unpinned run, spans without CPU time, or a segment without spans)")
    elif cpu["max"] > 100:
        out.append(f"client CPU demand {cpu['max']} % of the {cpu['cpus']} pinned CPUs: over 100 %, the measurement is broken")
    elif cpu["max"] >= CPU_MAX_PCT:
        out.append(f"client CPU demand {cpu['max']} % of the {cpu['cpus']} pinned CPUs in a segment ({cpu['segments']}), "
                   f"the limit is under {CPU_MAX_PCT:g} %: the client may be the bottleneck")
    if elu is None:
        out.append("client worker ELU missing (no loop spans in a segment)")
    elif elu["max"] > ELU_MAX:
        out.append(f"client worker ELU {elu['max']} in a segment ({elu['segments']}), the limit is {ELU_MAX:g}")
    return out
