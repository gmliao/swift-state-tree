#!/usr/bin/env bash
# The turn core's rules that the compiler can't check (Notes/plans/2026-11-18-swift-state-turns-core.md §7).
# Per Swift file under Sources/, Tests/ and Examples/ (comments and string literals ignored; a
# declaration whose header spans several lines is read as one):
#
#   plain-data   no hand-written `PlainData` conformance outside Sources/SwiftStateTurns: a type,
#                extension or protocol that lists PlainData among its conformances or refines it,
#                or a typealias that names it (a class could conform through either).
#                `@PlainData` writes the conformance and checks every field; a hand-written one
#                checks nothing. A constraint (`where T: PlainData`, `<T: PlainData>`) isn't one.
#   let-core     a type that conforms to TurnActor (in its declaration or in an extension, in any
#                file) declares `let core` as a member of its declaration, and no `var core`
#                member anywhere (the protocol can't require a stored `let`).
#   machine-file no task (`Task {`, `Task(…)`, `Task<…>`, `Task.init`, `Task.detached`),
#                `nonisolated(unsafe)` or `@unchecked Sendable` in a file that declares a
#                TurnMachine, outside Sources/SwiftStateTurns: a machine's file holds its steps,
#                and its steps start no work and share nothing.
#   isolated     no `assumeIsolated` outside the boundary files listed below, and no more calls in
#                a listed file than its count.
#
# A deliberate site (a test that shows at run time what a rule refuses) carries
# `// lint-allow: turns-<rule>: <reason>` on its line, or on any line of a multi-line header. A
# marker is accepted only under Tests/, with a reason of at least ten characters, and in a file
# listed in ALLOW_MARKERS with no more markers than its count.
#
# Both lists may only shrink: a count below its listed value fails until the list is lowered in
# the same change.
#
# Usage: scripts/lint-turns.sh [--self-test] [repo root]

set -euo pipefail

# Boundary files that enter another actor's isolation synchronously, with their call counts and
# the reason each may.
ISOLATED_BOUNDARIES='
Sources/SwiftStateTreeTransport/TransportAdapter+LandKeeperTransport.swift 5 the keeper calls the adapter inside its turn, on their shared executor
Sources/SwiftStateTreeTransport/TransportAdapter.swift 3 the adapter submits sync streams into its keeper on their shared executor
'

# Test files that carry allow markers, with their counts.
ALLOW_MARKERS='
Tests/SwiftStateTurnsTests/Support/DemoActor.swift 5 the runtime stops (reentry, a replaced core, a class machine)
'

RULES='plain-data|let-core|machine-file|isolated'

# Prints the corpus of one file: `path<TAB>line<TAB>allowed rules<TAB>code`, with `//` comments,
# one-line `/* */` comments and string literals (one-line and `"""` blocks) removed. Allowed
# rules: those of a well-formed marker on the line, comma-separated. A malformed marker prints a
# line `path<TAB>line<TAB>!bad<TAB>` instead.
strip() {  # path
  # shellcheck disable=SC2016 # awk program, not shell
  awk -v path="$1" -v rules="$RULES" '
    {
      line = $0
      allow = ""
      if (match(line, /\/\/ lint-allow: turns-[a-z-]+:?.*/)) {
        marker = substr(line, RSTART + 21)
        rule = marker; sub(/:.*/, "", rule)
        reason = marker; if (index(reason, ":") > 0) { sub(/^[^:]*:[ \t]*/, "", reason) } else { reason = "" }
        if (rule ~ ("^(" rules ")$") && length(reason) >= 10) { allow = rule } else { allow = "!bad" }
      }
      if (inblock) {
        if (index(line, "\"\"\"") > 0) { inblock = 0 }
        print path "\t" NR "\t" allow "\t"
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
      print path "\t" NR "\t" allow "\t" out
    }' "$1"
}

# Reads the corpus; prints one row per declaration header, joined over the lines it spans:
# `path<TAB>first line<TAB>allowed rules of its lines<TAB>kind<TAB>name<TAB>header`. A type's or
# extension's header runs to its `{`; a typealias runs while it ends in `=`, `&` or `,`, or the
# next line starts with `&`.
headers() {
  # shellcheck disable=SC2016 # awk program, not shell
  awk -F'\t' '
    function flush() {
      if (pending) print hpath "\t" hline "\t" hallow "\t" hkind "\t" hname "\t" htext
      pending = 0
    }
    {
      path = $1; code = $4
      if (pending && path != hpath) flush()
      if (pending) {
        if (hkind == "typealias") {
          t = code; sub(/^[ \t]+/, "", t)
          e = htext; sub(/[ \t]+$/, "", e)
          if (e ~ /[=&,]$/ || t ~ /^&/) { htext = htext " " code; hallow = hallow "," $3; spans++ }
          else flush()
        } else {
          htext = htext " " code; hallow = hallow "," $3; spans++
          if (index(code, "{") > 0 || spans > 20) flush()
          next
        }
      }
      if (match(code, /(^|[^A-Za-z0-9_@.])(struct|enum|class|actor|extension|protocol|typealias)[ \t]+[A-Za-z_][A-Za-z0-9_.]*/)) {
        decl = substr(code, RSTART, RLENGTH); sub(/^[^A-Za-z]/, "", decl)
        split(decl, parts, /[ \t]+/)
        hpath = path; hline = $2; hallow = $3; hkind = parts[1]; hname = parts[2]; htext = code; spans = 1
        pending = 1
        if (hkind != "typealias" && index(code, "{") > 0) flush()
        else if (hkind == "typealias") {
          e = code; sub(/[ \t]+$/, "", e)
          if (e !~ /[=&,]$/) flush()
        }
      }
    }
    END { flush() }'
}

lint() {  # root
  local root="$1" file
  cd "$root"
  local corpus heads findings
  corpus="$(mktemp)"; heads="$(mktemp)"; findings="$(mktemp)"
  # shellcheck disable=SC2064 # expand now: the paths are local
  trap "rm -f '$corpus' '$heads' '$findings'" RETURN
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    strip "$file" >> "$corpus"
  done < <(find Sources Tests Examples -name '*.swift' -not -path '*/.build/*' -not -path '*/node_modules/*' 2>/dev/null | sort)
  headers < "$corpus" > "$heads"

  # The rules over the corpus and its headers. A path in the core targets is exempt from
  # plain-data, let-core and machine-file.
  # shellcheck disable=SC2016 # awk program, not shell
  LINT_ISOLATED="$ISOLATED_BOUNDARIES" LINT_MARKERS="$ALLOW_MARKERS" awk -F'\t' '
    function core(p) { return p ~ /^Sources\/SwiftStateTurns(Macros)?\// }
    function allowed(list, rule) { return index("," list ",", "," rule ",") > 0 }
    function word(text, w) { return text ~ ("(^|[^A-Za-z0-9_])" w "([^A-Za-z0-9_]|$)") }
    # The conformance list of a type, extension or protocol header: after the name, generics,
    # `where` and the body removed.
    function conformances(text,   t, p) {
      t = text
      sub(/[ \t]where[ \t].*/, "", t)
      sub(/\{.*/, "", t)
      while (match(t, /<[^<>]*>/)) t = substr(t, 1, RSTART - 1) substr(t, RSTART + RLENGTH)
      p = index(t, ":")
      return p == 0 ? "" : substr(t, p + 1)
    }
    function braces(code, sign,   i, c, d) {
      d = 0
      for (i = 1; i <= length(code); i++) {
        c = substr(code, i, 1)
        if (c == "{") d++
        else if (c == "}") d--
      }
      return d
    }
    FNR == 1 { pass++ }
    # Pass 1: the headers.
    pass == 1 {
      path = $1; n = $2; allow = $3; kind = $4; name = $5; text = $6
      if (core(path)) next
      if (kind == "typealias") {
        rhs = text; sub(/^[^=]*=/, "", rhs)
        if (word(rhs, "PlainData") && !allowed(allow, "plain-data"))
          print path ":" n ": [plain-data] a typealias for PlainData lets a type conform without @PlainData"
        next
      }
      list = conformances(text)
      if (word(list, "PlainData") && !allowed(allow, "plain-data")) {
        if (kind == "protocol")
          print path ":" n ": [plain-data] a protocol refining PlainData lets a type conform without @PlainData"
        else
          print path ":" n ": [plain-data] a hand-written PlainData conformance; use @PlainData"
      }
      if (word(list, "TurnActor")) actors[name] = 1
      if (kind != "extension" && kind != "protocol" && word(list, "TurnMachine")) machineFile[path] = 1
      if (kind == "extension" && word(list, "TurnMachine")) machineFile[path] = 1
      next
    }
    # Pass 2: the corpus, line by line, with brace depth per file.
    pass == 2 {
      path = $1; n = $2; allow = $3; code = $4
      if (path != lastPath) { depth = 0; body = 0; pendingName = ""; lastPath = path }
      if (allow == "!bad") {
        print path ":" n ": [allow] a lint-allow marker names a rule (" RULES ") and a reason of at least ten characters"
      } else if (allow != "") {
        if (path !~ /^Tests\//) print path ":" n ": [allow] lint-allow markers are accepted only under Tests/"
        else markers[path]++
      }
      if (!core(path)) {
        # machine-file
        if ((path in machineFile) && !allowed(allow, "machine-file") &&
            code ~ /(^|[^A-Za-z0-9_.])Task[ \t]*(\{|\(|<|\.init|\.detached)|nonisolated\(unsafe\)|@unchecked[ \t]+Sendable/)
          print path ":" n ": [machine-file] no task, nonisolated(unsafe) or @unchecked Sendable in a machine'"'"'s file"
        # let-core: a member of a conforming type'"'"'s declaration or extension.
        if (body > 0 && depth == body) {
          # Only what precedes the first brace on the line is at member level.
          member = code; sub(/\{.*/, "", member)
          if (member ~ /(^|[^A-Za-z0-9_])let[ \t]+core([^A-Za-z0-9_]|$)/ && bodyKind != "extension") hasLet[bodyName] = 1
          if (member ~ /(^|[^A-Za-z0-9_])var[ \t]+core([^A-Za-z0-9_]|$)/) {
            if (allowed(allow, "let-core")) markedVar[bodyName] = 1
            else print path ":" n ": [let-core] a TurnActor'"'"'s core is a stored let, not a var"
          }
        }
        if (match(code, /(^|[^A-Za-z0-9_@.])(struct|class|actor|extension)[ \t]+[A-Za-z_][A-Za-z0-9_.]*/)) {
          decl = substr(code, RSTART, RLENGTH); sub(/^[^A-Za-z]/, "", decl)
          split(decl, parts, /[ \t]+/)
          if (parts[2] in actors) { pendingName = parts[2]; pendingKind = parts[1]; pendingLine = n }
        }
      }
      before = depth
      depth += braces(code)
      if (pendingName != "" && index(code, "{") > 0) {
        # The body opens on this line: its members are one level below the brace.
        body = before + 1; bodyName = pendingName; bodyKind = pendingKind; pendingName = ""
        if (bodyKind != "extension") { primary[bodyName] = path ":" pendingLine }
        if (depth < body) body = 0
      } else if (body > 0 && depth < body) {
        body = 0
      }
      next
    }
    END {
      for (a in actors) {
        if ((a in primary) && !(a in hasLet) && !(a in markedVar))
          print primary[a] ": [let-core] a TurnActor declares '"'"'let core'"'"' as a member"
      }
      # Allow markers and assumeIsolated calls, against their lists.
      split(ENVIRON["LINT_MARKERS"], rows, "\n")
      for (i in rows) { split(rows[i], f, " "); if (f[1] != "") listedMarkers[f[1]] = f[2] }
      for (p in markers) {
        a = (p in listedMarkers) ? listedMarkers[p] : 0
        if (markers[p] + 0 > a + 0) print p ": [allow] " markers[p] " marker(s), " a " listed in ALLOW_MARKERS"
      }
      for (p in listedMarkers) {
        c = (p in markers) ? markers[p] : 0
        if (c + 0 < listedMarkers[p] + 0) print p ": [allow] " c " marker(s), listed " listedMarkers[p] ": lower ALLOW_MARKERS"
      }
    }' RULES="$RULES" "$heads" "$corpus" > "$findings"

  # isolated: unmarked assumeIsolated calls per file, against the list.
  # shellcheck disable=SC2016 # awk program, not shell
  awk -F'\t' '
    $3 != "" && index("," $3 ",", ",isolated,") > 0 { next }
    $4 ~ /(^|[^A-Za-z0-9_])assumeIsolated([^A-Za-z0-9_]|$)/ { count[$1]++ }
    END { for (p in count) print p " " count[p] }' "$corpus" > "$findings.counts"
  # shellcheck disable=SC2016 # awk program, not shell
  LINT_COUNTS="$(cat "$findings.counts")" LINT_LISTED="$ISOLATED_BOUNDARIES" awk '
    BEGIN {
      n = split(ENVIRON["LINT_LISTED"], rows, "\n")
      for (i = 1; i <= n; i++) { split(rows[i], f, " "); if (f[1] != "") listed[f[1]] = f[2] }
      n = split(ENVIRON["LINT_COUNTS"], rows, "\n")
      for (i = 1; i <= n; i++) { split(rows[i], f, " "); if (f[1] != "") found[f[1]] = f[2] }
      for (p in found) {
        a = (p in listed) ? listed[p] : 0
        if (found[p] + 0 > a + 0)
          print p ": [isolated] " found[p] " assumeIsolated call(s), " a " allowed: a step doesn'"'"'t call out; list a boundary file only with a reason"
      }
      for (p in listed) {
        c = (p in found) ? found[p] : 0
        if (c + 0 < listed[p] + 0)
          print p ": [isolated] " c " assumeIsolated call(s), listed " listed[p] ": lower the list in scripts/lint-turns.sh"
      }
    }' >> "$findings"
  rm -f "$findings.counts"

  if [ -s "$findings" ]; then
    sort "$findings"
    return 1
  fi
}

self_test() {
  local dir out
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the path is local
  trap "rm -rf '$dir'" RETURN
  mkdir -p "$dir/Sources/App" "$dir/Sources/SwiftStateTurns" "$dir/Tests/SwiftStateTurnsTests/Support" "$dir/Examples"
  local path n _reason
  while read -r path n _reason; do
    [ -n "$path" ] || continue
    mkdir -p "$dir/$(dirname "$path")"
    for _ in $(seq "$n"); do echo 'x.assumeIsolated { _ in }'; done > "$dir/$path"
  done <<<"$ISOLATED_BOUNDARIES"
  # Passing fixture. The marked file carries as many markers as ALLOW_MARKERS lists.
  cat > "$dir/Sources/App/Good.swift" <<'EOF'
// struct Fake: PlainData {} in a comment, and "extension X: PlainData" in a string.
let text = "struct S: PlainData {}"
@PlainData
struct Model: TurnMachine { var n: Int }
struct Box<T: PlainData>: Sendable where T: PlainData {}
func use<T>(_ value: T) where T: PlainData {}
protocol Plain where Self: PlainData {}
typealias Pair = PlainPair<Int, Int>
actor Owner:
    TurnActor
{
    let core = makeCore()
    func local() { let core = self.core; _ = core }
}
actor Split {
    let core = makeCore()
}
EOF
  cat > "$dir/Sources/App/SplitConformance.swift" <<'EOF'
extension Split: TurnActor {}
EOF
  local markers
  markers="$(awk 'NF { print $1, $2; exit }' <<<"$ALLOW_MARKERS")"
  {
    echo 'actor Replacing: TurnActor {'
    echo '    var core = makeCore() // lint-allow: turns-let-core: shows a replaced core is ignored'
    echo '    func reenter() { self.assumeIsolated { _ in } } // lint-allow: turns-isolated: shows the reentry stop'
    echo '    let unused = 0'
    echo '}'
    echo 'final class ClassMachine: TurnMachine, PlainData {} // lint-allow: turns-plain-data: the class-machine stop'
    local extra
    extra=$(( ${markers##* } - 3 ))
    for _ in $(seq "$extra"); do echo 'let a = 0 // lint-allow: turns-isolated: fills the listed marker count'; done
  } > "$dir/${markers%% *}"
  cat > "$dir/Sources/SwiftStateTurns/Core.swift" <<'EOF'
extension Int: PlainData {}
public final class WithdrawToken: @unchecked Sendable {}
public protocol TurnActor: Actor { var core: TurnCore<M> { get } }
public protocol TurnMachine: Sendable {}
EOF
  if ! out="$(lint "$dir" 2>&1)"; then
    echo "self-test: the passing fixture failed:"; echo "$out"; return 1
  fi
  # Failing fixture: one hit per case.
  cat > "$dir/Sources/App/Bad.swift" <<'EOF'
struct Plain: PlainData { var n: Int }
extension Other: Hashable, PlainData {}
actor VarOwner: TurnActor {
    var core = makeCore()
}
protocol Bridge: Sendable, PlainData {}
typealias Alias = PlainData
struct Wrapped:
    Hashable,
    PlainData
{
}
typealias Joined = Sendable &
    PlainData
actor LocalOnly: TurnActor {
    func f() { let core = makeCore(); _ = core }
}
actor Elsewhere {
    var core = makeCore()
}
let x = 0 // lint-allow: turns-isolated: a marker outside Tests
EOF
  cat > "$dir/Sources/App/BadConformance.swift" <<'EOF'
extension Elsewhere: TurnActor {}
EOF
  cat > "$dir/Sources/App/BadMachine.swift" <<'EOF'
struct Machine: TurnMachine {
    mutating func handle() { Task { } }
}
nonisolated(unsafe) var shared = 0
final class Box: @unchecked Sendable {}
func later() { Task(priority: .high) { } }
func typed() { _ = Task<Void, Never> { } }
EOF
  cat > "$dir/Tests/Marked.swift" <<'EOF'
let y = 0 // lint-allow: turns-isolated:
let z = 0 // lint-allow: turns-isolated: unlisted file, but a reason
EOF
  echo 'y.assumeIsolated { _ in }' > "$dir/Sources/App/Calls.swift"
  out="$(lint "$dir" 2>&1)" && { echo "self-test: the failing fixture passed"; return 1; }
  local want wants
  wants='Bad.swift:1: [plain-data] a hand-written
Bad.swift:2: [plain-data] a hand-written
Bad.swift:3: [let-core] a TurnActor declares
Bad.swift:4: [let-core] a TurnActor'"'"'s core is a stored let
Bad.swift:6: [plain-data] a protocol refining
Bad.swift:7: [plain-data] a typealias
Bad.swift:8: [plain-data] a hand-written
Bad.swift:13: [plain-data] a typealias
Bad.swift:15: [let-core] a TurnActor declares
Bad.swift:18: [let-core] a TurnActor declares
Bad.swift:19: [let-core] a TurnActor'"'"'s core is a stored let
Bad.swift:21: [allow] lint-allow markers are accepted only under Tests/
BadMachine.swift:2: [machine-file]
BadMachine.swift:4: [machine-file]
BadMachine.swift:5: [machine-file]
BadMachine.swift:6: [machine-file]
BadMachine.swift:7: [machine-file]
Marked.swift:1: [allow] a lint-allow marker names a rule
Tests/Marked.swift: [allow] 1 marker(s), 0 listed
Calls.swift: [isolated]'
  while IFS= read -r want; do
    if ! grep -q -F -- "$want" <<<"$out"; then
      echo "self-test: missing '$want' in:"; echo "$out"; return 1
    fi
  done <<<"$wants"
  local expected
  expected="$(grep -c . <<<"$wants")"
  if [ "$(grep -c . <<<"$out")" -ne "$expected" ]; then
    echo "self-test: expected $expected findings, got:"; echo "$out"; return 1
  fi
  # A listed count that went down must be lowered.
  rm "$dir/Sources/App/Bad.swift" "$dir/Sources/App/BadConformance.swift" "$dir/Sources/App/BadMachine.swift" \
     "$dir/Sources/App/Calls.swift" "$dir/Tests/Marked.swift"
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
