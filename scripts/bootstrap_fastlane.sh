#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$PWD"
WORKSPACE=""
SCHEME=""
XCODEPROJ=""
APP_IDENTIFIER=""
APPLE_ID=""
TEAM_ID=""
FORCE="false"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/bootstrap_fastlane.sh [options]

Options:
  --project-root <path>            项目根目录（默认当前目录）
  --workspace <name>               workspace（如 ReadFast.xcworkspace）
  --xcodeproj <name>               xcodeproj（如 ReadFast.xcodeproj）
  --scheme <name>                  scheme（如 ReadFast）
  --app-identifier <bundle>        bundle id（如 com.example.app）
  --apple-id <email>               Apple ID 默认值（写入 Appfile fallback）
  --team-id <id>                   Team ID（写入 Appfile）
  --force                          覆盖已有 Fastfile/Appfile
  --dry-run                        仅打印结果，不写入文件
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
  [[ -n "${XCODEPROJ}" ]] && { echo "${XCODEPROJ}"; return 0; }
  local first
  first="$(find "${PROJECT_ROOT}" -maxdepth 1 -type d -name "*.xcodeproj" | head -n1 || true)"
  [[ -n "${first}" ]] && basename "${first}"
}

detect_scheme() {
  [[ -n "${SCHEME}" ]] && { echo "${SCHEME}"; return 0; }
  local ws="$1"
  local proj="$2"
  local preferred="$3"
  [[ -z "${ws}" && -z "${proj}" ]] && return 0
  has_cmd xcodebuild || return 0
  has_cmd python3 || return 0
  local raw=""
  if [[ -n "${ws}" ]]; then
    raw="$(xcodebuild -list -json -workspace "${PROJECT_ROOT}/${ws}" 2>/dev/null || true)"
  else
    raw="$(xcodebuild -list -json -project "${PROJECT_ROOT}/${proj}" 2>/dev/null || true)"
  fi
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
holder = data.get("workspace") or data.get("project") or {}
schemes = holder.get("schemes") or []
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

build_setting() {
  local ws="$1"
  local proj="$2"
  local sc="$3"
  local key="$4"
  [[ -z "${sc}" ]] && return 0
  has_cmd xcodebuild || return 0
  local cmd=(xcodebuild -showBuildSettings -scheme "${sc}")
  if [[ -n "${ws}" ]]; then
    cmd+=(-workspace "${PROJECT_ROOT}/${ws}")
  elif [[ -n "${proj}" ]]; then
    cmd+=(-project "${PROJECT_ROOT}/${proj}")
  else
    return 0
  fi
  "${cmd[@]}" 2>/dev/null | awk -F' = ' -v key="${key}" '$1 ~ " "key"$" {print $2; exit}'
}

detect_bundle_id() {
  [[ -n "${APP_IDENTIFIER}" ]] && { echo "${APP_IDENTIFIER}"; return 0; }
  local ws="$1"
  local proj="$2"
  local sc="$3"
  local from_build
  from_build="$(build_setting "${ws}" "${proj}" "${sc}" "PRODUCT_BUNDLE_IDENTIFIER" || true)"
  if [[ -n "${from_build}" ]]; then
    echo "${from_build}"
    return 0
  fi
  local appfile="${PROJECT_ROOT}/fastlane/Appfile"
  if [[ -f "${appfile}" ]]; then
    sed -n 's/^[[:space:]]*app_identifier[[:space:]]*"\(.*\)".*/\1/p' "${appfile}" | head -n1
  fi
}

detect_team_id() {
  [[ -n "${TEAM_ID}" ]] && { echo "${TEAM_ID}"; return 0; }
  local ws="$1"
  local proj="$2"
  local sc="$3"
  local from_build
  from_build="$(build_setting "${ws}" "${proj}" "${sc}" "DEVELOPMENT_TEAM" || true)"
  if [[ -n "${from_build}" ]]; then
    echo "${from_build}"
    return 0
  fi
  local appfile="${PROJECT_ROOT}/fastlane/Appfile"
  if [[ -f "${appfile}" ]]; then
    sed -n 's/^[[:space:]]*team_id[[:space:]]*"\(.*\)".*/\1/p' "${appfile}" | head -n1
  fi
}

detect_apple_id() {
  [[ -n "${APPLE_ID}" ]] && { echo "${APPLE_ID}"; return 0; }
  local appfile="${PROJECT_ROOT}/fastlane/Appfile"
  if [[ -f "${appfile}" ]]; then
    local val
    val="$(sed -n 's/^[[:space:]]*apple_id[[:space:]]*"\(.*\)".*/\1/p' "${appfile}" | head -n1)"
    if [[ -n "${val}" ]]; then
      echo "${val}"
      return 0
    fi
    val="$(sed -n 's/^[[:space:]]*apple_id[[:space:]]*ENV\.fetch("APPLE_ID",[[:space:]]*"\(.*\)").*/\1/p' "${appfile}" | head -n1)"
    if [[ -n "${val}" ]]; then
      echo "${val}"
      return 0
    fi
  fi
  git -C "${PROJECT_ROOT}" config user.email 2>/dev/null || true
}

write_appfile() {
  local app_id="$1"
  local apple="$2"
  local team="$3"
  local appfile_path="${PROJECT_ROOT}/fastlane/Appfile"
  cat > "${appfile_path}" <<EOF
app_identifier "${app_id}"
apple_id ENV.fetch("APPLE_ID", "${apple}")
team_id "${team}"
EOF
}

write_fastfile() {
  local ws="$1"
  local sc="$2"
  local app_id="$3"
  local xcodeproj="$4"
  local fastfile_path="${PROJECT_ROOT}/fastlane/Fastfile"
  cat > "${fastfile_path}" <<EOF
default_platform(:ios)

require "shellwords"

def parse_tester_emails(raw_emails)
  raw_emails.to_s
    .split(/[,\s;]+/)
    .map(&:strip)
    .reject(&:empty?)
    .uniq
end

def default_tester_email
  email = \`git config user.email\`.to_s.strip
  return nil if email.empty?
  email
rescue StandardError
  nil
end

def resolved_api_key
  key_id = ENV["ASC_KEY_ID"]
  issuer_id = ENV["ASC_ISSUER_ID"]
  key_filepath = ENV["ASC_KEY_FILEPATH"]
  key_content = ENV["ASC_KEY_CONTENT"]
  return nil if key_id.to_s.empty? || issuer_id.to_s.empty?
  return nil if key_filepath.to_s.empty? && key_content.to_s.empty?
  app_store_connect_api_key(
    key_id: key_id,
    issuer_id: issuer_id,
    key_filepath: (key_filepath unless key_filepath.to_s.empty?),
    key_content: (key_content unless key_content.to_s.empty?),
    is_key_content_base64: ENV["ASC_KEY_IS_BASE64"] == "true",
    duration: 1200,
    in_house: false
  )
end

def connect_api_login!
  key_id = ENV["ASC_KEY_ID"]
  issuer_id = ENV["ASC_ISSUER_ID"]
  key_filepath = ENV["ASC_KEY_FILEPATH"]
  key_content = ENV["ASC_KEY_CONTENT"]
  UI.user_error!("缺少 ASC_KEY_ID") if key_id.to_s.empty?
  UI.user_error!("缺少 ASC_ISSUER_ID") if issuer_id.to_s.empty?
  UI.user_error!("缺少 ASC_KEY_FILEPATH 或 ASC_KEY_CONTENT") if key_filepath.to_s.empty? && key_content.to_s.empty?
  token = Spaceship::ConnectAPI::Token.create(
    key_id: key_id,
    issuer_id: issuer_id,
    filepath: (key_filepath unless key_filepath.to_s.empty?),
    key: (key_content unless key_content.to_s.empty?),
    is_key_content_base64: ENV["ASC_KEY_IS_BASE64"] == "true",
    duration: 1200,
    in_house: false
  )
  Spaceship::ConnectAPI.token = token
end

def find_app_specific_beta_tester(app:, email:)
  candidates = Spaceship::ConnectAPI::BetaTester.all(filter: { email: email }, includes: "apps")
  candidates.find { |tester| (tester.apps || []).any? { |related_app| related_app.id == app.id } }
end

def ensure_latest_build_ready_for_internal_testing!(app_identifier:, max_polls: 20, poll_interval: 6)
  connect_api_login!
  app = Spaceship::ConnectAPI::App.find(app_identifier)
  UI.user_error!("未找到 App: #{app_identifier}") unless app
  latest_build = app.get_builds(sort: "-uploadedDate", limit: 1, includes: "app,buildBetaDetail,preReleaseVersion,buildBundles").first
  UI.user_error!("未找到可用 build，请先上传构建。") unless latest_build
  build_detail = latest_build.build_beta_detail
  if build_detail&.internal_build_state == "MISSING_EXPORT_COMPLIANCE" || build_detail&.external_build_state == "MISSING_EXPORT_COMPLIANCE"
    UI.message("检测到导出合规缺失，自动设置 usesNonExemptEncryption=false（build: #{latest_build.version}）")
    latest_build.update(attributes: { uses_non_exempt_encryption: false })
  end
  max_polls.times do |idx|
    refreshed = Spaceship::ConnectAPI::Build.get(build_id: latest_build.id, includes: "app,buildBetaDetail,preReleaseVersion,buildBundles")
    internal_state = refreshed.build_beta_detail&.internal_build_state
    external_state = refreshed.build_beta_detail&.external_build_state
    UI.message("build 状态轮询[#{idx + 1}/#{max_polls}] internal=#{internal_state} external=#{external_state}")
    return refreshed if ["READY_FOR_BETA_TESTING", "IN_BETA_TESTING"].include?(internal_state)
    sleep poll_interval
  end
  UI.user_error!("build 尚未进入 Internal Testing 可用状态，请稍后重试。")
end

def ensure_testers_and_build_for_group!(app_identifier:, group_name:, tester_emails:)
  connect_api_login!
  app = Spaceship::ConnectAPI::App.find(app_identifier)
  UI.user_error!("未找到 App: #{app_identifier}") unless app
  groups = app.get_beta_groups(limit: 200)
  group = groups.find { |g| g.name == group_name }
  unless group
    group = app.create_beta_group(
      group_name: group_name,
      is_internal_group: true,
      has_access_to_all_builds: true,
      public_link_enabled: nil,
      public_link_limit: nil,
      public_link_limit_enabled: nil
    )
    UI.message("已创建 Internal Group: #{group_name}")
  end
  initial_group_testers_resp = Spaceship::ConnectAPI.get_beta_testers(filter: { betaGroups: group.id }, limit: 200).all_pages
  initial_group_testers = initial_group_testers_resp.flat_map(&:to_models)
  initial_group_emails = initial_group_testers.map { |t| t.email.to_s.downcase }
  tester_emails.each do |email|
    email_downcase = email.to_s.downcase
    if initial_group_emails.include?(email_downcase)
      UI.message("tester 已在 Internal Group，跳过分配: #{email}")
      next
    end
    existing_tester = find_app_specific_beta_tester(app: app, email: email)
    if existing_tester
      begin
        group.add_beta_testers(beta_tester_ids: [existing_tester.id])
      rescue => e
        msg = e.message.to_s
        raise unless msg.include?("already exists") || msg.include?("already associated") || msg.include?("Tester(s) cannot be assigned")
        UI.important("ASC 未允许 API 自动分配 internal tester: #{email}，请在 App Store Connect 页面手动加入该组。") if msg.include?("Tester(s) cannot be assigned")
      end
    else
      begin
        Spaceship::ConnectAPI.post_beta_tester_assignment(
          beta_group_ids: [group.id],
          attributes: { email: email, firstName: "Internal", lastName: "Tester" }
        )
      rescue => e
        msg = e.message.to_s
        raise unless msg.include?("Tester(s) cannot be assigned")
        UI.important("ASC 未允许 API 自动分配 internal tester: #{email}，请在 App Store Connect 页面手动加入该组。")
      end
    end
  end
  group_testers_resp = Spaceship::ConnectAPI.get_beta_testers(filter: { betaGroups: group.id }, limit: 200).all_pages
  group_testers = group_testers_resp.flat_map(&:to_models)
  group_emails = group_testers.map { |t| t.email.to_s.downcase }
  missing_emails = tester_emails.map { |e| e.to_s.downcase }.reject { |email| group_emails.include?(email) }
  latest_build = app.get_builds(sort: "-uploadedDate", limit: 1).first
  if latest_build
    current_group_build_ids = group.fetch_builds.map(&:id)
    unless current_group_build_ids.include?(latest_build.id)
      begin
        latest_build.add_beta_groups(beta_groups: [group])
      rescue => e
        msg = e.message.to_s
        raise unless msg.include?("Cannot add internal group to a build")
      end
    end
  end
  { missing_emails: missing_emails }
end

platform :ios do
  desc "不构建不上传：仅将 tester 加入 Internal Group，并分发现有最新 build"
  lane :assign_internal_tester do |options|
    app_identifier = options[:app_identifier] || ENV.fetch("IOS_APP_IDENTIFIER", "${app_id}")
    group_name = options[:group] || ENV.fetch("INTERNAL_GROUP_NAME", "Agent Internal Testing")
    tester_emails = parse_tester_emails(options[:testers] || ENV["TESTER_EMAILS"])
    if tester_emails.empty?
      fallback_email = default_tester_email
      tester_emails = [fallback_email] if fallback_email
    end
    UI.user_error!("未获取到 tester 邮箱。请设置 TESTER_EMAILS=you@example.com") if tester_emails.empty?
    result = ensure_testers_and_build_for_group!(
      app_identifier: app_identifier,
      group_name: group_name,
      tester_emails: tester_emails
    )
    if result[:missing_emails].any?
      UI.user_error!("仍有 tester 未加入 Internal Group：#{result[:missing_emails].join(', ')}。请先在 App Store Connect 的 Users and Access 确认内部测试权限后重试。")
    end
    UI.success("tester 已加入 Internal Group，并已分发现有 build。")
  end

  desc "构建 -> 上传 TestFlight -> 分发 Internal Group -> 确保 tester 在组内"
  lane :internal_release do |options|
    scheme = options[:scheme] || ENV.fetch("IOS_SCHEME", "${sc}")
    workspace = options[:workspace] || ENV.fetch("IOS_WORKSPACE", "${ws}")
    app_identifier = options[:app_identifier] || ENV.fetch("IOS_APP_IDENTIFIER", "${app_id}")
    group_name = options[:group] || ENV.fetch("INTERNAL_GROUP_NAME", "Agent Internal Testing")
    skip_build = (options[:skip_build].to_s == "true") || (ENV["SKIP_BUILD"] == "true")
    auto_increment_build = if options.key?(:auto_increment_build)
      options[:auto_increment_build].to_s == "true"
    else
      ENV.fetch("AUTO_INCREMENT_BUILD", "true") == "true"
    end
    tester_emails = parse_tester_emails(options[:testers] || ENV["TESTER_EMAILS"])
    if tester_emails.empty?
      fallback_email = default_tester_email
      tester_emails = [fallback_email] if fallback_email
    end
    UI.user_error!("未获取到 tester 邮箱。请设置 TESTER_EMAILS=you@example.com") if tester_emails.empty?
    api_key = resolved_api_key
    auth_options = {}
    auth_options[:api_key] = api_key if api_key
    unless skip_build
      if auto_increment_build
        new_build_number = Time.now.strftime("%Y%m%d%H%M")
        increment_build_number(xcodeproj: "${xcodeproj}", build_number: new_build_number)
      end
      build_app(
        workspace: workspace,
        scheme: scheme,
        clean: true,
        export_method: "app-store",
        output_directory: "build/fastlane",
        output_name: "#{scheme}.ipa"
      )
    end
    ipa_path = options[:ipa] || ENV["IPA_PATH"] || lane_context[SharedValues::IPA_OUTPUT_PATH]
    upload_options = {
      app_identifier: app_identifier,
      skip_waiting_for_build_processing: false,
      distribute_external: false,
      skip_submission: true,
      notify_external_testers: false
    }.merge(auth_options)
    upload_options[:ipa] = ipa_path if ipa_path && File.exist?(ipa_path)
    upload_to_testflight(**upload_options)
    ensure_latest_build_ready_for_internal_testing!(app_identifier: app_identifier)
    result = ensure_testers_and_build_for_group!(
      app_identifier: app_identifier,
      group_name: group_name,
      tester_emails: tester_emails
    )
    if result[:missing_emails].any?
      UI.user_error!("上传成功，但以下 tester 尚未加入 Internal Group：#{result[:missing_emails].join(', ')}。请先在 App Store Connect 的 Users and Access 完成内部测试权限。")
    end
    UI.success("Internal TestFlight 发布完成，已尝试将 tester 加入 group。")
  end
end
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="${2:-}"; shift 2 ;;
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --xcodeproj) XCODEPROJ="${2:-}"; shift 2 ;;
    --scheme) SCHEME="${2:-}"; shift 2 ;;
    --app-identifier) APP_IDENTIFIER="${2:-}"; shift 2 ;;
    --apple-id) APPLE_ID="${2:-}"; shift 2 ;;
    --team-id) TEAM_ID="${2:-}"; shift 2 ;;
    --force) FORCE="true"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "未知参数: $1" ;;
  esac
done

PROJECT_ROOT="$(cd "${PROJECT_ROOT}" && pwd)"
[[ -d "${PROJECT_ROOT}" ]] || fail "project root 不存在: ${PROJECT_ROOT}"

WORKSPACE="$(detect_workspace)"
XCODEPROJ="$(detect_xcodeproj)"
preferred=""
if [[ -n "${WORKSPACE}" ]]; then
  preferred="${WORKSPACE%.xcworkspace}"
elif [[ -n "${XCODEPROJ}" ]]; then
  preferred="${XCODEPROJ%.xcodeproj}"
fi
SCHEME="$(detect_scheme "${WORKSPACE}" "${XCODEPROJ}" "${preferred}")"
APP_IDENTIFIER="$(detect_bundle_id "${WORKSPACE}" "${XCODEPROJ}" "${SCHEME}")"
TEAM_ID="$(detect_team_id "${WORKSPACE}" "${XCODEPROJ}" "${SCHEME}")"
APPLE_ID="$(detect_apple_id)"

[[ -n "${WORKSPACE}" || -n "${XCODEPROJ}" ]] || fail "未发现 .xcworkspace/.xcodeproj"
[[ -n "${SCHEME}" ]] || fail "无法自动识别 scheme，请使用 --scheme 指定"
[[ -n "${APP_IDENTIFIER}" ]] || fail "无法自动识别 bundle id，请使用 --app-identifier 指定"
[[ -n "${XCODEPROJ}" ]] || fail "无法自动识别 xcodeproj，请使用 --xcodeproj 指定"
[[ -n "${TEAM_ID}" ]] || TEAM_ID="YOUR_TEAM_ID"
[[ -n "${APPLE_ID}" ]] || APPLE_ID="your-apple-id@example.com"

fastlane_dir="${PROJECT_ROOT}/fastlane"
fastfile_path="${fastlane_dir}/Fastfile"
appfile_path="${fastlane_dir}/Appfile"

if [[ "${FORCE}" != "true" ]] && [[ -f "${fastfile_path}" || -f "${appfile_path}" ]]; then
  echo "[INFO] fastlane 已存在。使用 --force 可覆盖。"
  echo "[DONE] 跳过 bootstrap。"
  exit 0
fi

echo "== Fastlane Bootstrap Plan =="
echo "Project Root        : ${PROJECT_ROOT}"
echo "Workspace           : ${WORKSPACE:-<none>}"
echo "Xcodeproj           : ${XCODEPROJ}"
echo "Scheme              : ${SCHEME}"
echo "App Identifier      : ${APP_IDENTIFIER}"
echo "Apple ID Fallback   : ${APPLE_ID}"
echo "Team ID             : ${TEAM_ID}"
echo "Fastfile Path       : ${fastfile_path}"
echo "Appfile Path        : ${appfile_path}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "[DRY-RUN] 未写入 fastlane 文件。"
  exit 0
fi

mkdir -p "${fastlane_dir}"
write_appfile "${APP_IDENTIFIER}" "${APPLE_ID}" "${TEAM_ID}"
write_fastfile "${WORKSPACE:-${preferred}.xcworkspace}" "${SCHEME}" "${APP_IDENTIFIER}" "${XCODEPROJ}"

echo "[DONE] 已创建 fastlane/Appfile 与 fastlane/Fastfile。"
