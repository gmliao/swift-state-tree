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
  - Finds processes LISTENing on the given TCP port (macOS: lsof).
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

if ! command -v lsof >/dev/null 2>&1; then
  echo "Missing dependency: lsof" >&2
  exit 1
fi

get_pids() {
  # -t prints only PIDs; if nothing is listening, exits with 1, so we swallow errors.
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true
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
