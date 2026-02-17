#!/usr/bin/env python3
"""cursor_agent_run.py — 可靠地运行 Cursor Agent CLI

支持两种模式：
- headless（非交互）：通过 `agent -p "prompt" --trust` 执行，适用于 CI / 自动化
- interactive（交互）：通过 tmux 启动 `agent "prompt"`，适用于斜杠命令交互场景

Cursor Agent CLI 参考：
- 交互模式：agent "prompt"
- 非交互模式：agent -p "prompt" --output-format text --trust
- 完整文档：https://cursor.com/docs/cli/overview
"""

from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_AGENT_BIN = os.environ.get("AGENT_BIN", "agent")


def which(name: str) -> str | None:
    """Search PATH for an executable."""
    paths = os.environ.get("PATH", "").split(":")
    for p in paths:
        cand = Path(p) / name
        try:
            if cand.is_file() and os.access(cand, os.X_OK):
                return str(cand)
        except OSError:
            pass
    return None


def looks_like_slash_commands(prompt: str | None) -> bool:
    """Detect if the prompt contains interactive slash commands."""
    if not prompt:
        return False
    for line in prompt.splitlines():
        stripped = line.strip()
        if stripped.startswith("/") and not stripped.startswith("//"):
            return True
    return False


def build_headless_cmd(args: argparse.Namespace) -> list[str]:
    """Build the CLI command for headless (non-interactive) execution.

    agent -p "prompt" --trust --output-format text [--model X] [--workspace W] [--yolo]
    """
    cmd: list[str] = [args.agent_bin]

    # -p / --print: 非交互模式，输出到 stdout
    cmd.append("-p")

    # --trust: 免信任提示（headless 必需）
    cmd.append("--trust")

    if args.output_format:
        cmd += ["--output-format", args.output_format]

    if args.model:
        cmd += ["--model", args.model]

    if args.workspace:
        cmd += ["--workspace", args.workspace]
    elif args.cwd:
        cmd += ["--workspace", args.cwd]

    if args.yolo:
        cmd.append("--yolo")

    if args.mode:
        cmd += ["--mode", args.mode]

    # prompt 作为位置参数放最后
    if args.prompt:
        cmd.append(args.prompt)

    if args.extra:
        cmd += args.extra

    return cmd


def run_with_pty(cmd: list[str], cwd: str | None, env: dict[str, str] | None = None) -> int:
    """Run command inside a PTY via script(1) to prevent hanging."""
    cmd_str = " ".join(shlex.quote(c) for c in cmd)

    script_bin = which("script")
    if not script_bin:
        print("[runner] script(1) not found, running directly", file=sys.stderr)
        proc = subprocess.run(cmd, cwd=cwd, text=True, env=env)
        return proc.returncode

    proc = subprocess.run(
        [script_bin, "-q", "-c", cmd_str, "/dev/null"],
        cwd=cwd,
        text=True,
        env=env,
    )
    return proc.returncode


# ---- tmux 交互模式 ----

def tmux_cmd(socket_path: str, *args: str) -> list[str]:
    return ["tmux", "-S", socket_path, *args]


def tmux_capture(socket_path: str, target: str, lines: int = 200) -> str:
    out = subprocess.check_output(
        tmux_cmd(socket_path, "capture-pane", "-p", "-J", "-t", target, "-S", f"-{lines}"),
        text=True,
    )
    return out


def tmux_wait_for_text(
    socket_path: str, target: str, pattern: str,
    timeout_s: int = 30, poll_s: float = 0.5,
) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            buf = tmux_capture(socket_path, target, lines=200)
            if pattern in buf:
                return True
        except subprocess.CalledProcessError:
            pass
        time.sleep(poll_s)
    return False


def run_interactive_tmux(args: argparse.Namespace) -> int:
    """Run Cursor Agent in tmux for interactive slash-command workflows.

    tmux 中执行: agent "prompt" [--model X] [--workspace W]
    """
    if not which("tmux"):
        print("[runner] tmux not found in PATH", file=sys.stderr)
        return 2

    socket_dir = args.tmux_socket_dir or os.environ.get(
        "CURSOR_DISPATCH_TMUX_SOCKET_DIR",
        f"{os.environ.get('TMPDIR', '/tmp')}/cursor-dispatch-tmux",
    )
    Path(socket_dir).mkdir(parents=True, exist_ok=True)
    socket_path = str(Path(socket_dir) / args.tmux_socket_name)

    session = args.tmux_session
    target = f"{session}:0.0"

    subprocess.run(
        tmux_cmd(socket_path, "kill-session", "-t", session),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    subprocess.check_call(
        tmux_cmd(socket_path, "new", "-d", "-s", session, "-n", "shell"),
    )

    cwd = args.workspace or args.cwd or os.getcwd()

    # 构建交互模式命令: agent "prompt" --model X --workspace W
    agent_parts: list[str] = [args.agent_bin]
    if args.model:
        agent_parts += ["--model", args.model]
    if args.yolo:
        agent_parts.append("--yolo")
    if args.mode:
        agent_parts += ["--mode", args.mode]
    agent_parts += ["--workspace", cwd]
    if args.extra:
        agent_parts += args.extra

    launch = " ".join(shlex.quote(p) for p in agent_parts)
    subprocess.check_call(
        tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", launch),
    )
    subprocess.check_call(
        tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"),
    )

    # 等待 workspace trust prompt
    if tmux_wait_for_text(socket_path, target, "trust", timeout_s=20):
        subprocess.run(tmux_cmd(socket_path, "send-keys", "-t", target, "y"), check=False)
        subprocess.run(tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"), check=False)
        time.sleep(0.8)

    # 发送 prompt（交互模式下作为第一条消息输入）
    if args.prompt:
        time.sleep(2)
        for line in [ln for ln in args.prompt.splitlines() if ln.strip()]:
            subprocess.check_call(
                tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", line),
            )
            subprocess.check_call(
                tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"),
            )
            time.sleep(args.interactive_send_delay_ms / 1000.0)

    print("[runner] Started interactive Cursor Agent in tmux.")
    print(f"  Monitor:  tmux -S {shlex.quote(socket_path)} attach -t {shlex.quote(session)}")
    print(f"  Snapshot: tmux -S {shlex.quote(socket_path)} capture-pane -p -J -t {shlex.quote(target)} -S -200")

    if args.interactive_wait_s > 0:
        time.sleep(args.interactive_wait_s)
        try:
            snap = tmux_capture(socket_path, target, lines=200)
            print("\n--- tmux snapshot (last 200 lines) ---\n")
            print(snap)
        except subprocess.CalledProcessError:
            pass

    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Run Cursor Agent CLI reliably (headless or interactive via tmux)",
    )

    ap.add_argument("-p", "--prompt", help="Task prompt text")
    ap.add_argument(
        "--run-mode", choices=["auto", "headless", "interactive"], default="auto",
        help="Execution mode. auto = interactive if prompt has slash commands, else headless",
    )
    ap.add_argument(
        "--mode", default=None, choices=["plan", "ask"],
        help="Agent execution mode (plan / ask). Default is agent mode.",
    )
    ap.add_argument("--model", default=None, help="Model override (e.g. gpt-5, sonnet-4)")
    ap.add_argument(
        "--yolo", action="store_true", default=False,
        help="Force allow all commands (alias for --force)",
    )
    ap.add_argument(
        "--output-format", default="text", choices=["text", "json", "stream-json"],
        help="Output format for headless mode (default: text)",
    )
    ap.add_argument(
        "--workspace", default=None,
        help="Workspace directory for agent",
    )
    ap.add_argument(
        "--agent-bin", default=DEFAULT_AGENT_BIN,
        help=f"Path to agent binary (default: {DEFAULT_AGENT_BIN}). Or set AGENT_BIN env.",
    )
    ap.add_argument("--cwd", help="Working directory (defaults to current directory)")

    # tmux 相关
    ap.add_argument("--tmux-session", default="cursor-agent", help="tmux session name")
    ap.add_argument("--tmux-socket-dir", default=None, help="tmux socket directory")
    ap.add_argument("--tmux-socket-name", default="cursor-agent.sock", help="tmux socket file")
    ap.add_argument("--interactive-wait-s", type=int, default=0, help="Wait N seconds then print tmux snapshot")
    ap.add_argument("--interactive-send-delay-ms", type=int, default=800, help="Delay between sending lines in interactive mode")

    ap.add_argument("extra", nargs=argparse.REMAINDER, help="Extra args after --")

    args = ap.parse_args()

    extra = args.extra
    if extra and extra[0] == "--":
        extra = extra[1:]
    args.extra = extra

    # 检测 agent 可执行文件
    agent_path = which(args.agent_bin)
    if not agent_path and not Path(args.agent_bin).exists():
        print(f"[runner] agent binary not found: {args.agent_bin}", file=sys.stderr)
        print("Tip: install via `curl https://cursor.com/install -fsS | bash`", file=sys.stderr)
        print("  or set AGENT_BIN=/path/to/agent", file=sys.stderr)
        return 2

    mode = args.run_mode
    if mode == "auto" and looks_like_slash_commands(args.prompt):
        mode = "interactive"

    if mode == "interactive":
        return run_interactive_tmux(args)

    cmd = build_headless_cmd(args)
    env = os.environ.copy()
    return run_with_pty(cmd, cwd=args.cwd, env=env)


if __name__ == "__main__":
    raise SystemExit(main())
