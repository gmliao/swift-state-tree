#!/usr/bin/env bash
# Tests for scripts/ci-apt-install.sh against stub apt-get and dpkg commands on PATH, with the
# bounds and the waits shortened. Each stub follows a plan, one word per call: `ok`, `fail`
# (exit 100, a mirror error), `hang` (sleeps far past the bound, #659) or `stubborn` (also ignores
# TERM, so only the KILL after `--kill-after` ends it). Each run of the helper has a deadline of
# its own, so a regression that hangs fails its case instead of the CI step.
# Usage: scripts/test-ci-apt-install.sh
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp=""
# A stub the helper failed to stop (a regression, or a `stubborn` one without KILL) outlives the
# deadline, and so can its child (`sleep`), whose command line names no stub. `timeout` starts its
# command in a process group of its own, so each stub that waits records its group in its case's
# `groups` file. Each case ends its own groups as soon as the helper returns, children included, and drops
# the file, so no group is signalled after its case (a group id can be reused). Never this script's
# own group.
end_groups() {
  local file=$1 own group
  [ -f "$file" ] || return 0
  own=$(ps -o pgid= $$ | tr -d ' ')
  while read -r group; do
    [ "$group" != "$own" ] && kill -KILL -- "-$group" 2>/dev/null
  done < <(sort -u "$file")
  rm -f "$file"
}
# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() {
  local file
  [ -n "$tmp" ] || return 0
  for file in "$tmp"/*/groups; do end_groups "$file"; done
  rm -rf "$tmp"
}
# The EXIT trap also runs when the script is interrupted or terminated (a CI cancel).
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
tmp="$(mktemp -d)"
fail=0
deadline=60
stub_path_prefix=""

mkdir -p "$tmp/bin"
for tool in apt-get dpkg; do
  cat > "$tmp/bin/$tool" <<'STUB'
#!/usr/bin/env bash
# TERM is ignored from the first line, so a `stubborn` stub ignores a TERM that arrives while it
# reads its plan; the other words restore it before they wait or exit. Until the word is known the
# stub runs builtins only and records its call first: a bound of 1 s must not end an `ok` stub
# that is slow to fork on a loaded runner (#821).
trap '' TERM
tool=${0##*/}
echo "$tool $*" >> "$APT_STUB_DIR/log"
read -r n < "$APT_STUB_DIR/$tool.calls"
n=$((n + 1))
echo "$n" > "$APT_STUB_DIR/$tool.calls"
word= i=0
while IFS= read -r line; do
  i=$((i + 1))
  if [ "$i" -eq "$n" ]; then word=$line; break; fi
done < "$APT_STUB_DIR/$tool.plan"
case "$word" in
  ok) exit 0 ;;
  hang) ps -o pgid= $$ | tr -d ' ' >> "$APT_STUB_GROUPS"; trap - TERM; exec sleep 600 ;;
  stubborn) ps -o pgid= $$ | tr -d ' ' >> "$APT_STUB_GROUPS"; while :; do sleep 1; done ;;
  *) exit 100 ;;
esac
STUB
  chmod +x "$tmp/bin/$tool"
done

# The calls the helper must make for an apt-get plan, in order: per attempt, `dpkg --configure -a`
# first (from the second attempt), then update, then install only if the update succeeded; it
# stops after the first install that succeeds, or after 5 attempts.
expected_calls() {
  local -a plan
  read -ra plan <<<"$1"
  local attempt next=0 word
  for attempt in 1 2 3 4 5; do
    [ "$attempt" -gt 1 ] && echo "dpkg --configure -a"
    echo "apt-get -o Acquire::Retries=3 update"
    word=${plan[$next]:-fail}; next=$((next + 1))
    [ "$word" = ok ] || continue
    echo "apt-get -o Acquire::Retries=3 install -y curl"
    word=${plan[$next]:-fail}; next=$((next + 1))
    [ "$word" = ok ] && return
  done
}

# name, expected exit, apt-get plan, dpkg plan, expected dpkg runs, max seconds, [required output]
case_() {
  local name=$1 want=$2 apt=$3 dpkg=$4 dpkgs=$5 limit=$6 pattern=${7:-} dir="$tmp/$1" rc=0 start elapsed runs calls
  mkdir -p "$dir" && : > "$dir/log"
  for tool in apt-get dpkg; do echo 0 > "$dir/$tool.calls"; done
  tr ' ' '\n' <<<"$apt" > "$dir/apt-get.plan"
  tr ' ' '\n' <<<"$dpkg" > "$dir/dpkg.plan"
  start=$SECONDS
  APT_STUB_DIR="$dir" APT_STUB_GROUPS="$dir/groups" PATH="${stub_path_prefix}$tmp/bin:$PATH" CI_APT_UPDATE_TIMEOUT=1 CI_APT_INSTALL_TIMEOUT=1 \
    CI_APT_DPKG_TIMEOUT=1 CI_APT_KILL_AFTER=1 CI_APT_RETRY_DELAY=0 \
    timeout --kill-after=5 "$deadline" bash "$root/scripts/ci-apt-install.sh" curl > "$dir/out" 2>&1 || rc=$?
  elapsed=$((SECONDS - start))
  end_groups "$dir/groups"
  runs=$(grep -c '^dpkg --configure -a$' "$dir/log")
  calls=ok; expected_calls "$apt" | diff -u - "$dir/log" > "$dir/calls.diff" || calls=wrong
  if [ "$rc" = "$want" ] && [ "$runs" = "$dpkgs" ] && [ "$calls" = ok ] && [ "$elapsed" -le "$limit" ] &&
     { [ -z "$pattern" ] || grep -qE -- "$pattern" "$dir/out"; }; then
    echo "ok   $name (exit $rc, ${elapsed} s)"
  else
    echo "FAIL $name: exit $rc (wanted $want; 124/137: the ${deadline} s deadline), dpkg --configure runs $runs (wanted $dpkgs), calls $calls, ${elapsed} s (limit $limit)${pattern:+, output /$pattern/}"
    sed 's/^/     /' "$dir/calls.diff" "$dir/out"; fail=1
  fi
}

case_ first-attempt-ok 0 "ok ok" "" 0 3
case_ mirror-error-then-ok 0 "fail ok ok" "ok" 1 3
case_ update-hangs-then-ok 0 "hang ok ok" "ok" 1 15
case_ install-hangs-then-ok 0 "ok hang ok ok" "ok" 1 15
# The TERM-ignoring cases: the KILL comes 1 s after the 1 s bound, so a good run takes about 2 s.
# Their ceiling is 6 s: without --kill-after nothing is bound to end the stub, and how long it
# survives depends on how `timeout` signals the group on that platform (#665), so the ceiling,
# not only the deadline, must catch it.
case_ install-ignores-term-then-ok 0 "ok stubborn ok ok" "ok" 1 6
case_ repair-hangs-then-ok 0 "fail ok ok" "hang" 1 15 'dpkg --configure -a failed or timed out \(exit 124\)'
case_ repair-ignores-term-then-ok 0 "fail ok ok" "stubborn" 1 6 'dpkg --configure -a failed or timed out \(exit 137\)'
case_ repair-fails-then-ok 0 "fail ok ok" "fail" 1 3 'dpkg --configure -a failed or timed out \(exit 100\)'
case_ every-attempt-hangs 1 "hang hang hang hang hang" "ok ok ok ok" 4 30 'apt failed after 5 attempts'

# slow-forks: each of basename, ps, tr, cat and sed is shimmed to sleep 3 s before exec-ing the
# real tool. With the old stub those forks happen before the log write; a 2 s kill (1 s bound +
# 1 s --kill-after) ends an ok or fail stub before it can record. With the fixed stub the ok and
# fail paths use only builtins, so the shims are never reached.
shim_dir="$tmp/shims"
mkdir -p "$shim_dir"
for _stool in basename ps tr cat sed; do
  _sreal="$(command -v "$_stool")"
  printf '#!/usr/bin/env bash\nsleep 3\nexec %s "$@"\n' "$_sreal" > "$shim_dir/$_stool"
  chmod +x "$shim_dir/$_stool"
done
stub_path_prefix="$shim_dir:"
case_ slow-forks 0 "fail ok ok" "ok" 1 3
stub_path_prefix=""

# No package: the usage text, and no apt-get call.
dir="$tmp/no-package-args"; mkdir -p "$dir" && : > "$dir/log" && echo 0 > "$dir/apt-get.calls"
rc=0; APT_STUB_DIR="$dir" APT_STUB_GROUPS="$dir/groups" PATH="$tmp/bin:$PATH" timeout --kill-after=5 "$deadline" bash "$root/scripts/ci-apt-install.sh" > "$dir/out" 2>&1 || rc=$?
if [ "$rc" = 2 ] && [ "$(cat "$dir/apt-get.calls")" = 0 ] && grep -q '^usage: .*ci-apt-install.sh <package>\.\.\.$' "$dir/out"; then
  echo "ok   usage without a package (exit 2, the usage text, no apt-get)"
else
  echo "FAIL usage without a package: exit $rc, apt-get calls $(cat "$dir/apt-get.calls")"; sed 's/^/     /' "$dir/out"; fail=1
fi
exit $fail
