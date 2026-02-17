# cursor-Dispatch

One-command dispatch of dev tasks to Cursor Agent CLI with auto-notification via OpenClaw.

Fire-and-forget your coding tasks -> Cursor Agent builds it in the background -> you get a Telegram notification when it's done.

## Features

- **Fire-and-forget** — Dispatch a task and walk away. Get notified when done.
- **Telegram notifications** — Rich completion reports with test results, file listings, duration via OpenClaw.
- **Three-layer callback** — Telegram message -> webhook wake -> heartbeat fallback.
- **Auto-callback detection** — Place a `dispatch-callback.json` in your workspace, zero params needed.
- **PTY wrapper** — Reliable execution in non-TTY environments via `script(1)`.
- **Interactive mode** — tmux-based interactive session for slash-command workflows.

## Architecture

```
dispatch.sh
  -> write task-meta.json
  -> launch Cursor Agent via cursor_agent_run.py (PTY wrapper)
     -> headless: agent -p --trust --output-format text "prompt"
     -> interactive: tmux + agent "prompt"
  -> Cursor Agent finishes
  -> notify-hook.sh reads meta + output
  -> writes latest.json
  -> sends Telegram notification via OpenClaw
  -> wakes AGI via webhook
  -> writes pending-wake.json (fallback)
```

## Quick Start

### 1. Install Cursor Agent CLI

```bash
# macOS / Linux / WSL
curl https://cursor.com/install -fsS | bash

# Verify
agent --version
```

### 2. Clone this repo

```bash
git clone https://github.com/mjodan-top/cursor-Dispatch.git
cd cursor-Dispatch
chmod +x scripts/*.sh scripts/*.py
```

### 3. Prerequisites

```bash
apt install jq    # JSON processing (required)
# Optional: openclaw CLI for Telegram notifications
```

### 4. Dispatch a Task

```bash
# Simple task (headless mode)
bash scripts/dispatch.sh \
  -p "Build a Python CLI calculator with Click" \
  -n "calc-cli" \
  -w /path/to/project

# With Telegram notification
bash scripts/dispatch.sh \
  -p "Build a REST API with FastAPI" \
  -n "my-api" \
  -g "<telegram-group-id>" \
  -w /path/to/project

# Auto-approve all commands (yolo mode)
bash scripts/dispatch.sh \
  -p "Refactor the auth module to use JWT" \
  -n "auth-refactor" \
  -w /path/to/project \
  --yolo

# Specify model
bash scripts/dispatch.sh \
  -p "Add unit tests for the payment module" \
  -n "payment-tests" \
  -w /path/to/project \
  --model "sonnet-4"
```

## Cursor Agent CLI Reference

| Command | Description |
|---------|-------------|
| `agent` | Start interactive session |
| `agent "prompt"` | Interactive with initial prompt |
| `agent -p "prompt"` | Headless / non-interactive mode (print to stdout) |
| `agent -p --trust "prompt"` | Headless + skip workspace trust prompt |
| `agent -p --yolo "prompt"` | Headless + auto-approve all commands |
| `agent --model gpt-5 "prompt"` | Specify model |
| `agent --mode plan "prompt"` | Plan mode (read-only analysis first) |
| `agent --mode ask "prompt"` | Ask mode (read-only, no changes) |
| `agent resume` | Resume latest conversation |
| `agent ls` | List previous sessions |

Full docs: https://cursor.com/docs/cli/overview

## Dispatch Parameters

| Param | Short | Required | Description |
|-------|-------|----------|-------------|
| `--prompt` | `-p` | Yes | Task description |
| `--name` | `-n` | | Task name for tracking |
| `--group` | `-g` | | Telegram group ID for notifications |
| `--workdir` | `-w` | | Working directory (default: cwd) |
| `--model` | | | Model override (e.g. gpt-5, sonnet-4) |
| `--yolo` | | | Auto-approve all commands |
| `--mode` | | | Agent mode (plan/ask) |
| `--output-format` | | | Output format (text/json/stream-json) |
| `--callback-group` | | | Telegram group for callback |
| `--callback-dm` | | | Telegram user ID for DM callback |
| `--callback-account` | | | Telegram bot account name |

## Auto-Callback Detection

Place a `dispatch-callback.json` in your workspace root:

**For group notifications:**
```json
{
  "type": "group",
  "group": "<telegram-group-id>"
}
```

**For DM notifications:**
```json
{
  "type": "dm",
  "dm": "<telegram-user-id>",
  "account": "<bot-account-name>"
}
```

**For webhook wake only:**
```json
{
  "type": "wake"
}
```

## Result Files

All results stored in `data/cursor-agent-results/`:

| File | Content |
|------|---------|
| `latest.json` | Full result (output, task name, group, timestamp) |
| `task-meta.json` | Task metadata (prompt, workdir, status, duration) |
| `task-output.txt` | Raw Cursor Agent stdout |
| `pending-wake.json` | Heartbeat fallback notification |
| `hook.log` | Hook execution log |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RESULT_DIR` | `./data/cursor-agent-results` | Result storage directory |
| `AGENT_BIN` | auto-detect `agent` | Path to Cursor Agent CLI |
| `OPENCLAW_BIN` | auto-detect `openclaw` | Path to openclaw CLI |
| `OPENCLAW_CONFIG` | `~/.openclaw/openclaw.json` | OpenClaw config file |
| `OPENCLAW_GATEWAY_PORT` | `18789` | Gateway port for webhook |

## Integration with OpenClaw

This tool is designed to integrate with [OpenClaw](https://docs.openclaw.ai):

- Telegram notifications via `openclaw message send`
- AGI wake via `/hooks/wake` webhook

## Documentation

- [Hook Setup Guide](docs/hook-setup.md)
- [Prompt Guide](docs/prompt-guide.md)

## Gotchas

- **Must use PTY wrapper** — Direct `agent -p` may hang in non-TTY environments. `cursor_agent_run.py` handles this via `script(1)`.
- **`--trust` is required in headless** — Without it, agent will prompt for workspace trust and hang in non-interactive mode.
- **tee pipe race condition** — Hook sleeps 1s to wait for pipe flush.
- **Always set `-w` explicitly** — Missing workdir can drift into wrong cwd.
- **Meta file expiry** — task-meta.json older than 2h is ignored to prevent stale notifications.

## License

MIT
