#!/usr/bin/env python3
"""iOS Internal Release 资料收敛工具（本地优先 + memory 回写）。"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, Tuple

REQUIRED_KEYS = ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_FILEPATH"]

TRACKED_KEYS = [
    "ASC_KEY_ID",
    "ASC_ISSUER_ID",
    "ASC_KEY_FILEPATH",
    "ASC_KEY_IS_BASE64",
    "TESTER_EMAILS",
    "INTERNAL_GROUP_NAME",
    "IOS_WORKSPACE",
    "IOS_SCHEME",
    "IOS_APP_IDENTIFIER",
    "XCODEPROJ_PATH",
    "APPLE_ID",
    "TEAM_ID",
]

DEFAULTS = {
    "INTERNAL_GROUP_NAME": "Agent Internal Testing",
    "ASC_KEY_IS_BASE64": "false",
}

SENSITIVE_KEYS = {
    "ASC_KEY_ID",
    "ASC_ISSUER_ID",
    "ASC_KEY_FILEPATH",
    "TESTER_EMAILS",
    "APPLE_ID",
}


def now_iso() -> str:
    return dt.datetime.now().replace(microsecond=0).isoformat()


def mask_value(key: str, value: str) -> str:
    if not value:
        return ""
    if key not in SENSITIVE_KEYS:
        return value
    if key == "ASC_KEY_FILEPATH":
        p = Path(value)
        return str(p.parent / ("***" + p.name[-10:])) if p.name else "***"
    if "@" in value:
        name, domain = value.split("@", 1)
        return (name[:2] + "***@" + domain) if len(name) >= 2 else "***@" + domain
    if len(value) <= 6:
        return "***"
    return value[:2] + "***" + value[-2:]


def run_cmd(cmd: list[str], cwd: Path | None = None) -> str:
    try:
        out = subprocess.check_output(cmd, cwd=str(cwd) if cwd else None, stderr=subprocess.DEVNULL, text=True)
        return out.strip()
    except Exception:
        return ""


def parse_set_values(pairs: list[str]) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for pair in pairs:
        if "=" not in pair:
            raise ValueError(f"--set 参数格式错误（应为 KEY=VALUE）: {pair}")
        key, value = pair.split("=", 1)
        key = key.strip()
        if not key:
            raise ValueError(f"--set 参数 KEY 为空: {pair}")
        result[key] = value.strip()
    return result


def derive_key_id_from_key_filepath(key_filepath: str) -> str:
    """从 AuthKey_<KEY_ID>.p8 文件名提取 ASC_KEY_ID。"""
    if not key_filepath:
        return ""
    base = Path(key_filepath).name
    # Apple 官方下载文件名通常为 AuthKey_<KEYID>.p8
    m = re.match(r"^AuthKey_([A-Za-z0-9]+)\.p8$", base, flags=re.IGNORECASE)
    if m:
        return m.group(1)
    return ""


def detect_workspace(project_root: Path) -> str:
    items = sorted(project_root.glob("*.xcworkspace"))
    return items[0].name if items else ""


def detect_xcodeproj(project_root: Path) -> str:
    items = sorted(project_root.glob("*.xcodeproj"))
    return items[0].name if items else ""


def detect_scheme(project_root: Path, workspace_name: str, preferred: str = "") -> str:
    if not workspace_name:
        return ""
    workspace_path = project_root / workspace_name
    raw = run_cmd(["xcodebuild", "-list", "-json", "-workspace", str(workspace_path)])
    if not raw:
        return ""
    try:
        data = json.loads(raw)
        schemes = data.get("workspace", {}).get("schemes") or []
        if not schemes:
            return ""
        if preferred:
            p = preferred.strip().lower()
            for s in schemes:
                if s.lower() == p:
                    return s
        return schemes[0]
    except Exception:
        return ""


def parse_appfile(appfile: Path) -> Dict[str, str]:
    if not appfile.exists():
        return {}
    text = appfile.read_text(encoding="utf-8", errors="ignore")
    values: Dict[str, str] = {}

    m = re.search(r'^\s*app_identifier\s+"([^"]+)"', text, re.MULTILINE)
    if m:
        values["IOS_APP_IDENTIFIER"] = m.group(1).strip()

    m = re.search(r'^\s*team_id\s+"([^"]+)"', text, re.MULTILINE)
    if m:
        values["TEAM_ID"] = m.group(1).strip()

    # apple_id "xx@xx.com" 或 apple_id ENV.fetch("APPLE_ID", "xx@xx.com")
    m = re.search(r'^\s*apple_id\s+"([^"]+)"', text, re.MULTILINE)
    if m:
        values["APPLE_ID"] = m.group(1).strip()
    else:
        m = re.search(r'^\s*apple_id\s+ENV\.fetch\("APPLE_ID",\s*"([^"]+)"\)', text, re.MULTILINE)
        if m:
            values["APPLE_ID"] = m.group(1).strip()

    return values


def detect_local_values(project_root: Path) -> Dict[str, str]:
    appfile_values = parse_appfile(project_root / "fastlane" / "Appfile")
    workspace = detect_workspace(project_root)
    xcodeproj = detect_xcodeproj(project_root)
    preferred = ""
    if workspace:
        preferred = workspace.removesuffix(".xcworkspace")
    elif xcodeproj:
        preferred = xcodeproj.removesuffix(".xcodeproj")
    scheme = detect_scheme(project_root, workspace, preferred=preferred)
    git_email = run_cmd(["git", "config", "user.email"], cwd=project_root)

    values = {
        "IOS_WORKSPACE": workspace,
        "XCODEPROJ_PATH": xcodeproj,
        "IOS_SCHEME": scheme,
        "TESTER_EMAILS": git_email,
    }
    values.update(appfile_values)
    return {k: v for k, v in values.items() if v}


def load_memory(memory_file: Path) -> Dict:
    if not memory_file.exists():
        return {"schema_version": 1, "projects": {}}
    try:
        return json.loads(memory_file.read_text(encoding="utf-8"))
    except Exception:
        return {"schema_version": 1, "projects": {}}


def save_memory(memory_file: Path, data: Dict) -> None:
    memory_file.parent.mkdir(parents=True, exist_ok=True)
    memory_file.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def render_memory_md(memory_md_path: Path, memory_json: Dict) -> None:
    lines = [
        "# iOS TestFlight Remote Release Memory",
        "",
        "> 说明：本文件为人类可读视图；机器读写以 `memory.json` 为准。",
        "",
    ]
    projects = memory_json.get("projects", {})
    if not projects:
        lines.extend(
            [
                "## 最近项目记录",
                "",
                "当前暂无记录。首次执行 `resolve_materials.py --write-memory` 后自动生成。",
                "",
            ]
        )
    else:
        for project_root, item in projects.items():
            values = item.get("values", {})
            lines.extend([f"## Project: `{project_root}`", "", f"- updated_at: `{item.get('updated_at', '')}`"])
            for key in TRACKED_KEYS:
                val = values.get(key, "")
                if val:
                    lines.append(f"- {key}: `{mask_value(key, str(val))}`")
            lines.append("")
    memory_md_path.write_text("\n".join(lines), encoding="utf-8")


def resolve_values(
    explicit: Dict[str, str],
    env_values: Dict[str, str],
    local_values: Dict[str, str],
    memory_values: Dict[str, str],
) -> Tuple[Dict[str, str], Dict[str, str]]:
    resolved: Dict[str, str] = {}
    source: Dict[str, str] = {}
    for key in TRACKED_KEYS:
        if key in explicit and explicit[key]:
            resolved[key] = explicit[key]
            source[key] = "explicit"
            continue
        env_v = env_values.get(key, "")
        if env_v:
            resolved[key] = env_v
            source[key] = "env"
            continue
        local_v = local_values.get(key, "")
        if local_v:
            resolved[key] = local_v
            source[key] = "local"
            continue
        mem_v = memory_values.get(key, "")
        if mem_v:
            resolved[key] = mem_v
            source[key] = "memory"
            continue
        default_v = DEFAULTS.get(key, "")
        if default_v:
            resolved[key] = default_v
            source[key] = "default"
            continue
        resolved[key] = ""
        source[key] = "missing"

    # 补充推导：若 ASC_KEY_ID 缺失，尝试从 ASC_KEY_FILEPATH 文件名推导
    if not resolved.get("ASC_KEY_ID"):
        derived_key_id = derive_key_id_from_key_filepath(resolved.get("ASC_KEY_FILEPATH", ""))
        if derived_key_id:
            resolved["ASC_KEY_ID"] = derived_key_id
            source["ASC_KEY_ID"] = "derived_from_key_filepath"
    return resolved, source


def print_scan(project_root: Path, resolved: Dict[str, str], source: Dict[str, str]) -> None:
    missing_required = [k for k in REQUIRED_KEYS if not resolved.get(k)]
    print("# Materials Scan")
    print(f"- project_root: `{project_root}`")
    print("")
    print("| 字段 | 状态 | 值(掩码) | 来源 |")
    print("|---|---|---|---|")
    for key in TRACKED_KEYS:
        value = resolved.get(key, "")
        status = "OK" if value else "MISSING"
        print(f"| `{key}` | {status} | `{mask_value(key, value)}` | `{source.get(key, '')}` |")
    print("")
    if missing_required:
        print("## 缺失必填项")
        for key in missing_required:
            print(f"- {key}")
    else:
        print("## 缺失必填项")
        print("- 无")


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve internal release materials with local-first strategy.")
    parser.add_argument("--project-root", default=os.getcwd(), help="iOS 项目根目录")
    parser.add_argument("--memory-file", default="", help="自定义 memory.json 路径（默认 data/memory.json）")
    parser.add_argument("--set", action="append", default=[], help="手动注入 KEY=VALUE，可重复")
    parser.add_argument("--scan", action="store_true", help="输出扫描表")
    parser.add_argument("--json", action="store_true", help="输出 JSON")
    parser.add_argument("--print-export", action="store_true", help="输出 export 语句")
    parser.add_argument("--write-memory", action="store_true", help="将解析结果回写 memory")
    args = parser.parse_args()

    project_root = Path(args.project_root).expanduser().resolve()
    if not project_root.exists():
        print(f"[ERROR] project root 不存在: {project_root}", file=sys.stderr)
        return 2

    explicit = parse_set_values(args.set)
    env_values = {k: os.getenv(k, "") for k in TRACKED_KEYS}
    local_values = detect_local_values(project_root)

    skill_root = Path(__file__).resolve().parents[1]
    memory_json_path = Path(args.memory_file).expanduser().resolve() if args.memory_file else (skill_root / "data" / "memory.json")
    memory_md_path = memory_json_path.with_name("memory.md")

    memory_all = load_memory(memory_json_path)
    projects = memory_all.setdefault("projects", {})
    project_key = str(project_root)
    memory_values = projects.get(project_key, {}).get("values", {})

    resolved, source = resolve_values(explicit, env_values, local_values, memory_values)

    if args.write_memory:
        values_to_save = {k: v for k, v in resolved.items() if v}
        projects[project_key] = {"updated_at": now_iso(), "values": values_to_save}
        save_memory(memory_json_path, memory_all)
        render_memory_md(memory_md_path, memory_all)

    if args.scan:
        print_scan(project_root, resolved, source)

    if args.print_export:
        for key in TRACKED_KEYS:
            value = resolved.get(key, "")
            if value:
                safe = value.replace('"', '\\"')
                print(f'export {key}="{safe}"')

    if args.json:
        print(json.dumps({"resolved": resolved, "source": source}, ensure_ascii=False, indent=2))

    missing_required = [k for k in REQUIRED_KEYS if not resolved.get(k)]
    if missing_required:
        print(f"[WARN] 缺失必填项: {', '.join(missing_required)}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
