#!/usr/bin/env bash
# Re-records and verifies the 41 Part A recordings (replay-scale-fp-perturbation) at record 2.5.
# Usage: run-batch.sh <repo-root> <out-dir>
set -u
repo="$1"; out="$2"
bin="$repo/Examples/GameDemo/.build/release/ReevaluationRunner"
mkdir -p "$out/records" "$out/logs"
: > "$out/summary.tsv"
run() {  # seed players moveEvery ticks
  local n=$1 p=$2 m=$3 t=$4 f="$out/records/s$1.json"
  "$bin" --record --seed-id "$n" --players "$p" --move-every "$m" --ticks "$t" --output "$f" > "$out/logs/s$n.record.log" 2>&1
  local rec=$?
  "$bin" --input "$f" --verify > "$out/logs/s$n.verify.log" 2>&1
  local ver=$?
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$p" "$m" "$t" "$rec" "$ver" "$(shasum -a 256 "$f" | cut -d' ' -f1)" >> "$out/summary.tsv"
}
for n in $(seq 1 30); do run "$n" 5 20 1200; done
for n in 101 102 103; do run "$n" 2 20 1200; done
for n in 111 112 113; do run "$n" 10 20 1200; done
for n in 121 122 123; do run "$n" 5 5 1200; done
for n in 201 202; do run "$n" 5 20 12000; done
echo "done: $(wc -l < "$out/summary.tsv") recordings, record failures $(awk -F'\t' '$5!=0' "$out/summary.tsv" | wc -l), verify failures $(awk -F'\t' '$6!=0' "$out/summary.tsv" | wc -l)"
