#!/usr/bin/env bash
# Checks that a client of SwiftStateTurns gets the core's step path specialized for its own
# machine, with no build flag (Notes/plans/2026-11-18-swift-state-turns-core.md, rule 19).
#
# Builds TurnsBench in release and reads its symbols: the core's generic code inlined into the
# bench appears as generic specializations on the bench's machine and actor types. None means the
# step path runs through unspecialized generic code, several times slower per step; the usual
# cause is a function on it that lost `@inlinable` or a type that lost `@usableFromInline`.
#
# Usage: scripts/check-turns-inlinable.sh [scratch path]   (default .build)
# Needs the build slot (it builds).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${1:-$root/.build}"
cd "$root"

swift build -c release --product TurnsBench --scratch-path "$scratch" 2>&1 | grep -E "error:|Compiling SwiftStateTurns|Build complete" || true
binary="$(swift build -c release --product TurnsBench --scratch-path "$scratch" --show-bin-path)/TurnsBench"
[ -x "$binary" ] || { echo "check-turns-inlinable: no TurnsBench binary at $binary"; exit 1; }

# Full demangling: `--simplified` drops the specialization's type arguments.
symbols="$(nm "$binary" | awk '{ print $NF }' | swift demangle 2>/dev/null)"
# The step path: the core's step and runtime, specialized on the bench's types.
specialized="$(grep -E 'generic specialization <[^>]*TurnsBench\.(BenchMachine|BenchActor)' <<<"$symbols" \
    | grep -E 'SwiftStateTurns\.(TurnCore\.step|Runtime\.|Turn\.|TurnActor\.)' || true)"
count="$(grep -c . <<<"$specialized" || true)"
if [ "$count" -eq 0 ]; then
    echo "check-turns-inlinable: FAILED: no specialization of the turn core for TurnsBench's machine"
    echo "(check that the step path is @inlinable and what it touches @usableFromInline)"
    exit 1
fi
echo "check-turns-inlinable: $count specialized symbol(s) of the turn core on TurnsBench's types, for example:"
sed -n 1,5p <<<"$specialized" | cut -c1-160
