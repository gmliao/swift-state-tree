#!/usr/bin/env bash
# Lessons enforced in CI instead of prose (CLAUDE.md § Coding Conventions):
#
#   task-sleep  `Task.sleep(for:` (also `Task<…>.sleep(for:`) in Sources/, except
#               Sources/SwiftStateTree/Support/SafeTaskSleep.swift: it crashes the Swift runtime on
#               macOS release builds under load. Use `safeTaskSleep(for:)`.
#   format-s    a `%s` specifier (not `%%s`) in a `String(format:` call in Sources/ or Examples/:
#               `%s` reads a C string pointer, and a Swift String there crashes release builds. Use
#               `%@` or interpolation.
#   ticket-after-await
#               a generation ticket issued (`.issue(`, `?? <table>.issue(` included) after an `await`
#               in the same function in Sources/SwiftStateTreeTransport/: a teardown or another
#               turn can end the key during the await, and a ticket issued then is current for a
#               key that is gone (#531). Take the ticket before the first `await` and pass it on;
#               to move a held ticket to a new generation, `renew(_:)` (it checks the ticket is
#               still current). The scope is per function in line order: a function starts at a
#               `func`/`init` declaration line, and a closure or a nested function is not a scope
#               of its own (an `await` in it counts for the rest of the outer function).
#
# A line that must keep the pattern carries `// lint-allow: <rule>` on the same line.
# Comment-only lines are skipped. The check is per line: a format string on a later line than
# `String(format:` is not seen.
#
# Usage: scripts/lint-lessons.sh [--self-test] [repo root]
#   Exits 1 and prints `file:line: [rule] text` for every finding; prints the finding count.

set -euo pipefail

TASK_SLEEP='Task(<[^>]*>)?\.sleep\(for:'
# A `%` not escaped as `%%`: preceded by an even number of `%`.
FORMAT_S='String\(format:.*([^%]|^)(%%)*%[-+ #0]*[0-9*]*(\.[0-9*]+)?s'
SAFE_TASK_SLEEP='Sources/SwiftStateTree/Support/SafeTaskSleep.swift'

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
      if (text ~ ("//.*lint-allow: " rule)) next
      sub(/^[ \t]+/, "", text)
      print substr(file, length(root) + 1) ":" line ": [" rule "] " text
    }'
}

# Prints `rel:line: [ticket-after-await] text` for each `.issue(` after an `await` in the same
# function, in the files on stdin (NUL-separated).
scan_ticket_after_await() {
  local root=$1
  { xargs -0 awk -v root="$root/" '
    FNR == 1 { awaited = 0 }
    {
      text = $0
      if (text ~ /^[ \t]*\/\//) next
      code = text; sub(/\/\/.*/, "", code)
      if (code ~ /^[ \t]*((@[A-Za-z_]+(\([^)]*\))?|public|private|fileprivate|internal|package|static|class|override|nonisolated|mutating|final|convenience|required|isolated)[ \t]+)*(func[ \t]|init[ \t]*[(<?])/) awaited = 0
      at = match(code, /\.issue\(/)
      if (at > 0 && text !~ /\/\/.*lint-allow: ticket-after-await/) {
        before = substr(code, 1, at - 1)
        if (awaited || before ~ /(^|[^A-Za-z0-9_])await([ \t(]|$)/) {
          line = text; sub(/^[ \t]+/, "", line)
          print substr(FILENAME, length(root) + 1) ":" FNR ": [ticket-after-await] " line
        }
      }
      if (code ~ /(^|[^A-Za-z0-9_])await([ \t(]|$)/) awaited = 1
    }' 2>/dev/null || true; }
}

lint() {
  local root=$1 out
  out=$(
    find "$root/Sources" -name '*.swift' -not -path "$root/$SAFE_TASK_SLEEP" -not -path '*/.build/*' -print0 2>/dev/null \
      | scan "$root" task-sleep "$TASK_SLEEP"
    find "$root/Sources" "$root/Examples" -name '*.swift' -not -path '*/.build/*' -print0 2>/dev/null \
      | scan "$root" format-s "$FORMAT_S"
    find "$root/Sources/SwiftStateTreeTransport" -name '*.swift' -not -path '*/.build/*' -print0 2>/dev/null \
      | scan_ticket_after_await "$root"
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
  local tmp out status
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/seeded/Sources/A/Support" "$tmp/seeded/Sources/SwiftStateTree/Support" "$tmp/seeded/Examples/B/Sources"
  cat > "$tmp/seeded/Sources/A/Bad.swift" <<'SWIFT'
try await Task.sleep(for: .seconds(1))
let a = String(format: "%s", name)
let b = String(format: "%-27s|%.1f", name, x)
// try await Task.sleep(for: .seconds(1)) and String(format: "%s") in a comment
try await Task.sleep(for: .seconds(1)) // lint-allow: task-sleep
let c = String(format: "%@ %d", name, n)
let d = String(format: "%.2f%%", x)
try await Task<Never, Never>.sleep(for: .seconds(1))
print("lint-allow: task-sleep"); try await Task.sleep(for: .seconds(1))
let e = String(format: "100%%s", x)
let f = String(format: "%%%s", name)
SWIFT
  echo 'try await Task.sleep(for: .seconds(1))' > "$tmp/seeded/Sources/SwiftStateTree/Support/SafeTaskSleep.swift"
  echo 'try await Task.sleep(for: .seconds(1))' > "$tmp/seeded/Sources/A/Support/SafeTaskSleep.swift"
  printf '%s\n' 'try await Task.sleep(for: .seconds(1))' 'print(String(format: "%5s", s))' > "$tmp/seeded/Examples/B/Sources/main.swift"
  mkdir -p "$tmp/seeded/Sources/SwiftStateTreeTransport"
  cat > "$tmp/seeded/Sources/SwiftStateTreeTransport/Tickets.swift" <<'SWIFT'
func before(_ k: Int) async {
    let t = tickets.ticket(for: k) ?? tickets.issue(k)
    await work(t)
}
private func after(_ k: Int) async {
    let entry = await read(k)
    let t = tickets.ticket(for: k) ?? tickets.issue(k)
}
func sameLine(_ k: Int) async {
    let e = await read(k); let t = tickets.issue(k)
}
func renews(_ t: Ticket) async {
    await work(t)
    let next = tickets.renew(t)
}
func allowed(_ k: Int) async {
    await work(k)
    // tickets.issue(k) in a comment
    let t = tickets.issue(k) // lint-allow: ticket-after-await
}
    init(k: Int) {
        let t = tickets.issue(k)
    }
func closure(_ k: Int) {
    Task { await work(k) }
    let t = tickets.issue(k)
}
SWIFT
  echo 'func f() async { await g(); let t = tickets.issue(1) }' > "$tmp/seeded/Sources/A/OtherModule.swift"
  local expected
  expected=$(cat <<'OUT'
Examples/B/Sources/main.swift:2: [format-s] print(String(format: "%5s", s))
Sources/A/Bad.swift:1: [task-sleep] try await Task.sleep(for: .seconds(1))
Sources/A/Bad.swift:2: [format-s] let a = String(format: "%s", name)
Sources/A/Bad.swift:3: [format-s] let b = String(format: "%-27s|%.1f", name, x)
Sources/A/Bad.swift:8: [task-sleep] try await Task<Never, Never>.sleep(for: .seconds(1))
Sources/A/Bad.swift:9: [task-sleep] print("lint-allow: task-sleep"); try await Task.sleep(for: .seconds(1))
Sources/A/Bad.swift:11: [format-s] let f = String(format: "%%%s", name)
Sources/A/Support/SafeTaskSleep.swift:1: [task-sleep] try await Task.sleep(for: .seconds(1))
Sources/SwiftStateTreeTransport/Tickets.swift:7: [ticket-after-await] let t = tickets.ticket(for: k) ?? tickets.issue(k)
Sources/SwiftStateTreeTransport/Tickets.swift:10: [ticket-after-await] let e = await read(k); let t = tickets.issue(k)
Sources/SwiftStateTreeTransport/Tickets.swift:26: [ticket-after-await] let t = tickets.issue(k)
lint-lessons: 11 finding(s)
OUT
)
  set +e; out=$(lint "$tmp/seeded"); status=$?; set -e
  if [[ $status -eq 0 || "$(echo "$out" | LC_ALL=C sort)" != "$(echo "$expected" | LC_ALL=C sort)" ]]; then
    echo "lint-lessons self-test FAILED on the seeded tree (exit $status)"; echo "--- got"; echo "$out"; echo "--- expected"; echo "$expected"
    return 1
  fi
  # A clean tree passes: exit 0 and no findings.
  mkdir -p "$tmp/clean/Sources/A" "$tmp/clean/Examples/B"
  printf '%s\n' 'try await safeTaskSleep(for: .seconds(1))' 'let a = String(format: "%@ %d%%", name, n)' > "$tmp/clean/Sources/A/Good.swift"
  set +e; out=$(lint "$tmp/clean"); status=$?; set -e
  if [[ $status -ne 0 || "$out" != "lint-lessons: 0 finding(s)" ]]; then
    echo "lint-lessons self-test FAILED on the clean tree (exit $status)"; echo "$out"
    return 1
  fi
  echo "lint-lessons self-test passed"
}

if [[ ${1:-} == --self-test ]]; then
  self_test
else
  lint "$(cd "${1:-$(dirname "$0")/..}" && pwd)"
fi
