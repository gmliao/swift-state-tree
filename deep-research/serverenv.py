#!/usr/bin/env python3
"""The EncodingBenchmark server's environment: the variables that change what it sends or how it
syncs, for the topics that measure the shipped path (snapshot-baseline, entity-delta-baseline,
visibility).

- the sync path: USE_SNAPSHOT_FOR_SYNC, IN_TURN_SYNC, USE_SYNC_TABLES (#465: the adapter's broadcast
  diff on the typed tables, default off), ROW_ADDRESSING (#487: row-addressed wire frames, which turn
  the sync tables on; default off), TYPED_LEAF_VALUES (#513: leaf fields converted by their typed
  form wherever the sync tables are in effect; default off), SYNC_STRATEGY (delta or full-snapshot: what every sync sends; the
  benchmark's --sync-strategy sets it in-process, so unsetting the shell's doesn't change a run). The
  first two of #465/#487 are listed before they reach main, so a shell that has one set can't
  change a run's sync path unrecorded;
- the wire knobs: PATH_INDEX, FIELD_MERGE, DYNAMIC_KEY_COMPRESSION;
- dirty tracking: ENABLE_DIRTY_TRACKING, the benchmark's own ENCODING_BENCHMARK_DIRTY_TRACKING,
  AUTO_DIRTY_* (AUTO_DIRTY_SAMPLE_EVERY: which syncs the change rate is measured on, #391), and
  CHANGE_OBJECT_METRICS_EMA_ALPHA (the change-rate EMA that the auto switch compares with its
  thresholds);
- hero-defense's server events: HERO_DEFENSE_SERVER_EVENTS (the benchmark's --no-server-events
  flag is the topics' switch, not this variable);
- the action-job caps (the action completion queue): ACTION_IN_FLIGHT_MAX_PER_SESSION,
  RESOLVER_ABANDONED_ACTIONS_MAX, RESOLVER_ABANDONED_ACTIONS_MAX_PER_LAND (#507); beside them the
  server-input cap, SERVER_INPUT_IN_FLIGHT_MAX_PER_LAND (#387);
- the send bounds that change what a sync sends: OUTBOUND_WRITER_MAX_BYTES (an element over the
  outbound writer's backlog bound is dropped) and JOIN_FLIP_BUDGET (the joins flipped per sync
  phase, so the full views a join ramp's plans carry);
- sync-lag tracking (#332): SYNC_LAG_*, SYNC_ACK_*.

A topic's run.sh unsets them all (`unset $(python3 ../serverenv.py)`), so the benchmark's flags
and the shipped defaults decide. Its runmeta.py records them as run.json's serverEnv, collect.py
carries that into each result's meta.server_env, and regenerate.py refuses a run with any of them
set, or with none recorded (`failure`).

The action-job caps and sync-lag tracking joined the list for the 2026-11-09 rerun (ADDED). A record
from before then lacks them, and is accepted without them: its server predates both (the action
completion queue and #344 landed after the last runs recorded without them). A record that has
one must have it unset, like every other variable. The exemption isn't bounded in time: it rests on
running the current script, whose `record` writes every SERVER_ENV key, the added ones included,
so only a record from an older checkout of this file can lack them. USE_SYNC_TABLES,
ROW_ADDRESSING, SYNC_STRATEGY, OUTBOUND_WRITER_MAX_BYTES, JOIN_FLIP_BUDGET and
CHANGE_OBJECT_METRICS_EMA_ALPHA joined on
2026-11-10/11 (#468, #489, ADDED_LATER) on the same terms: a record before then may lack them,
and a record that has one must have it unset. AUTO_DIRTY_SAMPLE_EVERY and
SERVER_INPUT_IN_FLIGHT_MAX_PER_LAND joined with the merge of exp/next into main (2026-11-11), on
the same terms and in the same tuple, as did TYPED_LEAF_VALUES (#513, 2026-11-11).

Usage: python3 serverenv.py   prints the names, space-separated, for run.sh's unset.
"""
import os
import sys

SERVER_ENV = ("USE_SNAPSHOT_FOR_SYNC", "IN_TURN_SYNC", "USE_SYNC_TABLES", "ROW_ADDRESSING", "TYPED_LEAF_VALUES", "SYNC_STRATEGY", "PATH_INDEX", "FIELD_MERGE", "DYNAMIC_KEY_COMPRESSION",
              "ENABLE_DIRTY_TRACKING", "ENCODING_BENCHMARK_DIRTY_TRACKING", "AUTO_DIRTY_TRACKING",
              "AUTO_DIRTY_OFF_THRESHOLD", "AUTO_DIRTY_ON_THRESHOLD", "AUTO_DIRTY_REQUIRED_SAMPLES",
              "CHANGE_OBJECT_METRICS_EMA_ALPHA",
              "HERO_DEFENSE_SERVER_EVENTS",
              "AUTO_DIRTY_SAMPLE_EVERY",
              "ACTION_IN_FLIGHT_MAX_PER_SESSION", "RESOLVER_ABANDONED_ACTIONS_MAX",
              "RESOLVER_ABANDONED_ACTIONS_MAX_PER_LAND", "SERVER_INPUT_IN_FLIGHT_MAX_PER_LAND",
              "OUTBOUND_WRITER_MAX_BYTES", "JOIN_FLIP_BUDGET",
              "SYNC_LAG_RESYNC_MS", "SYNC_LAG_SLOW_CONSUMER_COUNT", "SYNC_LAG_SLOW_CONSUMER_WINDOW_MS",
              "SYNC_LAG_CLOSE_GRACE_MS", "SYNC_ACK_TIMEOUT_MS", "SYNC_ACK_FRESHNESS_MS")
# Listed since the 2026-11-09 rerun: a record from before then may lack these (see the docstring).
ADDED = ("ACTION_IN_FLIGHT_MAX_PER_SESSION", "RESOLVER_ABANDONED_ACTIONS_MAX",
         "SYNC_LAG_RESYNC_MS", "SYNC_LAG_SLOW_CONSUMER_COUNT", "SYNC_LAG_SLOW_CONSUMER_WINDOW_MS",
         "SYNC_LAG_CLOSE_GRACE_MS", "SYNC_ACK_TIMEOUT_MS", "SYNC_ACK_FRESHNESS_MS")
# Listed later than ADDED: since 2026-11-10/11 (#468, #489, the merge of exp/next, #507, #513). Records
# before then may lack them.
ADDED_LATER = ("USE_SYNC_TABLES", "ROW_ADDRESSING", "SYNC_STRATEGY", "OUTBOUND_WRITER_MAX_BYTES", "JOIN_FLIP_BUDGET",
                   "CHANGE_OBJECT_METRICS_EMA_ALPHA", "AUTO_DIRTY_SAMPLE_EVERY", "SERVER_INPUT_IN_FLIGHT_MAX_PER_LAND",
                   "RESOLVER_ABANDONED_ACTIONS_MAX_PER_LAND", "TYPED_LEAF_VALUES")


def record(environ=None):
    """{name: value or None} for every SERVER_ENV variable, as run.json's serverEnv."""
    environ = os.environ if environ is None else environ
    return {k: environ.get(k) for k in SERVER_ENV}


def failure(name, server_env):
    """None when every variable was recorded and unset; otherwise why the run can't be used."""
    if not isinstance(server_env, dict):
        return f"{name}: server environment not recorded (a run from before the shipped-path switch)"
    missing = [k for k in SERVER_ENV if k not in server_env and k not in ADDED and k not in ADDED_LATER]
    if missing:
        return f"{name}: server environment lacks {missing}"
    set_ = {k: v for k, v in server_env.items() if v is not None}
    if set_:
        return f"{name}: server environment set ({set_}); the tables are the shipped path and defaults"
    return None


if __name__ == "__main__":
    print(" ".join(SERVER_ENV))
    sys.exit(0)
