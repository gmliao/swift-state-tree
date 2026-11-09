#!/usr/bin/env bash
# Records and verifies the 41 Part A recordings (replay-scale-fp-perturbation) with the checkout's
# ReevaluationRunner, in whatever record format it writes (3.x since #245: `s<N>.sstr`).
# Usage: run-batch.sh <repo-root> <out-dir>
#
# Each recording: `--record` into records/s<N>.sstr, then `--input ... --verify` (exit 0 = the
# replayed hashes match the recorded ones and two re-evaluation runs agree). With TWICE=1 (the
# default) every seed is recorded a second time into records-2/, the determinism check. The two
# are compared by content, not bytes: the sha256 of each one's JSON view (`--convert`), i.e. the
# two are identical as the reader merges them (the metadata and every tick's merged frame: inputs,
# server events, state hash, watermarks, sync stream, initialize). The view doesn't keep the turn
# split, the footer's counts, an earlier value of a scalar overwritten later in the same tick, or a
# number's encoded MessagePack type. The bytes can differ with the same content, since the 3.x recorder splits
# a tick into several turn records at a point set by wall time (#327); scripts/turns.py counts the
# split ticks of each file, recorded as the reason. summary.tsv: seed, players, move-every, ticks,
# record exit, verify exit, sha256, second recording's sha256, content sha256, second recording's
# content sha256, split ticks, second recording's split ticks (the second-recording columns are
# empty with TWICE=0; a content or split column is empty when --convert or turns.py failed).
# source.json: the checkout the batch ran from: its commit (`git rev-parse HEAD`) and whether its
# tree was dirty (`git status --porcelain`, untracked files included), read before the build, then
# `built` once this script has built ReevaluationRunner (release) from that tree, and the same two
# read again after the last seed (`commitAtEnd`, `dirtyAtEnd`). An <out-dir> inside the checkout
# must be gitignored (refused otherwise: it would dirty the tree it records).
# scripts/summarize.py turns the directory into a results/batch-<format>-<arch>.json, taking the
# commit from source.json; it refuses a batch that wasn't built here, ran from a dirty tree, or
# whose commit or tree changed while it ran.
#
# Options (environment):
#   TWICE=0|1    record each seed twice and compare (default 1).
#   SEEDS="<n> ..." only these seeds (a smoke run); summarize.py records the count, and
#                regenerate.py --check refuses a batch with fewer than the 41.
#   DRY_RUN=1    prints every command and runs none.
#   SWIFT=<path> the swift that builds the runner (default: swift on PATH; tests pass a stand-in).
set -u
[ $# -eq 2 ] || { echo "usage: $0 <repo-root> <out-dir>" >&2; exit 2; }
repo="$1"; out="$2"
TWICE="${TWICE-1}"; DRY_RUN="${DRY_RUN-0}"; SEEDS="${SEEDS-}"; SWIFT="${SWIFT-swift}"
case "$TWICE" in 0|1) ;; *) echo "TWICE must be 0 or 1" >&2; exit 2 ;; esac
bin="$repo/Examples/GameDemo/.build/release/ReevaluationRunner"
turns="$(cd "$(dirname "$0")" && pwd)/turns.py"
# A portable sha256: coreutils, else perl's shasum, else python3.
sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1
  else python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; fi
}
# source.json's fields: `record_source <prefix> <commit> <status>` writes `commit`, `dirty`, `status` under
# that prefix's names (merged into the file), or `built`.
record_source() {
  python3 - "$out/source.json" "$@" <<'PY2'
import json, os, sys
path, what = sys.argv[1], sys.argv[2]
record = json.load(open(path)) if os.path.exists(path) else {}
if what == "built":
    record["built"] = True
else:
    commit, status = sys.argv[3:5]
    lines = [l for l in status.splitlines() if l.strip()]
    keys = ("commit", "dirty", "status") if what == "start" else ("commitAtEnd", "dirtyAtEnd", "statusAtEnd")
    record.update(dict(zip(keys, (commit, bool(lines), lines))))
json.dump(record, open(path, "w"), indent=2)
PY2
}
if [ "$DRY_RUN" = 1 ]; then
  echo "+ write $out/source.json (git rev-parse HEAD, git status --porcelain)"
  echo "+ cd $repo/Examples/GameDemo && $SWIFT build -c release --product ReevaluationRunner"
  x() { echo "+ $*"; }
else
  [ -e "$out/summary.tsv" ] && { echo "$out/summary.tsv exists: use a new out-dir" >&2; exit 1; }
  commit=$(git -C "$repo" rev-parse HEAD) || { echo "$repo isn't a git checkout: the batch must record its commit" >&2; exit 1; }
  # An out-dir inside the checkout must be ignored, or its files would make the tree dirty.
  inside=$(python3 -c 'import os,sys; r,o=map(os.path.realpath,sys.argv[1:]); print(1 if o==r or o.startswith(r+os.sep) else 0)' "$repo" "$out")
  # (Checked on a file under it: a `dir/` pattern matches only a directory, and out-dir may not exist yet.)
  if [ "$inside" = 1 ] && ! git -C "$repo" check-ignore -q "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$out")/source.json"; then
    echo "$out is inside $repo and not gitignored: use an out-dir outside the checkout or in an ignored path" >&2; exit 2
  fi
  status=$(git -C "$repo" status --porcelain) || exit 1
  mkdir -p "$out/records" "$out/logs"
  record_source start "$commit" "$status"
  # The runner is built from the tree just recorded, so the batch's commit is its binary's.
  (cd "$repo/Examples/GameDemo" && "$SWIFT" build -c release --product ReevaluationRunner) > "$out/logs/build.log" 2>&1 \
    || { echo "building ReevaluationRunner failed (see $out/logs/build.log)" >&2; exit 1; }
  [ -x "$bin" ] || { echo "no release ReevaluationRunner at $bin after the build" >&2; exit 1; }
  record_source built
  [ "$TWICE" = 1 ] && mkdir -p "$out/records-2"
  mkdir -p "$out/views"
  : > "$out/summary.tsv"
  x() { "$@"; }
fi
# The sha256 of a record's JSON view (`--convert`), empty when the conversion fails. The view is
# deleted once hashed.
content_sha256() {  # record view
  local sum=""
  "$bin" --convert "$1" "$2" > "$2.log" 2>&1 && sum=$(sha256 "$2" 2>/dev/null)
  rm -f "$2"
  echo "$sum"
}
# A record's split ticks (ticks with more than one turn record), empty when turns.py fails.
split_ticks() {
  python3 "$turns" "$1" 2>/dev/null | awk '{print $3}'
}
run() {  # seed players moveEvery ticks
  local n=$1 p=$2 m=$3 t=$4 f="$out/records/s$1.sstr" f2="$out/records-2/s$1.sstr" rec ver sum2="" content content2="" split split2=""
  local args=(--record --seed-id "$n" --players "$p" --move-every "$m" --ticks "$t")
  if [ "$DRY_RUN" = 1 ]; then
    x "$bin" "${args[@]}" --output "$f"
    x "$bin" --input "$f" --verify
    x "$bin" --convert "$f" "$out/views/s$n.json"
    x python3 "$turns" "$f"
    if [ "$TWICE" = 1 ]; then
      x "$bin" "${args[@]}" --output "$f2"
      x "$bin" --convert "$f2" "$out/views/s$n-2.json"
      x python3 "$turns" "$f2"
    fi
    return
  fi
  "$bin" "${args[@]}" --output "$f" > "$out/logs/s$n.record.log" 2>&1; rec=$?
  "$bin" --input "$f" --verify > "$out/logs/s$n.verify.log" 2>&1; ver=$?
  if [ "$TWICE" = 1 ]; then
    "$bin" "${args[@]}" --output "$f2" > "$out/logs/s$n.record-2.log" 2>&1 || rec=$((rec == 0 ? 1 : rec))
    sum2=$(sha256 "$f2" 2>/dev/null)
    content2=$(content_sha256 "$f2" "$out/views/s$n-2.json")
    split2=$(split_ticks "$f2")
  fi
  content=$(content_sha256 "$f" "$out/views/s$n.json")
  split=$(split_ticks "$f")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$p" "$m" "$t" "$rec" "$ver" \
    "$(sha256 "$f" 2>/dev/null)" "$sum2" "$content" "$content2" "$split" "$split2" >> "$out/summary.tsv"
}
want() { [ -z "$SEEDS" ] || [[ " $SEEDS " == *" $1 "* ]]; }
for n in $(seq 1 30); do want "$n" && run "$n" 5 20 1200; done
for n in 101 102 103; do want "$n" && run "$n" 2 20 1200; done
for n in 111 112 113; do want "$n" && run "$n" 10 20 1200; done
for n in 121 122 123; do want "$n" && run "$n" 5 5 1200; done
for n in 201 202; do want "$n" && run "$n" 5 20 12000; done
[ "$DRY_RUN" = 1 ] && exit 0
# The tree after the last seed: summarize refuses a batch whose commit or tree changed while it ran.
record_source end "$(git -C "$repo" rev-parse HEAD)" "$(git -C "$repo" status --porcelain)"
fail_rec=$(awk -F'\t' '$5!=0' "$out/summary.tsv" | wc -l | tr -d ' ')
fail_ver=$(awk -F'\t' '$6!=0' "$out/summary.tsv" | wc -l | tr -d ' ')
# A content digest that is missing (a failed --convert) fails the batch like a differing one.
fail_content=$(awk -F'\t' -v twice="$TWICE" '$9=="" || (twice==1 && $10=="")' "$out/summary.tsv" | wc -l | tr -d ' ')
differ=$(awk -F'\t' '$10!="" && $10!=$9' "$out/summary.tsv" | wc -l | tr -d ' ')
bytes_differ=$(awk -F'\t' '$8!="" && $8!=$7' "$out/summary.tsv" | wc -l | tr -d ' ')
echo "done: $(wc -l < "$out/summary.tsv" | tr -d ' ') recordings, record failures $fail_rec, verify failures $fail_ver, content digest failures $fail_content, second recordings differing $differ (in bytes: $bytes_differ)"
[ "$fail_rec" = 0 ] && [ "$fail_ver" = 0 ] && [ "$fail_content" = 0 ] && [ "$differ" = 0 ]
