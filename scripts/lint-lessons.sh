#!/usr/bin/env bash
# Lessons enforced in CI instead of prose (CLAUDE.md § Coding Conventions):
#
#   task-sleep  `Task.sleep(for:` in Sources/ (except SafeTaskSleep.swift): it crashes the Swift
#               runtime on macOS release builds under load. Use `safeTaskSleep(for:)`.
#   format-s    a `%s` specifier in a `String(format:` call in Sources/ or Examples/: `%s` reads a
#               C string pointer, and a Swift String there crashes release builds. Use `%@` or
#               interpolation.
#
# A line that must keep the pattern carries `lint-allow: <rule>` in a comment on the same line.
# Comment-only lines are skipped. The check is per line: a format string on a later line than
# `String(format:` is not seen.
#
# Usage: scripts/lint-lessons.sh [--self-test] [repo root]
#   Exits 1 and prints `file:line: [rule] text` for every finding; prints the finding count.

set -euo pipefail

TASK_SLEEP='Task\.sleep\(for:'
FORMAT_S='String\(format:.*%[-+ #0]*[0-9*]*(\.[0-9*]+)?s'

# Prints `rel:line: [rule] text` for each matching line of the files on stdin (NUL-separated).
scan() {
  local root=$1 rule=$2 pattern=$3
  { xargs -0 grep -nHE "$pattern" 2>/dev/null || true; } | awk -v root="$root/" -v rule="$rule" '
    {
      file = $0; sub(/:.*/, "", file)
      rest = substr($0, length(file) + 2)
      line = rest; sub(/:.*/, "", line)
      text = substr(rest, length(line) + 2)
      if (text ~ /^[ \t]*\/\//) next
      if (index(text, "lint-allow: " rule) > 0) next
      sub(/^[ \t]+/, "", text)
      print substr(file, length(root) + 1) ":" line ": [" rule "] " text
    }'
}

lint() {
  local root=$1 out
  out=$(
    find "$root/Sources" -name '*.swift' -not -name 'SafeTaskSleep.swift' -not -path '*/.build/*' -print0 2>/dev/null \
      | scan "$root" task-sleep "$TASK_SLEEP"
    find "$root/Sources" "$root/Examples" -name '*.swift' -not -path '*/.build/*' -print0 2>/dev/null \
      | scan "$root" format-s "$FORMAT_S"
  )
  local findings=0
  if [[ -n $out ]]; then
    echo "$out"
    findings=$(echo "$out" | wc -l | tr -d ' ')
  fi
  echo "lint-lessons: $findings finding(s)"
  [[ $findings -eq 0 ]]
}

self_test() {
  local tmp out
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/Sources/A/Support" "$tmp/Examples/B/Sources"
  cat > "$tmp/Sources/A/Bad.swift" <<'SWIFT'
try await Task.sleep(for: .seconds(1))
let a = String(format: "%s", name)
let b = String(format: "%-27s|%.1f", name, x)
// try await Task.sleep(for: .seconds(1)) and String(format: "%s") in a comment
try await Task.sleep(for: .seconds(1)) // lint-allow: task-sleep
let c = String(format: "%@ %d", name, n)
let d = String(format: "%.2f%%", x)
SWIFT
  echo 'try await Task.sleep(for: .seconds(1))' > "$tmp/Sources/A/Support/SafeTaskSleep.swift"
  printf '%s\n' 'try await Task.sleep(for: .seconds(1))' 'print(String(format: "%5s", s))' > "$tmp/Examples/B/Sources/main.swift"
  out=$(lint "$tmp" || true)
  local expected
  expected=$(cat <<'OUT'
Examples/B/Sources/main.swift:2: [format-s] print(String(format: "%5s", s))
Sources/A/Bad.swift:1: [task-sleep] try await Task.sleep(for: .seconds(1))
Sources/A/Bad.swift:2: [format-s] let a = String(format: "%s", name)
Sources/A/Bad.swift:3: [format-s] let b = String(format: "%-27s|%.1f", name, x)
lint-lessons: 4 finding(s)
OUT
)
  if [[ "$(echo "$out" | LC_ALL=C sort)" != "$(echo "$expected" | LC_ALL=C sort)" ]]; then
    echo "lint-lessons self-test FAILED"; echo "--- got"; echo "$out"; echo "--- expected"; echo "$expected"
    return 1
  fi
  echo "lint-lessons self-test passed"
}

if [[ ${1:-} == --self-test ]]; then
  self_test
else
  lint "$(cd "${1:-$(dirname "$0")/..}" && pwd)"
fi
