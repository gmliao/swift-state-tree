#!/usr/bin/env bash
# Runs the Autobahn|Testsuite fuzzing client against Tools/AutobahnEcho, an echo server on the
# real NIOWebSocketServer (#798).
#
# Builds the harness (unless AUTOBAHN_ECHO_BIN names a built one), starts it on 127.0.0.1:9001,
# runs the suite's Docker image against it (--network host, so the container reaches the harness
# on the host's loopback), stops the harness and prints a summary of the report.
#
# The report is written to scripts/autobahn/reports/ (index.json, one JSON file and one HTML
# page per case; open reports/servers/index.html). The exit status is 0 when the suite ran and
# the report exists, whatever the cases found: Autobahn failures are reported, not gated, yet.
# It is non-zero when the harness doesn't build or start, or the suite doesn't run.
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
        wait "$harness_pid" 2>/dev/null || true
    fi
}
trap stop_harness EXIT

# Wait for the listener: up to 60 s.
ready=0
for _ in $(seq 1 120); do
    if ! kill -0 "$harness_pid" 2>/dev/null; then
        break
    fi
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
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

stop_harness
trap - EXIT

if [[ ! -f "$reports/servers/index.json" ]]; then
    echo "autobahn: the suite wrote no reports/servers/index.json" >&2
    exit 6
fi

python3 "$here/summarize.py" "$reports/servers/index.json" | tee "$reports/summary.txt"
