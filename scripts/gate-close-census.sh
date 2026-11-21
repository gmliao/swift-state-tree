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
# Usage: scripts/gate-close-census.sh [DIR]     (default: Sources)
#        scripts/gate-close-census.sh --self-test
set -euo pipefail

allowed='closeAndNoteOutsideTurn|runSyncPhaseInTurnResult|closeOutputs'

census() { # dir
  local dir="$1" status=0 found=0
  # One awk over every file: a process substitution per file runs out of descriptors in the
  # bash 3.2 macOS ships, after about 250 files.
  while IFS=$'\t' read -r file line fn; do
    found=$((found + 1))
    if [[ "$fn" =~ ^($allowed)$ ]]; then
      printf 'ok    %s:%s in %s\n' "$file" "$line" "$fn"
    else
      printf 'FAIL  %s:%s in %s: close the gate through closeAndNoteOutsideTurn or failOutsideTurn\n' "$file" "$line" "${fn:-<no function>}"
      status=1
    fi
  done < <(find "$dir" -name '*.swift' -print0 | sort -z | xargs -0 awk '
    FNR == 1 { fn = "" }
    # Comments are not code: a close named in a comment is not a call.
    { line = $0; sub(/\/\/.*/, "", line) }
    # A member or type declaration (indented at most 4 spaces) that is not a function resets
    # the enclosing name, so a close in a property or an init is not credited to the function
    # above it. A local inside a function body is indented deeper and keeps the function.
    line ~ /^( {0,4})([a-z@][A-Za-z@() ]* )?(var|let|init|deinit|subscript|struct|class|enum|actor|extension)[^A-Za-z0-9_]/ && line !~ /func / { fn = "" }
    # For each call: the nearest declaration above it.
    match(line, /func [A-Za-z_][A-Za-z0-9_]*/) { fn = substr(line, RSTART + 5, RLENGTH - 5) }
    line ~ /outputGate\.close\(/ { printf "%s\t%d\t%s\n", FILENAME, FNR, fn }
  ')
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
  rm "$tmp/Bad.swift"
  cat > "$tmp/Property.swift" <<'SWIFT'
func closeAndNoteOutsideTurn(_ failure: LandFailure) {}
var closer: () -> Void = { outputGate.close(failure) }
SWIFT
  if census "$tmp" > /dev/null; then echo "self-test: a close in a property after the helper passed"; exit 1; fi
  rm "$tmp/Property.swift"
  cat > "$tmp/Comment.swift" <<'SWIFT'
func sendEvent() async {
    // outputGate.close(failure) used to be here
}
SWIFT
  census "$tmp" > /dev/null || { echo "self-test: a close in a comment was counted"; exit 1; }
  echo "self-test: ok"
  exit 0
fi

census "${1:-Sources}"
