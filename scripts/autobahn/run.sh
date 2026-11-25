#!/usr/bin/env bash
# Runs the Autobahn|Testsuite fuzzing client against Tools/AutobahnEcho, an echo server on the
# real NIOWebSocketServer (#798).
#
# Builds the harness (unless AUTOBAHN_ECHO_BIN names a built one), starts it on 127.0.0.1:9001,
# runs the suite's Docker image against it (--network host, so the container reaches the harness
# on the host's loopback), stops the harness and prints a summary of the report.
#
# The report is written to scripts/autobahn/reports/ (index.json, one JSON file and one HTML
# page per case; open reports/servers/index.html). The run is a gate on unlisted failures: the
# exit status is 0 when the suite ran, the report exists and every FAILED case is listed in
# expected-failures.txt (NON-STRICT and INFORMATIONAL cases never fail it; a listed case that
# passes is a warning). It is non-zero when the harness doesn't build or start (3, 4), the suite
# doesn't run (5, 6), the harness exits mid-suite (7), the index is partial (8, 9: summarize.py
# validates it), or a FAILED case isn't listed (10).
#
# Environment:
#   AUTOBAHN_ECHO_BIN   a built AutobahnEcho executable; skips the build.
#   AUTOBAHN_IMAGE      the suite's image (default: crossbario/autobahn-testsuite, by digest).
# Usage, from anywhere: scripts/autobahn/run.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
reports="$here/reports"
port=9001
image="${AUTOBAHN_IMAGE:-crossbario/autobahn-testsuite@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074}"

echo_bin="${AUTOBAHN_ECHO_BIN:-}"
if [[ -z "$echo_bin" ]]; then
    echo "autobahn: building Tools/AutobahnEcho"
    (cd "$root/Tools/AutobahnEcho" && swift build)
    echo_bin="$(cd "$root/Tools/AutobahnEcho" && swift build --show-bin-path)/AutobahnEcho"
fi
if [[ ! -x "$echo_bin" ]]; then
    echo "autobahn: the harness executable is missing: $echo_bin" >&2
    exit 3
fi

# The suite writes the whole report tree, so a stale one must not be mixed in.
rm -rf "$reports"
mkdir -p "$reports"

harness_log="$reports/harness.log"
"$echo_bin" "$port" >"$harness_log" 2>&1 &
harness_pid=$!
stop_harness() {
    if kill -0 "$harness_pid" 2>/dev/null; then
        kill -TERM "$harness_pid" 2>/dev/null || true
        # Bound the wait to 10 s, then force-kill.
        for _ in $(seq 1 20); do
            kill -0 "$harness_pid" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$harness_pid" 2>/dev/null; then
            echo "autobahn: harness did not stop after TERM; sending KILL" >&2
            kill -KILL "$harness_pid" 2>/dev/null || true
        fi
        wait "$harness_pid" 2>/dev/null || true
    fi
}
trap stop_harness EXIT

# Wait for the harness's own listening line: up to 60 s.
ready=0
for _ in $(seq 1 120); do
    if ! kill -0 "$harness_pid" 2>/dev/null; then
        break
    fi
    if grep -qF "AutobahnEcho listening" "$harness_log" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 0.5
done
if [[ "$ready" != 1 ]]; then
    echo "autobahn: the harness did not start listening on port $port" >&2
    cat "$harness_log" >&2 || true
    exit 4
fi
echo "autobahn: harness listening on 127.0.0.1:$port"

echo "autobahn: running $image"
if ! docker run --rm --network host \
    -v "$here:/config:ro" \
    -v "$reports:/reports" \
    "$image" \
    wstest -m fuzzingclient -s /config/fuzzingclient.json; then
    echo "autobahn: the suite did not run to the end" >&2
    exit 5
fi

# Fail distinctly when the harness exited before the suite finished.
if ! kill -0 "$harness_pid" 2>/dev/null; then
    echo "autobahn: the harness exited before the suite finished" >&2
    exit 7
fi

stop_harness
trap - EXIT

if [[ ! -f "$reports/servers/index.json" ]]; then
    echo "autobahn: the suite wrote no reports/servers/index.json" >&2
    exit 6
fi

python3 "$here/summarize.py" "$reports/servers/index.json" | tee "$reports/summary.txt"

# The gate: a FAILED case that expected-failures.txt doesn't list fails the run (exit 10).
gate=0
python3 "$here/summarize.py" "$reports/servers/index.json" \
    --check-expected "$here/expected-failures.txt" || gate=$?
if [[ "$gate" != 0 ]]; then
    echo "autobahn: the gate failed (exit $gate); see the summary above and reports/servers/index.html" >&2
    exit "$gate"
fi
