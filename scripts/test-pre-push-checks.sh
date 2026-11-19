#!/usr/bin/env bash
# Tests for scripts/pre-push-checks.sh, each case in a throwaway clone of this checkout's HEAD
# (with the working tree's pre-push-checks.sh, lint-text-encoding.py, check-plan-index.sh and
# check-turns-doc-blocks.py copied in),
# against that HEAD as the base.
# Usage: scripts/test-pre-push-checks.sh
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

# A PATH where `shellcheck` is a stub that isn't found-like (no version, exit 127), as on a host
# without ShellCheck.
noshellcheck="$tmp/noshellcheck-bin"
mkdir -p "$noshellcheck"
printf '#!/bin/sh\nexit 127\n' > "$noshellcheck/shellcheck"
chmod +x "$noshellcheck/shellcheck"

case_() {  # name, expected exit, required output line (grep -E), setup command (run in the clone),
           # [PATH prefix]
  local name=$1 want=$2 pattern=$3 setup=$4 prefix=${5:-} dir="$tmp/$1" out rc=0
  git clone -q --shared --no-checkout "$root" "$dir" && git -C "$dir" checkout -q "$(git -C "$root" rev-parse HEAD)"
  cp "$root/scripts/pre-push-checks.sh" "$dir/scripts/pre-push-checks.sh"
  cp "$root/scripts/lint-text-encoding.py" "$dir/scripts/lint-text-encoding.py"
  cp "$root/scripts/check-plan-index.sh" "$dir/scripts/check-plan-index.sh"
  cp "$root/scripts/check-turns-doc-blocks.py" "$dir/scripts/check-turns-doc-blocks.py"
  git -C "$dir" -c user.name=t -c user.email=t@t commit -q -am "pre-push-checks under test" --allow-empty
  base="$(git -C "$dir" rev-parse HEAD)"
  (cd "$dir" && eval "$setup")
  out="$(cd "$dir" && PATH="${prefix:+$prefix:}$PATH" bash scripts/pre-push-checks.sh "$base" 2>&1)" || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$pattern" <<<"$out"; then
    echo "ok   $name (exit $rc)"
  else
    echo "FAIL $name: exit $rc, wanted $want and /$pattern/"; echo "$out" | tail -15; fail=1
  fi
}

case_ unchanged 0 '^skip  deep-research and its readers' ':'
case_ new-script-sc2164 1 '^FAIL  shellcheck' 'printf "#!/usr/bin/env bash\ncd /nonexistent\necho hi\n" > scripts/bad.sh'
case_ held-script-now-clean 1 'has no findings now' 'printf "#!/usr/bin/env bash\necho clean\n" > deep-research/visibility/run.sh'
case_ new-wall-clock-poll 1 '^FAIL  wall-clock' 'mkdir -p Tests/SwiftStateTreeTests && printf "import Testing\n@Test func poll() async {\n    let deadline = ContinuousClock.now + .seconds(1)\n    while ContinuousClock.now < deadline { await Task.yield() }\n}\n" > Tests/SwiftStateTreeTests/PrePushPollProbe.swift'
case_ markdown-only-without-shellcheck 0 '^skip  shellcheck \(no shell file changed\)' 'echo "probe" >> Notes/plans/README.md' "$noshellcheck"
case_ script-change-without-shellcheck 1 'CI pins 0.11.0' 'echo "# probe" >> scripts/pre-push-checks.sh' "$noshellcheck"
case_ new-unencoded-text-read 1 '^FAIL  text-encoding' 'printf "from pathlib import Path\nprint(Path(\"x\").read_text())\n" > deep-research/encoding_probe.py'
case_ sources-change-runs-serverenv 0 '^ok    serverenv' 'echo "// probe" >> Sources/SwiftStateTree/Support/EnvHelpers.swift'
# A shell script outside deep-research/ reaches the pipefail-reader check (#608's examples failure
# got through when only deep-research/ triggered it). The check reads tracked scripts, as a push
# carries them, so the probe is added.
case_ script-pipefail-reader 1 '^FAIL  pipefail-readers' 'printf "#!/usr/bin/env bash\nset -o pipefail\nyes | head -1\n" > scripts/pipefail-probe.sh && git add scripts/pipefail-probe.sh'
case_ sync-lag-default-change 1 '^FAIL  sync-lag-defaults' 'sed -i.bak "s/resyncAfter: Duration = .seconds(3)/resyncAfter: Duration = .seconds(4)/" Sources/SwiftStateTreeTransport/SyncLag.swift && rm Sources/SwiftStateTreeTransport/SyncLag.swift.bak'
# A union merge of the plan index keeps both versions of a row one side changed.
case_ plan-index-duplicate-row 1 '^FAIL  plan-index' 'grep -m1 "^| .*\\](2026-" Notes/plans/README.md >> Notes/plans/README.md'
# A Swift block added to the Turns docs that no tested file contains (f515e11f turned main red so).
case_ turns-doc-block-untested 1 '^FAIL  turns-doc-blocks' 'printf "\n\x60\x60\x60swift\nlet prePushProbe = 1\n\x60\x60\x60\n" >> docs/turns/README.md'
case_ gitignore-change-runs-ignore-readers 0 '^ok    multiroom-ignored' 'echo "# probe" >> .gitignore'
exit $fail
