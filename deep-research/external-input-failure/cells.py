#!/usr/bin/env python3
"""The matrix (Notes/plans/2026-11-08-external-input-failure-experiment-design.md § D3), read by
run.sh, cell.py, collect.py and regenerate.py (stdlib only).

  python3 cells.py names        the cell names, one line
  python3 cells.py show <cell>  one cell as JSON

Each cell is one GameServer process. `env` is the server's environment on top of the defaults
below; `outcome` is CallServiceAction's `outcome` in the scenario; `injects` the action outcomes
the cell injects (any other is a failed cell, and each injected one must occur); `leavers` the
players per room that leave when the steady phase ends (a second client instance holds their
slots and stops there, so the lands stay up with the others).
"""
import json, sys

# The service and framework defaults of every cell, overridden per cell.
BASE_ENV = {
    "RESOLVER_TEST_DELAY_MS": "200",
    "RESOLVER_TEST_DELAY_JITTER_MS": "0",
    "RESOLVER_TEST_FAILURE_RATE": "0",
    "RESOLVER_TEST_DEADLINE_MS": "1000",
    "RESOLVER_TEST_SEED": "1",
    "RESOLVER_TEST_IGNORE_CANCELLATION": "false",
    "RESOLVER_TEST_JOIN_FAILURE_RATE": "0",
    "RESOLVER_TEST_LEAVE_FAILURE_RATE": "0",
    "RESOLVER_TIMEOUT_MS": "5000",
}
PLAYERS = 4
ACTIONS_PER_SECOND = 2
PRE_S, STEADY_S, TAIL_S = 5, 60, 90
# A service deadline that never fires before the delay (the framework-deadline cells).
OFF = "10000"


def cell(rooms=50, outcome="rate", injects=(), leavers=0, **env):
    return {"rooms": rooms, "outcome": outcome, "injects": sorted(injects), "leavers": leavers,
            "env": dict(BASE_ENV, **{f"RESOLVER_TEST_{k.upper()}" if k != "framework_ms" else "RESOLVER_TIMEOUT_MS": str(v)
                                     for k, v in env.items()})}


CELLS = {
    # Tick and latency reference: the resolver runs and returns at once.
    "baseline": cell(outcome="succeed", delay_ms=0),
    # Failure rate (delay 200 ms, service deadline 1000, framework 5000).
    "rate0": cell(),
    "rate10": cell(injects=["failed"], failure_rate=0.1),
    "rate50": cell(injects=["failed"], failure_rate=0.5),
    "rate10-jitter": cell(injects=["failed"], failure_rate=0.1, delay_jitter_ms=200),
    "rate10-r200": cell(rooms=200, injects=["failed"], failure_rate=0.1),
    # Which deadline fires (rate 0, delay 1500 ms).
    "service-deadline": cell(injects=["failed"], delay_ms=1500),
    "framework-deadline": cell(injects=["timedOut"], delay_ms=1500, deadline_ms=OFF, framework_ms=1000),
    "framework-deadline-r200": cell(rooms=200, injects=["timedOut"], delay_ms=1500, deadline_ms=OFF, framework_ms=1000),
    "framework-deadline-ignored": cell(injects=["timedOut"], delay_ms=1500, deadline_ms=OFF, framework_ms=1000,
                                       ignore_cancellation="true"),
    "framework-deadline-ignored-r200": cell(rooms=200, injects=["timedOut"], delay_ms=1500, deadline_ms=OFF, framework_ms=1000,
                                            ignore_cancellation="true"),
    # Join and leave phases: 10% of the checks fail.
    "join10": cell(join_failure_rate=0.1),
    "leave10": cell(leave_failure_rate=0.1, leavers=2),
}


def framework_deadline_ms(c):
    return int(c["env"]["RESOLVER_TIMEOUT_MS"])


def longest_call_ms(c):
    """The longest a planned call can run: its delay and jitter, unless a deadline cuts it short;
    a call that ignores cancellation runs its whole delay."""
    env = c["env"]
    delay = int(env["RESOLVER_TEST_DELAY_MS"]) + int(env["RESOLVER_TEST_DELAY_JITTER_MS"])
    if env["RESOLVER_TEST_IGNORE_CANCELLATION"] == "true":
        return delay
    return min(delay, int(env["RESOLVER_TEST_DEADLINE_MS"]), framework_deadline_ms(c))


def cooperative(c):
    return c["env"]["RESOLVER_TEST_IGNORE_CANCELLATION"] != "true"


if __name__ == "__main__":
    if sys.argv[1:] == ["names"]:
        print(" ".join(CELLS))
    elif len(sys.argv) == 3 and sys.argv[1] == "show":
        print(json.dumps(CELLS[sys.argv[2]], indent=2, sort_keys=True))
    else:
        sys.exit(__doc__)
