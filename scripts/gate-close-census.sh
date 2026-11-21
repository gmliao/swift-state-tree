#!/usr/bin/env bash
# Census of the places that close a land's output gate (#704;
# Notes/plans/2026-11-21-closed-gate-replies-and-pending-failure.md §2.2).
#
# A close outside a keeper turn must also note the failure on the keeper, so the keeper's next
# step ends the land before anything of that step goes out. Every such close goes through
# `closeAndNoteOutsideTurn` (or `failOutsideTurn`, which calls it). So `outputGate.close(` may
# appear only in the functions listed below:
#   closeAndNoteOutsideTurn   the helper itself
#   runSyncPhaseInTurnResult  an in-turn event loss: the keeper's turn gets .landFailed back
#   closeOutputs              the keeper's own failLand, already in its turn
# Any other function that calls it fails the census, naming the file, line and function.
#
# Usage: scripts/gate-close-census.sh [DIR]     (default: Sources/SwiftStateTreeTransport)
#        scripts/gate-close-census.sh --self-test
set -euo pipefail

allowed='closeAndNoteOutsideTurn|runSyncPhaseInTurnResult|closeOutputs'

census() { # dir
  local dir="$1" status=0 found=0
  while IFS= read -r file; do
    # For each call: the nearest `func` declaration above it.
    while IFS=$'\t' read -r line fn; do
      found=$((found + 1))
      if [[ "$fn" =~ ^($allowed)$ ]]; then
        printf 'ok    %s:%s in %s\n' "$file" "$line" "$fn"
      else
        printf 'FAIL  %s:%s in %s: close the gate through closeAndNoteOutsideTurn or failOutsideTurn\n' "$file" "$line" "${fn:-<no function>}"
        status=1
      fi
    done < <(awk '
      match($0, /func [A-Za-z_][A-Za-z0-9_]*/) { fn = substr($0, RSTART + 5, RLENGTH - 5) }
      /outputGate\.close\(/ && !/^[[:space:]]*\/\// { printf "%d\t%s\n", NR, fn }
    ' "$file")
  done < <(find "$dir" -name '*.swift' | sort)
  if [[ "$found" -eq 0 ]]; then
    echo "FAIL  no outputGate.close( found under $dir: the census looks in the wrong place"
    status=1
  fi
  return "$status"
}

if [[ "${1:-}" == "--self-test" ]]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/Good.swift" <<'SWIFT'
func closeAndNoteOutsideTurn(_ failure: LandFailure) {
    outputGate.close(failure)
}
SWIFT
  census "$tmp" > /dev/null || { echo "self-test: an allowed close was refused"; exit 1; }
  cat > "$tmp/Bad.swift" <<'SWIFT'
func sendEvent() async {
    outputGate.close(failure)
}
SWIFT
  if census "$tmp" > /dev/null; then echo "self-test: a close outside the helper passed"; exit 1; fi
  echo "self-test: ok"
  exit 0
fi

census "${1:-Sources/SwiftStateTreeTransport}"
