#!/usr/bin/env bash
# The turn core's rules that the compiler can't check (Notes/plans/2026-11-18-swift-state-turns-core.md §7).
# Per Swift file under Sources/, Tests/ and Examples/ (comments and string literals ignored):
#
#   plain-data   no hand-written `PlainData` conformance outside Sources/SwiftStateTurns: a type or
#                extension that lists PlainData among its conformances. `@PlainData` writes it and
#                checks every field; a hand-written one checks nothing. A constraint
#                (`where T: PlainData`, `<T: PlainData>`) isn't a conformance.
#   let-core     a type that conforms to TurnActor stores `let core`, never `var core` or a
#                computed `core` (the protocol can't require a stored `let`).
#   machine-file no `Task {`, `Task.detached`, `nonisolated(unsafe)` or `@unchecked Sendable` in a
#                file that declares a TurnMachine, outside Sources/SwiftStateTurns: a machine's
#                file holds its steps, and its steps start no work and share nothing.
#   isolated     no `assumeIsolated` outside the boundary files listed below, and no more calls in
#                a listed file than its count. The list may only shrink: a count below its
#                listed value fails until the list is lowered in the same change.
#
# A deliberate site (a test that shows what a rule refuses at run time) carries
# `// lint-allow: turns-<rule>: <reason>` on its line, with a non-empty reason.
#
# Usage: scripts/lint-turns.sh [--self-test] [repo root]

set -euo pipefail

# Boundary files that enter another actor's isolation synchronously, with their call counts and
# the reason each may.
ISOLATED_BOUNDARIES='
Sources/SwiftStateTreeTransport/TransportAdapter+LandKeeperTransport.swift 5 the keeper calls the adapter inside its turn, on their shared executor
Sources/SwiftStateTreeTransport/TransportAdapter.swift 3 the adapter submits sync streams into its keeper on their shared executor
'

# Strips `//` comments, `/* */` comments on one line, and string literals (one-line and `"""`
# blocks), keeping line numbers: prints `line<TAB>code`.
strip() {
  # shellcheck disable=SC2016 # awk program, not shell
  awk '
    {
      line = $0
      if (inblock) {
        if (index(line, "\"\"\"") > 0) { inblock = 0 }
        print NR "\t"
        next
      }
      out = ""; i = 1; n = length(line)
      while (i <= n) {
        c = substr(line, i, 1)
        if (substr(line, i, 3) == "\"\"\"") { inblock = 1; break }
        if (c == "\"") {
          i++
          while (i <= n && substr(line, i, 1) != "\"") { if (substr(line, i, 1) == "\\") i++; i++ }
          out = out "\"\""; i++; continue
        }
        if (substr(line, i, 2) == "//") break
        if (substr(line, i, 2) == "/*") {
          j = index(substr(line, i + 2), "*/")
          if (j == 0) break
          i = i + 2 + j + 1; continue
        }
        out = out c; i++
      }
      print NR "\t" out
    }' "$1"
}

# Drops the lines of stripped code (`line<TAB>code`) whose original line in $1 carries the
# allow marker for rule $2.
unmarked() {  # file rule < stripped
  local allowed
  allowed="$(grep -n -E "// lint-allow: turns-$2: [^ ]" "$1" | cut -d: -f1 | tr '\n' ' ' || true)"
  awk -F'\t' -v allowed=" $allowed" 'index(allowed, " " $1 " ") == 0'
}

lint() {  # root
  local root="$1" failures=0 file rel stripped
  cd "$root"
  local files
  files="$(find Sources Tests Examples -name '*.swift' -not -path '*/.build/*' -not -path '*/node_modules/*' 2>/dev/null | sort)"
  local counts=""
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    rel="$file"
    stripped="$(strip "$file")"
    local in_core=0
    case "$rel" in Sources/SwiftStateTurns/*|Sources/SwiftStateTurnsMacros/*) in_core=1 ;; esac

    if [ $in_core -eq 0 ]; then
      # plain-data: the inheritance clause of a type or extension declaration, generics and
      # `where` removed.
      while IFS=$'\t' read -r n code; do
        echo "$rel:$n: [plain-data] a hand-written PlainData conformance; use @PlainData"
        failures=$((failures + 1))
      done < <(awk -F'\t' '
        {
          code = $2
          if (code !~ /(^|[^A-Za-z0-9_@])(struct|enum|class|actor|extension)[ \t]+[A-Za-z_]/) next
          sub(/[ \t]where[ \t].*/, "", code)
          sub(/\{.*/, "", code)
          while (match(code, /<[^<>]*>/)) code = substr(code, 1, RSTART - 1) substr(code, RSTART + RLENGTH)
          p = index(code, ":")
          if (p == 0) next
          if (substr(code, p + 1) ~ /(^|[^A-Za-z0-9_])PlainData([^A-Za-z0-9_]|$)/) print $1 "\t" $2
        }' <<<"$stripped")
    fi

    if [ $in_core -eq 0 ] && grep -q -E '(^|[^A-Za-z0-9_])TurnActor([^A-Za-z0-9_]|$)' <<<"$stripped"; then
      # let-core: a file with a TurnActor conformance declares `let core` and no other `core`.
      if grep -q -E $'\t'"[^:]*(actor|class|struct|extension)[^{]*:[^{]*TurnActor" <<<"$stripped"; then
        if unmarked "$file" let-core <<<"$stripped" | grep -q -E '(^|[^A-Za-z0-9_])var[ \t]+core([^A-Za-z0-9_]|$)'; then
          echo "$rel: [let-core] a TurnActor's core is a stored let, not a var"
          failures=$((failures + 1))
        elif ! grep -q -E '(^|[^A-Za-z0-9_])let[ \t]+core([^A-Za-z0-9_]|$)' <<<"$stripped"; then
          echo "$rel: [let-core] a TurnActor declares 'let core'"
          failures=$((failures + 1))
        fi
      fi
    fi

    if [ $in_core -eq 0 ] && grep -q -E $'\t'"[^:]*(struct|enum|extension)[^{]*:[^{]*TurnMachine" <<<"$stripped"; then
      while IFS=$'\t' read -r n _; do
        echo "$rel:$n: [machine-file] no Task, nonisolated(unsafe) or @unchecked Sendable in a machine's file"
        failures=$((failures + 1))
      done < <(grep -E $'\t'".*(Task[ \t]*\\{|Task\\.detached|nonisolated\\(unsafe\\)|@unchecked[ \t]+Sendable)" <<<"$stripped" || true)
    fi

    local count
    count="$(unmarked "$file" isolated <<<"$stripped" | grep -c -E '(^|[^A-Za-z0-9_])assumeIsolated([^A-Za-z0-9_]|$)' || true)"
    if [ "$count" -gt 0 ]; then counts+="$rel $count"$'\n'; fi
  done <<<"$files"

  # isolated: compare the counts with the list (bash 3.2 has no associative arrays).
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "$line"
    failures=$((failures + 1))
  done < <(LINT_COUNTS="$counts" LINT_LISTED="$ISOLATED_BOUNDARIES" awk '
    BEGIN {
      counts = ENVIRON["LINT_COUNTS"]; listed = ENVIRON["LINT_LISTED"]
      n = split(listed, rows, "\n")
      for (i = 1; i <= n; i++) { split(rows[i], f, " "); if (f[1] != "") allowed[f[1]] = f[2] }
      n = split(counts, rows, "\n")
      for (i = 1; i <= n; i++) { split(rows[i], f, " "); if (f[1] != "") found[f[1]] = f[2] }
      for (p in found) {
        a = (p in allowed) ? allowed[p] : 0
        if (found[p] + 0 > a + 0)
          print p ": [isolated] " found[p] " assumeIsolated call(s), " a " allowed: a step doesn'"'"'t call out; list a boundary file only with a reason"
      }
      for (p in allowed) {
        c = (p in found) ? found[p] : 0
        if (c + 0 < allowed[p] + 0)
          print p ": [isolated] " c " assumeIsolated call(s), listed " allowed[p] ": lower the list in scripts/lint-turns.sh"
      }
    }')
  [ "$failures" -eq 0 ]
}

self_test() {
  local dir out
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  mkdir -p "$dir/Sources/App" "$dir/Sources/SwiftStateTurns" "$dir/Tests" "$dir/Examples"
  for path in $(awk 'NF { print $1 }' <<<"$ISOLATED_BOUNDARIES"); do
    mkdir -p "$dir/$(dirname "$path")"
    local n
    n="$(awk -v p="$path" '$1 == p { print $2 }' <<<"$ISOLATED_BOUNDARIES")"
    for _ in $(seq "$n"); do echo 'x.assumeIsolated { _ in }'; done > "$dir/$path"
  done
  # Passing fixture.
  cat > "$dir/Sources/App/Good.swift" <<'EOF'
// struct Fake: PlainData {} in a comment, and "extension X: PlainData" in a string.
let text = "struct S: PlainData {}"
@PlainData
struct Model: TurnMachine { var n: Int }
struct Box<T: PlainData>: Sendable where T: PlainData {}
func use<T>(_ value: T) where T: PlainData {}
actor Owner: TurnActor {
    let core = makeCore()
}
actor Replacing: TurnActor {
    var core = makeCore() // lint-allow: turns-let-core: shows a replaced core's completions are dropped
    func reenter() { self.assumeIsolated { _ in } } // lint-allow: turns-isolated: shows the stop
}
EOF
  cat > "$dir/Sources/SwiftStateTurns/Core.swift" <<'EOF'
extension Int: PlainData {}
public final class EndToken: @unchecked Sendable {}
public protocol TurnActor: Actor { var core: TurnCore<M> { get } }
public protocol TurnMachine: Sendable {}
EOF
  if ! out="$(lint "$dir" 2>&1)"; then
    echo "self-test: the passing fixture failed:"; echo "$out"; return 1
  fi
  # Failing fixture: one hit per rule.
  cat > "$dir/Sources/App/Bad.swift" <<'EOF'
struct Plain: PlainData { var n: Int }
extension Other: Hashable, PlainData {}
actor VarOwner: TurnActor {
    var core = makeCore()
}
EOF
  cat > "$dir/Sources/App/BadMachine.swift" <<'EOF'
struct Machine: TurnMachine {
    mutating func handle() { Task { } }
}
nonisolated(unsafe) var shared = 0
final class Box: @unchecked Sendable {}
EOF
  echo 'y.assumeIsolated { _ in }' > "$dir/Sources/App/Calls.swift"
  out="$(lint "$dir" 2>&1)" && { echo "self-test: the failing fixture passed"; return 1; }
  local want
  for want in "Bad.swift:1: [plain-data]" "Bad.swift:2: [plain-data]" "Bad.swift: [let-core]" \
              "BadMachine.swift:2: [machine-file]" "BadMachine.swift:4: [machine-file]" \
              "BadMachine.swift:5: [machine-file]" "Calls.swift: [isolated]"; do
    if ! grep -q -F -- "$want" <<<"$out"; then
      echo "self-test: missing '$want' in:"; echo "$out"; return 1
    fi
  done
  if [ "$(grep -c . <<<"$out")" -ne 7 ]; then
    echo "self-test: expected 7 findings, got:"; echo "$out"; return 1
  fi
  # A listed count that went down must be lowered.
  rm "$dir/Sources/App/Bad.swift" "$dir/Sources/App/BadMachine.swift" "$dir/Sources/App/Calls.swift"
  local first
  first="$(awk 'NF { print $1; exit }' <<<"$ISOLATED_BOUNDARIES")"
  sed -i.bak '1d' "$dir/$first" && rm -f "$dir/$first.bak"
  out="$(lint "$dir" 2>&1)" && { echo "self-test: a lowered count passed"; return 1; }
  grep -q -F "lower the list" <<<"$out" || { echo "self-test: no 'lower the list' in:"; echo "$out"; return 1; }
  echo "lint-turns: self-test passed"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
if lint "$root"; then
  echo "lint-turns: passed"
else
  echo "lint-turns: FAILED"
  exit 1
fi
