#!/usr/bin/env bash
# Installs apt packages in a CI container, retrying the index update and the install together.
#
# A mirror that is syncing serves index files whose size doesn't match its release file ("File
# has unexpected size … Mirror sync in progress?"), or drops the connection mid-download. Both
# fail the step with exit code 100. `Acquire::Retries` retries one download at once, which a
# syncing mirror fails again; the loop waits longer between whole attempts, so a later one finds
# the mirror consistent.
#
# Usage: scripts/ci-apt-install.sh <package>...
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <package>..." >&2
  exit 2
fi

attempts=5
for attempt in $(seq 1 "$attempts"); do
  if apt-get -o Acquire::Retries=3 update && apt-get -o Acquire::Retries=3 install -y "$@"; then
    exit 0
  fi
  if [ "$attempt" -lt "$attempts" ]; then
    delay=$((attempt * 30))
    echo "apt attempt $attempt of $attempts failed; retrying in ${delay} s" >&2
    sleep "$delay"
  fi
done
echo "apt failed after $attempts attempts: $*" >&2
exit 1
