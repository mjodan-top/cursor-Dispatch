#!/bin/bash
# dispatch.sh — 调度开发任务到 Cursor Agent CLI，完成后通过 OpenClaw 通知
#
# Usage:
#   dispatch.sh [OPTIONS] -p "your prompt here"
#
# Options:
#   -p, --prompt TEXT             Task prompt (required)
#   -n, --name NAME               Task name (for tracking)
#   -g, --group ID                Telegram group ID for result delivery
#   -w, --workdir DIR             Working directory for Cursor Agent
#   --callback-group ID           Telegram group for callback
#   --callback-dm ID              Telegram user ID for DM callback
#   --callback-account NAME       Telegram bot account name for DM
#   --model MODEL                 Model override (e.g. gpt-5, sonnet-4)
#   --yolo                        Auto-approve all commands
#   --mode MODE                   Agent mode (plan/ask, default: agent)
#   --output-format FORMAT        Output format (text/json/stream-json)
#
# Cursor Agent CLI reference:
#   Interactive:  agent "prompt"
#   Headless:     agent -p "prompt" --trust --output-format text
#   Docs:         https://cursor.com/docs/cli/overview
#
# Environment variables:
#   RESULT_DIR                    Result storage dir (default: ./data/cursor-agent-results)
#   OPENCLAW_BIN                  Path to openclaw CLI (default: auto-detect)
#   AGENT_BIN                     Path to agent CLI (default: auto-detect)

set -euo pipefail

# ---- 配置（可通过环境变量覆盖） ----
RESULT_DIR="${RESULT_DIR:-$(pwd)/data/cursor-agent-results}"
META_FILE="${RESULT_DIR}/task-meta.json"
TASK_OUTPUT="${RESULT_DIR}/task-output.txt"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="${SCRIPT_DIR}/cursor_agent_run.py"

# 自动检测 openclaw
OPENCLAW_BIN="${OPENCLAW_BIN:-$(command -v openclaw 2>/dev/null || echo "")}"

# 默认值
PROMPT=""
TASK_NAME="task-$(date +%s)"
TELEGRAM_GROUP=""
CALLBACK_GROUP=""
CALLBACK_DM=""
CALLBACK_ACCOUNT=""
WORKDIR="$(pwd)"
MODEL=""
YOLO=""
MODE=""
OUTPUT_FORMAT="text"

# ---- 参数解析 ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--prompt)          PROMPT="$2";           shift 2;;
    -n|--name)            TASK_NAME="$2";        shift 2;;
    -g|--group)           TELEGRAM_GROUP="$2";   shift 2;;
    --callback-group)     CALLBACK_GROUP="$2";   shift 2;;
    --callback-dm)        CALLBACK_DM="$2";      shift 2;;
    --callback-account)   CALLBACK_ACCOUNT="$2"; shift 2;;
    -w|--workdir)         WORKDIR="$2";          shift 2;;
    --model)              MODEL="$2";            shift 2;;
    --yolo)               YOLO="1";              shift;;
    --mode)               MODE="$2";             shift 2;;
    --output-format)      OUTPUT_FORMAT="$2";    shift 2;;
    *)  echo "Unknown option: $1" >&2; exit 1;;
  esac
done

if [ -z "$PROMPT" ]; then
  echo "Error: --prompt is required" >&2
  exit 1
fi

# ---- 自动检测 dispatch-callback.json ----
if [ -z "$CALLBACK_GROUP" ] && [ -z "$CALLBACK_DM" ]; then
  for SEARCH_DIR in "$(pwd)" "$WORKDIR"; do
    CALLBACK_CONFIG="${SEARCH_DIR}/dispatch-callback.json"
    if [ -f "$CALLBACK_CONFIG" ] 2>/dev/null; then
      CB_TYPE=$(jq -r '.type // ""' "$CALLBACK_CONFIG" 2>/dev/null || echo "")
      case "$CB_TYPE" in
        group)
          CALLBACK_GROUP=$(jq -r '.group // ""' "$CALLBACK_CONFIG" 2>/dev/null || echo "")
          [ -n "$CALLBACK_GROUP" ] && echo "[dispatch] Auto-detected callback: group $CALLBACK_GROUP"
          ;;
        dm)
          CALLBACK_DM=$(jq -r '.dm // ""' "$CALLBACK_CONFIG" 2>/dev/null || echo "")
          CALLBACK_ACCOUNT=$(jq -r '.account // ""' "$CALLBACK_CONFIG" 2>/dev/null || echo "")
          [ -n "$CALLBACK_DM" ] && echo "[dispatch] Auto-detected callback: DM $CALLBACK_DM via ${CALLBACK_ACCOUNT:-default}"
          ;;
      esac
      break
    fi
  done
fi

# ---- 1. 写入任务元数据 ----
mkdir -p "$RESULT_DIR"

jq -n \
  --arg name "$TASK_NAME" \
  --arg group "$TELEGRAM_GROUP" \
  --arg callback_group "$CALLBACK_GROUP" \
  --arg callback_dm "$CALLBACK_DM" \
  --arg callback_account "$CALLBACK_ACCOUNT" \
  --arg prompt "$PROMPT" \
  --arg workdir "$WORKDIR" \
  --arg ts "$(date -Iseconds)" \
  --arg model "${MODEL:-default}" \
  '{
    task_name: $name,
    telegram_group: $group,
    callback_group: $callback_group,
    callback_dm: $callback_dm,
    callback_account: $callback_account,
    prompt: $prompt,
    workdir: $workdir,
    started_at: $ts,
    model: $model,
    status: "running"
  }' \
  > "$META_FILE"

echo "[dispatch] Task metadata written: $META_FILE"
echo "  Task:    $TASK_NAME"
echo "  Workdir: $WORKDIR"
echo "  Model:   ${MODEL:-default}"
echo "  Group:   ${TELEGRAM_GROUP:-none}"

# ---- 2. 清空上次输出 ----
> "$TASK_OUTPUT"

# ---- 3. 构建运行命令 ----
CMD=(python3 "$RUNNER" -p "$PROMPT" --cwd "$WORKDIR" --workspace "$WORKDIR")

[ -n "$MODEL" ]         && CMD+=(--model "$MODEL")
[ -n "$YOLO" ]          && CMD+=(--yolo)
[ -n "$MODE" ]          && CMD+=(--mode "$MODE")
[ -n "$OUTPUT_FORMAT" ] && CMD+=(--output-format "$OUTPUT_FORMAT")

# ---- 4. 启动 Cursor Agent ----
echo "[dispatch] Launching Cursor Agent..."
echo "  Command: ${CMD[*]}"
echo ""

"${CMD[@]}" 2>&1 | tee "$TASK_OUTPUT"
EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "[dispatch] Cursor Agent exited with code: $EXIT_CODE"

# ---- 5. 更新元数据 ----
if [ -f "$META_FILE" ]; then
  jq --arg code "$EXIT_CODE" --arg ts "$(date -Iseconds)" \
    '. + {exit_code: ($code | tonumber), completed_at: $ts, status: "done"}' \
    "$META_FILE" > "${META_FILE}.tmp" && mv "${META_FILE}.tmp" "$META_FILE"
fi

# ---- 6. 触发通知 ----
NOTIFY_HOOK="${SCRIPT_DIR}/notify-hook.sh"
if [ -x "$NOTIFY_HOOK" ]; then
  echo "[dispatch] Triggering notification hook..."
  bash "$NOTIFY_HOOK" || echo "[dispatch] Notification hook failed (non-fatal)"
fi

echo "[dispatch] Results: ${RESULT_DIR}/latest.json"
exit $EXIT_CODE
