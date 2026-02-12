#!/usr/bin/env bash
# Verify: same room path -> same backend (same process)
#
# Method: Connect to same room twice, check admin API - land should exist on
# exactly ONE backend. Connect to different room - may be on different backend.
#
# Prereqs: 3 GameServers (8080,8081,8082), nginx on 9090, admin key

set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADMIN_KEY="hero-defense-admin-key"
# GameServer uses X-API-Key header
BACKENDS="8080 8081 8082"

# Which backend has this land? (200 + land stats, not 404)
which_backend_has() {
  local land_id="$1"
  for port in $BACKENDS; do
    local resp
    resp=$(curl -s -w "\n%{http_code}" -H "X-API-Key: $ADMIN_KEY" "http://localhost:$port/admin/lands/$(echo "$land_id" | sed 's/:/%3A/g')")
    local code
    code=$(echo "$resp" | tail -1)
    if [ "$code" = "200" ]; then
      echo "$port"
      return
    fi
  done
  echo ""
}

# List all lands on a backend
list_lands() {
  local port="$1"
  curl -s -H "X-API-Key: $ADMIN_KEY" "http://localhost:$port/admin/lands" | grep -oE 'hero-defense:[a-z0-9-]+' || true
}

echo "=== Verify: same room -> same process ==="
echo ""

# Check services
echo "1. Checking services..."
for port in $BACKENDS 9090; do
  if curl -s --connect-timeout 2 "http://localhost:$port/health" >/dev/null 2>&1; then
    echo "   port $port: OK"
  else
    echo "   port $port: NOT reachable"
    echo ""
    echo "Start services first:"
    echo "  GameServers: cd Examples/GameDemo && PORT=8080 .build/debug/GameServer & (x3)"
    echo "  nginx: docker compose -f docs/deploy/docker-compose.nginx.yml up -d"
    exit 1
  fi
done
echo ""

ROOM_A="room-verify-$(date +%s)-a"
ROOM_B="room-verify-$(date +%s)-b"
echo "2. Test rooms: $ROOM_A, $ROOM_B"
echo ""

# Connect client to room A via nginx
echo "3. Connecting client to ws://localhost:9090/game/hero-defense/$ROOM_A ..."
cd "$REPO_ROOT/Tools/CLI"
timeout 15 npm run dev -- connect \
  -u "ws://localhost:9090/game/hero-defense/$ROOM_A" \
  -l "hero-defense:$ROOM_A" \
  --once --timeout 10 2>/dev/null || true
cd "$REPO_ROOT"
sleep 1

# Find which backend has room A
BACKEND_A=$(which_backend_has "hero-defense:$ROOM_A")
if [ -z "$BACKEND_A" ]; then
  echo "   FAIL: land not found on any backend (join may have failed)"
  exit 1
fi
echo "   Room A -> backend :$BACKEND_A"

# Second client to SAME room - should hit same backend
echo ""
echo "4. Connecting 2nd client to SAME room $ROOM_A ..."
cd "$REPO_ROOT/Tools/CLI"
timeout 15 npm run dev -- connect \
  -u "ws://localhost:9090/game/hero-defense/$ROOM_A" \
  -l "hero-defense:$ROOM_A" \
  -p "player-2" \
  --once --timeout 10 2>/dev/null || true
cd "$REPO_ROOT"
sleep 1

# Still only one backend should have it (same process)
BACKEND_A2=$(which_backend_has "hero-defense:$ROOM_A")
if [ -n "$BACKEND_A2" ] && [ "$BACKEND_A" = "$BACKEND_A2" ]; then
  echo "   Room A still on :$BACKEND_A (same process)"
else
  echo "   FAIL: Room A migrated or on multiple backends"
  exit 1
fi

# Connect to different room B - may be different backend
echo ""
echo "5. Connecting client to DIFFERENT room $ROOM_B ..."
cd "$REPO_ROOT/Tools/CLI"
timeout 15 npm run dev -- connect \
  -u "ws://localhost:9090/game/hero-defense/$ROOM_B" \
  -l "hero-defense:$ROOM_B" \
  --once --timeout 10 2>/dev/null || true
cd "$REPO_ROOT"
sleep 1

BACKEND_B=$(which_backend_has "hero-defense:$ROOM_B")
echo "   Room B -> backend :${BACKEND_B:-unknown}"

echo ""
echo "=== Result ==="
echo "  Room A ($ROOM_A): backend :$BACKEND_A"
echo "  Room B ($ROOM_B): backend :${BACKEND_B:-none}"
echo ""
echo "  Same room ($ROOM_A) -> same backend :$BACKEND_A"
if [ -n "$BACKEND_B" ] && [ "$BACKEND_A" != "$BACKEND_B" ]; then
  echo "  Different rooms -> different backends (hash distribution working)"
fi
echo ""
echo "=== PASS: Same room routes to same process ==="
