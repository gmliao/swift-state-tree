#!/usr/bin/env bash
# The nightly's report, for scheduled runs only: one open issue labeled nightly-failure.
#   failure: comment on the open issue, or open one, with the run, its failed jobs and the commits
#            since the last green scheduled nightly;
#   success: comment and close the open issue, if there is one;
#   other (a cancelled or skipped half): nothing.
#
# Usage: scripts/nightly-report.sh <success|failure|other> <sha> <run url>
# Needs `gh` with GH_TOKEN (issues: write, actions: read), GH_REPO and GITHUB_RUN_ID, and a
# checkout with history (fetch-depth: 0) for the commit list.
set -euo pipefail

if [ $# -ne 3 ]; then
  echo "usage: $0 <success|failure|other> <sha> <run url>" >&2
  exit 2
fi
result=$1
sha=$2
url=$3
label=nightly-failure
title="Nightly failing on main"
milestone="Test and CI reliability"
priority="priority: before-rerun"

case "$result" in
  success|failure) ;;
  other)
    echo "report: the run neither passed nor failed (cancelled or skipped); nothing to report"
    exit 0
    ;;
  *)
    echo "report: unknown result '$result'" >&2
    exit 2
    ;;
esac

open=$(gh issue list --label "$label" --state open --limit 1 --json number --jq '.[0].number // ""')

if [ "$result" = success ]; then
  if [ -n "$open" ]; then
    gh issue comment "$open" --body "Green at $sha: $url"
    gh issue close "$open"
    echo "report: closed #$open"
  else
    echo "report: green, no open issue"
  fi
  exit 0
fi

# The current run is still in progress, so this is the previous green scheduled run.
last=$(gh run list --workflow nightly.yml --event schedule --status success --limit 1 \
  --json headSha --jq '.[0].headSha // ""')
failed=$(gh run view "$GITHUB_RUN_ID" --json jobs \
  --jq '.jobs[] | select(.conclusion == "failure") | "- \(.name)"')
if [ -n "$last" ] && git cat-file -e "$last^{commit}" 2>/dev/null; then
  range="Commits since the last green scheduled nightly ($last):"
  commits=$(git log --oneline "$last..$sha")
else
  range="No green scheduled nightly to compare with; the last 20 commits:"
  commits=$(git log --oneline -20 "$sha")
fi
fence='```'
body=$(printf 'Nightly failed at %s: %s\n\nFailed jobs:\n%s\n\n%s\n\n%s\n%s\n%s\n' \
  "$sha" "$url" "${failed:-(none reported)}" "$range" "$fence" "${commits:-(none)}" "$fence")

if [ -n "$open" ]; then
  printf '%s\n' "$body" | gh issue comment "$open" --body-file -
  echo "report: commented on #$open"
else
  gh label create "$label" --color B60205 --description "The scheduled nightly is failing on main" --force
  printf '%s\n' "$body" | gh issue create --title "$title" --label "$label" --label bug \
    --label "$priority" --milestone "$milestone" --body-file -
  echo "report: opened an issue"
fi
