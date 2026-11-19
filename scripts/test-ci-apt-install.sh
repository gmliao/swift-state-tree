#!/usr/bin/env bash
# Tests for scripts/ci-apt-install.sh against stub apt-get and dpkg commands on PATH, with the
# bounds and the waits shortened. Each stub follows a plan, one word per call: `ok`, `fail`
# (exit 100, a mirror error), `hang` (sleeps far past the bound, #659) or `stubborn` (also ignores
# TERM, so only the KILL after `--kill-after` ends it). Each run of the helper has a deadline of
# its own, so a regression that hangs fails its case instead of the CI step.
# Usage: scripts/test-ci-apt-install.sh
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
# A stub the helper failed to stop (a regression, or a `stubborn` one without KILL) outlives the
# deadline: `timeout` starts its command in a process group of its own. End every process still
# running a stub from this directory.
trap 'pkill -KILL -f "$tmp/bin/" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
deadline=60

mkdir -p "$tmp/bin"
for tool in apt-get dpkg; do
  cat > "$tmp/bin/$tool" <<'STUB'
#!/usr/bin/env bash
tool=$(basename "$0")
n=$(( $(cat "$APT_STUB_DIR/$tool.calls") + 1 ))
echo "$n" > "$APT_STUB_DIR/$tool.calls"
echo "$tool $*" >> "$APT_STUB_DIR/log"
case "$(sed -n "${n}p" "$APT_STUB_DIR/$tool.plan")" in
  ok) exit 0 ;;
  hang) exec sleep 600 ;;
  stubborn) trap '' TERM; while :; do sleep 1; done ;;
  *) exit 100 ;;
esac
STUB
  chmod +x "$tmp/bin/$tool"
done

# name, expected exit, apt-get plan, dpkg plan, expected dpkg runs, max seconds, [required output]
case_() {
  local name=$1 want=$2 apt=$3 dpkg=$4 dpkgs=$5 limit=$6 pattern=${7:-} dir="$tmp/$1" rc=0 start elapsed runs
  mkdir -p "$dir" && : > "$dir/log"
  for tool in apt-get dpkg; do echo 0 > "$dir/$tool.calls"; done
  tr ' ' '\n' <<<"$apt" > "$dir/apt-get.plan"
  tr ' ' '\n' <<<"$dpkg" > "$dir/dpkg.plan"
  start=$SECONDS
  APT_STUB_DIR="$dir" PATH="$tmp/bin:$PATH" CI_APT_UPDATE_TIMEOUT=1 CI_APT_INSTALL_TIMEOUT=1 \
    CI_APT_DPKG_TIMEOUT=1 CI_APT_KILL_AFTER=1 CI_APT_RETRY_DELAY=0 \
    timeout --kill-after=5 "$deadline" bash "$root/scripts/ci-apt-install.sh" curl > "$dir/out" 2>&1 || rc=$?
  elapsed=$((SECONDS - start))
  runs=$(grep -c '^dpkg --configure -a$' "$dir/log")
  if [ "$rc" = "$want" ] && [ "$runs" = "$dpkgs" ] && [ "$elapsed" -le "$limit" ] &&
     { [ -z "$pattern" ] || grep -qE -- "$pattern" "$dir/out"; }; then
    echo "ok   $name (exit $rc, ${elapsed} s)"
  else
    echo "FAIL $name: exit $rc (wanted $want; 124/137: the ${deadline} s deadline), dpkg --configure runs $runs (wanted $dpkgs), ${elapsed} s (limit $limit)${pattern:+, output /$pattern/}"
    sed 's/^/     /' "$dir/log" "$dir/out"; fail=1
  fi
}

case_ first-attempt-ok 0 "ok ok" "" 0 3
case_ mirror-error-then-ok 0 "fail ok ok" "ok" 1 3
case_ update-hangs-then-ok 0 "hang ok ok" "ok" 1 15
case_ install-hangs-then-ok 0 "ok hang ok ok" "ok" 1 15
case_ install-ignores-term-then-ok 0 "ok stubborn ok ok" "ok" 1 15
case_ repair-hangs-then-ok 0 "fail ok ok" "hang" 1 15 'dpkg --configure -a failed or timed out \(exit 124\)'
case_ repair-ignores-term-then-ok 0 "fail ok ok" "stubborn" 1 15 'dpkg --configure -a failed or timed out \(exit 137\)'
case_ repair-fails-then-ok 0 "fail ok ok" "fail" 1 3 'dpkg --configure -a failed or timed out \(exit 100\)'
case_ every-attempt-hangs 1 "hang hang hang hang hang" "ok ok ok ok" 4 30 'apt failed after 5 attempts'

# No package: usage, and no apt-get call.
dir="$tmp/no-package-args"; mkdir -p "$dir" && : > "$dir/log" && echo 0 > "$dir/apt-get.calls"
rc=0; APT_STUB_DIR="$dir" PATH="$tmp/bin:$PATH" timeout "$deadline" bash "$root/scripts/ci-apt-install.sh" > /dev/null 2>&1 || rc=$?
if [ "$rc" = 2 ] && [ "$(cat "$dir/apt-get.calls")" = 0 ]; then echo "ok   usage without a package (exit 2, no apt-get)"; else echo "FAIL usage without a package: exit $rc"; fail=1; fi
exit $fail
