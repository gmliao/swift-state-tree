#!/usr/bin/env bash
# Tests for scripts/pre-push-checks.sh, each case in a throwaway clone of this checkout's HEAD
# (with the working tree's pre-push-checks.sh copied in), against that HEAD as the base.
# Usage: scripts/test-pre-push-checks.sh
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

case_() {  # name, expected exit, required output line (grep -E), setup command (run in the clone)
  local name=$1 want=$2 pattern=$3 setup=$4 dir="$tmp/$1" out rc=0
  git clone -q --shared --no-checkout "$root" "$dir" && git -C "$dir" checkout -q "$(git -C "$root" rev-parse HEAD)"
  cp "$root/scripts/pre-push-checks.sh" "$dir/scripts/pre-push-checks.sh"
  git -C "$dir" -c user.name=t -c user.email=t@t commit -q -am "pre-push-checks under test" --allow-empty
  base="$(git -C "$dir" rev-parse HEAD)"
  (cd "$dir" && eval "$setup")
  out="$(cd "$dir" && bash scripts/pre-push-checks.sh "$base" 2>&1)" || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$pattern" <<<"$out"; then
    echo "ok   $name (exit $rc)"
  else
    echo "FAIL $name: exit $rc, wanted $want and /$pattern/"; echo "$out" | tail -15; fail=1
  fi
}

case_ unchanged 0 '^skip  deep-research, serverenv' ':'
case_ new-script-sc2164 1 '^FAIL  shellcheck' 'printf "#!/usr/bin/env bash\ncd /nonexistent\necho hi\n" > scripts/bad.sh'
case_ held-script-now-clean 1 'has no findings now' 'printf "#!/usr/bin/env bash\necho clean\n" > deep-research/visibility/run.sh'
case_ new-wall-clock-poll 1 '^FAIL  wall-clock' 'mkdir -p Tests/SwiftStateTreeTests && printf "import Testing\n@Test func poll() async {\n    let deadline = ContinuousClock.now + .seconds(1)\n    while ContinuousClock.now < deadline { await Task.yield() }\n}\n" > Tests/SwiftStateTreeTests/PrePushPollProbe.swift'
case_ sources-change-runs-serverenv 0 '^ok    serverenv' 'echo "// probe" >> Sources/SwiftStateTree/Support/EnvHelpers.swift'
exit $fail
