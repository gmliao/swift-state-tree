#!/usr/bin/env bash
# Census of the symbols #546 L2c deletes with the adapter's off mode
# (Notes/plans/2026-11-20-remove-adapter-off-mode.md §3.6).
#
# For each symbol: the readers at BASE (default: the merge base with origin/main), file by file,
# and how many are left at HEAD. A symbol L2c deletes must be left nowhere; the forwards L2c keeps
# until L2d are listed with their HEAD count, and fail if the adapter no longer declares them.
#
# Usage: scripts/l2c-census.sh [BASE]
set -euo pipefail

base="${1:-$(git merge-base HEAD origin/main)}"
paths=(Sources Tests Examples Tools)
forwards_file=Sources/SwiftStateTreeTransport/TransportAdapter+LandKeeperTransport.swift

# pattern|kept   (kept = the symbol stays through L2c; its HEAD count is reported, not required to be 0)
symbols=(
  'inTurnSync:|'
  'inTurnSyncEnabled|'
  'cycleBeforeEndSync|'
  'busyRetry|'
  'followUpSynced|'
  'SyncCycleHold|'
  'incrementSyncSkipsBusy|'
  'skipsBusy|'
  'syncSkips\.busy|'
  'syncDeferredByCycleCountForTesting|'
  'syncLagFullPlanRequested|'
  'syncLagResyncDue|'
  'deferSyncForOutboundBacklog|'
  'runBacklogDeferredSync|'
  'planBroadcastOnlySyncPhase|'
  'beginSyncLocatedIfRecording|'
  'withSyncState|'
  'syncNowFromTransport|kept'
  'syncBroadcastOnlyFromTransport|kept'
)

count_at() { # ref pattern
  { git grep -c -E "$2" "$1" -- "${paths[@]}" 2>/dev/null || true; } | awk -F: '{n+=$NF} END {print n+0}'
}

status=0
printf 'base %s, head %s\n\n' "$(git rev-parse --short "$base")" "$(git rev-parse --short HEAD)"
for entry in "${symbols[@]}"; do
  pattern="${entry%%|*}"
  kept="${entry#*|}"
  before=$(count_at "$base" "$pattern")
  after=$(count_at HEAD "$pattern")
  if [[ -n "$kept" ]]; then
    # A kept symbol still has protocol and test references, so its count alone proves nothing:
    # the adapter's own forward must be declared at HEAD.
    if git grep -q -E "func ${pattern}\(" HEAD -- "$forwards_file"; then
      verdict="kept until L2d"
    else
      verdict="FORWARD MISSING"
      status=1
    fi
  elif [[ "$after" -eq 0 ]]; then
    verdict="gone"
  else
    verdict="LEFT"
    status=1
  fi
  printf '%-36s base %4d  head %4d  %s\n' "$pattern" "$before" "$after" "$verdict"
  if [[ "$before" -gt 0 ]]; then
    { git grep -c -E "$pattern" "$base" -- "${paths[@]}" || true; } | sed -E "s#^[^:]+:#    #; s#:([0-9]+)\$# (\\1)#"
  fi
  if [[ "$verdict" == "LEFT" ]]; then
    { git grep -n -E "$pattern" HEAD -- "${paths[@]}" || true; } | sed -E 's#^HEAD:#    left: #'
  fi
done
exit "$status"
