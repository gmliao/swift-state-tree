#!/usr/bin/env bash
# Fails on new wall-clock polls in the Swift tests (Tests/, Examples/*/Tests), #457.
#
# A test that polls state against a deadline fails on a loaded runner while the order it asserts
# holds (#447). Tests wait on the event the code reports, or step a clock
# (Notes/solutions/2026-11-05-hold-points-not-timing-in-race-tests.md). Rules, per line:
#
#   clock-poll  a `while`, `guard` or `if` comparing `ContinuousClock.now`, `Date()` or a
#               `clock.now`.
#   yield-poll  a loop whose body spins on `Task.yield()`.
#   sleep-poll  `Task.sleep` or `safeTaskSleep` inside a `while`, `repeat` or `for … in` loop.
#   poll-helper a call to `pollUntil`, the shared condition poll (its own loop is marked). Prefer
#               an event (`TestGate`, `HoldPoints`); a new call needs a stated reason, like any
#               raised count (for example "no event to await").
#   helper-poll a call to a function of the same file whose body has a `sleep-poll` hit (#472):
#               the file's own polling helper. Its loop is one `sleep-poll` hit however many
#               tests call it, so each call counts too. Two passes per file: the helpers are
#               collected first, so a call above the declaration counts. `pollUntil` keeps its
#               own rule. Direct calls only: a function that calls a helper isn't a helper
#               itself. A helper whose loop is marked isn't collected.
#
# A `for … in` loop counts as a loop: a poll spelled `for _ in 0..<N { if done { break }; sleep }`
# is the same wait with its deadline as an iteration count. Loops are tracked by brace depth.
# String literals (one-line and `"""` multi-line) and comments are ignored; raw strings
# (`#"…"#`) and `/* */` block comments are not recognized.
#
# A deliberate site carries `// wall-clock: <reason>`, with a non-empty reason, in a comment on
# the line or on a comment line directly above it; a marked loop allows every line inside it.
#
# Ratchet: scripts/wall-clock-baseline.txt holds the existing hits as `<file> <rule> <count>`.
# A count above its baseline (a file not listed counts 0) fails, with the new lines. A count
# below its baseline fails too, until the baseline is lowered in the same change (#458 burns
# it down). Raising the baseline passes, but loudly: with --base-baseline <file> (the base
# branch's copy), every count raised over it prints `BASELINE RAISED: <file> <rule> a→b` and a
# CI warning, and the PR states the reason.
#
# Usage: scripts/lint-wall-clock-tests.sh [--self-test | --write-baseline] [--base-baseline <file>] [repo root]

set -euo pipefail

BASELINE_REL='scripts/wall-clock-baseline.txt'

# Prints `file:line: [rule] text` for every unmarked hit in the files named on stdin, one per
# line, relative to the current directory. With mode `collect`, prints `file<TAB>name` instead
# for every function whose body has an unmarked `sleep-poll` hit; mode `scan` reads those pairs
# from the file $2 and reports calls to them as `helper-poll`.
scan_files() {
  # shellcheck disable=SC2016 # awk program, not shell
  xargs awk -v mode="$1" -v helpers_file="${2:-}" '
    BEGIN {
      if (helpers_file != "") {
        while ((getline pair < helpers_file) > 0) {
          split(pair, kv, "\t")
          helpers[kv[1]] = helpers[kv[1]] " " kv[2]
        }
      }
    }
    # Whether `code` calls one of the file`s polling helpers (not its declaration).
    function calls_helper(code,    names, n, i, name) {
      if (!(FILENAME in helpers)) return 0
      n = split(helpers[FILENAME], names, " ")
      for (i = 1; i <= n; i++) {
        name = names[i]
        if (code ~ ("(^|[^A-Za-z0-9_])" name "[ \t]*[({]") && code !~ ("func[ \t]+" name "([^A-Za-z0-9_]|$)")) return 1
      }
      return 0
    }
    # Splits a line, with string literals emptied, into code (`c`) and its trailing comment (`cm`).
    function split_line(s,    i) {
      gsub(/"([^"\\]|\\.)*"/, "\"\"", s)
      i = index(s, "//")
      if (i) { c = substr(s, 1, i - 1); cm = substr(s, i) } else { c = s; cm = "" }
    }
    # A marker: `// wall-clock:` followed by a non-empty reason, in the comment part only.
    function has_marker(comment) { return comment ~ /^\/\/[ \t]*wall-clock:[ \t]*[^ \t]/ }
    FNR == 1 { depth = 0; nloops = 0; prevMark = 0; inML = 0; nfuncs = 0 }
    {
      raw = $0
      # A multi-line `"""` literal: its lines are string, not code. Keep the code before an
      # opening `"""` and after a closing one.
      line = raw
      if (inML) {
        i = index(line, "\"\"\"")
        if (!i) next
        line = substr(line, i + 3); inML = 0
      }
      n = gsub(/"""/, "\"\"\"", line)
      if (n % 2 == 1) { i = index(line, "\"\"\""); line = substr(line, 1, i - 1); inML = 1 }
      split_line(line)
      code = c
      marked = prevMark || has_marker(cm)
      if (code ~ /^[ \t]*$/ && cm != "") { prevMark = marked; next }
      prevMark = 0
      inMarked = 0
      for (i = 1; i <= nloops; i++) if (loopMarked[i]) inMarked = 1
      isLoop = (code ~ /(^|[^A-Za-z0-9_.])(while|repeat)([^A-Za-z0-9_]|$)/) || (code ~ /(^|[^A-Za-z0-9_.])for[ \t].*[ \t]in[ \t]/)
      # A function declaration: its body is open while the depth stays above the line`s depth. A
      # declaration without a body (a protocol requirement) goes when its enclosing scope closes.
      if (match(code, /(^|[^A-Za-z0-9_])func[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
        decl = substr(code, RSTART, RLENGTH); sub(/^.*func[ \t]+/, "", decl)
        nfuncs++; funcName[nfuncs] = decl; funcDepth[nfuncs] = depth; funcOpened[nfuncs] = 0; funcLine[nfuncs] = FNR
      }
      rule = ""
      if (code ~ /(^|[^A-Za-z0-9_.])pollUntil[ \t]*[({]/ && code !~ /func[ \t]+pollUntil/) rule = "poll-helper"
      else if (mode == "scan" && calls_helper(code)) rule = "helper-poll"
      else if (code ~ /(^|[^A-Za-z0-9_.])(while|guard|if)[ (!].*(ContinuousClock\.now|Date\(\)|[A-Za-z]*[cC]lock\.now)/) rule = "clock-poll"
      else if (isLoop && code ~ /\{[ \t]*(await[ \t]+)?Task\.yield\(\)[ \t]*\}/) rule = "yield-poll"
      else if (code ~ /(Task\.sleep|safeTaskSleep)\(/ && (nloops > 0 || isLoop)) rule = "sleep-poll"
      else if (code ~ /^[ \t]*(await[ \t]+)?Task\.yield\(\)/ && nloops > 0) rule = "yield-poll"
      if (rule != "" && !marked && !inMarked) {
        if (mode == "collect") {
          # The innermost open function polls, one whose body opens on this line included;
          # `pollUntil` has its own rule.
          for (i = nfuncs; i > 0 && !funcOpened[i] && !(funcLine[i] == FNR && code ~ /\{/); i--) ;
          if (rule == "sleep-poll" && i > 0 && funcName[i] != "pollUntil" && !((FILENAME, funcName[i]) in seen)) {
            seen[FILENAME, funcName[i]] = 1
            print FILENAME "\t" funcName[i]
          }
        } else {
          text = raw; sub(/^[ \t]+/, "", text)
          print FILENAME ":" FNR ": [" rule "] " text
        }
      }
      opens = gsub(/\{/, "{", code); closes = gsub(/\}/, "}", code)
      if (isLoop && opens > closes) { nloops++; loopDepth[nloops] = depth + opens - closes; loopMarked[nloops] = marked }
      depth += opens - closes
      while (nloops > 0 && depth < loopDepth[nloops]) nloops--
      if (nfuncs > 0 && !funcOpened[nfuncs] && depth > funcDepth[nfuncs]) funcOpened[nfuncs] = 1
      while (nfuncs > 0 && ((funcOpened[nfuncs] && depth <= funcDepth[nfuncs]) || depth < funcDepth[nfuncs])) nfuncs--
    }'
}

# Prints the hits under the repository root $1, sorted.
scan() {
  local tmp
  tmp=$(mktemp -d)
  (
    cd "$1"
    {
      [[ -d Tests ]] && find Tests -name '*.swift' -not -path '*/.build/*'
      [[ -d Examples ]] && find Examples -path 'Examples/*/Tests/*' -name '*.swift' -not -path '*/.build/*'
    } | LC_ALL=C sort | { grep . || true; } > "$tmp/files"
    if [[ -s "$tmp/files" ]]; then
      scan_files collect < "$tmp/files" > "$tmp/helpers"
      scan_files scan "$tmp/helpers" < "$tmp/files"
    fi
  ) | LC_ALL=C sort -t: -k1,1 -k2,2n
  rm -rf "$tmp"
}

# Reads hits on stdin; prints `file rule count` per file and rule, sorted.
counts() {
  awk '{ file = $0; sub(/:.*/, "", file); rule = $0; sub(/^[^[]*\[/, "", rule); sub(/\].*/, "", rule); n[file " " rule]++ }
       END { for (k in n) print k, n[k] }' | LC_ALL=C sort
}

# Reads a baseline file, dropping comments and blank lines.
baseline_entries() {
  [[ -f $1 ]] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$1" | LC_ALL=C sort || true
}

lint() {
  local root=$1 base_baseline=$2 hits current baseline status=0
  hits=$(scan "$root")
  current=$(printf '%s\n' "$hits" | { grep . || true; } | counts)
  baseline=$(baseline_entries "$root/$BASELINE_REL")

  # Per file and rule: above the baseline fails with the lines; below it fails until lowered.
  local report
  report=$(join -a1 -a2 -e 0 -o 0,1.2,2.2 \
             <(printf '%s\n' "$current" | awk 'NF { print $1 "|" $2, $3 }' | LC_ALL=C sort) \
             <(printf '%s\n' "$baseline" | awk 'NF { print $1 "|" $2, $3 }' | LC_ALL=C sort) |
           awk '{ split($1, k, "|"); if ($2 > $3) print "over", k[1], k[2], $3, $2; else if ($2 < $3) print "under", k[1], k[2], $3, $2 }')
  if [[ -n $report ]]; then
    while read -r kind file rule was now; do
      if [[ $kind == over ]]; then
        echo "::error file=$file::$file: $now $rule hit(s), baseline $was. Wait on an event or a stepped clock, not on time; a deliberate site carries // wall-clock: <reason>"
        printf '%s\n' "$hits" | grep -F "$file:" | grep -F "[$rule]" || true
      else
        echo "::error file=$file::$file: $now $rule hit(s), baseline $was: lower $BASELINE_REL to $now in this change (scripts/lint-wall-clock-tests.sh --write-baseline)"
      fi
      status=1
    done <<< "$report"
  fi

  # Raises over the base branch's baseline: loud, not failing.
  if [[ -n $base_baseline ]]; then
    local raised
    raised=$(join -a1 -e 0 -o 0,1.2,2.2 \
               <(printf '%s\n' "$baseline" | awk 'NF { print $1 "|" $2, $3 }' | LC_ALL=C sort) \
               <(baseline_entries "$base_baseline" | awk 'NF { print $1 "|" $2, $3 }' | LC_ALL=C sort) |
             awk '{ split($1, k, "|"); if ($2 > $3) print k[1], k[2], $3, $2 }')
    if [[ -n $raised ]]; then
      while read -r file rule was now; do
        echo "BASELINE RAISED: $file $rule ${was}→${now}"
        echo "::warning file=$BASELINE_REL,title=Wall-clock baseline raised::$file $rule ${was}→${now}. State the reason in the PR body (Baseline raised: <reason>)."
      done <<< "$raised"
    fi
  fi

  local total
  total=$(printf '%s\n' "$hits" | grep -c . || true)
  echo "lint-wall-clock-tests: $total hit(s), $(printf '%s\n' "$baseline" | awk 'NF { s += $3 } END { print s + 0 }') in the baseline"
  return $status
}

write_baseline() {
  local root=$1
  {
    echo "# Wall-clock polls in tests that predate the check (#457), as <file> <rule> <count>."
    echo "# Counts only go down: rewrite a poll to wait on an event (#458), then lower its count."
    echo "# Regenerate with scripts/lint-wall-clock-tests.sh --write-baseline."
    scan "$root" | counts
  } > "$root/$BASELINE_REL"
  echo "wrote $BASELINE_REL"
}

self_test() {
  local tmp out status
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/t/Tests/A" "$tmp/t/Examples/G/Tests/B" "$tmp/t/Examples/G/Sources" "$tmp/t/scripts"
  cat > "$tmp/t/Tests/A/Polls.swift" <<'SWIFT'
func a() async {
    while ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    guard try await withinDeadline("x", { () async -> Void in
        while await !keeper.isDone() { await Task.yield() }
    }) != nil else { return }
    repeat {
        await Task.yield()
    } while !done
    while Date() < end { }
    // wall-clock: a hang guard, far past any stall
    while !(await condition()), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    while true { try await safeTaskSleep(for: .seconds(60)) } // wall-clock: stuck until cancelled
    try await Task.sleep(for: .milliseconds(5))
    let s = "while ContinuousClock.now < x { }"
    // while ContinuousClock.now < deadline {
    for x in xs { try await Task.sleep(for: .milliseconds(1)) }
    for _ in 0..<20 { await Task.yield() }
    while Date() < end { } // see "// wall-clock: in a string"
    while Date() < end { } // wall-clock:
    let fixture = """
        while Date() < end { await Task.yield() } {
        """
    try await Task.sleep(for: .milliseconds(5))
    for frame in frames(for: x) { send(frame) }
    try #require(await pollUntil { done })
}
func pollUntil(_ condition: () async -> Bool) async -> Bool { true }
SWIFT
  # A file's own polling helper (#472): each call counts, the first one above the declaration.
  cat > "$tmp/t/Tests/A/Helpers.swift" <<'SWIFT'
func early() async {
    await waitFor(3)
}
private func waitFor(_ n: Int) async {
    while count < n {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
func quiet() { while busy { step() } }
protocol Waits {
    func wait()
}
func callers() async {
    await waitFor(1)
    await fixture.waitFor(2)
    await waitFor(4) // wall-clock: a hang guard
    quiet()
    let waitForLabel = "waitFor(5)"
}
func outer() async {
    func inner() async { while busy { try? await Task.sleep(for: .seconds(1)) } }
    await inner()
}
func user() async { await outer() }
func guarded() async {
    // wall-clock: a hang guard, far past any stall
    while !done {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
func guardedUser() async { await guarded() }
SWIFT
  printf '%s\n' 'while clock.now < deadline { await Task.yield() }' > "$tmp/t/Examples/G/Tests/B/E.swift"
  printf '%s\n' 'while ContinuousClock.now < deadline { }' > "$tmp/t/Examples/G/Sources/NotATest.swift"
  local expected
  expected=$(cat <<'OUT'
Examples/G/Tests/B/E.swift:1: [clock-poll] while clock.now < deadline { await Task.yield() }
Tests/A/Helpers.swift:2: [helper-poll] await waitFor(3)
Tests/A/Helpers.swift:6: [sleep-poll] try? await Task.sleep(for: .milliseconds(5))
Tests/A/Helpers.swift:14: [helper-poll] await waitFor(1)
Tests/A/Helpers.swift:15: [helper-poll] await fixture.waitFor(2)
Tests/A/Helpers.swift:21: [sleep-poll] func inner() async { while busy { try? await Task.sleep(for: .seconds(1)) } }
Tests/A/Helpers.swift:22: [helper-poll] await inner()
Tests/A/Polls.swift:2: [clock-poll] while ContinuousClock.now < deadline {
Tests/A/Polls.swift:3: [sleep-poll] try? await Task.sleep(for: .milliseconds(5))
Tests/A/Polls.swift:6: [yield-poll] while await !keeper.isDone() { await Task.yield() }
Tests/A/Polls.swift:9: [yield-poll] await Task.yield()
Tests/A/Polls.swift:11: [clock-poll] while Date() < end { }
Tests/A/Polls.swift:20: [sleep-poll] for x in xs { try await Task.sleep(for: .milliseconds(1)) }
Tests/A/Polls.swift:21: [yield-poll] for _ in 0..<20 { await Task.yield() }
Tests/A/Polls.swift:22: [clock-poll] while Date() < end { } // see "// wall-clock: in a string"
Tests/A/Polls.swift:23: [clock-poll] while Date() < end { } // wall-clock:
Tests/A/Polls.swift:29: [poll-helper] try #require(await pollUntil { done })
OUT
)
  out=$(scan "$tmp/t")
  if [[ "$out" != "$expected" ]]; then
    echo "lint-wall-clock-tests self-test FAILED: scan"; echo "--- got"; echo "$out"; echo "--- expected"; echo "$expected"
    return 1
  fi

  # The baseline as written passes.
  write_baseline "$tmp/t" > /dev/null
  set +e; out=$(lint "$tmp/t" ""); status=$?; set -e
  if [[ $status -ne 0 || "$out" != "lint-wall-clock-tests: 17 hit(s), 17 in the baseline" ]]; then
    echo "lint-wall-clock-tests self-test FAILED: at the baseline (exit $status)"; echo "$out"
    return 1
  fi

  # A new poll fails and prints its line.
  cp -R "$tmp/t" "$tmp/over"
  printf '%s\n' 'while ContinuousClock.now < later { }' >> "$tmp/over/Tests/A/Polls.swift"
  set +e; out=$(lint "$tmp/over" ""); status=$?; set -e
  if [[ $status -eq 0 ]] || ! grep -q '^::error file=Tests/A/Polls.swift::Tests/A/Polls.swift: 5 clock-poll hit(s), baseline 4' <<< "$out" \
     || ! grep -qF 'Tests/A/Polls.swift:32: [clock-poll] while ContinuousClock.now < later { }' <<< "$out"; then
    echo "lint-wall-clock-tests self-test FAILED: a new poll (exit $status)"; echo "$out"
    return 1
  fi

  # A removed poll fails until the baseline is lowered.
  cp -R "$tmp/t" "$tmp/under"
  rm "$tmp/under/Examples/G/Tests/B/E.swift"
  set +e; out=$(lint "$tmp/under" ""); status=$?; set -e
  if [[ $status -eq 0 ]] || ! grep -q '^::error file=Examples/G/Tests/B/E.swift::Examples/G/Tests/B/E.swift: 0 clock-poll hit(s), baseline 1: lower' <<< "$out"; then
    echo "lint-wall-clock-tests self-test FAILED: a removed poll (exit $status)"; echo "$out"
    return 1
  fi

  # A raised baseline passes, and says so against the base branch's copy.
  cp -R "$tmp/t" "$tmp/raised"
  cp "$tmp/t/$BASELINE_REL" "$tmp/base-baseline.txt"
  printf '%s\n' 'while ContinuousClock.now < later { }' >> "$tmp/raised/Tests/A/Polls.swift"
  write_baseline "$tmp/raised" > /dev/null
  set +e; out=$(lint "$tmp/raised" "$tmp/base-baseline.txt"); status=$?; set -e
  if [[ $status -ne 0 ]] || ! grep -qx 'BASELINE RAISED: Tests/A/Polls.swift clock-poll 4→5' <<< "$out" \
     || ! grep -q '^::warning file=scripts/wall-clock-baseline.txt,title=Wall-clock baseline raised::' <<< "$out"; then
    echo "lint-wall-clock-tests self-test FAILED: a raised baseline (exit $status)"; echo "$out"
    return 1
  fi
  # And an unchanged baseline prints no raise.
  set +e; out=$(lint "$tmp/t" "$tmp/base-baseline.txt"); status=$?; set -e
  if [[ $status -ne 0 ]] || grep -q 'BASELINE RAISED' <<< "$out"; then
    echo "lint-wall-clock-tests self-test FAILED: an unchanged baseline (exit $status)"; echo "$out"
    return 1
  fi
  echo "lint-wall-clock-tests self-test passed"
}

mode=lint base_baseline="" root=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --self-test) mode=self-test ;;
    --write-baseline) mode=write-baseline ;;
    --base-baseline) base_baseline=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); shift ;;
    *) root=$1 ;;
  esac
  shift
done
root=$(cd "${root:-$(dirname "$0")/..}" && pwd)
case $mode in
  self-test) self_test ;;
  write-baseline) write_baseline "$root" ;;
  lint) lint "$root" "$base_baseline" ;;
esac
