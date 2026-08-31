#!/usr/bin/env bash
# Cross-architecture verification: replay the arm64-recorded batch on this (x86_64) machine.
#
# 1) Copy reeval-batch-arm64.tar.gz from the recording machine and extract:
#      mkdir -p /tmp/reeval-batch && tar xzf reeval-batch-arm64.tar.gz -C /tmp/reeval-batch
# 2) From the repo root, on branch experiment/replay-scale-fp-perturbation:
#      bash deep-research/replay-scale-fp-perturbation/crossarch-verify.sh
set -e
cd "$(dirname "$0")/../../Examples/GameDemo"
swift build -c release
BIN=.build/release/ReevaluationRunner
pass=0; fail=0
for f in /tmp/reeval-batch/*.json; do
  if "$BIN" --input "$f" --verify > /tmp/crossarch-$(basename "$f" .json).log 2>&1; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL: $f (log: /tmp/crossarch-$(basename "$f" .json).log)"
  fi
done
echo "cross-arch verify ($(uname -m)): pass=$pass fail=$fail"
