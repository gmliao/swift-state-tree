#!/bin/bash
# Watch script for GameDemo server
# Automatically rebuilds and runs GameServer when Swift files change

cd "$(dirname "$0")"

watchexec \
  -w Sources \
  -w ../../Sources \
  --ignore .build \
  --ignore .swiftpm \
  --exts swift \
  -- \
  'swift run GameServer'
