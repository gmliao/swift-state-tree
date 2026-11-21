#!/usr/bin/env bash
# Checks that a client of SwiftStateTurns gets the core's step path specialized for its own
# machine, with no build flag (Notes/plans/2026-11-18-swift-state-turns-core.md, rule 19).
#
# Builds TurnsBench in release and reads its symbols: the core's generic code inlined into the
# bench appears as generic specializations on the bench's machine and actor types. Each driver
# function in REQUIRED must have one; a missing one means the step path runs through
# unspecialized generic code, several times slower per step. The usual cause is a function on it
# that lost `@inlinable`, or a type it touches that lost `@usableFromInline`.
#
# The negative control builds a copy of the package with every `@inlinable` in the core removed
# (internal ones become `@usableFromInline`, so the copy still compiles), and expects the same
# check to find nothing. A check that passes there can't tell the two apart.
#
# Usage: scripts/check-turns-inlinable.sh [scratch path]   (default .build)
# Needs the build slot (it builds twice).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${1:-$root/.build}"
cd "$root"

# The driver functions that must be specialized on TurnsBench's types, per bench machine.
# BenchMachine declares no follow-ups (`FollowUpSlot == Never`), so the core's follow-up paths
# fold away on it; they are checked on FollowUpBenchMachine, which has them. Not covered: the
# gate path (`gateReturned`, `launchGate`), which needs a bench machine whose `Effect` isn't
# `Never`.
BENCH_TYPES='TurnsBench\.(BenchMachine|BenchActor)'
REQUIRED='SwiftStateTurns.TurnCore.step(
(extension in SwiftStateTurns):SwiftStateTurns.TurnActor.runSegment('
FOLLOW_UP_TYPES='TurnsBench\.(FollowUpBenchMachine|FollowUpBenchActor)'
FOLLOW_UP_REQUIRED='SwiftStateTurns.TurnCore.step(
(extension in SwiftStateTurns):SwiftStateTurns.TurnActor.runSegment(
(extension in SwiftStateTurns):SwiftStateTurns.TurnActor.continueBatch(
(extension in SwiftStateTurns):SwiftStateTurns.TurnActor.scheduleContinuation(
(extension in SwiftStateTurns):SwiftStateTurns.TurnActor.settleQuiescence(
(extension in SwiftStateTurns):SwiftStateTurns.TurnActor.registerQuiescenceWaiter('

# Builds TurnsBench in release in package $1 with scratch path $2; prints its path. Fails when the
# build fails, so a stale binary from an earlier build is never read.
build_bench() {  # package scratch
  local log
  log="$(mktemp)"
  if ! (cd "$1" && swift build -c release --product TurnsBench --scratch-path "$2") > "$log" 2>&1; then
    grep -m 20 -E "error:" "$log" >&2 || tail -20 "$log" >&2
    rm -f "$log"
    echo "check-turns-inlinable: FAILED: the release build of TurnsBench failed" >&2
    return 1
  fi
  rm -f "$log"
  local binary
  binary="$(cd "$1" && swift build -c release --product TurnsBench --scratch-path "$2" --show-bin-path)/TurnsBench"
  [ -x "$binary" ] || { echo "check-turns-inlinable: FAILED: no TurnsBench binary at $binary" >&2; return 1; }
  echo "$binary"
}

# Prints the functions of `required` that have no specialization on `types` (an ERE), one per
# line; prints nothing when all have one.
# Fails when nm can't read the binary or finds none of the bench's symbols, so a wrong path
# can't pass as "nothing specialized".
missing_in() {  # binary types required
  local symbols demangled specialized required
  symbols="$(nm "$1")" || { echo "check-turns-inlinable: FAILED: nm couldn't read $1" >&2; return 1; }
  # Full demangling: `--simplified` drops the specialization's type arguments.
  demangled="$(awk '{ print $NF }' <<<"$symbols" | swift demangle)" \
    || { echo "check-turns-inlinable: FAILED: swift demangle failed on $1" >&2; return 1; }
  grep -q -F 'TurnsBench.' <<<"$demangled" \
    || { echo "check-turns-inlinable: FAILED: no TurnsBench symbols in $1" >&2; return 1; }
  # Identical specializations on two bench actors are folded into one `merged generic
  # specialization` symbol, named after one of them: it counts.
  specialized="$(grep -E "^(merged )?generic specialization <[^>]*$2" <<<"$demangled" || true)"
  while IFS= read -r required; do
    [ -n "$required" ] || continue
    grep -q -F -- "> of $required" <<<"$specialized" || echo "$required"
  done <<<"$3"
}

binary="$(build_bench "$root" "$scratch")"
missing="$(missing_in "$binary" "$BENCH_TYPES" "$REQUIRED")" || exit 1
follow_up_missing="$(missing_in "$binary" "$FOLLOW_UP_TYPES" "$FOLLOW_UP_REQUIRED")" || exit 1
if [ -n "$missing$follow_up_missing" ]; then
  if [ -n "$missing" ]; then
    echo "check-turns-inlinable: FAILED: no specialization on BenchMachine/BenchActor for:"
    awk '{ print "  " $0 }' <<<"$missing"
  fi
  if [ -n "$follow_up_missing" ]; then
    echo "check-turns-inlinable: FAILED: no specialization on FollowUpBenchMachine/FollowUpBenchActor for:"
    awk '{ print "  " $0 }' <<<"$follow_up_missing"
  fi
  echo "(check that the step path is @inlinable and what it touches @usableFromInline)"
  exit 1
fi
echo "check-turns-inlinable: every required driver function is specialized on TurnsBench's types"

# The negative control: the same package with the core's @inlinable attributes removed.
control="$scratch/turns-inlinable-control"
rm -rf "$control/package"
mkdir -p "$control/package/Sources"
cp Package.resolved "$control/package/"
cp -R Sources/SwiftStateTurns Sources/SwiftStateTurnsMacros Sources/TurnsBench "$control/package/Sources/"
# The same three targets as the package's, and its swift-syntax requirement.
syntax="$(grep -E '\.package\(url: "https://github.com/apple/swift-syntax.git"' Package.swift | sed -E 's/^[[:space:]]*//; s/,$//')"
cat > "$control/package/Package.swift" <<EOF
// swift-tools-version: 6.0
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "TurnsInlinableControl",
    platforms: [.macOS(.v14)],
    dependencies: [$syntax],
    targets: [
        .target(name: "SwiftStateTurns", dependencies: ["SwiftStateTurnsMacros"], path: "Sources/SwiftStateTurns"),
        .macro(
            name: "SwiftStateTurnsMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/SwiftStateTurnsMacros"
        ),
        .executableTarget(name: "TurnsBench", dependencies: ["SwiftStateTurns"], path: "Sources/TurnsBench"),
    ]
)
EOF
for file in "$control/package/Sources/SwiftStateTurns"/*.swift; do
  # `@inlinable` before a public declaration goes; before an internal one it becomes
  # `@usableFromInline`, so the inlinable code that remains still type-checks.
  perl -0pi -e 's/\@inlinable((?:\s+\@\w+(?:\([^)]*\))?)*\s+(?:public|open)\b)/$1/g; s/\@inlinable\b/\@usableFromInline/g; s/\@usableFromInline(\s+\@usableFromInline)+/\@usableFromInline/g' "$file"
done
# Only stdout is the path; the build's diagnostics go to a log shown on failure.
if ! control_binary="$(build_bench "$control/package" "$control/build" 2>"$control/build.log")"; then
  echo "check-turns-inlinable: FAILED: the negative control didn't build:"
  cat "$control/build.log"
  exit 1
fi
control_missing="$(missing_in "$control_binary" "$BENCH_TYPES" "$REQUIRED")" || exit 1
control_follow_up_missing="$(missing_in "$control_binary" "$FOLLOW_UP_TYPES" "$FOLLOW_UP_REQUIRED")" || exit 1
if [ "$control_missing" != "$REQUIRED" ] || [ "$control_follow_up_missing" != "$FOLLOW_UP_REQUIRED" ]; then
  echo "check-turns-inlinable: FAILED: the negative control (no @inlinable) still has specializations for:"
  grep -v -x -F -f <(printf '%s\n' "$control_missing") <<<"$REQUIRED" | sed 's/^/  BenchMachine: /' || true
  grep -v -x -F -f <(printf '%s\n' "$control_follow_up_missing") <<<"$FOLLOW_UP_REQUIRED" | sed 's/^/  FollowUpBenchMachine: /' || true
  echo "(the check can't tell an inlinable step path from one that isn't)"
  exit 1
fi
echo "check-turns-inlinable: negative control: none of them specialized without @inlinable, as expected"
