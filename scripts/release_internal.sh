#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_ROOT="$PWD"
WORKSPACE=""
SCHEME=""
XCODEPROJ_PATH=""
APP_IDENTIFIER=""
GROUP_NAME="${INTERNAL_GROUP_NAME:-Agent Internal Testing}"
TESTERS="${TESTER_EMAILS:-}"
CHANGE_TYPE="patch"
MARKETING_VERSION=""
CONFIRM_VERSION=""
SKIP_BUILD="false"
DRY_RUN="false"
AUTO_VERIFY="true"
INSTALL_CONNECTED_FIRST="false"
BOOTSTRAP_FASTLANE="true"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/release_internal.sh [options]

Options:
  --project-root <path>            项目根目录（默认当前目录）
  --workspace <name>               workspace（例如 ReadFast.xcworkspace）
  --scheme <name>                  scheme（例如 ReadFast）
  --xcodeproj <name>               xcodeproj（例如 ReadFast.xcodeproj）
  --app-identifier <bundle>        App Identifier
  --group <name>                   Internal Group（默认 Agent Internal Testing）
  --testers <emails>               tester 邮箱，逗号分隔
  --marketing-version <x.y.z>      明确指定版本号
  --change-type <patch|minor|major> 未指定版本时用于建议版本（默认 patch）
  --confirm-version <x.y.z>        确认采用某个版本（用于“先建议后确认”）
  --skip-build <true|false>        是否跳过构建（默认 false）
  --install-connected-first        先尝试安装到已连接 iPhone（需 ios-deploy）
  --no-bootstrap-fastlane          缺少 fastlane 时不自动初始化（默认自动）
  --dry-run                        仅输出计划，不执行发布
  --no-verify                      发布后不执行 verify_distribution
  -h, --help                       显示帮助
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
  [[ -n "${WORKSPACE}" ]] && { echo "${WORKSPACE}"; return 0; }
  local first
  first="$(find "${PROJECT_ROOT}" -maxdepth 1 -type d -name "*.xcworkspace" | head -n1 || true)"
  [[ -n "${first}" ]] && basename "${first}"
}

detect_xcodeproj() {
  [[ -n "${XCODEPROJ_PATH}" ]] && { echo "${XCODEPROJ_PATH}"; return 0; }
  local first
  first="$(find "${PROJECT_ROOT}" -maxdepth 1 -type d -name "*.xcodeproj" | head -n1 || true)"
  [[ -n "${first}" ]] && basename "${first}"
}

detect_scheme() {
  [[ -n "${SCHEME}" ]] && { echo "${SCHEME}"; return 0; }
  local ws="$1"
  local preferred="$2"
  [[ -z "${ws}" ]] && return 0
  local raw
  raw="$(xcodebuild -list -json -workspace "${PROJECT_ROOT}/${ws}" 2>/dev/null || true)"
  [[ -z "${raw}" ]] && return 0
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
  [[ -n "${APP_IDENTIFIER}" ]] && { echo "${APP_IDENTIFIER}"; return 0; }
  local appfile="${PROJECT_ROOT}/fastlane/Appfile"
  [[ -f "${appfile}" ]] || return 0
  sed -n 's/^[[:space:]]*app_identifier[[:space:]]*"\(.*\)".*/\1/p' "${appfile}" | head -n1
}

detect_connected_iphone_udid() {
  if ! has_cmd xcrun; then
    return 0
  fi
  xcrun xctrace list devices 2>/dev/null \
    | awk -F'[()]' '/iPhone/ && $0 !~ /Simulator/ {print $4; exit}'
}

install_on_connected_iphone() {
  local ws="$1"
  local sc="$2"
  local udid="$3"
  [[ -n "${udid}" ]] || fail "未检测到可用 iPhone UDID，无法执行本地安装。"
  has_cmd ios-deploy || fail "缺少 ios-deploy，请先安装（brew install ios-deploy）或移除 --install-connected-first。"

  echo "[RUN] 构建 Debug 并安装到已连接 iPhone: ${udid}"
  (
    cd "${PROJECT_ROOT}"
    xcodebuild \
      -workspace "${ws}" \
      -scheme "${sc}" \
      -destination "id=${udid}" \
      -configuration Debug \
      -allowProvisioningUpdates \
      build >/dev/null

    local settings target_build_dir wrapper_name app_path
    settings="$(xcodebuild \
      -workspace "${ws}" \
      -scheme "${sc}" \
      -destination "id=${udid}" \
      -configuration Debug \
      -showBuildSettings 2>/dev/null || true)"
    target_build_dir="$(echo "${settings}" | awk -F' = ' '/ TARGET_BUILD_DIR = / {print $2; exit}')"
    wrapper_name="$(echo "${settings}" | awk -F' = ' '/ WRAPPER_NAME = / {print $2; exit}')"
    app_path="${target_build_dir}/${wrapper_name}"
    [[ -d "${app_path}" ]] || fail "未找到构建产物 .app：${app_path}"
    ios-deploy --id "${udid}" --bundle "${app_path}" --justlaunch >/dev/null
  )
  echo "[OK] 已完成已连接 iPhone 本地安装验证。"
}

read_current_marketing_version() {
  local ws="$1"
  local sc="$2"
  local version=""

  if [[ -n "${ws}" && -n "${sc}" ]] && has_cmd xcodebuild; then
    version="$(xcodebuild -workspace "${PROJECT_ROOT}/${ws}" -scheme "${sc}" -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/MARKETING_VERSION = / {print $2; exit}' || true)"
  fi
  if [[ -z "${version}" ]] && has_cmd xcrun; then
    version="$(cd "${PROJECT_ROOT}" && xcrun agvtool what-marketing-version -terse1 2>/dev/null | head -n1 || true)"
  fi
  echo "${version}"
}

ensure_semver() {
  local v="$1"
  [[ "${v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

next_version() {
  local current="$1"
  local mode="$2"
  IFS='.' read -r major minor patch <<<"${current}"
  case "${mode}" in
    patch)
      patch=$((patch + 1))
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    *)
      fail "不支持的 change-type: ${mode}"
      ;;
  esac
  echo "${major}.${minor}.${patch}"
}

resolve_fastlane_cmd() {
  if [[ -f "${PROJECT_ROOT}/Gemfile" ]] && has_cmd bundle; then
    echo "bundle exec fastlane"
  else
    echo "fastlane"
  fi
}

ensure_fastlane_ready() {
  if [[ -f "${PROJECT_ROOT}/fastlane/Fastfile" ]]; then
    return 0
  fi
  if [[ "${BOOTSTRAP_FASTLANE}" != "true" ]]; then
    fail "缺少 fastlane/Fastfile，且已禁用自动初始化。"
  fi
  echo "[INFO] 检测到缺少 fastlane/Fastfile，开始自动初始化..."
  bootstrap_cmd=(bash "${SCRIPT_DIR}/bootstrap_fastlane.sh" --project-root "${PROJECT_ROOT}")
  [[ -n "${WORKSPACE}" ]] && bootstrap_cmd+=(--workspace "${WORKSPACE}")
  [[ -n "${XCODEPROJ_PATH}" ]] && bootstrap_cmd+=(--xcodeproj "${XCODEPROJ_PATH}")
  [[ -n "${SCHEME}" ]] && bootstrap_cmd+=(--scheme "${SCHEME}")
  [[ -n "${APP_IDENTIFIER}" ]] && bootstrap_cmd+=(--app-identifier "${APP_IDENTIFIER}")
  "${bootstrap_cmd[@]}"
  [[ -f "${PROJECT_ROOT}/fastlane/Fastfile" ]] || fail "自动初始化 fastlane 失败。"
}

update_marketing_version() {
  local target="$1"
  local current="$2"
  [[ -z "${target}" ]] && return 0
  if [[ "${target}" == "${current}" ]]; then
    echo "[INFO] MARKETING_VERSION 已是 ${target}，跳过更新。"
    return 0
  fi

  echo "[INFO] 更新 MARKETING_VERSION: ${current:-<unknown>} -> ${target}"
  (
    cd "${PROJECT_ROOT}"
    if has_cmd xcrun && xcrun agvtool new-marketing-version "${target}" >/dev/null; then
      echo "[OK] agvtool 已更新版本到 ${target}"
      return 0
    fi
    echo "[WARN] agvtool 更新失败，尝试 fastlane increment_version_number"
    local fl fl_parts=()
    fl="$(resolve_fastlane_cmd)"
    read -r -a fl_parts <<<"${fl}"
    "${fl_parts[@]}" run increment_version_number version_number:"${target}" >/dev/null
    echo "[OK] fastlane increment_version_number 已更新版本到 ${target}"
  )
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="${2:-}"; shift 2 ;;
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --scheme) SCHEME="${2:-}"; shift 2 ;;
    --xcodeproj) XCODEPROJ_PATH="${2:-}"; shift 2 ;;
    --app-identifier) APP_IDENTIFIER="${2:-}"; shift 2 ;;
    --group) GROUP_NAME="${2:-}"; shift 2 ;;
    --testers) TESTERS="${2:-}"; shift 2 ;;
    --marketing-version) MARKETING_VERSION="${2:-}"; shift 2 ;;
    --change-type) CHANGE_TYPE="${2:-}"; shift 2 ;;
    --confirm-version) CONFIRM_VERSION="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD="${2:-}"; shift 2 ;;
    --install-connected-first) INSTALL_CONNECTED_FIRST="true"; shift ;;
    --no-bootstrap-fastlane) BOOTSTRAP_FASTLANE="false"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --no-verify) AUTO_VERIFY="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "未知参数: $1" ;;
  esac
done

PROJECT_ROOT="$(cd "${PROJECT_ROOT}" && pwd)"
[[ -d "${PROJECT_ROOT}" ]] || fail "project root 不存在: ${PROJECT_ROOT}"

ensure_fastlane_ready

# 1) 先预检
preflight_cmd=(bash "${SCRIPT_DIR}/preflight_scan.sh" --project-root "${PROJECT_ROOT}")
[[ -n "${WORKSPACE}" ]] && preflight_cmd+=(--workspace "${WORKSPACE}")
[[ -n "${SCHEME}" ]] && preflight_cmd+=(--scheme "${SCHEME}")
[[ -n "${XCODEPROJ_PATH}" ]] && preflight_cmd+=(--xcodeproj "${XCODEPROJ_PATH}")
[[ -n "${APP_IDENTIFIER}" ]] && preflight_cmd+=(--app-identifier "${APP_IDENTIFIER}")
"${preflight_cmd[@]}"

# 2) 资料收敛：本地 + memory -> export
set +e
resolved_exports="$(python3 "${SCRIPT_DIR}/resolve_materials.py" --project-root "${PROJECT_ROOT}" --print-export --write-memory)"
resolve_rc=$?
set -e
if [[ -n "${resolved_exports}" ]]; then
  # shellcheck disable=SC1090,SC2086
  eval "${resolved_exports}"
fi

if [[ ${resolve_rc} -ne 0 ]]; then
  fail "资料未齐全。请补齐 ASC_ISSUER_ID 与 ASC_KEY_FILEPATH；ASC_KEY_ID 可由 AuthKey_<KEY_ID>.p8 自动提取，若文件名不符合需手动提供。"
fi

# 3) 解析最终参数
WORKSPACE="$(detect_workspace)"
XCODEPROJ_PATH="$(detect_xcodeproj)"
scheme_preferred=""
if [[ -n "${WORKSPACE}" ]]; then
  scheme_preferred="${WORKSPACE%.xcworkspace}"
elif [[ -n "${XCODEPROJ_PATH}" ]]; then
  scheme_preferred="${XCODEPROJ_PATH%.xcodeproj}"
fi
SCHEME="$(detect_scheme "${WORKSPACE}" "${scheme_preferred}")"
APP_IDENTIFIER="$(detect_app_identifier)"

GROUP_NAME="${GROUP_NAME:-${INTERNAL_GROUP_NAME:-Agent Internal Testing}}"
TESTERS="${TESTERS:-${TESTER_EMAILS:-}}"
[[ -n "${WORKSPACE}" ]] || fail "无法自动发现 workspace，请通过 --workspace 指定"
[[ -n "${SCHEME}" ]] || fail "无法自动发现 scheme，请通过 --scheme 指定"
[[ -n "${APP_IDENTIFIER}" ]] || fail "无法自动发现 app identifier，请通过 --app-identifier 指定"
[[ -n "${ASC_KEY_ID:-}" ]] || fail "缺少 ASC_KEY_ID"
[[ -n "${ASC_ISSUER_ID:-}" ]] || fail "缺少 ASC_ISSUER_ID"
[[ -n "${ASC_KEY_FILEPATH:-}" ]] || fail "缺少 ASC_KEY_FILEPATH"
[[ -n "${TESTERS}" ]] || fail "缺少 tester 邮箱，请传入 --testers 或设置 TESTER_EMAILS"

current_version="$(read_current_marketing_version "${WORKSPACE}" "${SCHEME}")"
[[ -z "${current_version}" || "$(ensure_semver "${current_version}" && echo ok || true)" == "ok" ]] \
  || fail "当前 MARKETING_VERSION 不是三段式 semver: ${current_version}"

if [[ -z "${MARKETING_VERSION}" ]]; then
  [[ -n "${current_version}" ]] || fail "未指定 --marketing-version 且无法读取当前版本。"
  suggested_version="$(next_version "${current_version}" "${CHANGE_TYPE}")"
  if [[ -z "${CONFIRM_VERSION}" ]]; then
    echo "[ACTION REQUIRED] 未指定 MARKETING_VERSION。"
    echo "[INFO] 当前版本: ${current_version}"
    echo "[INFO] 按 ${CHANGE_TYPE} 建议版本: ${suggested_version}"
    echo "[INFO] 请确认后重试，例如："
    echo "  bash scripts/release_internal.sh --project-root \"${PROJECT_ROOT}\" --confirm-version \"${suggested_version}\" --change-type \"${CHANGE_TYPE}\""
    exit 20
  fi
  MARKETING_VERSION="${CONFIRM_VERSION}"
  if [[ "${MARKETING_VERSION}" != "${suggested_version}" ]]; then
    echo "[WARN] 你确认的版本(${MARKETING_VERSION})与建议版本(${suggested_version})不同，将按确认值执行。"
  fi
fi

ensure_semver "${MARKETING_VERSION}" || fail "MARKETING_VERSION 必须为 x.y.z 格式，当前: ${MARKETING_VERSION}"

fastlane_cmd="$(resolve_fastlane_cmd)"
read -r -a fastlane_parts <<<"${fastlane_cmd}"
release_cmd=("${fastlane_parts[@]}" ios internal_release)
lane_args=(
  "group:${GROUP_NAME}"
  "workspace:${WORKSPACE}"
  "scheme:${SCHEME}"
  "app_identifier:${APP_IDENTIFIER}"
  "testers:${TESTERS}"
  "skip_build:${SKIP_BUILD}"
)

echo
echo "== Release Plan =="
echo "Project Root        : ${PROJECT_ROOT}"
echo "Workspace           : ${WORKSPACE}"
echo "Scheme              : ${SCHEME}"
echo "App Identifier      : ${APP_IDENTIFIER}"
echo "Internal Group      : ${GROUP_NAME}"
echo "Testers             : ${TESTERS}"
echo "Current Version     : ${current_version:-<unknown>}"
echo "Target Version      : ${MARKETING_VERSION}"
echo "Skip Build          : ${SKIP_BUILD}"
echo "Install To iPhone   : ${INSTALL_CONNECTED_FIRST}"
echo "Fastlane Command    : ${release_cmd[*]} ${lane_args[*]}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo
  echo "[DRY-RUN] 未执行版本更新和发布。"
  exit 0
fi

if [[ "${INSTALL_CONNECTED_FIRST}" == "true" ]]; then
  connected_udid="$(detect_connected_iphone_udid || true)"
  install_on_connected_iphone "${WORKSPACE}" "${SCHEME}" "${connected_udid}"
fi

update_marketing_version "${MARKETING_VERSION}" "${current_version}"

echo
echo "[RUN] 执行 internal_release..."
(
  cd "${PROJECT_ROOT}"
  export INTERNAL_GROUP_NAME="${GROUP_NAME}"
  export TESTER_EMAILS="${TESTERS}"
  export IOS_WORKSPACE="${WORKSPACE}"
  export IOS_SCHEME="${SCHEME}"
  export IOS_APP_IDENTIFIER="${APP_IDENTIFIER}"
  "${release_cmd[@]}" "${lane_args[@]}"
)

if [[ "${AUTO_VERIFY}" == "true" ]]; then
  echo
  echo "[RUN] 执行发布后校验..."
  python3 "${SCRIPT_DIR}/verify_distribution.py" \
    --project-root "${PROJECT_ROOT}" \
    --group "${GROUP_NAME}" \
    --testers "${TESTERS}" \
    --app-identifier "${APP_IDENTIFIER}"
fi

echo
echo "[DONE] Internal 发布流程完成。"
