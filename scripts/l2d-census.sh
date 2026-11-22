#!/usr/bin/env bash
# Census for #546 L2d-2/L2d-3: every live keeper routes through turns, and the keeper's legacy
# pass and sync flag are gone (Notes/plans/2026-11-20-remove-adapter-off-mode.md §3.8.4,
# Notes/plans/2026-11-21-l2d3-delete-legacy-sync.md).
#
# 1. Symbol counts. Non-comment lines (first non-space characters not `//`) in Sources, Tests,
#    Examples and Tools, per file and symbol, at REF. scripts/l2d-census.allow lists
#    `path symbol count reason`; a count above the allowlist (an unlisted file allows 0) fails.
# 2. The migration list (§3.5): every keeper built outside the core tests, with whether its
#    builder passes `transport:` and whether the file attaches one later (`setTransport`). A keeper
#    with neither has no port: its inputs run as turns and its outputs are recorded, not delivered.
#    Core test files are counted per file.
#
# Usage: scripts/l2d-census.sh [REF]   (default HEAD; the revert check runs it at the base)
set -euo pipefail

# The pathspecs below are relative to the repository root, and a ref that doesn't resolve would
# make every count 0: either is an error, never a pass.
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || { echo "l2d-census: not in a git repository" >&2; exit 2; }
cd "$root"
ref="${1:-HEAD}"
git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || { echo "l2d-census: not a commit: $ref" >&2; exit 2; }
allow_file="scripts/l2d-census.allow"
[[ -f "$allow_file" ]] || { echo "l2d-census: missing $allow_file" >&2; exit 2; }
paths=(Sources Tests Examples Tools)

# name|pattern
symbols=(
  'syncNowFromTransport-call|\.syncNowFromTransport\('
  'syncBroadcastOnlyFromTransport-call|\.syncBroadcastOnlyFromTransport\('
  'syncNowFromTransport-decl|func syncNowFromTransport\('
  'syncBroadcastOnlyFromTransport-decl|func syncBroadcastOnlyFromTransport\('
  'usesInTurnSync|usesInTurnSync'
  'legacyCycle|\.legacyCycle([^A-Za-z0-9_]|$)'
  # Deleted in L2d-3: allowed nowhere.
  'beginSync|(^|[^A-Za-z0-9_])beginSync(Located)?\('
  'endSync|(^|[^A-Za-z0-9_])endSync\('
  'isSyncing|(^|[^A-Za-z0-9_])isSyncing([^A-Za-z0-9_]|$)'
  'syncInFlight|\.syncInFlight([^A-Za-z0-9_]|$)|case syncInFlight'
  'syncOnlyTurnAfterLegacyCycle|[sS]yncOnlyTurnAfterLegacyCycle'
  'legacyPass|runLegacyPass|finishTicklessLegacyPass|deliverLegacyPass|legacyDeliveries|runTicklessJobPass|legacyPass(Callers|Results|Owner|AppliedBy)'
  'legacyHoldPoints|\.(legacyShutdownPass|syncOnlyAfterLegacyCycle|legacyDelivery|ticklessJobPass)([^A-Za-z0-9_]|$)|case (legacyShutdownPass|syncOnlyAfterLegacyCycle|legacyDelivery|ticklessJobPass)'
)

# Prints `path count` for non-comment lines matching pattern at ref.
counts_at() { # ref pattern
  # git grep exits 1 for no match; any other failure prints its error (the ref is checked above).
  { git grep -n -E "$2" "$1" -- "${paths[@]}" || true; } |
    sed -E "s#^$1:##" |
    awk -F: '{ line = $0; sub(/^[^:]+:[0-9]+:/, "", line); if (line ~ /^[[:space:]]*\/\//) next; n[$1]++ }
             END { for (f in n) print f, n[f] }' |
    sort
}

allowed() { # path name
  awk -v p="$1" -v s="$2" '$1 == p && $2 == s { print $3; found = 1 } END { if (!found) print 0 }' \
    <(grep -v -E '^[[:space:]]*(#|$)' "$allow_file")
}

status=0
printf 'census at %s\n\n' "$(git rev-parse --short "$ref")"
for entry in "${symbols[@]}"; do
  name="${entry%%|*}"
  pattern="${entry#*|}"
  total=0
  report=""
  while read -r path count; do
    [[ -z "$path" ]] && continue
    total=$((total + count))
    limit=$(allowed "$path" "$name")
    if (( count > limit )); then
      report+="    OVER  $path: $count (allowed $limit)"$'\n'
      status=1
    fi
  done < <(counts_at "$ref" "$pattern")
  printf '%-40s %4d\n' "$name" "$total"
  printf '%s' "$report"
done

printf '\nMigration list: keepers built outside the core tests\n'
{ git grep -n -E 'LandKeeper(<[A-Za-z0-9_.]+>)?\($' "$ref" -- Sources Examples Tools 2>/dev/null || true
  git grep -n -E 'LandKeeper(<[A-Za-z0-9_.]+>)?\([a-z]' "$ref" -- Sources Examples Tools 2>/dev/null || true; } |
  sed -E "s#^$ref:##" | awk -F: '!seen[$1 FS $2]++' | sort -t: -k1,1 -k2,2n |
  while IFS=: read -r path line _; do
    content=$(git show "$ref:$path" </dev/null)
    # The builder's argument list: a call on one line ends there; otherwise at the first line
    # that starts with `)`.
    args=$(sed -n "${line},\$p" <<<"$content" |
      awk 'done { next } NR == 1 { print; if ($0 ~ /\)[[:space:]]*$/) done = 1; next } { print } /^[[:space:]]*\)/ { done = 1 }')
    if grep -q -E 'transport:[[:space:]]*nil' <<<"$args"; then port="transport: nil"
    elif grep -q -E 'transport:' <<<"$args"; then port="transport: argument"
    else port="no transport:"; fi
    if grep -q -E 'setTransport\(' <<<"$content"; then later="setTransport in file"; else later="never attached"; fi
    printf '  %s:%s  %s, %s\n' "$path" "$line" "$port" "$later"
  done

printf '\nCore tests: keepers built per file (no setTransport in the file = portless)\n'
{ git grep -c -E 'LandKeeper(<[A-Za-z0-9_.]+>)?\(' "$ref" -- Tests 2>/dev/null || true; } | sed -E "s#^$ref:##" |
  while IFS=: read -r path count; do
    content=$(git show "$ref:$path" </dev/null)
    if grep -q -E 'setTransport\(|transport:[[:space:]]*[A-Za-z(]' <<<"$content"; then kind="attaches"; else kind="portless"; fi
    printf '  %-80s %3d  %s\n' "$path" "$count" "$kind"
  done | sort -k3,3 -k1,1

exit "$status"
