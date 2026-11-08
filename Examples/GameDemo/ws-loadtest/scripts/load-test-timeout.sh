# shellcheck shell=bash
# Sourced by run-ws-loadtest.sh. The load test's timeout in seconds: the wait until `--start-at`,
# the scenario's phases, and the client's own end budget, so a slow end (workers busy at the
# phase end, a slow shutdown) writes its report before the wrapper kills the client:
# - per phase, its transition (closing the surplus, creating and connecting the clients);
# - the workers' shutdown reply (30 s), their exit (10 s) and the server profile wait (3 s),
#   the bounds in src/run.ts and src/server-sync.ts (tests/impair-script.test.ts checks them);
# - a margin for building and writing the report.
# load_test_timeout <phase seconds> <phase count> [<start-at epoch ms> <now epoch ms>]
LOAD_TEST_PHASE_TRANSITION_S=10
LOAD_TEST_SHUTDOWN_S=30
LOAD_TEST_WORKER_EXIT_S=10
LOAD_TEST_PROFILE_WAIT_S=3
LOAD_TEST_REPORT_MARGIN_S=15
load_test_timeout() {
  local phases="$1" count="$2" start_at="${3:-}" now="${4:-}" delay=0
  if [ -n "$start_at" ] && [ "$start_at" -gt "$now" ]; then
    delay=$(( (start_at - now + 999) / 1000 ))
  fi
  echo $(( delay + phases + count * LOAD_TEST_PHASE_TRANSITION_S + LOAD_TEST_SHUTDOWN_S + LOAD_TEST_WORKER_EXIT_S \
    + LOAD_TEST_PROFILE_WAIT_S + LOAD_TEST_REPORT_MARGIN_S ))
}
