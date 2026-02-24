#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$PWD"
WORKSPACE=""
SCHEME=""
APP_IDENTIFIER=""
XCODEPROJ=""
INTERNAL_GROUP_NAME="${INTERNAL_GROUP_NAME:-Agent Internal Testing}"
AUTO_BOOTSTRAP_FASTLANE="true"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/preflight_scan.sh [options]

Options:
  --project-root <path>       iOS 项目根目录（默认当前目录）
  --workspace <name>          workspace 文件名（如 ReadFast.xcworkspace）
  --scheme <name>             scheme 名称（如 ReadFast）
  --xcodeproj <name>          xcodeproj 文件名（如 ReadFast.xcodeproj）
  --app-identifier <bundle>   App Identifier
  --no-auto-bootstrap         缺少 fastlane 时不自动初始化（默认自动初始化）
  -h, --help                  显示帮助
EOF
}

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

detect_workspace() {
  if [[ -n "${WORKSPACE}" ]]; then
    echo "${WORKSPACE}"
    return 0
  fi
  local first
  first="$(find "${PROJECT_ROOT}" -maxdepth 1 -type d -name "*.xcworkspace" | head -n1 || true)"
  if [[ -n "${first}" ]]; then
    basename "${first}"
  fi
}

detect_xcodeproj() {
  if [[ -n "${XCODEPROJ}" ]]; then
    echo "${XCODEPROJ}"
    return 0
  fi
  local first
  first="$(find "${PROJECT_ROOT}" -maxdepth 1 -type d -name "*.xcodeproj" | head -n1 || true)"
  if [[ -n "${first}" ]]; then
    basename "${first}"
  fi
}

detect_scheme() {
  if [[ -n "${SCHEME}" ]]; then
    echo "${SCHEME}"
    return 0
  fi
  local ws="$1"
  local preferred="$2"
  if [[ -z "${ws}" ]]; then
    return 0
  fi
  if ! has_cmd xcodebuild || ! has_cmd python3; then
    return 0
  fi
  local raw
  raw="$(xcodebuild -list -json -workspace "${PROJECT_ROOT}/${ws}" 2>/dev/null || true)"
  if [[ -z "${raw}" ]]; then
    return 0
  fi
  python3 - "${raw}" "${preferred}" <<'PY' || true
import json
import sys

raw = sys.argv[1]
preferred = (sys.argv[2] or "").strip().lower()
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)
workspace = data.get("workspace", {})
schemes = workspace.get("schemes") or []
if not schemes:
    sys.exit(0)
if preferred:
    for s in schemes:
        if s.lower() == preferred:
            print(s)
            sys.exit(0)
print(schemes[0])
PY
}

detect_app_identifier() {
  if [[ -n "${APP_IDENTIFIER}" ]]; then
    echo "${APP_IDENTIFIER}"
    return 0
  fi
  local appfile="${PROJECT_ROOT}/fastlane/Appfile"
  if [[ ! -f "${appfile}" ]]; then
    return 0
  fi
  sed -n 's/^[[:space:]]*app_identifier[[:space:]]*"\(.*\)".*/\1/p' "${appfile}" | head -n1
}

detect_connected_iphone() {
  if ! has_cmd xcrun; then
    return 0
  fi
  xcrun xctrace list devices 2>/dev/null | awk '/iPhone/ && $0 !~ /Simulator/ {print; exit}'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      PROJECT_ROOT="${2:-}"
      shift 2
      ;;
    --workspace)
      WORKSPACE="${2:-}"
      shift 2
      ;;
    --scheme)
      SCHEME="${2:-}"
      shift 2
      ;;
    --xcodeproj)
      XCODEPROJ="${2:-}"
      shift 2
      ;;
    --app-identifier)
      APP_IDENTIFIER="${2:-}"
      shift 2
      ;;
    --no-auto-bootstrap)
      AUTO_BOOTSTRAP_FASTLANE="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "未知参数: $1"
      ;;
  esac
done

[[ -d "${PROJECT_ROOT}" ]] || fail "project root 不存在: ${PROJECT_ROOT}"
if [[ ! -f "${PROJECT_ROOT}/fastlane/Fastfile" ]]; then
  if [[ "${AUTO_BOOTSTRAP_FASTLANE}" == "true" ]]; then
    echo "[INFO] 检测到缺少 fastlane/Fastfile，开始自动初始化 fastlane..."
    bootstrap_cmd=(bash "${SCRIPT_DIR}/bootstrap_fastlane.sh" --project-root "${PROJECT_ROOT}")
    [[ -n "${WORKSPACE}" ]] && bootstrap_cmd+=(--workspace "${WORKSPACE}")
    [[ -n "${XCODEPROJ}" ]] && bootstrap_cmd+=(--xcodeproj "${XCODEPROJ}")
    [[ -n "${SCHEME}" ]] && bootstrap_cmd+=(--scheme "${SCHEME}")
    [[ -n "${APP_IDENTIFIER}" ]] && bootstrap_cmd+=(--app-identifier "${APP_IDENTIFIER}")
    "${bootstrap_cmd[@]}"
    echo "[INFO] fastlane 初始化完成，继续预检。"
  else
    fail "缺少 fastlane/Fastfile: ${PROJECT_ROOT}"
  fi
fi

FASTFILE="${PROJECT_ROOT}/fastlane/Fastfile"
grep -q "lane :internal_release" "${FASTFILE}" || fail "Fastfile 中缺少 lane :internal_release"
grep -q "lane :assign_internal_tester" "${FASTFILE}" || fail "Fastfile 中缺少 lane :assign_internal_tester"

WORKSPACE="$(detect_workspace)"
XCODEPROJ="$(detect_xcodeproj)"
scheme_preferred=""
if [[ -n "${WORKSPACE}" ]]; then
  scheme_preferred="${WORKSPACE%.xcworkspace}"
elif [[ -n "${XCODEPROJ}" ]]; then
  scheme_preferred="${XCODEPROJ%.xcodeproj}"
fi
SCHEME="$(detect_scheme "${WORKSPACE}" "${scheme_preferred}")"
APP_IDENTIFIER="$(detect_app_identifier)"

echo "== Preflight Scan =="
echo "Project Root        : ${PROJECT_ROOT}"
echo "Workspace           : ${WORKSPACE:-<missing>}"
echo "Scheme              : ${SCHEME:-<missing>}"
echo "Xcodeproj           : ${XCODEPROJ:-<missing>}"
echo "App Identifier      : ${APP_IDENTIFIER:-<missing>}"
echo "Internal Group      : ${INTERNAL_GROUP_NAME}"

echo
echo "== Toolchain Check =="
for tool in xcodebuild ruby fastlane git; do
  if has_cmd "${tool}"; then
    echo "[OK] ${tool}: $(command -v "${tool}")"
  else
    echo "[WARN] ${tool}: not found"
  fi
done

if [[ -f "${PROJECT_ROOT}/Gemfile" ]]; then
  if has_cmd bundle; then
    echo "[OK] bundle: $(command -v bundle)"
  else
    echo "[WARN] Gemfile 存在但 bundle 不可用"
  fi
fi

echo
echo "== Connected Device Check =="
iphone_line="$(detect_connected_iphone || true)"
if [[ -n "${iphone_line}" ]]; then
  echo "[OK] 检测到已连接 iPhone: ${iphone_line}"
else
  echo "[INFO] 未检测到已连接 iPhone（可继续走 TestFlight 远程分发）"
fi

echo
echo "[DONE] 预检完成。"
