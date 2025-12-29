#!/usr/bin/env bash
set -euo pipefail

# Change to repository root (this script lives in Tools/CLI)
cd "$(dirname "$0")/../.."

OUT_DIR="docs/performance"
ENABLE_SIZE=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --size)
      ENABLE_SIZE=1
      ;;
    *)
      POSITIONAL+=("$arg")
      ;;
  esac
done
if [ ${#POSITIONAL[@]} -gt 0 ]; then
  OUT_DIR="${POSITIONAL[0]}"
fi
DATE="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$OUT_DIR"

run_case() {
  local suite="$1"
  local dirty="$2"
  local encoding="$3"
  local out="$OUT_DIR/${suite}-dirty-${dirty}-${encoding}-${DATE}.txt"

  echo "Running: suite=${suite} dirty=${dirty} encoding=${encoding}"
  if [ "$ENABLE_SIZE" -eq 1 ]; then
    SST_TRANSPORT_SIZE_PROFILE=1 swift run -c release SwiftStateTreeBenchmarks "$suite" \
      "--dirty-${dirty}" \
      --no-wait \
      --csv \
      "--encoding=${encoding}" \
      > "$out"
  else
    swift run -c release SwiftStateTreeBenchmarks "$suite" \
      "--dirty-${dirty}" \
      --no-wait \
      --csv \
      "--encoding=${encoding}" \
      > "$out"
  fi
  echo "  -> $out"
}

for encoding in messagepack json; do
  for suite in transport-sync transport-sync-players; do
    for dirty in on off; do
      run_case "$suite" "$dirty" "$encoding"
    done
  done
done

echo ""
echo "Done. Timestamp: $DATE"
if [ "$ENABLE_SIZE" -eq 1 ]; then
  echo "Size profiling enabled (SST_TRANSPORT_SIZE_PROFILE=1)."
fi
