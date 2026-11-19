#!/usr/bin/env bash
# Whether the nightly runs its tests. A scheduled run skips when the commit under test already
# passed a scheduled nightly. Only scheduled runs count: a dispatch or tag run on another ref
# must not make the next scheduled run skip main's HEAD. Dispatch and tag runs always run.
#
# Usage: scripts/nightly-gate.sh <event name> <sha>
# Prints run=true|false, and appends it to $GITHUB_OUTPUT when that is set. Needs `gh` with
# GH_TOKEN (actions: read) and GH_REPO.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <event name> <sha>" >&2
  exit 2
fi
event=$1
sha=$2
run=true
if [ "$event" = schedule ]; then
  last=$(gh run list --workflow nightly.yml --event schedule --status success --limit 1 \
    --json headSha --jq '.[0].headSha // ""')
  if [ "$last" = "$sha" ]; then
    run=false
    echo "skip: $sha already passed a scheduled nightly"
  else
    echo "last green scheduled nightly: ${last:-none}; testing $sha"
  fi
fi
echo "run=$run"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "run=$run" >> "$GITHUB_OUTPUT"
fi
