#!/bin/bash
# 自動化協議測量腳本
# 測量 opcode 和 json 兩種編碼格式的流量並生成對比報告

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GAMEDEMO_DIR="$PROJECT_ROOT/Examples/GameDemo"
RESULTS_DIR="$PROJECT_ROOT/Notes/protocol/measurements"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
OUTPUT_FILE="$RESULTS_DIR/${TIMESTAMP}.md"
DURATION_SECONDS="${DURATION_SECONDS:-60}"
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-60}"

# 創建結果目錄
mkdir -p "$RESULTS_DIR"

echo "📊 開始協議測量..."
echo "測試時間: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 清理函數
cleanup() {
  echo ""
  echo "🧹 清理環境..."
  if [ ! -z "${SERVER_PID:-}" ]; then
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
  fi
}

trap cleanup EXIT

# 預先編譯，避免每次 swift run 都在 build
echo "🔧 預先編譯 GameServer..." >&2
(cd "$GAMEDEMO_DIR" && swift build > /dev/null) || true
echo "✅ 預先編譯完成" >&2
echo "" >&2

# 測量單一格式
measure_format() {
  local format=$1
  local format_name=$2
  local temp_json="/tmp/measure-${format}-${TIMESTAMP}.json"
  local server_log="/tmp/gameserver-${format}-${TIMESTAMP}.log"
  
  echo "📡 測量格式: $format_name" >&2
  
  # 啟動 GameServer
  echo "  啟動 GameServer ($format)..." >&2
  cd "$GAMEDEMO_DIR"
  rm -f "$server_log"
  TRANSPORT_ENCODING=$format swift run GameServer > "$server_log" 2>&1 &
  SERVER_PID=$!
  
  # 等待服務器啟動
  echo "  等待服務器就緒 (timeout: ${STARTUP_TIMEOUT_SECONDS}s)..." >&2
  for _ in $(seq 1 "$STARTUP_TIMEOUT_SECONDS"); do
    if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if ! lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "  ❌ GameServer 未在 :8080 就緒，請查看 server log: $server_log" >&2
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
    return 1
  fi
  
  # 運行測量
  echo "  開始測量 (${DURATION_SECONDS} 秒)..." >&2
  cd "$SCRIPT_DIR/.."
  npm run measure -- \
    --url ws://localhost:8080/game/hero-defense \
    --land hero-defense \
    --duration "$DURATION_SECONDS" \
    --format $format \
    --output "$temp_json" \
    > /dev/null
  
  # 停止服務器
  echo "  停止 GameServer..." >&2
  kill $SERVER_PID
  wait $SERVER_PID 2>/dev/null || true
  SERVER_PID=""
  
  # 等待端口釋放
  sleep 2
  
  echo "  ✅ $format_name 測量完成" >&2
  echo "  🧾 server log: $server_log" >&2
  echo "" >&2
  
  # IMPORTANT: only print the JSON path to stdout (used by command substitution)
  echo "$temp_json"
}

# 測量三種格式
echo "開始測量 opcode 格式..."
OPCODE_RESULT=$(measure_format "opcode" "Opcode + JSON Array")

echo "開始測量 messagepack 格式..."
MESSAGEPACK_RESULT=$(measure_format "messagepack" "Opcode + MessagePack Binary")

echo "開始測量 json 格式..."
JSON_RESULT=$(measure_format "json" "JSON Object")

# 生成報告
echo "📝 生成對比報告..."

cat > "$OUTPUT_FILE" << 'EOF'
# Protocol 測量結果

EOF

# 添加日期和環境資訊
cat >> "$OUTPUT_FILE" << EOF
**測試日期**: $(date '+%Y-%m-%d %H:%M:%S')  
**GameServer**: hero-defense  
**測試時長**: 60 秒  

---

EOF

# 處理 opcode 結果
if [ -f "$OPCODE_RESULT" ]; then
  OPCODE_DATA=$(cat "$OPCODE_RESULT")
  
  cat >> "$OUTPUT_FILE" << 'EOF'
## Opcode + JSON Array 格式

EOF
  
  # 提取數據並格式化
  OPCODE_STATE_BYTES=$(echo "$OPCODE_DATA" | jq -r '.breakdown.stateUpdate.bytes')
  OPCODE_STATE_COUNT=$(echo "$OPCODE_DATA" | jq -r '.breakdown.stateUpdate.count')
  OPCODE_STATE_AVG=$(echo "$OPCODE_DATA" | jq -r '.breakdown.stateUpdate.avgSize')
  
  OPCODE_EVENT_BYTES=$(echo "$OPCODE_DATA" | jq -r '.breakdown.event.bytes')
  OPCODE_EVENT_COUNT=$(echo "$OPCODE_DATA" | jq -r '.breakdown.event.count')
  OPCODE_EVENT_AVG=$(echo "$OPCODE_DATA" | jq -r '.breakdown.event.avgSize')
  
  cat >> "$OUTPUT_FILE" << EOF
### StateUpdate
- 總流量: $(echo "scale=2; $OPCODE_STATE_BYTES / 1024" | bc) KB
- 封包數: $OPCODE_STATE_COUNT 個
- 平均大小: $OPCODE_STATE_AVG bytes

### Event
- 總流量: $(echo "scale=2; $OPCODE_EVENT_BYTES / 1024" | bc) KB
- 封包數: $OPCODE_EVENT_COUNT 個
- 平均大小: $OPCODE_EVENT_AVG bytes

---

EOF
  
  rm "$OPCODE_RESULT"
fi

# 處理 messagepack 結果
if [ -f "$MESSAGEPACK_RESULT" ]; then
  MESSAGEPACK_DATA=$(cat "$MESSAGEPACK_RESULT")
  
  cat >> "$OUTPUT_FILE" << 'EOF'
## Opcode + MessagePack Binary 格式

EOF
  
  # 提取數據並格式化
  MESSAGEPACK_STATE_BYTES=$(echo "$MESSAGEPACK_DATA" | jq -r '.breakdown.stateUpdate.bytes')
  MESSAGEPACK_STATE_COUNT=$(echo "$MESSAGEPACK_DATA" | jq -r '.breakdown.stateUpdate.count')
  MESSAGEPACK_STATE_AVG=$(echo "$MESSAGEPACK_DATA" | jq -r '.breakdown.stateUpdate.avgSize')
  
  MESSAGEPACK_EVENT_BYTES=$(echo "$MESSAGEPACK_DATA" | jq -r '.breakdown.event.bytes')
  MESSAGEPACK_EVENT_COUNT=$(echo "$MESSAGEPACK_DATA" | jq -r '.breakdown.event.count')
  MESSAGEPACK_EVENT_AVG=$(echo "$MESSAGEPACK_DATA" | jq -r '.breakdown.event.avgSize')
  
  MESSAGEPACK_TRANSPORT_BYTES=$(echo "$MESSAGEPACK_DATA" | jq -r '.breakdown.transport.bytes')
  MESSAGEPACK_TRANSPORT_COUNT=$(echo "$MESSAGEPACK_DATA" | jq -r '.breakdown.transport.count')
  MESSAGEPACK_TRANSPORT_AVG=$(echo "$MESSAGEPACK_DATA" | jq -r '.breakdown.transport.avgSize')
  
  cat >> "$OUTPUT_FILE" << EOF
### StateUpdate
- 總流量: $(echo "scale=2; $MESSAGEPACK_STATE_BYTES / 1024" | bc) KB
- 封包數: $MESSAGEPACK_STATE_COUNT 個
- 平均大小: $MESSAGEPACK_STATE_AVG bytes

### Event
- 總流量: $(echo "scale=2; $MESSAGEPACK_EVENT_BYTES / 1024" | bc) KB
- 封包數: $MESSAGEPACK_EVENT_COUNT 個
- 平均大小: $MESSAGEPACK_EVENT_AVG bytes

### Transport Messages
- 總流量: $(echo "scale=2; $MESSAGEPACK_TRANSPORT_BYTES / 1024" | bc) KB
- 封包數: $MESSAGEPACK_TRANSPORT_COUNT 個
- 平均大小: $MESSAGEPACK_TRANSPORT_AVG bytes

---

EOF
  
  rm "$MESSAGEPACK_RESULT"
fi

# 處理 json 結果
if [ -f "$JSON_RESULT" ]; then
  JSON_DATA=$(cat "$JSON_RESULT")
  
  cat >> "$OUTPUT_FILE" << 'EOF'
## JSON Object 格式

EOF
  
  JSON_STATE_BYTES=$(echo "$JSON_DATA" | jq -r '.breakdown.stateUpdate.bytes')
  JSON_STATE_COUNT=$(echo "$JSON_DATA" | jq -r '.breakdown.stateUpdate.count')
  JSON_STATE_AVG=$(echo "$JSON_DATA" | jq -r '.breakdown.stateUpdate.avgSize')
  
  JSON_EVENT_BYTES=$(echo "$JSON_DATA" | jq -r '.breakdown.event.bytes')
  JSON_EVENT_COUNT=$(echo "$JSON_DATA" | jq -r '.breakdown.event.count')
  JSON_EVENT_AVG=$(echo "$JSON_DATA" | jq -r '.breakdown.event.avgSize')
  
  cat >> "$OUTPUT_FILE" << EOF
### StateUpdate
- 總流量: $(echo "scale=2; $JSON_STATE_BYTES / 1024" | bc) KB
- 封包數: $JSON_STATE_COUNT 個
- 平均大小: $JSON_STATE_AVG bytes

### Event
- 總流量: $(echo "scale=2; $JSON_EVENT_BYTES / 1024" | bc) KB
- 封包數: $JSON_EVENT_COUNT 個
- 平均大小: $JSON_EVENT_AVG bytes

---

EOF
  
  rm "$JSON_RESULT"
fi

# 添加對比分析
if [ ! -z "${OPCODE_STATE_BYTES:-}" ] && [ ! -z "${JSON_STATE_BYTES:-}" ] && [ ! -z "${MESSAGEPACK_STATE_BYTES:-}" ]; then
  cat >> "$OUTPUT_FILE" << 'EOF'
## 對比分析

| 訊息類型 | JSON Format | Opcode Format | MessagePack Format | Opcode 節省比例 | MessagePack 節省比例 |
|---------|--------------|--------------|-------------------|----------------|----------------------|
EOF
  
  # StateUpdate 對比（注意：messagepack 模式下 stateUpdate 仍是 opcodeJsonArray，通常與 opcode 幾乎相同）
  STATE_SAVINGS_OPCODE=$(echo "scale=2; (($JSON_STATE_BYTES - $OPCODE_STATE_BYTES) / $JSON_STATE_BYTES) * 100" | bc)
  STATE_SAVINGS_MESSAGEPACK=$(echo "scale=2; (($JSON_STATE_BYTES - $MESSAGEPACK_STATE_BYTES) / $JSON_STATE_BYTES) * 100" | bc)
  cat >> "$OUTPUT_FILE" << EOF
| StateUpdate (總流量) | $(echo "scale=2; $JSON_STATE_BYTES / 1024" | bc) KB | $(echo "scale=2; $OPCODE_STATE_BYTES / 1024" | bc) KB | $(echo "scale=2; $MESSAGEPACK_STATE_BYTES / 1024" | bc) KB | ${STATE_SAVINGS_OPCODE}% | ${STATE_SAVINGS_MESSAGEPACK}% |
EOF
  
  # StateUpdate 平均大小對比
  STATE_AVG_SAVINGS_OPCODE=$(echo "scale=2; (($JSON_STATE_AVG - $OPCODE_STATE_AVG) / $JSON_STATE_AVG) * 100" | bc)
  STATE_AVG_SAVINGS_MESSAGEPACK=$(echo "scale=2; (($JSON_STATE_AVG - $MESSAGEPACK_STATE_AVG) / $JSON_STATE_AVG) * 100" | bc)
  cat >> "$OUTPUT_FILE" << EOF
| StateUpdate (平均) | ${JSON_STATE_AVG} bytes | ${OPCODE_STATE_AVG} bytes | ${MESSAGEPACK_STATE_AVG} bytes | ${STATE_AVG_SAVINGS_OPCODE}% | ${STATE_AVG_SAVINGS_MESSAGEPACK}% |
EOF
  
  # Event 對比
  if [ "$OPCODE_EVENT_BYTES" != "0" ] && [ "$JSON_EVENT_BYTES" != "0" ]; then
    EVENT_SAVINGS_OPCODE=$(echo "scale=2; (($JSON_EVENT_BYTES - $OPCODE_EVENT_BYTES) / $JSON_EVENT_BYTES) * 100" | bc)
    EVENT_SAVINGS_MESSAGEPACK=$(echo "scale=2; (($JSON_EVENT_BYTES - $MESSAGEPACK_EVENT_BYTES) / $JSON_EVENT_BYTES) * 100" | bc)
    cat >> "$OUTPUT_FILE" << EOF
| Event (總流量) | $(echo "scale=2; $JSON_EVENT_BYTES / 1024" | bc) KB | $(echo "scale=2; $OPCODE_EVENT_BYTES / 1024" | bc) KB | $(echo "scale=2; $MESSAGEPACK_EVENT_BYTES / 1024" | bc) KB | ${EVENT_SAVINGS_OPCODE}% | ${EVENT_SAVINGS_MESSAGEPACK}% |
EOF

    EVENT_AVG_SAVINGS_OPCODE=$(echo "scale=2; (($JSON_EVENT_AVG - $OPCODE_EVENT_AVG) / $JSON_EVENT_AVG) * 100" | bc)
    EVENT_AVG_SAVINGS_MESSAGEPACK=$(echo "scale=2; (($JSON_EVENT_AVG - $MESSAGEPACK_EVENT_AVG) / $JSON_EVENT_AVG) * 100" | bc)
    cat >> "$OUTPUT_FILE" << EOF
| Event (平均) | ${JSON_EVENT_AVG} bytes | ${OPCODE_EVENT_AVG} bytes | ${MESSAGEPACK_EVENT_AVG} bytes | ${EVENT_AVG_SAVINGS_OPCODE}% | ${EVENT_AVG_SAVINGS_MESSAGEPACK}% |
EOF
  fi

  # Transport Messages 對比（messagepack 主要差異通常會出現在這裡：joinResponse / error / event 等）
  if [ ! -z "${OPCODE_DATA:-}" ] && [ ! -z "${JSON_DATA:-}" ] && [ ! -z "${MESSAGEPACK_DATA:-}" ]; then
    OPCODE_TRANSPORT_BYTES=$(echo "$OPCODE_DATA" | jq -r '.breakdown.transport.bytes')
    OPCODE_TRANSPORT_AVG=$(echo "$OPCODE_DATA" | jq -r '.breakdown.transport.avgSize')
    JSON_TRANSPORT_BYTES=$(echo "$JSON_DATA" | jq -r '.breakdown.transport.bytes')
    JSON_TRANSPORT_AVG=$(echo "$JSON_DATA" | jq -r '.breakdown.transport.avgSize')

    TRANSPORT_SAVINGS_OPCODE=$(echo "scale=2; (($JSON_TRANSPORT_BYTES - $OPCODE_TRANSPORT_BYTES) / $JSON_TRANSPORT_BYTES) * 100" | bc)
    TRANSPORT_SAVINGS_MESSAGEPACK=$(echo "scale=2; (($JSON_TRANSPORT_BYTES - $MESSAGEPACK_TRANSPORT_BYTES) / $JSON_TRANSPORT_BYTES) * 100" | bc)
    TRANSPORT_AVG_SAVINGS_OPCODE=$(echo "scale=2; (($JSON_TRANSPORT_AVG - $OPCODE_TRANSPORT_AVG) / $JSON_TRANSPORT_AVG) * 100" | bc)
    TRANSPORT_AVG_SAVINGS_MESSAGEPACK=$(echo "scale=2; (($JSON_TRANSPORT_AVG - $MESSAGEPACK_TRANSPORT_AVG) / $JSON_TRANSPORT_AVG) * 100" | bc)

    cat >> "$OUTPUT_FILE" << EOF
| Transport (總流量) | $(echo "scale=2; $JSON_TRANSPORT_BYTES / 1024" | bc) KB | $(echo "scale=2; $OPCODE_TRANSPORT_BYTES / 1024" | bc) KB | $(echo "scale=2; $MESSAGEPACK_TRANSPORT_BYTES / 1024" | bc) KB | ${TRANSPORT_SAVINGS_OPCODE}% | ${TRANSPORT_SAVINGS_MESSAGEPACK}% |
| Transport (平均) | ${JSON_TRANSPORT_AVG} bytes | ${OPCODE_TRANSPORT_AVG} bytes | ${MESSAGEPACK_TRANSPORT_AVG} bytes | ${TRANSPORT_AVG_SAVINGS_OPCODE}% | ${TRANSPORT_AVG_SAVINGS_MESSAGEPACK}% |
EOF
  fi
fi

echo ""
echo "✅ 測量完成！"
echo "📄 報告已保存到: $OUTPUT_FILE"
echo ""
cat "$OUTPUT_FILE"
