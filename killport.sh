#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./killport.sh [port] [--force] [--dry-run]

Examples:
  ./killport.sh 8080
  ./killport.sh 8080 --dry-run
  ./killport.sh 8080 --force

Behavior:
  - Finds processes LISTENing on the given TCP port (lsof on macOS/most Linux, ss on Linux).
  - Sends SIGTERM first, waits briefly, then sends SIGKILL if still running.
  - With --force, skips SIGTERM and sends SIGKILL immediately.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

PORT="${1:-8080}"
shift $(( $# > 0 ? 1 : 0 ))

FORCE="0"
DRY_RUN="0"
for arg in "$@"; do
  case "$arg" in
    --force) FORCE="1" ;;
    --dry-run) DRY_RUN="1" ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "Invalid port: $PORT" >&2
  exit 2
fi

if ! command -v lsof >/dev/null 2>&1 && ! command -v ss >/dev/null 2>&1 && [[ ! -f /proc/net/tcp ]]; then
  echo "Missing dependency: lsof, ss, or /proc (install lsof: apt install lsof / brew install lsof)" >&2
  exit 1
fi

# Get PIDs listening on TCP port. Prefer lsof (macOS + most Linux); fallback to ss, then /proc (Linux).
get_pids() {
  if command -v lsof >/dev/null 2>&1; then
    # -t prints only PIDs; -sTCP:LISTEN filters to listening sockets (works on macOS and Linux).
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true
  elif command -v ss >/dev/null 2>&1; then
    # Linux: ss -tlnp shows listeners; extract PIDs from "pid=123" in the output.
    ss -tlnp 2>/dev/null | grep -E ":$PORT[^0-9]|:$PORT\$" | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | grep -E '^[0-9]+$' | sort -u || true
  elif [[ -f /proc/net/tcp ]]; then
    # Linux fallback: parse /proc/net/tcp for inode, then find pid via /proc/*/fd (avoids
    # per-process net/tcp which can show shared namespace and false positives).
    local hex_be hex_le inode
    hex_be=$(printf '%04X' "$PORT")
    hex_le=$(printf '%02X%02X' $((PORT & 0xFF)) $((PORT >> 8)))
    while read -r inode; do
      [[ -z "$inode" ]] || [[ "$inode" -lt 10000 ]] && continue
      for fd in /proc/[0-9]*/fd/*; do
        [[ -L "$fd" ]] || continue
        [[ "$(readlink "$fd" 2>/dev/null)" == "socket:[$inode]" ]] || continue
        pid=${fd#/proc/}; pid=${pid%%/*}
        echo "$pid"
      done 2>/dev/null
    done < <(awk -v be=":$hex_be" -v le=":$hex_le" '
      NR>1 && $4=="0A" && ($2 ~ be || $2 ~ le) { print $10 }
    ' /proc/net/tcp 2>/dev/null)
    sort -u || true
  fi
}

PIDS="$(get_pids)"
if [[ -z "$PIDS" ]]; then
  echo "No process is listening on TCP port $PORT."
  exit 0
fi

echo "Processes listening on TCP port $PORT:"
while IFS= read -r pid; do
  [[ -z "$pid" ]] && continue
  # Best-effort display of the command name.
  cmd="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
  if [[ -n "$cmd" ]]; then
    echo "  - PID $pid ($cmd)"
  else
    echo "  - PID $pid"
  fi
done <<<"$PIDS"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run: no processes killed."
  exit 0
fi

if [[ "$FORCE" == "1" ]]; then
  echo "Sending SIGKILL to PIDs..."
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    kill -KILL "$pid" 2>/dev/null || true
  done <<<"$PIDS"
else
  echo "Sending SIGTERM to PIDs..."
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    kill -TERM "$pid" 2>/dev/null || true
  done <<<"$PIDS"

  # Wait up to ~2s for graceful shutdown.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.2
    STILL="$(get_pids)"
    [[ -z "$STILL" ]] && break
  done

  STILL="$(get_pids)"
  if [[ -n "$STILL" ]]; then
    echo "Still listening after SIGTERM; sending SIGKILL..."
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      kill -KILL "$pid" 2>/dev/null || true
    done <<<"$STILL"
  fi
fi

if [[ -n "$(get_pids)" ]]; then
  echo "⚠️  Port $PORT still appears to be in use (you may need elevated privileges)." >&2
  exit 1
fi

echo "✅ Freed TCP port $PORT."
