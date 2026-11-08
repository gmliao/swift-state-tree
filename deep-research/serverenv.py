#!/usr/bin/env python3
"""The EncodingBenchmark server's environment: the variables that change what it sends or how it
syncs, for the topics that measure the shipped path (snapshot-baseline, entity-delta-baseline,
visibility).

- the sync path: USE_SNAPSHOT_FOR_SYNC, IN_TURN_SYNC;
- the wire knobs: PATH_INDEX, FIELD_MERGE, DYNAMIC_KEY_COMPRESSION;
- dirty tracking: ENABLE_DIRTY_TRACKING, the benchmark's own ENCODING_BENCHMARK_DIRTY_TRACKING,
  AUTO_DIRTY_*;
- hero-defense's server events: HERO_DEFENSE_SERVER_EVENTS (the benchmark's --no-server-events
  flag is the topics' switch, not this variable).

A topic's run.sh unsets them all (`unset $(python3 ../serverenv.py)`), so the benchmark's flags
and the shipped defaults decide. Its runmeta.py records them as run.json's serverEnv, collect.py
carries that into each result's meta.server_env, and regenerate.py refuses a run with any of them
set, or with none recorded (`failure`).

Usage: python3 serverenv.py   prints the names, space-separated, for run.sh's unset.
"""
import os
import sys

SERVER_ENV = ("USE_SNAPSHOT_FOR_SYNC", "IN_TURN_SYNC", "PATH_INDEX", "FIELD_MERGE", "DYNAMIC_KEY_COMPRESSION",
              "ENABLE_DIRTY_TRACKING", "ENCODING_BENCHMARK_DIRTY_TRACKING", "AUTO_DIRTY_TRACKING",
              "AUTO_DIRTY_OFF_THRESHOLD", "AUTO_DIRTY_ON_THRESHOLD", "AUTO_DIRTY_REQUIRED_SAMPLES",
              "HERO_DEFENSE_SERVER_EVENTS")


def record(environ=None):
    """{name: value or None} for every SERVER_ENV variable, as run.json's serverEnv."""
    environ = os.environ if environ is None else environ
    return {k: environ.get(k) for k in SERVER_ENV}


def failure(name, server_env):
    """None when every variable was recorded and unset; otherwise why the run can't be used."""
    if not isinstance(server_env, dict):
        return f"{name}: server environment not recorded (a run from before the shipped-path switch)"
    missing = [k for k in SERVER_ENV if k not in server_env]
    if missing:
        return f"{name}: server environment lacks {missing}"
    set_ = {k: v for k, v in server_env.items() if v is not None}
    if set_:
        return f"{name}: server environment set ({set_}); the tables are the shipped path and defaults"
    return None


if __name__ == "__main__":
    print(" ".join(SERVER_ENV))
    sys.exit(0)
