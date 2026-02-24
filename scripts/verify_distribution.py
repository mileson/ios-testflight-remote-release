#!/usr/bin/env python3
"""发布后校验：通过 assign_internal_tester lane 做幂等校验与补齐。"""

from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
from pathlib import Path


def resolve_fastlane_cmd(project_root: Path) -> list[str]:
    if (project_root / "Gemfile").exists():
        return ["bundle", "exec", "fastlane"]
    return ["fastlane"]


def git_email(project_root: Path) -> str:
    try:
        out = subprocess.check_output(["git", "config", "user.email"], cwd=project_root, text=True)
        return out.strip()
    except Exception:
        return ""


def stream_command(cmd: list[str], cwd: Path, env: dict[str, str]) -> int:
    print("[RUN] " + " ".join(shlex.quote(c) for c in cmd))
    process = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    assert process.stdout is not None
    for line in process.stdout:
        sys.stdout.write(line)
    process.wait()
    return process.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify and fix internal tester distribution.")
    parser.add_argument("--project-root", default=os.getcwd(), help="iOS 项目根目录")
    parser.add_argument("--group", default=os.getenv("INTERNAL_GROUP_NAME", "Agent Internal Testing"))
    parser.add_argument("--testers", default=os.getenv("TESTER_EMAILS", ""))
    parser.add_argument("--app-identifier", default=os.getenv("IOS_APP_IDENTIFIER", ""))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    project_root = Path(args.project_root).expanduser().resolve()
    if not project_root.exists():
        print(f"[FAIL] project root 不存在: {project_root}", file=sys.stderr)
        return 2
    if not (project_root / "fastlane" / "Fastfile").exists():
        print("[FAIL] 缺少 fastlane/Fastfile", file=sys.stderr)
        return 2

    testers = args.testers.strip() or git_email(project_root)
    if not testers:
        print("[FAIL] 未提供 tester 邮箱（--testers 或 TESTER_EMAILS）", file=sys.stderr)
        return 2

    fastlane_cmd = resolve_fastlane_cmd(project_root)
    lane_cmd = fastlane_cmd + [
        "ios",
        "assign_internal_tester",
        f"group:{args.group}",
        f"testers:{testers}",
    ]
    if args.app_identifier:
        lane_cmd.append(f"app_identifier:{args.app_identifier}")

    if args.dry_run:
        print("[DRY-RUN] " + " ".join(shlex.quote(c) for c in lane_cmd))
        return 0

    env = os.environ.copy()
    env["INTERNAL_GROUP_NAME"] = args.group
    env["TESTER_EMAILS"] = testers
    if args.app_identifier:
        env["IOS_APP_IDENTIFIER"] = args.app_identifier

    rc = stream_command(lane_cmd, project_root, env)
    if rc != 0:
        print("[FAIL] 分发校验失败，请检查 fastlane 输出。", file=sys.stderr)
        return rc

    print("[DONE] Internal Group 与 tester 分发校验通过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
