#!/bin/bash
set -e

# Base URL
URL="http://127.0.0.1:8080"

echo "Verifying GET /health..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$URL/health")
if [ "$HTTP_CODE" -ne 200 ]; then
  echo "❌ GET /health failed with status $HTTP_CODE"
  exit 1
fi
echo "✅ GET /health passed"

echo "Verifying POST /v1/provisioning/allocate..."
RESPONSE=$(curl -s -X POST "$URL/v1/provisioning/allocate" -H "Content-Type: application/json")
EXPECTED='"serverId":"stub-server-1"'

if [[ "$RESPONSE" == *"$EXPECTED"* ]]; then
  echo "✅ POST /v1/provisioning/allocate passed"
  echo "Response: $RESPONSE"
else
  echo "❌ POST /v1/provisioning/allocate failed"
  echo "Expected to contain: $EXPECTED"
  echo "Got: $RESPONSE"
  exit 1
fi

echo "✅ All checks passed!"
