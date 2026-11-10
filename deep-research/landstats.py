"""Hero Defense's live load over a window, from GameServer's per-land stats (``land-stats.jsonl``,
``HERO_DEFENSE_STATS_PATH``), and whether it is stationary there (#425). Stdlib only; shared by the
topics that measure on hero-defense (network-impairment-2026-11, multiroom-load-2026-11).

The rule: bin the window in ``BIN_MS`` bins; per bin, take the median over every land of its live
monster count, over every 1 s line in the bin. The window is stationary when the coefficient of
variation (population stdev / mean) of those per-bin medians is at most ``COV_BOUND``, no bin's
median is more than ``MAX_DEV`` from their mean, and the drift (the median of the last third of the
bins less that of the first third, over their mean) is at most ``DRIFT_BOUND`` either way. The CoV
alone tolerates a slow trend (a rise of a third across 60 s is CoV 0.098); the drift bound
doesn't. A topic adds its own conditions (the spawn ramp it ran with)."""
from __future__ import annotations

import json
import math
import pathlib
import statistics

COV_BOUND = 0.10
MAX_DEV = 0.20
DRIFT_BOUND = 0.10
BIN_MS = 10_000
FLOWS = ("spawned", "killed", "reachedBase")


def read(path: pathlib.Path) -> list[dict]:
    """The file's lines (``{fromTs, ts, writeFailures, lands}``), blank lines skipped."""
    return [json.loads(raw) for raw in path.read_text().splitlines() if raw.strip()]


def summary(lines: list[dict], start: int, end: int, bin_ms: int = BIN_MS) -> dict | None:
    """Per ``bin_ms`` bin of ``[start, end)`` (server wall-clock ms, like each line's ``ts``): the
    median, p10 and p90 over lands of the live monster count, each flow's median rate per land
    (per second, from each land's totals at its first and last line in the bin), and the median
    base health; and over the bins, the medians' mean, coefficient of variation, largest
    deviation from the mean and drift (last third's median less the first third's, over the mean;
    a third is at least one bin). None when no line falls in the window."""
    live: dict[int, list[int]] = {}
    base: dict[int, list[int]] = {}
    first: dict[tuple[int, str], tuple[int, dict]] = {}
    last: dict[tuple[int, str], tuple[int, dict]] = {}
    for line in lines:
        if not start <= line["ts"] < end:
            continue
        k = (line["ts"] - start) // bin_ms
        for land, sample in line["lands"].items():
            live.setdefault(k, []).append(sample["monsters"])
            base.setdefault(k, []).append(sample["baseHealth"])
            first.setdefault((k, land), (line["ts"], sample))
            last[(k, land)] = (line["ts"], sample)
    if not live:
        return None

    def rate(k: int, flow: str) -> float | None:
        rates = [(last[key][1].get(flow, 0) - a.get(flow, 0)) / ((last[key][0] - ta) / 1000)
                 for key, (ta, a) in first.items() if key[0] == k and last[key][0] > ta]
        return round(statistics.median(rates), 3) if rates else None

    bins = []
    for k in sorted(live):
        counts = sorted(live[k])
        bins.append({"s": k * bin_ms // 1000, "median": statistics.median(counts), "p10": counts[len(counts) // 10],
                     "p90": counts[9 * len(counts) // 10], "rates": {f: rate(k, f) for f in FLOWS},
                     "baseHealth": statistics.median(base[k])})
    medians = [b["median"] for b in bins]
    mean = statistics.mean(medians)
    third = max(1, len(medians) // 3)
    drift = statistics.median(medians[-third:]) - statistics.median(medians[:third])
    return {"bins": bins, "mean": round(mean, 3),
            "cov": round(statistics.pstdev(medians) / mean, 4) if mean else math.inf,
            "maxDev": round(max(abs(m - mean) / mean for m in medians), 4) if mean else math.inf,
            "drift": round(drift / mean, 4) if mean else math.inf}


def stationary(s: dict | None) -> bool:
    """Whether a ``summary`` meets the rule (False without one)."""
    return s is not None and s["cov"] <= COV_BOUND and s["maxDev"] <= MAX_DEV and abs(s["drift"]) <= DRIFT_BOUND


def lines_table(s: dict) -> list[str]:
    """The summary as text lines: one per bin, then the verdict's numbers."""
    out = ["     s | live monsters, median (p10-p90) | spawned / killed / reached base per s per land | base health"]
    for b in s["bins"]:
        flows = " / ".join(f"{b['rates'][f]:5.2f}" if b["rates"][f] is not None else "  nan" for f in FLOWS)
        out.append(f"  {b['s']:4d} | {b['median']:5.1f} ({b['p10']}-{b['p90']}) | {flows} | {b['baseHealth']:5.1f}")
    out.append(f"per-bin medians: mean {s['mean']:.1f}, CoV {s['cov']:.3f} (bound {COV_BOUND}), largest deviation "
               f"{s['maxDev']:.1%} (bound {MAX_DEV:.0%}), drift {s['drift']:+.1%} (bound {DRIFT_BOUND:.0%})")
    return out
