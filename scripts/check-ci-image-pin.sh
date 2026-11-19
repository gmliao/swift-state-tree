#!/usr/bin/env bash
# Every Swift container image in the workflows is pinned to one digest, and every SwiftPM cache
# key names that digest, so a cache never outlives the image it was filled with and the jobs
# can't drift onto different images when the tag is pushed again.
set -euo pipefail
cd "$(dirname "$0")/.."

images="$(grep -hoE 'image: *swift:[^ #]+' .github/workflows/*.yml | sed -E 's/image: *//' | sort -u)"
if [ -z "$images" ]; then
  echo "::error::no Swift container image found in .github/workflows"
  exit 1
fi
if [ "$(printf '%s\n' "$images" | wc -l)" -ne 1 ]; then
  echo "::error::the workflows use more than one Swift container image:"
  printf '%s\n' "$images"
  exit 1
fi
case "$images" in
  *@sha256:*) ;;
  *) echo "::error::the Swift container image is not pinned by digest: $images"; exit 1 ;;
esac
digest="${images##*@sha256:}"

keys="$(grep -nE 'swiftpm-[$][{][{]' .github/workflows/*.yml || true)"
stale="$(printf '%s\n' "$keys" | grep -v "$digest" | grep . || true)"
if [ -n "$stale" ]; then
  echo "::error::a SwiftPM cache key or restore key doesn't name the image digest $digest:"
  printf '%s\n' "$stale"
  exit 1
fi
echo "ci image pin: $images; $(printf '%s\n' "$keys" | grep -c .) SwiftPM cache key lines name its digest"
