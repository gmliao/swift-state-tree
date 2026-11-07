# Sourced by run-ws-loadtest.sh. The load test's timeout in seconds: the scenario's phases plus
# 30 s, plus the wait until `--start-at`, which the client spends before its first phase.
# load_test_timeout <phase seconds> [<start-at epoch ms> <now epoch ms>]
load_test_timeout() {
  local phases="$1" start_at="${2:-}" now="${3:-}" delay=0
  if [ -n "$start_at" ] && [ "$start_at" -gt "$now" ]; then
    delay=$(( (start_at - now + 999) / 1000 ))
  fi
  echo $(( phases + 30 + delay ))
}
