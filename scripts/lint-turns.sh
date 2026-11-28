#!/usr/bin/env bash
# The turn core's rules that the compiler can't check (Notes/plans/2026-11-18-swift-state-turns-core.md §7).
# Per Swift file under Sources/, Tests/ and Examples/ (comments and string literals ignored; a
# declaration whose header spans several lines is read as one):
#
#   plain-data   moved to a test on SwiftSyntax's tokens: Tests/SwiftStateTurnsMacrosTests/
#                PlainDataLintTests.swift (no hand-written `_plainDataCheck` or PlainData
#                conformance outside Sources/SwiftStateTurns, no PlainDataCheck in code, no
#                declaration named SwiftStateTurns, Swift or a standard wrapper). Its `lint-allow`
#                markers are still validated and counted here, one per line.
#   let-core     a type that conforms to TurnActor (in its declaration or in an extension, in any
#                file) declares `let core` as a member of its declaration, and no `var core`
#                member anywhere (the protocol can't require a stored `let`).
#   let-mailbox     a TurnActor's `mailbox` member (in its declaration or an extension) is a stored
#                `nonisolated let mailbox` with no initial value, and every assignment to it in the
#                type's body reads `core.mailbox`: the actor stores the core's own mailbox, never a var,
#                a computed property or another value (#725). No lint-allow marker covers it, so a
#                test actor that replaces its core can't also take mail.
#   machine-file no task (`Task {`, `Task(…)`, `Task<…>`, `Task.init`, `Task.detached`),
#                `nonisolated(unsafe)` or `@unchecked Sendable` in a file that declares a
#                TurnMachine, outside Sources/SwiftStateTurns: a machine's file holds its steps,
#                and its steps start no work and share nothing.
#   isolated     no `assumeIsolated` outside the boundary files listed below, and no more calls in
#                a listed file than its count.
#   unchecked-state  every stored `var` of `TurnCore` (Sources/SwiftStateTurns/TurnCore.swift)
#                carries `@exclusivity(unchecked)` under exactly
#                `#if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED`, on the three lines above it (#621), and
#                no `@exclusivity(unchecked)` there sits under any other line or inline on a
#                declaration (inline it is unchecked in debug builds too). A stored var is a `var`
#                member with an initial value, or whose brace (on its line or the next) holds
#                observers (`didSet`, `willSet`), or with neither a value nor a getter's brace,
#                whatever its modifiers (`lazy`, `private(set)`, `final`). A missing one
#                isn't unsafe, only a release-build slowdown: every use of that var pays the
#                runtime exclusivity check. Debug builds, and release builds with
#                `-Xswiftc -DTURNS_EXCLUSIVITY_CHECKED`, keep the checks.
#   facade       in the file that declares `enum KeeperOwner` (the keeper's facade, #700 K2 plan
#                §3; no file declares it before K2-2, so the rule is inert until then), on
#                `LandKeeper`'s declaration and its extensions there:
#                - every `public` or `package` entry (func, var, subscript; not init) is one
#                  forwarding expression: `live.…` (`return`, `try` and `await` before it are
#                  fine), a `get` accessor holding one, or a `switch owner` whose every arm is
#                  one forwarding expression to a name its pattern binds. An entry that does
#                  other work fails, a guard or an `if` before the forward included. A file
#                  may have as many unforwarded entries as FACADE_EXCEPTIONS lists for it;
#                - every `assumeIsolated` in the file is `live.assumeIsolated`;
#                - no stored `var` member besides `owner`, and no `nonisolated(unsafe)` member.
#                Known limits: a check moved into a helper that the forward calls, or a
#                `let` of a class with mutable state, passes; so does an extension of the
#                facade in another file.
#
# A deliberate site (a test that shows at run time what a rule refuses) carries
# `// lint-allow: turns-<rule>: <reason>` on its line, or on any line of a multi-line header. A
# marker is accepted only under Tests/, with a reason of at least ten characters, and in a file
# listed in ALLOW_MARKERS with no more markers than its count.
#
# A list grows only in a change that adds the rule or runtime path its markers witness, with
# each marker mapped to the code it guards; a marker goes when that code goes. A count below
# its listed value fails until the list is lowered in the same change.
#
# Usage: scripts/lint-turns.sh [--self-test] [repo root]

set -euo pipefail

# Boundary files that enter another actor's isolation synchronously, with their call counts and
# the reason each may.
ISOLATED_BOUNDARIES='
Sources/SwiftStateTreeTransport/TransportAdapter+LandKeeperTransport.swift 6 the keeper calls the adapter inside its turn (the settle phase included), on their shared executor
Sources/SwiftStateTreeTransport/TransportAdapter.swift 3 the adapter submits sync streams into its keeper, on their shared executor
'

# Public or package entries of the facade that don't forward, per file, with their counts and
# the reason each may (the `facade` rule; empty until K2-2 declares the facade).
FACADE_EXCEPTIONS='
'

# Test files that carry allow markers, with their counts.
ALLOW_MARKERS='
Tests/SwiftStateTurnsTests/Support/DemoActor.swift 6 the runtime stops (reentry, a replaced core, a class machine and its checks)
Tests/SwiftStateTreeTests/KeeperReentryTrapTests.swift 1 a handler that re-enters its keeper, to show the exclusivity trap of the model access (LandKeeper.withHandlerStep)
Tests/SwiftStateTreeTests/DecimalRegistrationTests.swift 1 a Decimal in state for the registration walk (#597), which keeps guarding hand-written witnesses
Tests/SwiftStateTreeTests/KeeperTurnSkeletonTests.swift 8 the keeper refuses a synchronous re-entry from a transport or a staged effect during a turn body, its backstop applies one (and refuses the intake whose input it dropped), and an attach from the callback is refused (#700)
Tests/SwiftStateTreeTests/InTurnSyncFoldReportTests.swift 5 a fold-recording transport calls back into its keeper from a tick turn port call, which the sentinel refuses (#700), and from the phase query of initialization (#901)
Tests/SwiftStateTreeTests/KeeperCoreDifferentialTests.swift 12 the core differential ordered trace and its backstop case: a tracing port and a tick handler re-enter the keeper (or the source keeper of the core twin) mid-step, which the sentinel refuses (#700 K2-1); a sync draft factory and an OnJoin handler re-enter the same way, for the in-body re-entry and the failure of a frozen land, and the settle witness re-enters for its callOut case (#700 K2-2a); the OnInitialize body re-enters each path in turn, for the T11 late re-entry twin (#966); and a join report re-enters, for the refused report in a shutdown batch (#969)
Tests/SwiftStateTreeTests/TickLandFailureBeforeFirstTickTests.swift 1 a test body re-enters its keeper outside any call out, which the late backstop applies (#901)
Tests/SwiftStateTreeTests/InitAndDrainSegmentTests.swift 1 OnInitialize re-enters its keeper outside any call out, which the late backstop applies after the body (T11, #700 K2-1b)
Tests/SwiftStateTreeTests/InputTurnHoldTests.swift 1 a payload whose encode(to:) calls back into its keeper, to show the fallback record encode runs before the input turn holds the model (#700)
Tests/SwiftStateTreeTests/NestedNodePolicyTests.swift 1 a class in state for the runtime walk (#464), which keeps guarding hand-written witnesses
Tests/SwiftStateTreeTests/SyncRegistrationTests.swift 3 a class, open types and an Any in state for the runtime walks (#464, #535), which keep guarding hand-written witnesses
Tests/SwiftStateTreeTests/SyncTableDiffTests.swift 2 classes in state for the reference-type fallback of the sync tables (SyncTables.swift), which stays in every build
Tests/SwiftStateTreeTests/SyncTableFallbackFieldsTests.swift 1 a class in state for the reference-type fallback of the sync tables (SyncTables.swift), which stays in every build
Tests/SwiftStateTreeTests/SyncWrapperInPlaceTests.swift 1 a shared box that tells a copy of a synced value from an in-place change (the probe is a class holder on purpose)
Tests/SwiftStateTreeTests/SyncValueSemanticsTests.swift 9 classes in state for the runtime walk (#464), which keeps guarding hand-written witnesses
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
        # One marker per line: a second would be honored by PlainDataLintTests unseen by the count.
        tail = substr(line, RSTART + 14)
        if (index(tail, "// lint-allow:") > 0) allow = "!two"
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
          # A space, so a comment between two tokens can not glue them into one.
          out = out " "; i = i + 2 + j + 1; continue
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
    # The code is everything after the third tab: a source line may hold tabs of its own.
    function rest(n,   t, i) { t = $0; for (i = 1; i < n; i++) sub(/^[^\t]*\t/, "", t); return t }
    {
      path = $1; code = rest(4)
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
    # The code (or header text) is everything after its field: a source line may hold tabs.
    function rest(n,   t, i) { t = $0; for (i = 1; i < n; i++) sub(/^[^\t]*\t/, "", t); return t }
    function allowed(list, rule) { return index("," list ",", "," rule ",") > 0 }
    function last(n) { sub(/.*\./, "", n); return n }
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
      path = $1; n = $2; allow = $3; kind = $4; name = $5; text = rest(6)
      if (core(path)) next
      if (kind == "typealias") next
      list = conformances(text)
      if (word(list, "TurnActor")) {
        actors[last(name)] = 1
        # A qualified extension names its type; a primary declaration names it bare.
        if (kind == "extension") qualified[name] = 1
        else declared[last(name)] = 1
      }
      if (kind != "extension" && kind != "protocol" && word(list, "TurnMachine")) machineFile[path] = 1
      if (kind == "extension" && word(list, "TurnMachine")) machineFile[path] = 1
      next
    }
    # Pass 2: the corpus, line by line, with brace depth per file.
    pass == 2 {
      path = $1; n = $2; allow = $3; code = rest(4)
      if (path != lastPath) { depth = 0; body = 0; pendingName = ""; lastPath = path }
      if (allow == "!bad") {
        print path ":" n ": [allow] a lint-allow marker names a rule (" RULES ") and a reason of at least ten characters"
      } else if (allow == "!two") {
        print path ":" n ": [allow] one lint-allow marker per line"
      } else if (allow != "") {
        if (path !~ /^Tests\//) print path ":" n ": [allow] lint-allow markers are accepted only under Tests/"
        else markers[path]++
      }
      if (!core(path)) {
        # machine-file
        if ((path in machineFile) && !allowed(allow, "machine-file") &&
            code ~ /(^|[^A-Za-z0-9_.])Task[ \t]*(\{|\(|<|\.init|\.detached|$)|nonisolated\(unsafe\)|@unchecked[ \t]+Sendable/)
          print path ":" n ": [machine-file] no task, nonisolated(unsafe) or @unchecked Sendable in a machine'"'"'s file"
        # let-mailbox: an assignment anywhere in a conforming type'"'"'s body reads core.mailbox.
        if (body > 0 && depth >= body && code ~ /^[ \t]*(self\.)?mailbox[ \t]*=[^=]/ &&
            code !~ /=[ \t]*(self\.)?core\.mailbox[ \t]*$/)
          print path ":" n ": [let-mailbox] a TurnActor'"'"'s mailbox is assigned from core.mailbox only"
        # let-core: a member of a conforming type'"'"'s declaration or extension.
        if (body > 0 && depth == body) {
          # Only what precedes the first brace on the line is at member level.
          member = code; sub(/\{.*/, "", member)
          if (member ~ /(^|[^A-Za-z0-9_])let[ \t]+core([^A-Za-z0-9_]|$)/ && bodyKind != "extension") hasLet[bodyLoc] = 1
          if (member ~ /(^|[^A-Za-z0-9_])var[ \t]+core([^A-Za-z0-9_]|$)/) {
            if (allowed(allow, "let-core")) markedVar[bodyLoc] = 1
            else print path ":" n ": [let-core] a TurnActor'"'"'s core is a stored let, not a var"
          }
          if (member ~ /(^|[^A-Za-z0-9_])var[ \t]+mailbox([^A-Za-z0-9_]|$)/)
            print path ":" n ": [let-mailbox] a TurnActor'"'"'s mailbox is a stored nonisolated let, not a var"
          else if (member ~ /(^|[^A-Za-z0-9_])let[ \t]+mailbox([^A-Za-z0-9_]|$)/ &&
                   (member !~ /nonisolated[ \t]+let[ \t]+mailbox/ || member ~ /let[ \t]+mailbox[^=]*=/))
            print path ":" n ": [let-mailbox] a TurnActor'"'"'s mailbox is a nonisolated let, with no initial value"
        }
        if (match(code, /(^|[^A-Za-z0-9_@.])(struct|class|actor|extension)[ \t]+[A-Za-z_][A-Za-z0-9_.]*/)) {
          decl = substr(code, RSTART, RLENGTH); sub(/^[^A-Za-z]/, "", decl)
          split(decl, parts, /[ \t]+/)
          # A TurnActor is an actor (the protocol refines Actor), so a namesake struct or class
          # is not one. A qualified extension counts when that qualified name conforms, or when
          # the type declared the conformance itself.
          candidate = last(parts[2]) in actors
          if (candidate && parts[1] != "actor" && parts[1] != "extension") candidate = 0
          if (candidate && parts[1] == "extension" && index(parts[2], ".") > 0 &&
              !(parts[2] in qualified) && !(last(parts[2]) in declared)) candidate = 0
          if (candidate) { pendingName = last(parts[2]); pendingKind = parts[1]; pendingLine = n }
        }
      }
      before = depth
      depth += braces(code)
      if (pendingName != "" && index(code, "{") > 0) {
        # The body opens on this line: its members are one level below the brace.
        body = before + 1; bodyName = pendingName; bodyKind = pendingKind; pendingName = ""
        bodyLoc = path ":" pendingLine
        if (bodyKind != "extension") { primary[bodyLoc] = bodyName }
        if (depth < body) body = 0
      } else if (body > 0 && depth < body) {
        body = 0
      }
      next
    }
    END {
      # Each primary declaration of a TurnActor name needs its own `let core`: two nested
      # types can share a bare name.
      for (loc in primary) {
        if (!(loc in hasLet) && !(loc in markedVar))
          print loc ": [let-core] a TurnActor declares '"'"'let core'"'"' as a member"
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
    { code = $0; sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", code) }
    code ~ /(^|[^A-Za-z0-9_])assumeIsolated([^A-Za-z0-9_]|$)/ { count[$1]++ }
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

  unchecked_state >> "$findings"
  facade_rule "$heads" "$corpus" >> "$findings"

  if [ -s "$findings" ]; then
    sort "$findings"
    return 1
  fi
}

# unchecked-state, over TurnCore.swift as written (its `#if` lines are what it checks).
unchecked_state() {
  local file=Sources/SwiftStateTurns/TurnCore.swift
  if [ ! -f "$file" ]; then
    echo "$file: [unchecked-state] not found: the rule checks TurnCore's stored vars there"
    return
  fi
  # shellcheck disable=SC2016 # awk program, not shell
  awk -v path="$file" '
    function isVar(l) { return l ~ /^    (@?[A-Za-z_]+(\([^)]*\))? )*var [A-Za-z_]+/ }
    function unguarded(n) {
      print path ":" n ": [unchecked-state] a stored var of TurnCore without #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED / @exclusivity(unchecked) / #endif on the lines above it"
    }
    /^public final class TurnCore</ { inClass = 1; next }
    inClass && /^}/ { inClass = 0 }
    !inClass { next }
    {
      line = $0
      # A var decided by its next line. "observers": its line opened a brace, so it is stored
      # only if observers follow. "bare": no brace and no initial value, so it is stored unless
      # the next line opens the brace of a getter.
      if (pending == "observers") {
        if (line ~ /^[[:space:]]*(didSet|willSet)/) { stored++; if (!pendingGuarded) unguarded(pendingLine) }
      } else if (pending == "bare") {
        if (line !~ /^[[:space:]]*[{]/ || line ~ /^[[:space:]]*[{][[:space:]]*(didSet|willSet)/ || line ~ /^[[:space:]]*(didSet|willSet)/) {
          stored++; if (!pendingGuarded) unguarded(pendingLine)
        }
      }
      pending = ""
      if (index(line, "@exclusivity(unchecked)") > 0 && line !~ /^    @exclusivity\(unchecked\)[[:space:]]*$/) {
        print path ":" NR ": [unchecked-state] @exclusivity(unchecked) on a line of its own only, under #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED: inline it is unchecked in debug builds too"
        if (isVar(line)) stored++
        guarded = 0
      } else if (line ~ /^    @exclusivity\(unchecked\)[[:space:]]*$/) {
        if (prev != "    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED") print path ":" NR ": [unchecked-state] @exclusivity(unchecked) outside #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED: debug builds and that flag keep the checks"
      } else if (line ~ /^    #endif[[:space:]]*$/) {
        guarded = (prev == "    @exclusivity(unchecked)" && prev2 == "    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED")
      } else if (isVar(line)) {
        # Stored now: a brace that holds observers, or an initial value before any brace
        # (`lazy var x = { ... }()` included). Otherwise the next line decides.
        if (line ~ /[{][[:space:]]*(didSet|willSet)/ || line ~ /^[^{]*=/) {
          stored++
          if (!guarded) unguarded(NR)
        } else {
          pending = (line ~ /[{]/) ? "observers" : "bare"; pendingLine = NR; pendingGuarded = guarded
        }
        guarded = 0
      } else if (line != "    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED") {
        guarded = 0
      }
      prev2 = prev; prev = line
    }
    END { if (stored == 0) print path ": [unchecked-state] no stored var of TurnCore found: the rule matches nothing" }' "$file"
}

# facade, over the file that declares `enum KeeperOwner` (K2 plan §3): the facade is
# `LandKeeper`'s declaration and extensions there. Inert until K2-2 declares the owner.
facade_rule() {  # heads corpus
  # shellcheck disable=SC2016 # awk program, not shell
  LINT_FACADE="$FACADE_EXCEPTIONS" awk -F'\t' '
    function rest(n,   t, i) { t = $0; for (i = 1; i < n; i++) sub(/^[^\t]*\t/, "", t); return t }
    function last(n) { sub(/.*\./, "", n); return n }
    function trim(t) { sub(/^[ \t\n]+/, "", t); sub(/[ \t\n]+$/, "", t); return t }
    function braces(code,   i, c, d) {
      d = 0
      for (i = 1; i <= length(code); i++) { c = substr(code, i, 1); if (c == "{") d++; else if (c == "}") d-- }
      return d
    }
    # The index of the bracket that closes the one at `open` (any of ( [ {), or 0.
    function closing(t, open,   i, c, d) {
      d = 0
      for (i = open; i <= length(t); i++) {
        c = substr(t, i, 1)
        if (c == "(" || c == "[" || c == "{") d++
        else if (c == ")" || c == "]" || c == "}") { d--; if (d == 0) return i }
      }
      return 0
    }
    # The index of the first `{` outside parentheses and brackets, or 0.
    function firstBrace(t,   i, c, d) {
      d = 0
      for (i = 1; i <= length(t); i++) {
        c = substr(t, i, 1)
        if (c == "(" || c == "[") d++
        else if (c == ")" || c == "]") d--
        else if (c == "{" && d == 0) return i
      }
      return 0
    }
    # One statement: no `;` and no new line at depth 0 that starts another. A line that starts
    # with `.` or a closing bracket, or follows one that ends in an operator, continues it.
    function single(t,   i, c, d, r, f, b) {
      d = 0
      for (i = 1; i <= length(t); i++) {
        c = substr(t, i, 1)
        if (c == "(" || c == "[" || c == "{") d++
        else if (c == ")" || c == "]" || c == "}") d--
        else if (d == 0 && (c == ";" || c == "\n")) {
          r = trim(substr(t, i + 1)); if (r == "") return 1
          if (c == ";") return 0
          f = substr(r, 1, 1); b = trim(substr(t, 1, i - 1)); b = substr(b, length(b), 1)
          if (index(".)]}", f) == 0 && (b == "" || index("(,.=+*/&|?:[-", b) == 0)) return 0
        }
      }
      return 1
    }
    function forwardsTo(t, names,   p) {
      p = "^((return|try[?!]?|await)[ \t\n]+)*(" names ")[ \t\n]*\\."
      return single(t) && t ~ p
    }
    # Each arm of `switch owner` is one forwarding expression to a name its pattern binds.
    function armsForward(t,   n, L, i, d, line, arms, a, k, txt, colon, j, c, pd, pat, stmt, names, m) {
      n = split(t, L, "\n"); d = 0; arms = 0
      for (i = 1; i <= n; i++) {
        line = trim(L[i])
        if (d == 0 && line ~ /^(case[ \t]|default[ \t]*:|@unknown[ \t]+default)/) { arms++; arm[arms] = line }
        else if (line != "") { if (arms == 0) return 0; arm[arms] = arm[arms] "\n" line }
        d += braces(L[i])
      }
      if (arms == 0) return 0
      for (a = 1; a <= arms; a++) {
        txt = arm[a]; colon = 0; pd = 0
        for (j = 1; j <= length(txt); j++) {
          c = substr(txt, j, 1)
          if (c == "(") pd++; else if (c == ")") pd--; else if (c == ":" && pd == 0) { colon = j; break }
        }
        if (colon == 0) return 0
        pat = substr(txt, 1, colon - 1); stmt = trim(substr(txt, colon + 1)); names = ""
        if (pat ~ /^case[ \t]+let[ \t]/) {
          m = pat; sub(/^[^(]*\(/, "", m); sub(/\).*/, "", m); gsub(/[ \t]/, "", m); gsub(/,/, "|", m); names = m
        } else {
          m = pat
          while (match(m, /(let|var)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
            k = substr(m, RSTART, RLENGTH); sub(/^(let|var)[ \t]+/, "", k)
            names = names (names == "" ? "" : "|") k; m = substr(m, RSTART + RLENGTH)
          }
        }
        if (names == "" || !forwardsTo(stmt, names)) return 0
      }
      return 1
    }
    function forwards(t,   b, o, e) {
      b = trim(t)
      if (b ~ /^get([ \t\n]+(async|throws))*[ \t\n]*\{/) {
        o = index(b, "{"); e = closing(b, o)
        if (e == 0 || trim(substr(b, e + 1)) != "") return 0
        return forwards(substr(b, o + 1, e - o - 1))
      }
      if (b ~ /^switch[ \t]+(self\.)?owner[ \t\n]*\{/) {
        o = index(b, "{"); e = closing(b, o)
        if (e == 0 || trim(substr(b, e + 1)) != "") return 0
        return armsForward(substr(b, o + 1, e - o - 1))
      }
      return forwardsTo(b, "(self\\.)?live")
    }
    function finish(   o, e) {
      o = firstBrace(entText); e = o ? closing(entText, o) : 0
      if (!o || !e || !forwards(substr(entText, o + 1, e - o - 1))) {
        k = ++unforwarded[path]; unforwardedAt[path, k] = entLine
      }
      ent = 0
    }
    FNR == 1 { pass++ }
    pass == 1 {
      if ($4 == "enum" && last($5) == "KeeperOwner") facadeFile[$1] = 1
      next
    }
    {
      path = $1; n = $2; code = rest(4)
      if (path != lastPath) { depth = 0; fbody = 0; pendingF = 0; ent = 0; varPending = 0; lastPath = path }
      if (!(path in facadeFile)) next
      # Clause 2: every assumeIsolated in the file is live.assumeIsolated.
      t = code
      while (match(t, /[A-Za-z0-9_.]*assumeIsolated([^A-Za-z0-9_]|$)/)) {
        recv = substr(t, RSTART, RLENGTH); sub(/\.?assumeIsolated.*/, "", recv)
        if (recv !~ /(^|\.)live$/) { print path ":" n ": [facade] assumeIsolated in the facade file is live.assumeIsolated only"; break }
        t = substr(t, RSTART + RLENGTH)
      }
      before = depth
      if (varPending) {
        if (code !~ /^[ \t]*\{/ || code ~ /^[ \t]*\{[ \t]*(didSet|willSet)/)
          print path ":" varLine ": [facade] the facade has no stored var besides owner"
        varPending = 0
      }
      if (ent) {
        entText = entText "\n" code
      } else if (fbody > 0 && depth == fbody) {
        member = code; sub(/\{.*/, "", member)
        after = code; if (index(code, "{")) sub(/^[^{]*\{/, "", after); else after = ""
        stored = 0
        if (member ~ /nonisolated\(unsafe\)/) {
          print path ":" n ": [facade] no nonisolated(unsafe) member on the facade"
        } else if (match(member, /(^|[^A-Za-z0-9_])var[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
          name = substr(member, RSTART, RLENGTH); sub(/.*var[ \t]+/, "", name)
          if (index(code, "{")) stored = (member ~ /=/ || after ~ /^[ \t]*(didSet|willSet)/)
          else if (member ~ /=/) stored = 1
          else if (name != "owner") { varPending = 1; varLine = n }
          if (stored && name != "owner") print path ":" n ": [facade] the facade has no stored var besides owner"
        }
        if (!stored && !varPending && member ~ /(^|[ \t])(public|package)([ \t(]|$)/ &&
            member ~ /(^|[^A-Za-z0-9_])(func|var|subscript)([ \t(]|$)/) {
          ent = 1; entText = code; entLine = n; entDepth = depth
        }
      }
      if (fbody == 0 && match(code, /(^|[^A-Za-z0-9_@.])(actor|extension)[ \t]+LandKeeper([^A-Za-z0-9_.]|$)/)) pendingF = 1
      depth += braces(code)
      if (pendingF && index(code, "{") > 0) { fbody = before + 1; pendingF = 0; if (depth < fbody) fbody = 0 }
      else if (fbody > 0 && depth < fbody) fbody = 0
      # The entry ends where its body closes: back at the depth it started at.
      if (ent && index(entText, "{") > 0 && depth <= entDepth) finish()
      next
    }
    END {
      nl = split(ENVIRON["LINT_FACADE"], rows, "\n")
      for (i = 1; i <= nl; i++) { split(rows[i], f, " "); if (f[1] != "") listed[f[1]] = f[2] }
      for (p in unforwarded) {
        a = (p in listed) ? listed[p] : 0
        if (unforwarded[p] + 0 > a + 0)
          for (k = 1; k <= unforwarded[p]; k++)
            print p ":" unforwardedAt[p, k] ": [facade] a public or package entry of the facade is one forwarding expression (live.…, or a switch owner whose arms forward); list an exception in FACADE_EXCEPTIONS only with a reason"
      }
      for (p in listed) {
        c = (p in unforwarded) ? unforwarded[p] : 0
        if (c + 0 < listed[p] + 0) print p ": [facade] " c " entr(ies) that do not forward, listed " listed[p] ": lower FACADE_EXCEPTIONS"
      }
    }' "$1" "$2"
}

self_test() {
  local dir out
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the path is local
  trap "rm -rf '$dir'" RETURN
  mkdir -p "$dir/Sources/App" "$dir/Sources/SwiftStateTurns" "$dir/Tests/SwiftStateTurnsTests/Support" "$dir/Examples"
  # The facade fixtures: one listed exception, and the facade's two forwarding calls listed as
  # a boundary file, as K2-2 lists the facade's file.
  local FACADE_EXCEPTIONS='
Sources/App/Facade.swift 1 a nonisolated read that needs no hop
'
  local ISOLATED_BOUNDARIES="$ISOLATED_BOUNDARIES
Sources/App/Facade.swift 2 the facade forwards on its core's executor
"
  local path n _reason
  while read -r path n _reason; do
    [ -n "$path" ] || continue
    mkdir -p "$dir/$(dirname "$path")"
    for _ in $(seq "$n"); do echo 'x.assumeIsolated { _ in }'; done > "$dir/$path"
  done <<<"$ISOLATED_BOUNDARIES"
  # Passing fixture. The marked file carries as many markers as ALLOW_MARKERS lists.
  cat > "$dir/Sources/SwiftStateTurns/TurnCore.swift" <<'EOF'
public final class TurnCore<M: TurnMachine> {
    /// A doc line above the condition.
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline var machine: M
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    @usableFromInline package var onDiagnostic: ((TurnDiagnostic) -> Void)?
    @usableFromInline let clock: any TurnClock
    public var stats: TurnStats {
        var stats = counters
        return stats
    }
}
EOF
  cat > "$dir/Sources/App/Good.swift" <<'EOF'
// struct Fake: PlainData {} in a comment, and "extension X: PlainData" in a string.
let text = "struct S: PlainData {}"
@PlainData
struct Model: TurnMachine { var n: Int }
struct Box<T: PlainData>: Sendable where T: PlainData {}
func use<T>(_ value: T) where T: PlainData {}
protocol Constrained where Self: Sendable {}
typealias Pair = PlainPair<Int, Int>
// A protocol may refine PlainData: its conformers still need the requirement.
protocol Bridge: Sendable, PlainData {}
protocol WhereBridge where Self: PlainData {}
protocol WhereSplit
    where Self: Sendable & PlainData
{
}
actor Owner:
    TurnActor
{
    let core = makeCore()
    func local() { let core = self.core; _ = core }
}
actor Split {
    let core = makeCore()
}
enum Left {
    actor Pane {
        let core = makeCore()
    }
}
extension Left.Pane: TurnActor {}
enum Right {
    struct Pane {
        var core = 0
    }
}
extension Right.Pane {
    var core: Int { 0 }
}
EOF
  cat > "$dir/Sources/App/SplitConformance.swift" <<'EOF'
extension Split: TurnActor {}
actor Mailboxd: TurnActor {
    let core: TurnCore<M>
    nonisolated let mailbox: TurnMailbox<R>?
    init() {
        let core = makeCore()
        self.core = core
        self.mailbox = core.mailbox
        if let mailbox = self.mailbox { _ = mailbox }
    }
}
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
    echo 'extension ClassMachine { static func _plainDataCheck() {} } // lint-allow: turns-plain-data: its requirement'
    local extra
    extra=$(( ${markers##* } - 4 ))
    for _ in $(seq "$extra"); do echo 'let a = 0 // lint-allow: turns-isolated: fills the listed marker count'; done
  } > "$dir/${markers%% *}"
  # Every other listed file carries exactly its listed count.
  local listed count
  while read -r listed count _reason; do
    [ -n "$listed" ] && [ "$listed" != "${markers%% *}" ] || continue
    mkdir -p "$dir/$(dirname "$listed")"
    for _ in $(seq "$count"); do echo 'let a = 0 // lint-allow: turns-plain-data: fills the listed marker count'; done > "$dir/$listed"
  done <<<"$ALLOW_MARKERS"
  cat > "$dir/Sources/SwiftStateTurns/Core.swift" <<'EOF'
extension Int: PlainData {}
public final class WithdrawToken: @unchecked Sendable {}
public protocol TurnActor: Actor { var core: TurnCore<M> { get } }
public protocol TurnMachine: Sendable {}
EOF
  cat > "$dir/Sources/App/Facade.swift" <<'EOF'
enum KeeperOwner {
    case live(LiveTurns)
    case replay(ReplayOwner)
}
actor LiveTurns {
    nonisolated(unsafe) weak var facade: AnyObject?
    var count = 0
    func work() -> Int { count += 1; return count }
}
public actor LandKeeper<State> {
    let owner: KeeperOwner
    let live: LiveTurns
    nonisolated public var unownedExecutor: UnownedSerialExecutor { live.unownedExecutor }
    public init(live: LiveTurns) {
        self.live = live
        self.owner = .live(live)
    }
    public func count() -> Int { live.assumeIsolated { $0.work() } }
    @discardableResult
    public func join(
        playerID: String,
        clientID: String
    ) async throws -> Int {
        try await live.join(
            playerID: playerID,
            clientID: clientID
        )
    }
    package func closure() -> Int {
        live.assumeIsolated { turns in
            let a = turns.work()
            return a + 1
        }
    }
    public var state: Int {
        get async { await live.state }
    }
    public func located() async -> Int {
        switch owner {
        case .live(let live):
            return await live.located()
        case let .replay(replay):
            return replay.located()
        }
    }
    public func chained() async -> Int {
        await live
            .chained()
    }
    public nonisolated var exceptionCount: Int { 0 }
    private var computed: Int { 0 }
    private func helper() -> Int { if true { return 1 }; return 2 }
    package struct Outcome {
        var a: Int
        public func f() -> Int { a }
    }
}
extension LandKeeper {
    public func fromExtension() async -> Int { await live.fromExtension() }
}
EOF
  # Not the facade's file (no KeeperOwner): the rule is inert there.
  cat > "$dir/Sources/App/NotFacade.swift" <<'EOF'
actor LandKeeper {
    var x = 0
    public func f() -> Int { if true { return 1 }; return x }
}
EOF
  if ! out="$(lint "$dir" 2>&1)"; then
    echo "self-test: the passing fixture failed:"; echo "$out"; return 1
  fi
  # Failing fixture: one hit per case.
  cat > "$dir/Sources/App/Bad.swift" <<'EOF'
// (plain-data: PlainDataLintTests)
// (plain-data: PlainDataLintTests)
actor VarOwner: TurnActor {
    var core = makeCore()
}
// (the refining protocols are in the passing fixture)
// (plain-data: PlainDataLintTests)
// (plain-data: PlainDataLintTests)
// (plain-data: PlainDataLintTests)
// (plain-data: PlainDataLintTests)
// (plain-data: PlainDataLintTests)
// (plain-data: PlainDataLintTests)
// (plain-data: PlainDataLintTests)
// (plain-data: PlainDataLintTests)
actor LocalOnly: TurnActor {
    func f() { let core = makeCore(); _ = core }
}
actor Elsewhere {
    var core = makeCore()
}
let x = 0 // lint-allow: turns-isolated: a marker outside Tests
//
//
//
//
//
enum A {
    actor Owner: TurnActor {
        let core = makeCore()
    }
}
enum B {
    actor Owner: TurnActor {
    }
}
extension B.Owner {
    var core: TurnCore<M> { fatalError() }
}
actor MailboxVar: TurnActor {
    let core = makeCore()
    var mailbox: TurnMailbox<R>? = nil
}
actor MailboxIsolated: TurnActor {
    let core = makeCore()
    let mailbox: TurnMailbox<R>?
    init() {
        mailbox = makeMailbox()
    }
}
actor MailboxValue: TurnActor {
    let core = makeCore()
    nonisolated let mailbox = makeMailbox()
}
extension MailboxValue {
    nonisolated var mailbox2: Int { 0 }
}
actor TabOwner: TurnActor {
	var core = makeCore()
}
EOF
  cat > "$dir/Sources/App/BadConformance.swift" <<'EOF'
extension Elsewhere: TurnActor {}
EOF
  cat > "$dir/Sources/App/BadFacade.swift" <<'EOF'
enum KeeperOwner { case live(LiveTurns), replay(ReplayOwner) }
actor LandKeeper {
    let owner: KeeperOwner
    private var pendingFold: Int = 0
    nonisolated(unsafe) let leak = Box()
    var bare: Int
    public func guarded() async -> Int {
        if isDraining { return 0 }
        return await live.guarded()
    }
    package func crossed() {
        transport.assumeIsolated { _ in }
    }
    public func twice() async {
        await live.twice(); count += 1
    }
    public func arms() async -> Int {
        switch owner {
        case .live(let live):
            return await live.arms()
        case .replay:
            return 0
        }
    }
    var observed: Int = 0 { didSet { } }
    public func bareSelf() { assumeIsolated { _ in } }
}
EOF
  cat > "$dir/Sources/App/BadMachine.swift" <<'EOF'
struct Machine: TurnMachine {
    mutating func handle() { Task { } }
}
nonisolated(unsafe) var shared = 0
final class Box: @unchecked Sendable {}
func later() { Task(priority: .high) { } }
func typed() { _ = Task<Void, Never> { } }
func split() {
    Task
        .detached(priority: .high) { }
}
func spelled() { Task.init { }; Task.detached { } }
EOF
  cat > "$dir/Tests/Marked.swift" <<'EOF'
let y = 0 // lint-allow: turns-isolated:
let z = 0 // lint-allow: turns-isolated: unlisted file, but a reason
let w = 0 // lint-allow: turns-isolated: the first reason // lint-allow: turns-plain-data: a hidden second
EOF
  echo 'y.assumeIsolated { _ in }' > "$dir/Sources/App/Calls.swift"
  cp "$dir/Sources/SwiftStateTurns/TurnCore.swift" "$dir/GoodTurnCore.swift"
  cat > "$dir/Sources/SwiftStateTurns/TurnCore.swift" <<'EOF'
public final class TurnCore<M: TurnMachine> {
    @usableFromInline var bare = 0
    @exclusivity(unchecked)
    @usableFromInline var always = 0
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    /// A line between the condition and the var.
    @usableFromInline var separated = 0
    #if !DEBUG && !TURNS_EXCLUSIVITY_CHECKED
    @exclusivity(unchecked)
    #endif
    private var hidden = false
    #if !DEBUG
    @exclusivity(unchecked)
    #endif
    @usableFromInline var oldCondition = 0
    @exclusivity(unchecked) @usableFromInline var inline = 0
    lazy var lazyOne = 0
    private(set) var privateSet = 0
    final var finalOne = 0
    @usableFromInline var observed = 0 {
        didSet { }
    }
    var observedInline = 0 { didSet { } }
    lazy var closureInit: [Int] = { [] }()
    var computed: Int {
        0
    }
    var computedNextLine: Int
    {
        0
    }
    var uninitialized: Int
    var observedNextBrace: Int
    { didSet { } }
}
EOF
  out="$(lint "$dir" 2>&1)" && { echo "self-test: the failing fixture passed"; return 1; }
  local want wants
  wants='Bad.swift:3: [let-core] a TurnActor declares
Bad.swift:4: [let-core] a TurnActor'"'"'s core is a stored let
Bad.swift:15: [let-core] a TurnActor declares
Bad.swift:18: [let-core] a TurnActor declares
Bad.swift:19: [let-core] a TurnActor'"'"'s core is a stored let
Bad.swift:21: [allow] lint-allow markers are accepted only under Tests/
Bad.swift:33: [let-core] a TurnActor declares
Bad.swift:37: [let-core] a TurnActor'"'"'s core is a stored let
Bad.swift:41: [let-mailbox] a TurnActor'"'"'s mailbox is a stored nonisolated let, not a var
Bad.swift:45: [let-mailbox] a TurnActor'"'"'s mailbox is a nonisolated let
Bad.swift:47: [let-mailbox] a TurnActor'"'"'s mailbox is assigned from core.mailbox only
Bad.swift:52: [let-mailbox] a TurnActor'"'"'s mailbox is a nonisolated let
Bad.swift:57: [let-core] a TurnActor declares
Bad.swift:58: [let-core] a TurnActor'"'"'s core is a stored let
BadMachine.swift:2: [machine-file]
BadMachine.swift:4: [machine-file]
BadMachine.swift:5: [machine-file]
BadMachine.swift:6: [machine-file]
BadMachine.swift:7: [machine-file]
BadMachine.swift:9: [machine-file]
BadMachine.swift:12: [machine-file]
Marked.swift:1: [allow] a lint-allow marker names a rule
Marked.swift:3: [allow] one lint-allow marker per line
Tests/Marked.swift: [allow] 1 marker(s), 0 listed
Calls.swift: [isolated]
BadFacade.swift: [isolated]
BadFacade.swift:4: [facade] the facade has no stored var besides owner
BadFacade.swift:5: [facade] no nonisolated(unsafe) member on the facade
BadFacade.swift:6: [facade] the facade has no stored var besides owner
BadFacade.swift:7: [facade] a public or package entry of the facade is one forwarding expression
BadFacade.swift:11: [facade] a public or package entry of the facade is one forwarding expression
BadFacade.swift:12: [facade] assumeIsolated in the facade file is live.assumeIsolated only
BadFacade.swift:14: [facade] a public or package entry of the facade is one forwarding expression
BadFacade.swift:17: [facade] a public or package entry of the facade is one forwarding expression
BadFacade.swift:25: [facade] the facade has no stored var besides owner
BadFacade.swift:26: [facade] a public or package entry of the facade is one forwarding expression
BadFacade.swift:26: [facade] assumeIsolated in the facade file is live.assumeIsolated only
TurnCore.swift:2: [unchecked-state] a stored var
TurnCore.swift:3: [unchecked-state] @exclusivity(unchecked) outside
TurnCore.swift:4: [unchecked-state] a stored var
TurnCore.swift:9: [unchecked-state] a stored var
TurnCore.swift:15: [unchecked-state] @exclusivity(unchecked) outside
TurnCore.swift:17: [unchecked-state] a stored var
TurnCore.swift:18: [unchecked-state] @exclusivity(unchecked) on a line of its own only
TurnCore.swift:19: [unchecked-state] a stored var
TurnCore.swift:20: [unchecked-state] a stored var
TurnCore.swift:21: [unchecked-state] a stored var
TurnCore.swift:22: [unchecked-state] a stored var
TurnCore.swift:25: [unchecked-state] a stored var
TurnCore.swift:26: [unchecked-state] a stored var
TurnCore.swift:34: [unchecked-state] a stored var
TurnCore.swift:35: [unchecked-state] a stored var'
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
     "$dir/Sources/App/BadFacade.swift" \
     "$dir/Sources/App/Calls.swift" "$dir/Tests/Marked.swift"
  mv "$dir/GoodTurnCore.swift" "$dir/Sources/SwiftStateTurns/TurnCore.swift"
  local first
  first="$(awk 'NF { print $1; exit }' <<<"$ISOLATED_BOUNDARIES")"
  sed -i.bak '1d' "$dir/$first" && rm -f "$dir/$first.bak"
  out="$(lint "$dir" 2>&1)" && { echo "self-test: a lowered count passed"; return 1; }
  grep -q -F "lower the list" <<<"$out" || { echo "self-test: no 'lower the list' in:"; echo "$out"; return 1; }
  # A facade exception that went away must be lowered too.
  sed -i.bak '/exceptionCount/d' "$dir/Sources/App/Facade.swift" && rm -f "$dir/Sources/App/Facade.swift.bak"
  out="$(lint "$dir" 2>&1)" && { echo "self-test: a lowered facade count passed"; return 1; }
  grep -q -F "lower FACADE_EXCEPTIONS" <<<"$out" || { echo "self-test: no 'lower FACADE_EXCEPTIONS' in:"; echo "$out"; return 1; }
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
