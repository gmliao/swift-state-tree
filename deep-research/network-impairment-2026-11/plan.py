#!/usr/bin/env python3
"""The sweep's plan, without running anything (stdlib only): the cells, § 8's order, each run's
layout (client instances, room slots, workers), its groups and convergence roster, its
scenario, and the netem settings its cell takes from the calibration (calibration.py).

  plan.py order [--cells "U-P0 M-COMBO ..."] [--repeats "1 2 3"]   one line per run: <cell> <repeat>
  plan.py cells                                                     every cell id

Design: Notes/plans/2026-11-07-network-impairment-experiment-design.md (§ 3 profiles, § 4
populations, § 8 order). Cells are <population>-<profile>; SR-CAL is the slow-reader
calibration (§ 4), run once before the SR block, and isn't one of the 27 runs.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
SCENARIOS = TOPIC.parent.parent / "Examples" / "GameDemo" / "ws-loadtest" / "scenarios" / "hero-defense"
PLAYERS = 5
WORKERS = 12
REPEATS = (1, 2, 3)
# Reconstruct sampling: U reconstructs slots 0-1 of every room; M and SR every impaired
# player, one healthy player in each mixed room (slot 1: isolation is why the mixed rooms exist)
# and slot 0 of each all-healthy room. The convergence check covers exactly those.
U_RECONSTRUCT_SLOTS = (0, 1)
# M and SR: lt-client's workers (it reconstructs every one of its connections).
M_IMPAIRED_WORKERS = 2
# The rooms of the planned matrix (§ 2) and of the smoke (the 10-room scenarios).
ROOMS = (300, 10)

# Each block's cells, P0 first: every repeat starts with its P0, then the rest rotated (§ 8).
BLOCKS = {
    "U": ["U-P0", "U-D50J10", "U-L5", "U-RATE", "U-BO75"],
    "M": ["M-P0", "M-COMBO", "M-BO75"],
    "SR": ["SR"],
}
CALIBRATION_CELL = "SR-CAL"
CELLS = [c for block in BLOCKS.values() for c in block] + [CALIBRATION_CELL]


def population(cell: str) -> str:
    return "SR" if cell in ("SR", CALIBRATION_CELL) else cell.split("-", 1)[0]


def profile(cell: str) -> str:
    """The impair.sh profile of a cell: SR and its calibration name the slow-reader profile."""
    return "SR" if cell in ("SR", CALIBRATION_CELL) else cell.split("-", 1)[1]


def rotated(cells: list[str], repeat: int) -> list[str]:
    """A block's pass for one repeat: its P0 (when it has one) first, the others rotated by repeat."""
    head, rest = (cells[:1], cells[1:]) if cells[0].endswith("-P0") else ([], cells)
    k = (repeat - 1) % len(rest) if rest else 0
    return head + rest[k:] + rest[:k]


def order(cells: list[str] | None = None, repeats: list[int] | None = None) -> list[tuple[str, int]]:
    """§ 8: U, then M, then the SR calibration once, then SR; within a block, each repeat is one
    rotated pass starting with its P0. `cells` and `repeats` filter it (the order is kept)."""
    repeats = list(repeats or REPEATS)
    plan: list[tuple[str, int]] = []
    for name in ("U", "M"):
        for r in repeats:
            plan += [(c, r) for c in rotated(BLOCKS[name], r)]
    plan.append((CALIBRATION_CELL, 1))
    for r in repeats:
        plan += [(c, r) for c in rotated(BLOCKS["SR"], r)]
    if cells is not None:
        unknown = sorted(set(cells) - set(CELLS))
        if unknown:
            raise ValueError(f"unknown cells: {', '.join(unknown)} (one of: {' '.join(CELLS)})")
        plan = [(c, r) for c, r in plan if c in cells]
    return plan


def run_id(sweep: str, cell: str, repeat: int) -> str:
    return f"{sweep}-{cell}" if cell == CALIBRATION_CELL else f"{sweep}-{cell}-r{repeat}"


def mixed_rooms(rooms: int) -> int:
    """M and SR: one impaired player in each of half the rooms (§ 4)."""
    return rooms // 2


def instances(cell: str, rooms: int) -> dict[str, dict]:
    """The client instances of a run: namespace, room slots, workers, and the slots whose state is
    reconstructed (`reconstruct`, ws-loadtest --reconstruct-slots). U: one instance with every
    slot, reconstructing slots 0-1 of each room. M, SR: lt-client holds slot 0 of the mixed rooms
    and reconstructs each; lt-good the other four players there and every player of the healthy
    rooms, reconstructing slot 1 of each mixed room and slot 0 of each healthy room. lt-client
    gets 2 of the 12 workers."""
    if population(cell) == "U":
        a, b = U_RECONSTRUCT_SLOTS
        return {"lt-client": {"slots": None, "connections": rooms * PLAYERS, "workers": WORKERS,
                              "reconstruct": f"0-{rooms - 1}:{a}-{b}"}}
    mixed = mixed_rooms(rooms)
    impaired = mixed
    healthy = rooms * PLAYERS - impaired
    good_slots = f"0-{mixed - 1}:1-{PLAYERS - 1}" + (f",{mixed}-{rooms - 1}:0-{PLAYERS - 1}" if rooms > mixed else "")
    return {
        "lt-client": {"slots": f"0-{mixed - 1}:0", "connections": impaired, "workers": M_IMPAIRED_WORKERS,
                      "reconstruct": f"0-{mixed - 1}:0"},
        "lt-good": {"slots": good_slots, "connections": healthy, "workers": WORKERS - M_IMPAIRED_WORKERS,
                    "reconstruct": f"0-{mixed - 1}:1" + (f",{mixed}-{rooms - 1}:0" if rooms > mixed else "")},
    }


def land_id(run_tag: str, room: int) -> str:
    """ws-loadtest's rooms layout names a land `<run-id>-room-p<players>-<room>` (layout.ts)."""
    return f"{run_tag}-room-p{PLAYERS}-{room}"


def groups(cell: str, rooms: int, run_tag: str, actions_per_second: int = 1) -> dict[str, dict]:
    """run.json `groups` (analysis.py), before the run's loopDelayP99Ms is known."""
    if population(cell) == "U":
        n = rooms * PLAYERS
        return {"impaired": {"instance": "lt-client", "target": n, "sendTargetPerS": n * actions_per_second}}
    mixed = mixed_rooms(rooms)
    return {
        "impaired": {"instance": "lt-client", "target": mixed, "sendTargetPerS": mixed * actions_per_second},
        "healthy-mixed": {"instance": "lt-good", "target": mixed * (PLAYERS - 1), "sendTargetPerS": mixed * (PLAYERS - 1) * actions_per_second,
                          "lands": [land_id(run_tag, r) for r in range(mixed)]},
        "healthy-rooms": {"instance": "lt-good", "target": (rooms - mixed) * PLAYERS, "sendTargetPerS": (rooms - mixed) * PLAYERS * actions_per_second,
                          "lands": [land_id(run_tag, r) for r in range(mixed, rooms)]},
    }


def convergence_roster(cell: str, rooms: int) -> dict[str, dict[str, int]]:
    """params.convergenceRoster: per instance, rooms per reconstructed connection count (README):
    the sampled connections the convergence check must list (`instances`' `reconstruct`)."""
    if population(cell) == "U":
        return {"lt-client": {str(len(range(U_RECONSTRUCT_SLOTS[0], U_RECONSTRUCT_SLOTS[1] + 1))): rooms}}
    mixed = mixed_rooms(rooms)
    # lt-good: one reconstructed player in every room (slot 1 of a mixed room, slot 0 of a healthy one).
    return {"lt-client": {"1": mixed}, "lt-good": {"1": rooms}}


def scenario_file(cell: str, rooms: int) -> pathlib.Path:
    """The committed scenario a cell runs (SR's is derived from it with its pause, cell.py)."""
    if cell == CALIBRATION_CELL:
        if rooms != 300:
            raise ValueError("the SR calibration runs at 300 rooms only (design § 4: not a 10-room smoke)")
        return SCENARIOS / "impairment-300-srcal.json"
    suffix = "-bo75" if profile(cell) == "BO75" else ""
    return SCENARIOS / f"impairment-{rooms}{suffix}.json"


def timeline(scenario: dict) -> dict:
    return scenario["impairment"]


def with_impaired_seconds(scenario: dict, seconds: int) -> dict:
    """SR's scenario: the committed one with the impaired segment set to the slow reader's pause
    and the first phase stretched to match (it covers warm-up through tail)."""
    out = json.loads(json.dumps(scenario))
    tl = out["impairment"]
    tl["impairedSeconds"] = seconds
    out["phases"]["preflight"]["durationSeconds"] = sum(tl[k] for k in ("warmupSeconds", "baselineSeconds", "impairedSeconds",
                                                                         "recoverySeconds", "tailSeconds"))
    return out


def shaped_connections(cell: str, rooms: int) -> int:
    """The connections behind the shaped link (lt-client's, veth-c1): every one of U's, M's
    impaired players."""
    return instances(cell, rooms)["lt-client"]["connections"]


def refuse_stale_rate_cells(plan: list[tuple[str, int]], rooms: int, calibration_path: str | None, environ: dict) -> None:
    """Raises ValueError when a planned rate cell's rate (the calibration's, or RATE= in a
    smoke) is stale under #344's steady overhead (calibration.rate_staleness): run MODE=calibrate
    first. The run would not throttle as designed, so it isn't scheduled."""
    import calibration
    cal = calibration.load(calibration_path)
    for cell in sorted({c for c, _ in plan if c in calibration.RATE_CELLS}):
        rate = calibration.overrides_from(environ).get("rate") or (cal["cells"].get(cell) or {}).get("rate")
        if rate is None:
            continue
        check = calibration.rate_staleness(cell, rate, shaped_connections(cell, rooms))
        if check["stale"]:
            raise ValueError(f"{cell}: {check['message']} (P0 downstream {check['p0DownBytesPerS']} B/s, "
                             f"{check['extraDownBytesPerS']} B/s more over {shaped_connections(cell, rooms)} connections)")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    o = sub.add_parser("order")
    o.add_argument("--cells", default="")
    o.add_argument("--repeats", default="")
    o.add_argument("--rooms", type=int, default=ROOMS[0], help="the sweep's rooms (the rate cells' check)")
    o.add_argument("--calibration", default="", help="the sweep's calibration file (empty: the built-in one)")
    sub.add_parser("cells")
    args = ap.parse_args(argv)
    if args.command == "cells":
        print(" ".join(CELLS))
        return 0
    try:
        repeats = [int(r) for r in args.repeats.split()] or None
        if repeats and any(r not in REPEATS for r in repeats):
            raise ValueError(f"repeats must be among {list(REPEATS)}, not {repeats}")
        plan = order(args.cells.split() or None, repeats)
        refuse_stale_rate_cells(plan, args.rooms, args.calibration or None, dict(os.environ))
    except ValueError as e:
        print(f"plan.py: {e}", file=sys.stderr)
        return 2
    for cell, repeat in plan:
        print(cell, repeat)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
