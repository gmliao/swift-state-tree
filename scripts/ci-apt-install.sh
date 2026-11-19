#!/usr/bin/env bash
# Installs apt packages in a CI container, retrying the index update and the install together.
#
# A mirror that is syncing serves index files whose size doesn't match its release file ("File
# has unexpected size … Mirror sync in progress?"), or drops the connection mid-download. Both
# fail the step with exit code 100. `Acquire::Retries` retries one download at once, which a
# syncing mirror fails again; the loop waits longer between whole attempts, so a later one finds
# the mirror consistent.
#
# A download can also stall without failing, and then apt never exits (#659). Each call is
# bounded by `timeout`, which sends TERM at its bound and KILL 10 s later, so a stalled attempt
# fails like a mirror error and the loop retries it. A killed install can leave dpkg
# half-configured, so each retry first runs `dpkg --configure -a`, bounded the same way; a
# failed repair is logged and the install that follows reports what is still wrong.
#
# Worst case: five attempts of (60 + 10) + (120 + 10) s, four repairs of 30 + 10 s, and
# 30 + 60 + 90 + 120 s of waits: 1,000 + 160 + 300 = 1,460 s (24 min 20 s). The steps that
# call this set `timeout-minutes: 26` (1,560 s), above it.
#
# Usage: scripts/ci-apt-install.sh <package>...
# Tests: scripts/test-ci-apt-install.sh (it shortens the bounds and the waits, in seconds, with
# CI_APT_UPDATE_TIMEOUT, CI_APT_INSTALL_TIMEOUT, CI_APT_DPKG_TIMEOUT, CI_APT_KILL_AFTER and
# CI_APT_RETRY_DELAY).
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <package>..." >&2
  exit 2
fi

attempts=5
update_timeout=${CI_APT_UPDATE_TIMEOUT:-60}
install_timeout=${CI_APT_INSTALL_TIMEOUT:-120}
dpkg_timeout=${CI_APT_DPKG_TIMEOUT:-30}
kill_after=${CI_APT_KILL_AFTER:-10}
retry_delay=${CI_APT_RETRY_DELAY:-30}
for attempt in $(seq 1 "$attempts"); do
  if [ "$attempt" -gt 1 ]; then
    timeout --kill-after="$kill_after" "$dpkg_timeout" dpkg --configure -a
    status=$?
    if [ "$status" -ne 0 ]; then
      echo "dpkg --configure -a failed or timed out (exit $status); installing anyway" >&2
    fi
  fi
  if timeout --kill-after="$kill_after" "$update_timeout" apt-get -o Acquire::Retries=3 update &&
     timeout --kill-after="$kill_after" "$install_timeout" apt-get -o Acquire::Retries=3 install -y "$@"; then
    exit 0
  fi
  if [ "$attempt" -lt "$attempts" ]; then
    delay=$((attempt * retry_delay))
    echo "apt attempt $attempt of $attempts failed or timed out; retrying in ${delay} s" >&2
    sleep "$delay"
  fi
done
echo "apt failed after $attempts attempts: $*" >&2
exit 1
