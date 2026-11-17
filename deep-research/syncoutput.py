"""The re-evaluation runner's sync-output verdict, as `ReevaluationRunner --verify` prints it (stdlib only).

A replayed record whose sync stream was recorded ends its report with one line:

  Sync Output: passed [compared/unverifiable/skipped: broadcast 1364/0/0, per-player 5452/0/0, events 1364/0/0, seed 4/0/0, apply 6819/0/0]

`parse` reads that line from a runner output, `total` sums the counts of several outputs, and
`failures` names what keeps a set from the claim "every record passed, with nothing unverifiable or
skipped". A topic's collector turns its raw runner outputs into a committed summary with these
functions, and its regenerate.py gates and renders from that summary, so the claim needs no raw files.
"""
import re

LINE = re.compile(r"^\s*Sync Output: (\w+)(?: \[compared/unverifiable/skipped: ([^\]]*)\])?", re.M)
PART = re.compile(r"([\w-]+) (\d+)/(\d+)/(\d+)")
KINDS = ("broadcast", "per-player", "events", "seed", "apply")


def parse(text):
    """{"verdict": str, "counts": {kind: [compared, unverifiable, skipped]}} from one runner output;
    ValueError unless it has exactly one verdict line."""
    found = LINE.findall(text)
    if len(found) != 1:
        raise ValueError(f"{len(found)} 'Sync Output:' lines, expected 1")
    verdict, parts = found[0]
    counts = {}
    for kind, compared, unverifiable, skipped in PART.findall(parts):
        if kind in counts:
            raise ValueError(f"'{kind}' counted twice")
        counts[kind] = [int(compared), int(unverifiable), int(skipped)]
    return {"verdict": verdict, "counts": counts}


def total(entries):
    """{"records": n, "verdicts": {verdict: n}, "counts": {kind: [compared, unverifiable, skipped]}}."""
    verdicts, counts = {}, {k: [0, 0, 0] for k in KINDS}
    for e in entries:
        verdicts[e["verdict"]] = verdicts.get(e["verdict"], 0) + 1
        for kind, values in e["counts"].items():
            row = counts.setdefault(kind, [0, 0, 0])
            for i, v in enumerate(values):
                row[i] += v
    return {"records": len(entries), "verdicts": verdicts, "counts": counts}


def failures(summary, name):
    """Why `summary` (a `total`) isn't "every record passed, all five kinds compared, nothing
    unverifiable or skipped"; empty when it is."""
    out = []
    n = summary["records"]
    if not n:
        out.append(f"{name}: no records")
    if summary["verdicts"] != {"passed": n}:
        out.append(f"{name}: verdicts {summary['verdicts']}, expected {n} passed")
    for kind in KINDS:
        c = summary["counts"].get(kind)
        if c is None or c[0] == 0:
            out.append(f"{name}: nothing compared for {kind}")
        elif c[1] or c[2]:
            out.append(f"{name}: {kind} has {c[1]} unverifiable, {c[2]} skipped")
    extra = set(summary["counts"]) - set(KINDS)
    if extra:
        out.append(f"{name}: unknown kinds {sorted(extra)}")
    return out


def compared(summary):
    """"broadcast 12,482, per-player 70,564, ... apply 83,214" (compared counts)."""
    return ", ".join(f"{kind} {summary['counts'][kind][0]:,}" for kind in KINDS)
