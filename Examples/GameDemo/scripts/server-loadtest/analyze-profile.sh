#!/bin/bash
# Generate a CLI summary from an existing .perf file (Swift Profile Recorder or perf script format).
#
# Usage:
#   bash analyze-profile.sh /path/to/samples.perf
#   bash analyze-profile.sh /path/to/samples.perf -o summary.txt
#
# Output: prints top symbols by occurrence and (optional) writes to -o file.

set -e
PERF_FILE=""
OUT_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output) OUT_FILE="$2"; shift 2 ;;
        -h|--help) echo "Usage: $0 <file.perf> [-o summary.txt]"; exit 0 ;;
        *) PERF_FILE=$1; shift ;;
    esac
done

if [[ -z "$PERF_FILE" ]] || [[ ! -f "$PERF_FILE" ]]; then
    echo "Usage: $0 <file.perf> [-o summary.txt]"
    echo "  file.perf  path to .perf from Swift Profile Recorder or perf script"
    exit 1
fi

total=$(wc -l < "$PERF_FILE" | tr -d ' ')
# Extract likely symbol: last field that looks like a name (has letters, not just hex/numbers)
# Handles both "comm pid ... sym" and "  ip  sym" style lines
summary() {
    echo "=== Profile summary ==="
    echo "File: $PERF_FILE"
    echo "Total stack-frame lines: $total"
    echo ""
    echo "=== Top 50 symbols (by occurrence in stacks) ==="
    awk '{
        sym = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /[a-zA-Z_][a-zA-Z0-9_.():$]*/ && $i !~ /^[0-9]+$/ && $i !~ /^0x[0-9a-fA-F]+$/)
                sym = $i
        }
        if (sym != "") print sym
    }' "$PERF_FILE" | sort | uniq -c | sort -rn | head -50
    echo ""
    echo "=== View full profile ==="
    echo "  Drag $PERF_FILE into https://speedscope.app or https://profiler.firefox.com"
}

if [[ -n "$OUT_FILE" ]]; then
    summary | tee "$OUT_FILE"
    echo ""
    echo "Wrote: $OUT_FILE"
else
    summary
fi
