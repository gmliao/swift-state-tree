#!/usr/bin/env bash
# Builds the repro in release and runs every arm RUNS times, one process per run, recording each
# run's exit status (a signal shows as 128 + its number). Usage, from this directory:
#
#   ./run.sh [out-dir] [runs] [workers] [seconds]
#
# Writes <out-dir>/toolchain.txt, one <arm>-<run>.log per run, and <out-dir>/summary.tsv
# (arm, run, exit, last line). Defaults: out-dir results/<swift version>, 5 runs, 2000 workers, 20 s.
set -u
cd "$(dirname "$0")" || exit 1
version=$(swift --version 2>&1 | grep -oE 'Swift version [0-9.]+' | head -1 | tr ' ' '-')
out=${1:-results/$version-$(uname -s)-$(uname -m)}
runs=${2:-5}
workers=${3:-2000}
seconds=${4:-20}
mkdir -p "$out"
swift --version > "$out/toolchain.txt" 2>&1
uname -a >> "$out/toolchain.txt"
swift build -c release --scratch-path ".build-$(uname -s)" > "$out/build.log" 2>&1 || { echo "build failed, see $out/build.log"; exit 1; }
bin=$(swift build -c release --scratch-path ".build-$(uname -s)" --show-bin-path)/TaskSleepRepro
printf 'arm\trun\texit\tlast\n' > "$out/summary.tsv"
for arm in sleep-for sleep-nanoseconds async-let async-let-typed discarding-group; do
  for run in $(seq 1 "$runs"); do
    "$bin" --arm "$arm" --workers "$workers" --seconds "$seconds" > "$out/$arm-$run.log" 2>&1
    status=$?
    printf '%s\t%s\t%s\t%s\n' "$arm" "$run" "$status" "$(tail -1 "$out/$arm-$run.log" | cut -c1-160)" >> "$out/summary.tsv"
    echo "$arm run $run: exit $status"
  done
done
