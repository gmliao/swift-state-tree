#!/usr/bin/env python3
"""The netem settings each cell runs with, and where they came from (stdlib and git only).

A calibration is a commit, the wire form its runs had, and per cell the queue limits (packets,
down/up), the rate (RATE, COMBO) and, for the jitter cells, whether netem reorders and how much
(design § 1). The built-in one is 2026-11-07's (`BUILTIN`), run privately at server 12d3b01b.
`calibrate.py` writes a new one from fresh U-P0 and M-P0 runs (`run.sh` MODE=calibrate), which a
sweep reads with CALIBRATION=<file>.

**Rate cells depend on the wire form.** RATE and COMBO's rates are fractions of P0's downstream
bytes per second (§ 3), and their limits follow from the rate (§ 1). Field merge (#301) and the
path index (#308) shrank the frames, so a rate from a calibration of another wire form no longer
throttles as designed: `settings` refuses a rate cell unless the calibration's form (wireform)
is the sweep's. The other limits are the fixed 10000 of § 1, and the jitter cells' reordering
doesn't depend on payload size, so those carry over from any calibration.

Smoke overrides (environment, recorded in params.calibrationOverrides): RATE=<tc rate> (the cell's
rate), LIMITS=<down>:<up>, JITTER_REORDERS=0|1, REORDERED_PCT=<down>:<up>.
"""
from __future__ import annotations

import json
import pathlib
import sys

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC.parent))
import gameserver_wire  # noqa: E402
import wireform  # noqa: E402

FIXED_LIMITS = [10000, 10000]
# The rate cells: the population whose P0 downstream they take a fraction of, and the fraction (§ 3).
RATE_CELLS = {"U-RATE": ("U", 0.5), "M-COMBO": ("M", 0.8)}
JITTER_CELLS = ("U-D50J10", "M-COMBO")
# § 1: a rate cell's down limit holds 500 ms of full-size packets at its rate, at least 100.
RATE_QUEUE_S = 0.5
PACKET_BYTES = 1500

# #344's steady on-wire overhead per connection (sync-lag tracking, #332), resync bytes excluded:
# - upstream, one ack a second: about 7 B of MessagePack, a 6 B masked WebSocket header and
#   about 52 B of TCP/IP, so about 65 B/s;
# - downstream, every state frame grows by 1 to 9 B (its sync sequence; #344's As built note),
#   so up to about 90 B/s at 10 Hz.
SYNC_ACK_UP_BYTES_PER_S = 65
SYNC_SEQ_DOWN_BYTES_PER_S = 90
# A rate cell's calibration is stale when #344's frames add more than this share to the
# downstream demand its rate is a fraction of: it no longer throttles as designed.
STALE_DEMAND_SHARE = 0.20


def rate_bytes_per_s(rate: str) -> float:
    """A tc rate (``25218749bit``, ``3mbit``, ``1500kbit``) in bytes per second."""
    units = {"bit": 1, "kbit": 1e3, "mbit": 1e6, "gbit": 1e9}
    for unit in sorted(units, key=len, reverse=True):
        if rate.endswith(unit):
            return float(rate[: -len(unit)]) * units[unit] / 8
    raise ValueError(f"not a tc rate: {rate!r}")


def rate_staleness(cell: str, rate: str, shaped_connections: int) -> dict:
    """Whether #344's steady overhead makes a rate cell's calibration stale (the shared check:
    plan.py refuses to plan such a cell, regenerate.py reports it). Only the downstream is shaped
    (impair.sh: RATE and COMBO rate-limit veth-c1's egress, one link for every connection behind
    it), so only it is checked; the upstream overhead is reported, unshaped.

    ``P0_down`` is the demand the calibration measured (its rate over the cell's fraction);
    ``extra_down`` the frames' growth over the connections behind the shaped link."""
    _, fraction = RATE_CELLS[cell]
    p0_down = rate_bytes_per_s(rate) / fraction
    extra_down = shaped_connections * SYNC_SEQ_DOWN_BYTES_PER_S
    share = extra_down / p0_down
    out = {"cell": cell, "p0DownBytesPerS": round(p0_down), "extraDownBytesPerS": extra_down,
           "share": share, "upUnshapedBytesPerS": shaped_connections * SYNC_ACK_UP_BYTES_PER_S,
           "stale": share > STALE_DEMAND_SHARE}
    if out["stale"]:
        out["message"] = f"recalibrate: #344 frames add {share * 100:.0f} % to the calibrated demand"
    return out

BUILTIN = {
    "name": "2026-11-07",
    "commit": "12d3b01b",
    "encoding": "messagepack",
    # Not recorded in 2026-11-07's runs: resolved by ancestry (wireform), so both off at 12d3b01b.
    "features": None,
    "p0DownstreamBytesPerS": {"U": 6304687, "M": 632378},
    "cells": {
        "U-P0": {"limits": FIXED_LIMITS},
        "U-D50J10": {"limits": FIXED_LIMITS, "jitterReorders": True, "reorderedPct": {"down": 0.614, "up": 0.386}},
        "U-L5": {"limits": FIXED_LIMITS},
        "U-RATE": {"limits": [1050, 10000], "rate": "25218749bit"},
        "U-BO75": {"limits": FIXED_LIMITS},
        "M-P0": {"limits": FIXED_LIMITS},
        "M-COMBO": {"limits": [168, 10000], "rate": "4047216bit", "jitterReorders": True, "reorderedPct": {"down": 16.13, "up": 0.843}},
        "M-BO75": {"limits": FIXED_LIMITS},
        "SR": {"limits": FIXED_LIMITS},
        "SR-CAL": {"limits": FIXED_LIMITS},
    },
}


class Refused(ValueError):
    """The cell can't run with this calibration: say why."""


def load(path: str | None) -> dict:
    return BUILTIN if not path else json.loads(pathlib.Path(path).read_text())


def form(calibration: dict) -> wireform.WireForm:
    """The calibration's wire form: what its P0 runs' joins named, or by ancestry when it recorded none."""
    return wireform.resolve(calibration["commit"], calibration["encoding"], features=calibration.get("features"))


def intended_form(environ: dict, commit: str | None = None) -> wireform.WireForm:
    """The sweep's form from the server's environment, by the server's rules (gameserver_wire).
    `commit`: the server's, for ROW_ADDRESSING's default."""
    return gameserver_wire.intended(environ, commit=commit)


def overrides_from(environ: dict) -> dict:
    out = {}
    if environ.get("RATE"):
        out["rate"] = environ["RATE"]
    if environ.get("LIMITS"):
        down, _, up = environ["LIMITS"].partition(":")
        out["limits"] = [int(down), int(up)]
    if environ.get("JITTER_REORDERS"):
        out["jitterReorders"] = environ["JITTER_REORDERS"] == "1"
    if environ.get("REORDERED_PCT"):
        down, _, up = environ["REORDERED_PCT"].partition(":")
        out["reorderedPct"] = {"down": float(down), "up": float(up)}
    return out


def settings(calibration: dict, cell: str, sweep_form: wireform.WireForm, overrides: dict | None = None) -> dict:
    """The cell's params from the calibration: limits, and rate / jitterReorders / reorderedPct
    where the cell has them. Raises Refused for a rate cell whose calibration has another wire
    form, unless the overrides give both its rate and its limits."""
    overrides = dict(overrides or {})
    entry = dict(calibration["cells"].get(cell) or {})
    if not entry:
        raise Refused(f"calibration {calibration['name']} has no values for {cell}")
    if cell in RATE_CELLS and not {"rate", "limits"} <= set(overrides):
        try:
            cal_form = form(calibration)
        except wireform.MissingWireForm as e:
            raise Refused(f"{cell}: calibration {calibration['name']}'s wire form is unknown ({e})") from None
        if cal_form != sweep_form:
            raise Refused(f"{cell}: calibration {calibration['name']} (commit {calibration['commit']}) ran {cal_form.caption()}, "
                          f"the sweep runs {sweep_form.caption()}: its rate no longer throttles as designed. "
                          "Run MODE=calibrate at this commit and pass CALIBRATION=<its file>, or give RATE= and LIMITS= (smoke).")
    if overrides and cell not in RATE_CELLS:
        overrides.pop("rate", None)
    if overrides and cell not in JITTER_CELLS:
        overrides.pop("jitterReorders", None)
        overrides.pop("reorderedPct", None)
    entry.update(overrides)
    out = {"limits": {"down": entry["limits"][0], "up": entry["limits"][1]},
           "calibration": {"name": calibration["name"], "commit": calibration["commit"]}}
    if cell in RATE_CELLS:
        out["rate"] = entry["rate"]
    if cell in JITTER_CELLS and entry.get("jitterReorders"):
        if entry.get("reorderedPct") is None:
            raise Refused(f"{cell}: jitter reorders but calibration {calibration['name']} has no reorderedPct")
        out["jitterReorders"] = True
        out["reorderedPct"] = entry["reorderedPct"]
    if overrides:
        out["calibrationOverrides"] = overrides
    return out


def rate_settings(p0_down_bytes_per_s: float, fraction: float) -> dict:
    """§ 1 / § 3: the rate (tc bits) and the down limit of a rate cell from its P0 downstream."""
    rate_bytes = p0_down_bytes_per_s * fraction
    return {"rate": f"{round(rate_bytes * 8)}bit",
            "limits": [max(100, int(rate_bytes * RATE_QUEUE_S // PACKET_BYTES)), FIXED_LIMITS[1]]}
