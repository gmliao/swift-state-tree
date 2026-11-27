#!/usr/bin/env bash
# Tests for scripts/pre-push-checks.sh, each case in a throwaway clone of this checkout's HEAD
# (with the working tree's pre-push-checks.sh, lint-text-encoding.py, check-plan-index.sh and
# check-turns-doc-blocks.py and solutions-index.py copied in),
# against that HEAD as the base.
# Usage: scripts/test-pre-push-checks.sh [case-name-regex]   (default: every case)
# The setup commands are strings eval'd in the clone, so their $variables are meant to stay
# unexpanded here (SC2016), and `zeros` is read only inside them (SC2034).
# shellcheck disable=SC2016,SC2034
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
only="${1:-}"

# A PATH where `shellcheck` is a stub that isn't found-like (no version, exit 127), as on a host
# without ShellCheck.
noshellcheck="$tmp/noshellcheck-bin"
mkdir -p "$noshellcheck"
printf '#!/bin/sh\nexit 127\n' > "$noshellcheck/shellcheck"
chmod +x "$noshellcheck/shellcheck"

# A PATH where `swift` is a stub that isn't found-like (exit 127), as on a host without a Swift
# toolchain.
noswift="$tmp/noswift-bin"
mkdir -p "$noswift"
printf '#!/bin/sh\nexit 127\n' > "$noswift/swift"
chmod +x "$noswift/swift"

case_() {  # name, expected exit, required output line (grep -E), setup command (run in the clone),
           # [PATH prefix], [GIT_DIR the checks inherit], [VAR=value the checks inherit],
           # [stdin mode]. The setup may write ref lines to "$stdinfile": they are the hook's stdin
           # (else empty). Mode "open-pipe": stdin is a pipe that stays open until the run ends,
           # as for `ssh host cmd` or a background job, and the run is bounded by `timeout`.
  local name=$1 want=$2 pattern=$3 setup=$4 prefix=${5:-} gitdir=${6:-} extraenv=${7:-} stdinmode=${8:-} dir="$tmp/$1" out rc=0
  local stdinfile="$tmp/$1.stdin" done="$tmp/$1.done"
  [ -z "$only" ] || [[ $1 =~ $only ]] || return 0
  git clone -q --shared --no-checkout "$root" "$dir" && git -C "$dir" checkout -q "$(git -C "$root" rev-parse HEAD)"
  cp "$root/scripts/pre-push-checks.sh" "$dir/scripts/pre-push-checks.sh"
  cp "$root/scripts/lint-text-encoding.py" "$dir/scripts/lint-text-encoding.py"
  cp "$root/scripts/check-plan-index.sh" "$dir/scripts/check-plan-index.sh"
  cp "$root/scripts/check-turns-doc-blocks.py" "$dir/scripts/check-turns-doc-blocks.py"
  cp "$root/scripts/solutions-index.py" "$dir/scripts/solutions-index.py"
  git -C "$dir" -c user.name=t -c user.email=t@t commit -q -am "pre-push-checks under test" --allow-empty
  base="$(git -C "$dir" rev-parse HEAD)"
  (cd "$dir" && eval "$setup")
  [ -f "$stdinfile" ] || : > "$stdinfile"
  if [ "$stdinmode" = open-pipe ]; then
    # The holder keeps the pipe open until the run is over (the done file), then ends: no orphan.
    out="$(cd "$dir" && timeout 240 env ${gitdir:+GIT_DIR="$gitdir"} ${extraenv:+"$extraenv"} PATH="${prefix:+$prefix:}$PATH" bash scripts/pre-push-checks.sh "$base" < <({ while [ ! -e "$done" ]; do sleep 1; done; } 2> /dev/null) 2>&1)" || rc=$?
    : > "$done"
  else
    out="$(cd "$dir" && env ${gitdir:+GIT_DIR="$gitdir"} ${extraenv:+"$extraenv"} PATH="${prefix:+$prefix:}$PATH" bash scripts/pre-push-checks.sh "$base" < "$stdinfile" 2>&1)" || rc=$?
  fi
  if [ "$rc" = "$want" ] && grep -qE -- "$pattern" <<<"$out"; then
    echo "ok   $name (exit $rc)"
  else
    echo "FAIL $name: exit $rc, wanted $want and /$pattern/"; echo "$out" | tail -15; fail=1
  fi
}

case_ unchanged 0 '^skip  deep-research and its readers' ':'
# A hook run from a linked worktree inherits GIT_DIR. Here it names an empty repository: a check
# that used it would find no merge base (exit 2).
git init -q --bare "$tmp/inherited.git"
case_ inherited-git-dir 0 '^pre-push-checks: passed' ':' '' "$tmp/inherited.git"
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
# The solutions index runs on every push, and an entry whose row is missing from the generated
# index fails it.
case_ solutions-index-runs 0 '^ok    solutions-index' ':'
case_ solutions-index-stale 1 '^FAIL  solutions-index' 'printf -- "---\ntitle: \"Probe\"\ndate: 2026-11-25\ntags:\n  - probe\n---\n# Probe\n" > Notes/solutions/2026-11-25-probe.md'
# A Swift block added to the Turns docs that no tested file contains (f515e11f turned main red so).
case_ turns-doc-block-untested 1 'README.md: a Swift block in no tested file, starting: let prePushProbe = 1' 'printf "\n\x60\x60\x60swift\nlet prePushProbe = 1\n\x60\x60\x60\n" >> docs/turns/README.md'
# The image pin runs on every push, and a .devcontainer-only digest drift fails it (Swift Build &
# Test ignores .devcontainer/**, so the Image pin workflow and this check are what see it).
case_ image-pin-runs 0 '^ok    image-pin' ':'
case_ devcontainer-digest-drift 1 '^FAIL  image-pin' 'sed -i.bak "1s/sha256:4ed5/sha256:0000/" .devcontainer/Dockerfile && rm .devcontainer/Dockerfile.bak'
# The variant test-selection check runs on every push, a TransportAdapter built without
# transportEnvConfig in a test target the variant run leaves out (rule R1; #790 slipped it past
# pre-push) fails it, and a host without Swift fails the topic instead of skipping it.
case_ variant-selection-runs 0 '^ok    variant-selection' ':'
case_ variant-selection-r1-violation 1 '^FAIL  variant-selection' 'printf "import Testing\n@testable import SwiftStateTreeTransport\n@Suite struct VariantProbe {\n    func make(_ keeper: LandKeeper<S>, _ transport: T) { _ = TransportAdapter<S>(keeper: keeper, transport: transport, landID: \"x\") }\n}\n" > Tests/SwiftStateTreeTests/VariantSelectionProbe.swift'
case_ variant-selection-without-swift 1 'swift not found on PATH' ':' "$noswift"
case_ gitignore-change-runs-ignore-readers 0 '^ok    multiroom-ignored' 'echo "# probe" >> .gitignore'
# A pre-push hook gets the pushed refs on stdin (#856). `mkcommit <file> <content>` makes a commit on
# top of the base and goes back to it, leaving the checkout clean and at the base; the commit's sha
# is $pushed. The checks must run on the pushed commit, not on the checkout.
mkcommit='mkcommit() { git checkout -q --detach && printf "$2" > "$1" && git add "$1" && git -c user.name=t -c user.email=t@t commit -q -m probe && pushed="$(git rev-parse HEAD)" && git checkout -q --detach "$(git rev-parse HEAD~1)"; }'
zeros=0000000000000000000000000000000000000000
case_ pushed-other-commit-fails 1 '^FAIL  shellcheck' "$mkcommit"'; mkcommit scripts/bad.sh "#!/usr/bin/env bash\ncd /nonexistent\necho hi\n" && echo "refs/heads/x $pushed refs/heads/x $zeros" > "$stdinfile"'
case_ pushed-other-commit-passes 0 '^pre-push-checks: passed \(the pushed commits' "$mkcommit"'; mkcommit scripts/probe.txt "probe\n" && echo "refs/heads/x $pushed refs/heads/x $zeros" > "$stdinfile"'
# HEAD is pushed, and a failing commit exists but isn't pushed: the checkout is what's checked.
case_ pushed-head-passes 0 '^pre-push-checks: passed$' "$mkcommit"'; mkcommit scripts/bad.sh "#!/usr/bin/env bash\ncd /nonexistent\n"; echo "refs/heads/x $(git rev-parse HEAD) refs/heads/x $zeros" > "$stdinfile"'
# Only a deleted ref: nothing is pushed, so a failing checkout doesn't matter.
case_ pushed-deletion-skipped 0 'is a deletion, nothing to check' 'printf "#!/usr/bin/env bash\ncd /nonexistent\n" > scripts/bad.sh; echo "(delete) $zeros refs/heads/x $zeros" > "$stdinfile"'
# A pushed commit that is not in the repository is refused.
case_ pushed-unknown-sha 2 'is not a commit here' 'echo "refs/heads/x 1234567890123456789012345678901234567890 refs/heads/x $zeros" > "$stdinfile"'
# An exported GIT_INDEX_FILE (a hook run by `git commit` or a rebase) lists another tree than the
# files on disk: the script drops it.
case_ inherited-index-file 0 '^ok    shellcheck' 'echo "# probe" >> scripts/pre-push-checks.sh' '' '' "GIT_INDEX_FILE=$tmp/no-such.index"
# Command-line use with a stdin that stays open (`ssh host cmd`, a background job, an agent without
# `< /dev/null`) must not wait for an end of input that never comes: no ref line within the first
# read's bound means command-line use, and the checkout is checked.
case_ open-stdin-pipe-checks-checkout 1 '^FAIL  shellcheck' 'printf "#!/usr/bin/env bash\ncd /nonexistent\necho hi\n" > scripts/bad.sh' '' '' '' open-pipe
# HEAD is pushed but the checkout has an uncommitted (here untracked) failing file: the pushed
# commit is what is checked, in a temporary worktree.
case_ pushed-dirty-head-checks-the-commit 0 '^pre-push-checks: passed \(the pushed commits' 'printf "#!/usr/bin/env bash\ncd /nonexistent\necho hi\n" > scripts/bad.sh; echo "refs/heads/x $(git rev-parse HEAD) refs/heads/x $zeros" > "$stdinfile"'
# HEAD is a pushed commit that fails a check, and the checkout carries an uncommitted fix: the push fails.
case_ pushed-dirty-head-commit-fails 1 '^FAIL  shellcheck' 'printf "#!/usr/bin/env bash\ncd /nonexistent\necho hi\n" > scripts/bad.sh && git add scripts/bad.sh && git -c user.name=t -c user.email=t@t commit -q -m bad && printf "#!/usr/bin/env bash\necho fixed\n" > scripts/bad.sh; echo "refs/heads/x $(git rev-parse HEAD) refs/heads/x $zeros" > "$stdinfile"'
exit $fail
