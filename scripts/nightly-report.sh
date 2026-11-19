#!/usr/bin/env bash
# The nightly's report, for scheduled runs only: one open issue labeled nightly-failure.
#   failure: comment on the open issue, or open one, with the run, its failed jobs and the commits
#            since the last green scheduled nightly that this commit contains;
#   success: comment and close the open issue, if there is one and this commit contains the one
#            it was opened for (so a rerun of an older green run can't close a newer failure);
#   other (a cancelled or skipped half): nothing.
# The result comes from the jobs' results: a failed gate, or a failed build-and-test or e2e, is
# a failure; both calls passing is a success; anything else (cancelled, skipped) is other.
#
# Usage: scripts/nightly-report.sh <gate result> <build-and-test result> <e2e result> <sha> <run url>
#        (each result as Actions gives it: success, failure, cancelled or skipped)
# Needs `gh` with GH_TOKEN (issues: write, actions: read), GH_REPO and GITHUB_RUN_ID, and a
# checkout with history (fetch-depth: 0) for the commit list.
set -euo pipefail

if [ $# -ne 5 ]; then
  echo "usage: $0 <gate result> <build-and-test result> <e2e result> <sha> <run url>" >&2
  exit 2
fi
gate=$1
build=$2
e2e=$3
sha=$4
url=$5
case "$gate/$build/$e2e" in
  failure/*) result=failure ;;
  */failure/*|*/*/failure) result=failure ;;
  success/success/success) result=success ;;
  *) result=other ;;
esac
echo "gate: $gate, build-and-test: $build, e2e: $e2e -> $result"
label=nightly-failure
title="Nightly failing on main"
milestone="Test and CI reliability"
priority="priority: before-rerun"

if [ "$result" = other ]; then
  echo "report: the run neither passed nor failed (cancelled or skipped); nothing to report"
  exit 0
fi

open=$(gh issue list --label "$label" --state open --limit 1 --json number --jq '.[0].number // ""')

if [ "$result" = success ]; then
  if [ -n "$open" ]; then
    # The issue body starts "Nightly failed at <sha>:", the commit it was opened for.
    opened_at=$(gh issue view "$open" --json body --jq '.body' \
      | sed -n '1s/^Nightly failed at \([0-9a-f]\{40\}\):.*/\1/p')
    if [ -n "$opened_at" ] && ! git merge-base --is-ancestor "$opened_at" "$sha" 2>/dev/null; then
      echo "report: #$open was opened for $opened_at, which $sha doesn't contain (a rerun of an older run?); left open"
      exit 0
    fi
    gh issue comment "$open" --body "Green at $sha: $url"
    gh issue close "$open"
    echo "report: closed #$open"
  else
    echo "report: green, no open issue"
  fi
  exit 0
fi

# The baseline: the newest green scheduled run whose commit this one contains. The current run is
# still in progress, so it isn't listed; a rerun of an older run skips greens on later commits.
greens=$(gh run list --workflow nightly.yml --event schedule --status success --limit 20 \
  --json headSha --jq '.[].headSha')
last=""
while IFS= read -r candidate; do
  if [ -n "$candidate" ] && [ "$candidate" != "$sha" ] \
    && git merge-base --is-ancestor "$candidate" "$sha" 2>/dev/null; then
    last=$candidate
    break
  fi
done <<< "$greens"
# Every completed job that didn't pass: failed, cancelled or timed out. Not this report job: it
# is still in progress, and gh gives such a job `"conclusion": ""`, not null.
failed=$(gh run view "$GITHUB_RUN_ID" --json jobs \
  --jq '.jobs[] | select(.status == "completed" and .conclusion != "success" and .conclusion != "skipped") | "- \(.name) (\(.conclusion))"')
if [ -n "$last" ]; then
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
