#!/bin/bash
# notify-hook.sh — 任务完成后通过 OpenClaw 发送通知
#
# 可以由 dispatch.sh 自动调用，也可以独立运行。
#
# 功能：
#   1. 读取 task-meta.json 中的任务元数据
#   2. 收集 task-output.txt 中的 Cursor Agent 输出
#   3. 通过 OpenClaw CLI 发送 Telegram 通知
#   4. 向调度方发送回调（group 或 DM）
#   5. 写入 latest.json 和 pending-wake.json
#
# Environment variables:
#   RESULT_DIR              Result storage dir (default: ./data/cursor-agent-results)
#   OPENCLAW_BIN            Path to openclaw CLI (default: auto-detect)
#   OPENCLAW_GATEWAY_PORT   Gateway port for webhook (default: 18789)

set -uo pipefail

RESULT_DIR="${RESULT_DIR:-$(pwd)/data/cursor-agent-results}"
META_FILE="${RESULT_DIR}/task-meta.json"
TASK_OUTPUT="${RESULT_DIR}/task-output.txt"
LOG="${RESULT_DIR}/hook.log"
OPENCLAW_BIN="${OPENCLAW_BIN:-$(command -v openclaw 2>/dev/null || echo "")}"

mkdir -p "$RESULT_DIR"

log() { echo "[$(date -Iseconds)] $*" >> "$LOG"; }

log "=== Notify hook fired ==="

# ---- 去重：30 秒内只处理一次 ----
LOCK_FILE="${RESULT_DIR}/.hook-lock"
LOCK_AGE_LIMIT=30

if [ -f "$LOCK_FILE" ]; then
  LOCK_TIME=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  AGE=$(( NOW - LOCK_TIME ))
  if [ "$AGE" -lt "$LOCK_AGE_LIMIT" ]; then
    log "Duplicate hook within ${AGE}s, skipping"
    exit 0
  fi
fi
touch "$LOCK_FILE"

# ---- 收集输出 ----
OUTPUT=""
sleep 1  # 等待 tee pipe flush

if [ -f "$TASK_OUTPUT" ] && [ -s "$TASK_OUTPUT" ]; then
  OUTPUT=$(tail -c 4000 "$TASK_OUTPUT")
  log "Output collected (${#OUTPUT} chars)"
fi

# ---- 读取任务元数据（仅处理 2 小时内的） ----
TASK_NAME="unknown"
TELEGRAM_GROUP=""
CALLBACK_GROUP=""
CALLBACK_DM=""
CALLBACK_ACCOUNT=""
PROJECT_DIR=""
EXIT_CODE_VAL="0"
DURATION=""

if [ -f "$META_FILE" ]; then
  META_AGE=$(( $(date +%s) - $(stat -c %Y "$META_FILE" 2>/dev/null || echo 0) ))
  if [ "$META_AGE" -gt 7200 ]; then
    log "Meta file is ${META_AGE}s old (>2h), ignoring stale meta"
  else
    TASK_NAME=$(jq -r '.task_name // "unknown"' "$META_FILE" 2>/dev/null || echo "unknown")
    TELEGRAM_GROUP=$(jq -r '.telegram_group // ""' "$META_FILE" 2>/dev/null || echo "")
    CALLBACK_GROUP=$(jq -r '.callback_group // ""' "$META_FILE" 2>/dev/null || echo "")
    CALLBACK_DM=$(jq -r '.callback_dm // ""' "$META_FILE" 2>/dev/null || echo "")
    CALLBACK_ACCOUNT=$(jq -r '.callback_account // ""' "$META_FILE" 2>/dev/null || echo "")
    PROJECT_DIR=$(jq -r '.workdir // ""' "$META_FILE" 2>/dev/null || echo "")
    EXIT_CODE_VAL=$(jq -r '.exit_code // 0' "$META_FILE" 2>/dev/null || echo "0")

    # 计算耗时
    STARTED=$(jq -r '.started_at // ""' "$META_FILE" 2>/dev/null || echo "")
    COMPLETED=$(jq -r '.completed_at // ""' "$META_FILE" 2>/dev/null || echo "")
    if [ -n "$STARTED" ] && [ -n "$COMPLETED" ]; then
      START_TS=$(date -d "$STARTED" +%s 2>/dev/null || echo 0)
      END_TS=$(date -d "$COMPLETED" +%s 2>/dev/null || echo 0)
      if [ "$START_TS" -gt 0 ] && [ "$END_TS" -gt 0 ]; then
        ELAPSED=$(( END_TS - START_TS ))
        MINS=$(( ELAPSED / 60 ))
        SECS=$(( ELAPSED % 60 ))
        DURATION="${MINS}m${SECS}s"
      fi
    fi

    log "Meta: task=$TASK_NAME group=$TELEGRAM_GROUP age=${META_AGE}s"
  fi
fi

# ---- 写入 latest.json ----
jq -n \
  --arg ts "$(date -Iseconds)" \
  --arg output "$OUTPUT" \
  --arg task "$TASK_NAME" \
  --arg group "$TELEGRAM_GROUP" \
  --arg exit_code "$EXIT_CODE_VAL" \
  --arg duration "${DURATION:-unknown}" \
  '{
    timestamp: $ts,
    output: $output,
    task_name: $task,
    telegram_group: $group,
    exit_code: ($exit_code | tonumber),
    duration: $duration,
    status: "done"
  }' \
  > "${RESULT_DIR}/latest.json" 2>/dev/null

log "Wrote latest.json"

# ---- 构建通知消息 ----
STATUS_EMOJI="ok"
[ "$EXIT_CODE_VAL" != "0" ] && STATUS_EMOJI="FAILED"

MSG="[Cursor Agent Task Complete]
Task: ${TASK_NAME}
Status: ${STATUS_EMOJI}"
[ -n "$PROJECT_DIR" ] && MSG="${MSG}
Path: ${PROJECT_DIR}"
[ -n "$DURATION" ] && MSG="${MSG}
Duration: ${DURATION}"
[ "$EXIT_CODE_VAL" != "0" ] && MSG="${MSG}
Exit Code: ${EXIT_CODE_VAL}"

# 提取测试结果摘要
if [ -f "$TASK_OUTPUT" ] && [ -s "$TASK_OUTPUT" ]; then
  TEST_SUMMARY=$(grep -iE '(tests? (passed|failed)|pytest|PASS|FAIL)' "$TASK_OUTPUT" 2>/dev/null | tail -3 || true)
  [ -n "$TEST_SUMMARY" ] && MSG="${MSG}

Tests: $(echo "$TEST_SUMMARY" | head -3 | tr '\n' '; ')"
fi

# 文件列表
if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
  FILE_TREE=$(find "$PROJECT_DIR" -maxdepth 3 -type f \
    ! -path '*/venv/*' ! -path '*/__pycache__/*' ! -path '*/.git/*' ! -path '*.pyc' ! -path '*/node_modules/*' \
    2>/dev/null | sort | sed "s|${PROJECT_DIR}/||" | head -15)
  [ -n "$FILE_TREE" ] && MSG="${MSG}

Files:
${FILE_TREE}"
fi

# 输出摘要（最后 500 字符）
SUMMARY=$(echo "$OUTPUT" | tail -c 500 | tr '\n' ' ')
[ -n "$SUMMARY" ] && MSG="${MSG}

Output (tail): ${SUMMARY}"

echo "[notify] Notification message built (${#MSG} chars)"

# ---- 发送 Telegram 通知 ----
if [ -n "$TELEGRAM_GROUP" ] && [ -n "$OPENCLAW_BIN" ]; then
  "$OPENCLAW_BIN" message send \
    --channel telegram \
    --target "$TELEGRAM_GROUP" \
    --message "$MSG" 2>/dev/null && log "Sent Telegram notification" || log "Telegram send failed"

  # 回调到调度方 group
  if [ -n "$CALLBACK_GROUP" ] && [ "$CALLBACK_GROUP" != "$TELEGRAM_GROUP" ]; then
    CALLBACK_MSG="[Task Complete] ${TASK_NAME} - ${STATUS_EMOJI}"
    [ -n "$DURATION" ] && CALLBACK_MSG="${CALLBACK_MSG} (${DURATION})"

    "$OPENCLAW_BIN" message send \
      --channel telegram --target "$CALLBACK_GROUP" \
      --message "$CALLBACK_MSG" 2>/dev/null && log "Sent callback to $CALLBACK_GROUP" || log "Callback failed"
  fi

  # DM 回调
  if [ -n "$CALLBACK_DM" ]; then
    DM_MSG="[Task Complete] ${TASK_NAME} - ${STATUS_EMOJI}"
    [ -n "$DURATION" ] && DM_MSG="${DM_MSG} (${DURATION})"

    DM_CMD=("$OPENCLAW_BIN" message send --channel telegram --target "$CALLBACK_DM" --message "$DM_MSG")
    [ -n "$CALLBACK_ACCOUNT" ] && DM_CMD+=(--account "$CALLBACK_ACCOUNT")
    "${DM_CMD[@]}" 2>/dev/null && log "Sent DM to $CALLBACK_DM" || log "DM failed"
  fi
elif [ -z "$OPENCLAW_BIN" ]; then
  echo "[notify] openclaw CLI not found, skipping Telegram notification"
  log "openclaw CLI not found"
elif [ -z "$TELEGRAM_GROUP" ]; then
  echo "[notify] No telegram group configured, skipping notification"
  log "No telegram group"
fi

# ---- 写入 pending-wake.json（心跳回退） ----
jq -n \
  --arg task "$TASK_NAME" \
  --arg group "$TELEGRAM_GROUP" \
  --arg ts "$(date -Iseconds)" \
  --arg summary "$(echo "$OUTPUT" | head -c 500 | tr '\n' ' ')" \
  '{task_name: $task, telegram_group: $group, timestamp: $ts, summary: $summary, processed: false}' \
  > "${RESULT_DIR}/pending-wake.json" 2>/dev/null

# ---- 通过 webhook 唤醒 AGI ----
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
OPENCLAW_CONFIG="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"
HOOK_TOKEN=""

if [ -f "$OPENCLAW_CONFIG" ]; then
  HOOK_TOKEN=$(jq -r '.hooks.token // ""' "$OPENCLAW_CONFIG" 2>/dev/null || echo "")
fi

if [ -n "$HOOK_TOKEN" ]; then
  WAKE_TEXT="[CURSOR_AGENT_DONE] task=${TASK_NAME} status=done group=${TELEGRAM_GROUP:-none} ts=$(date -Iseconds)"
  (
    curl -s -o /dev/null -w "" -X POST \
      "http://localhost:${GATEWAY_PORT}/hooks/wake" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${HOOK_TOKEN}" \
      -d "{\"text\":\"${WAKE_TEXT}\",\"mode\":\"now\"}" 2>/dev/null && \
      log "Wake event sent" || log "Wake failed"
  ) &
fi

log "=== Notify hook completed ==="
echo "[notify] Done."
exit 0
