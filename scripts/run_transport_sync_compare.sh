#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-"$ROOT_DIR/docs/performance"}"
STAMP="${STAMP_OVERRIDE:-$(date +"%Y%m%d-%H%M%S")}"

mkdir -p "$OUT_DIR"

run_case() {
  local label="$1"
  shift
  local outfile="$OUT_DIR/${label}-${STAMP}.txt"
  echo "Running ${label}..." >&2
  swift run -c release SwiftStateTreeBenchmarks "$@" --csv --no-wait > "$outfile"
  echo "$outfile"
}

sync_on=$(run_case "transport-sync-dirty-on" transport-sync --dirty-on)
sync_off=$(run_case "transport-sync-dirty-off" transport-sync --dirty-off)
players_on=$(run_case "transport-sync-players-dirty-on" transport-sync-players --dirty-on)
players_off=$(run_case "transport-sync-players-dirty-off" transport-sync-players --dirty-off)

summary="$OUT_DIR/transport-sync-compare-${STAMP}.txt"

python3 - "$sync_on" "$sync_off" "$players_on" "$players_off" "$summary" <<'PY'
import re
import statistics
import sys


def parse(path: str) -> dict[tuple[str, str, int], float]:
    suite = None
    state = None
    players = None
    data: dict[tuple[str, str, int], float] = {}

    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            suite_match = re.search(r"(TransportAdapter Sync \(.*\))", line)
            if suite_match:
                suite = suite_match.group(1).strip()
                continue

            run_match = re.search(r"Running: (.+?) \(", line)
            if run_match:
                state = run_match.group(1).strip()
                continue

            players_match = re.search(r"Testing with (\d+) players", line)
            if players_match:
                players = int(players_match.group(1))
                continue

            avg_match = re.search(r"Average: ([0-9.]+)ms", line)
            if avg_match and suite and state and players is not None:
                data[(suite, state, players)] = float(avg_match.group(1))

    return data


def summarize_suite(suite_name: str, on_list: list[float], off_list: list[float]) -> list[str]:
    if not on_list or not off_list:
        return []
    on_avg = statistics.mean(on_list)
    off_avg = statistics.mean(off_list)
    delta = on_avg - off_avg
    pct = (delta / off_avg * 100.0) if off_avg else 0.0
    return [
        f"Suite Average, ,{on_avg:.4f},{off_avg:.4f},{delta:+.4f},{pct:+.2f}%",
        "",
    ]


def compare(on_path: str, off_path: str, title: str) -> list[str]:
    on = parse(on_path)
    off = parse(off_path)
    keys = sorted(set(on.keys()) | set(off.keys()))

    lines: list[str] = []
    lines.append(title)
    lines.append(f"on:  {on_path}")
    lines.append(f"off: {off_path}")
    lines.append("")

    current_suite = None
    suite_on: list[float] = []
    suite_off: list[float] = []

    for suite, state, players in keys:
        if (suite, state, players) not in on or (suite, state, players) not in off:
            continue

        if current_suite != suite:
            if current_suite is not None:
                lines.extend(summarize_suite(current_suite, suite_on, suite_off))
                suite_on = []
                suite_off = []

            current_suite = suite
            lines.append(f"Suite: {suite}")
            lines.append("State,Players,On(ms),Off(ms),Delta(ms),Delta(%)")

        on_ms = on[(suite, state, players)]
        off_ms = off[(suite, state, players)]
        delta = on_ms - off_ms
        pct = (delta / off_ms * 100.0) if off_ms else 0.0
        lines.append(f"{state},{players},{on_ms:.4f},{off_ms:.4f},{delta:+.4f},{pct:+.2f}%")

        suite_on.append(on_ms)
        suite_off.append(off_ms)

    if current_suite is not None:
        lines.extend(summarize_suite(current_suite, suite_on, suite_off))

    lines.append("")
    return lines


def main() -> None:
    sync_on_path, sync_off_path, players_on_path, players_off_path, out_path = sys.argv[1:6]

    lines: list[str] = []
    lines.append("TransportAdapter Sync Comparison")
    lines.append("")
    lines.extend(compare(sync_on_path, sync_off_path, "TransportAdapter Sync (hands dirty only)"))
    lines.extend(compare(players_on_path, players_off_path, "TransportAdapter Sync (broadcast players hot)"))

    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines).rstrip() + "\n")


if __name__ == "__main__":
    main()
PY

echo "Summary written to $summary"
