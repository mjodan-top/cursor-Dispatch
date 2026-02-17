# Hook 配置指南

## 前置依赖

```bash
# 必需
apt install jq                                    # JSON 处理
curl https://cursor.com/install -fsS | bash       # 安装 Cursor Agent CLI

# 验证
agent --version
jq --version

# 可选（通知功能）
# openclaw CLI — 用于 Telegram 通知
# tmux — 用于交互模式
```

## 目录结构

```
cursor-Dispatch/
├── scripts/
│   ├── dispatch.sh            # 主调度脚本
│   ├── cursor_agent_run.py    # PTY 包装器
│   └── notify-hook.sh         # 完成通知 hook
├── data/
│   └── cursor-agent-results/  # 运行时数据（自动创建）
│       ├── task-meta.json     # 任务元数据
│       ├── task-output.txt    # Cursor Agent 原始输出
│       ├── latest.json        # 最近一次结果
│       ├── pending-wake.json  # 心跳回退通知
│       └── hook.log           # Hook 执行日志
└── dispatch-callback.json     # 可选：自动回调配置
```

## 安装

```bash
git clone https://github.com/mjodan-top/cursor-Dispatch.git
cd cursor-Dispatch
chmod +x scripts/*.sh scripts/*.py
```

## Cursor Agent CLI 用法

### 交互模式

```bash
# 启动交互式会话
agent

# 带初始提示启动
agent "refactor the auth module to use JWT tokens"
```

### 非交互模式（脚本/自动化）

```bash
# 基本用法：-p 开启 print 模式（非交互），--trust 跳过信任提示
agent -p --trust "find and fix performance issues"

# 指定模型和输出格式
agent -p --trust --model "sonnet-4" --output-format text "review code for bugs"

# 自动批准所有命令（yolo 模式）
agent -p --trust --yolo "add comprehensive unit tests"
```

### Agent 模式

| 模式 | 用法 | 说明 |
|------|------|------|
| Agent | 默认 | 完整工具访问，处理复杂编码任务 |
| Plan | `--mode plan` | 先分析后编码，先提出澄清性问题 |
| Ask | `--mode ask` | 只读探索，不修改代码 |

### 会话管理

```bash
agent ls                    # 列出历史对话
agent resume                # 恢复最近的对话
agent --resume="chat-id"    # 恢复指定对话
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RESULT_DIR` | `./data/cursor-agent-results` | 结果存储目录 |
| `AGENT_BIN` | `agent` (auto-detect) | Cursor Agent CLI 路径 |
| `OPENCLAW_BIN` | auto-detect | openclaw CLI 路径 |
| `OPENCLAW_CONFIG` | `~/.openclaw/openclaw.json` | OpenClaw 配置文件路径 |
| `OPENCLAW_GATEWAY_PORT` | `18789` | Gateway webhook 端口 |
| `CURSOR_API_KEY` | | API key（agent CLI 也支持 `--api-key`） |

## 自动回调配置

在工作目录放置 `dispatch-callback.json`，dispatch 脚本会自动检测并配置回调：

### Group 模式

```json
{
  "type": "group",
  "group": "<telegram-group-id>"
}
```

### DM 模式

```json
{
  "type": "dm",
  "dm": "<telegram-user-id>",
  "account": "<bot-account-name>"
}
```

### 仅 Webhook 唤醒

```json
{
  "type": "wake"
}
```

## OpenClaw Telegram 配置

要使通知功能正常工作，目标 Telegram group 需要：

1. Bot 已加入群组
2. OpenClaw 配置中的白名单：

```json
{
  "channels": {
    "telegram": {
      "groups": {
        "<your-group-id>": {
          "requireMention": false,
          "enabled": true
        }
      }
    }
  }
}
```

## 注意事项

- **PTY 需求**：在无 TTY 环境下直接运行 `agent -p` 可能挂起，`cursor_agent_run.py` 通过 `script(1)` 解决此问题。
- **`--trust` 必须在 headless 中使用**：否则 agent 会等待用户确认 workspace trust 而挂起。
- **tee pipe 竞态**：notify-hook 会等待 1 秒让 pipe flush 完成后再读取输出。
- **去重机制**：hook 通过 `.hook-lock` 文件做 30 秒去重，避免重复通知。
- **元数据过期**：超过 2 小时的 `task-meta.json` 会被忽略，防止误发旧任务通知。
- **始终指定 `-w`**：不指定工作目录可能导致在错误的 cwd 中执行。
- **Cloud Agent**：在交互模式中，消息前加 `&` 可以把任务推送到 Cloud Agent 继续运行（`& refactor auth and add tests`）。
