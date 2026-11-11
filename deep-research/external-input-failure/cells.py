#!/usr/bin/env python3
"""The matrix (Notes/plans/2026-11-08-external-input-failure-experiment-design.md § D3), read by
run.sh, cell.py, collect.py and regenerate.py (stdlib only).

  python3 cells.py names        the cell names, one line
  python3 cells.py show <cell>  one cell as JSON

Each cell is one GameServer process. `env` is the server's environment on top of the defaults
below; `outcome` is CallServiceAction's `outcome` in the scenario; `injects` the action outcomes
the cell injects (any other is a failed cell, and each injected one must occur); `leavers` the
players per room that leave when the steady phase ends (a second client instance holds their
slots and stops there, so the lands stay up with the others); `actions_per_second` each player's
offered rate.

Since the action completion queue (#338, #349), an action whose resolvers run no longer holds its
session: it becomes a job, the session's next input is handled at once, and the job is answered
when its resolvers finish, or at the framework deadline. A job keeps a place in the server's caps
until its resolvers' task ends, a call that ignores cancellation included: 8 per session in
flight (ACTION_IN_FLIGHT_MAX_PER_SESSION) and 256 abandoned in the process
(RESOLVER_ABANDONED_ACTIONS_MAX). An action over a cap is rejected at once; the load client counts
it as its own outcome, which the framework-deadline-ignored cells report and every other cell
fails on (`allows_limit_rejections`).

`check` still refuses a cell whose players offer at least one action per `hold_ms`
(`actions_per_second * hold_ms >= 1000`). That rule was set when an action held its session's
inbound chain (before the queue), and is kept so that the matrix stays the one measured before:
each player has at most about one action in its resolvers at a time, far below the per-session
cap. The process-wide cap is the closer one: a framework-deadline-ignored cell at 200 rooms keeps
about 200 abandoned calls running at once.
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
# The rate of the cells whose action's resolvers run for up to a second (the deadline cells):
# offered 0.5/s against at most 1000 ms in the resolvers, so each player has at most about one
# action in its resolvers at a time (the rule `check` keeps; see above).
HELD_ACTIONS_PER_SECOND = 0.5
# The most messages a session may hold read but not yet handled (the profiler's
# `inboundQueuedMessagesMax`) in any interval of the load. A cell that offers less than a session
# serves (`check`) holds at most the action being handled plus one that arrived during it; the
# bound leaves room for the client's send timing to bunch two more. A backlog instead grows by
# about one per second per session for as long as the load runs.
BACKLOG_BOUND = 4
PRE_S, STEADY_S, TAIL_S = 5, 60, 90
# A service deadline that never fires before the delay (the framework-deadline cells).
OFF = "10000"


def cell(rooms=50, outcome="rate", injects=(), leavers=0, actions_per_second=ACTIONS_PER_SECOND, **env):
    return {"rooms": rooms, "outcome": outcome, "injects": sorted(injects), "leavers": leavers,
            "actions_per_second": actions_per_second,
            "env": dict(BASE_ENV, **{f"RESOLVER_TEST_{k.upper()}" if k != "framework_ms" else "RESOLVER_TIMEOUT_MS": str(v)
                                     for k, v in env.items()})}


HELD = HELD_ACTIONS_PER_SECOND


CELLS = {
    # Tick and latency reference: the resolver runs and returns at once.
    "baseline": cell(outcome="succeed", delay_ms=0),
    # Failure rate (delay 200 ms, service deadline 1000, framework 5000).
    "rate0": cell(),
    "rate10": cell(injects=["failed"], failure_rate=0.1),
    "rate50": cell(injects=["failed"], failure_rate=0.5),
    "rate10-jitter": cell(injects=["failed"], failure_rate=0.1, delay_jitter_ms=200),
    "rate10-r200": cell(rooms=200, injects=["failed"], failure_rate=0.1),
    # Which deadline fires (rate 0, delay 1500 ms). Each action's resolvers run for up to 1000 ms,
    # so these cells offer 0.5/s (see `check`).
    "service-deadline": cell(injects=["failed"], delay_ms=1500, actions_per_second=HELD),
    "framework-deadline": cell(injects=["timedOut"], actions_per_second=HELD, delay_ms=1500, deadline_ms=OFF, framework_ms=1000),
    "framework-deadline-r200": cell(rooms=200, injects=["timedOut"], actions_per_second=HELD, delay_ms=1500, deadline_ms=OFF, framework_ms=1000),
    "framework-deadline-ignored": cell(injects=["timedOut"], actions_per_second=HELD, delay_ms=1500, deadline_ms=OFF, framework_ms=1000,
                                       ignore_cancellation="true"),
    "framework-deadline-ignored-r200": cell(rooms=200, injects=["timedOut"], actions_per_second=HELD, delay_ms=1500, deadline_ms=OFF, framework_ms=1000,
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


# The action-job caps' rejections (ws-loadtest's `abandonedLimitRejected` and
# `inFlightLimitRejected` outcomes, the server's `action*LimitRejections` counters).
LIMIT_REJECTIONS = (("abandonedLimitRejected", "actionAbandonedLimitRejections"),
                    ("inFlightLimitRejected", "actionInFlightLimitRejections"))


def allows_limit_rejections(c):
    """Whether a cap rejection is a reported outcome of the cell, not a failure: only where calls
    ignore cancellation (the framework-deadline-ignored cells), whose abandoned calls can reach the
    process cap (the module docstring). Anywhere else a rejection fails the cell."""
    return not cooperative(c)


def hold_ms(c):
    """The longest an action waits for its answer: until its resolvers finish, or until the
    framework deadline gives up on them. A call that ignores cancellation keeps running after
    that, as an abandoned job, but its caller has its answer. (Before the action completion
    queue, this was also how long the action held its session's inbound chain.)"""
    env = c["env"]
    delay = int(env["RESOLVER_TEST_DELAY_MS"]) + int(env["RESOLVER_TEST_DELAY_JITTER_MS"])
    return min(delay, int(env["RESOLVER_TEST_DEADLINE_MS"]), framework_deadline_ms(c))


def check(name, c):
    """Refuses a cell whose players offer at least one action per `hold_ms` (see the module
    docstring: the matrix as measured before the action completion queue)."""
    offered = c["actions_per_second"] * hold_ms(c)
    if offered >= 1000:
        raise ValueError(f"cell {name}: {c['actions_per_second']} actions/s per player, each holding its session up to "
                         f"{hold_ms(c)} ms, is {offered / 1000:g} s of work per second: the session would queue a backlog. "
                         f"Offer less than {1000 / hold_ms(c):g} actions/s.")


for _name, _c in CELLS.items():
    check(_name, _c)


if __name__ == "__main__":
    if sys.argv[1:] == ["names"]:
        print(" ".join(CELLS))
    elif len(sys.argv) == 3 and sys.argv[1] == "show":
        print(json.dumps(CELLS[sys.argv[2]], indent=2, sort_keys=True))
    else:
        sys.exit(__doc__)
