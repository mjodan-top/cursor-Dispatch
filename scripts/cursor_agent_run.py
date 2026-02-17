#!/usr/bin/env python3
"""cursor_agent_run.py — 可靠地运行 Cursor Agent（headless 或 tmux 交互模式）

默认模式为 auto：
- 如果 prompt 包含斜杠命令（如 /xxx），启动 tmux 交互模式
- 否则通过 script(1) 在伪终端中运行 headless 模式

为什么需要这个包装器：
- Cursor Agent 在无 TTY 环境下可能挂起
- CI / exec 环境通常是非交互式的
- script(1) 能强制分配伪终端
"""

from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_CURSOR = os.environ.get("CURSOR_BIN", "cursor")


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
        if line.strip().startswith("/"):
            return True
    return False


def build_headless_cmd(args: argparse.Namespace) -> list[str]:
    """Build the CLI command for headless (non-interactive) execution."""
    cmd: list[str] = [args.cursor_bin, "agent"]

    if args.prompt is not None:
        cmd += ["-m", args.prompt]

    if args.permission_mode:
        cmd += ["--permission-mode", args.permission_mode]

    if args.model:
        cmd += ["--model", args.model]

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
    """Run Cursor Agent in tmux for interactive slash-command workflows."""
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

    cwd = args.cwd or os.getcwd()

    cursor_parts = [args.cursor_bin, "agent"]
    if args.permission_mode:
        cursor_parts += ["--permission-mode", args.permission_mode]
    if args.model:
        cursor_parts += ["--model", args.model]
    if args.extra:
        cursor_parts += args.extra

    launch = f"cd {shlex.quote(cwd)} && " + " ".join(shlex.quote(p) for p in cursor_parts)
    subprocess.check_call(
        tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", launch),
    )
    subprocess.check_call(
        tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"),
    )

    # 等待 workspace trust prompt
    if tmux_wait_for_text(socket_path, target, "trust", timeout_s=20):
        subprocess.run(tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"), check=False)
        time.sleep(0.8)

    # 发送 prompt
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
        description="Run Cursor Agent reliably (headless or interactive via tmux)",
    )

    ap.add_argument("-p", "--prompt", help="Task prompt text")
    ap.add_argument(
        "--mode", choices=["auto", "headless", "interactive"], default="auto",
        help="Execution mode. auto = interactive if prompt has slash commands, else headless",
    )
    ap.add_argument(
        "--permission-mode", default=None,
        help="Permission mode passed to cursor agent (e.g. ask, auto, bypass)",
    )
    ap.add_argument("--model", default=None, help="Model override")
    ap.add_argument(
        "--cursor-bin", default=DEFAULT_CURSOR,
        help=f"Path to cursor binary (default: {DEFAULT_CURSOR}). Or set CURSOR_BIN env.",
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

    # 检测 cursor 可执行文件
    cursor_path = which(args.cursor_bin) if not Path(args.cursor_bin).exists() else args.cursor_bin
    if not cursor_path:
        print(f"[runner] cursor binary not found: {args.cursor_bin}", file=sys.stderr)
        print("Tip: set CURSOR_BIN=/path/to/cursor", file=sys.stderr)
        return 2

    mode = args.mode
    if mode == "auto" and looks_like_slash_commands(args.prompt):
        mode = "interactive"

    if mode == "interactive":
        return run_interactive_tmux(args)

    cmd = build_headless_cmd(args)
    env = os.environ.copy()
    return run_with_pty(cmd, cwd=args.cwd, env=env)


if __name__ == "__main__":
    raise SystemExit(main())
