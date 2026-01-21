#!/bin/bash
set -e

# 1. Start GameServer in background
echo "🚀 Starting GameServer..."
swift run GameServer &
SERVER_PID=$!

# Function to cleanup
cleanup() {
    echo "🧹 Cleaning up..."
    kill $SERVER_PID || true
}
trap cleanup EXIT

# Wait for server to be ready
echo "⏳ Waiting for server..."
sleep 5

# 2. Join game using CLI to create session
echo "🎮 Joining game to create session..."
cd ../../Tools/CLI
npm run dev -- connect -u ws://localhost:8080/game/hero-defense -l hero-defense --once

# 3. Wait for destroy (Land configured to destroy after 5s when empty)
echo "⏳ Waiting 10s for Land to destroy and save record..."
sleep 10

# 4. List records
echo "📋 Listing records..."
npm run dev -- admin reevaluation-records -u http://localhost:8080 -k hero-defense-admin-key

echo "✅ Test complete!"
