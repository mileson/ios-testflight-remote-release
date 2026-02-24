---
name: ios-testflight-remote-release
description: |
  iOS 远程构建并发布到 TestFlight Internal 的标准化工作流。
  This skill should be used when Claude needs to 在用户不在电脑旁（手机远程）时，
  完成资料预检、版本规划、构建上传、Internal Group 分发、首次安装指引与发布结果校验。
  触发词：TestFlight、internal_release、远程构建、iOS 内测发布、Internal Group 自动分发。
disable-model-invocation: true
---

# iOS TestFlight Remote Release

## 目标
将“代码改完后发布给手机测试”流程标准化，确保在远程场景下也能稳定完成：
1. 本地资料优先扫描，缺失项一次性收集；
2. 自动构建并上传 TestFlight；
3. 自动分发到 `Agent Internal Testing`；
4. 输出可复用的首次安装与后续更新指引。

## 何时使用
当用户提出以下需求时使用本 Skill：
1. “帮我构建并发布到 TestFlight”
2. “我不在电脑旁，手机要更新内测版本”
3. “执行 internal_release（构建+上传+分发）”
4. “自动加到 Internal Group 并可见最新 build”

## 路径约束（固定）
1. 本 Skill 只走 `fastlane` 路径，不提供“手动 Xcode 上传”分支。
2. 若项目缺少 `fastlane/Fastfile`，必须自动执行 bootstrap 初始化后继续。
3. 仅当用户明确要求不用 fastlane 时，才停止并说明原因。

## Wizard 总流程
```text
+-----------------------------------------------------------+
| iOS Remote Release Wizard                                |
+-----------------------------------------------------------+
| 1) Preflight & 本地资料扫描                              |
| 2) 缺失项一次性补齐（ASC + Tester + 项目元数据）         |
| 3) 版本策略确认（MARKETING_VERSION / BUILD_NUMBER）      |
| 4) 执行 internal_release（构建 + 上传 + 分发）           |
| 5) 校验 Internal Group & 最新 build 可见性               |
| 6) 结果回写 memory（下次优先复用）                       |
+-----------------------------------------------------------+
```

## 执行顺序（必须）

### Step 1. Preflight（环境与项目可执行性）
先运行：
```bash
bash scripts/preflight_scan.sh --project-root "$PWD"
```

检查：
1. Xcode / fastlane / ruby 可用；
2. 当前目录是 iOS 项目，存在 `fastlane/Fastfile`；
3. 包含 `internal_release` 和 `assign_internal_tester` lane；
4. 解析项目基础信息（workspace/scheme/app_identifier）。
5. 若缺少 `fastlane/Fastfile`，自动执行 `scripts/bootstrap_fastlane.sh` 初始化。

### Step 2. 资料收敛（本地优先）
运行：
```bash
python3 scripts/resolve_materials.py --project-root "$PWD" --scan --write-memory
```

数据来源优先级（从高到低）：
1. 用户本轮明确提供（命令参数/对话）
2. 本地环境变量（`ASC_*`, `TESTER_EMAILS` 等）
3. 本地项目文件自动发现（`fastlane/Appfile`, workspace, scheme）
4. `data/memory.json` 历史记忆
5. 默认值（仅非敏感字段，例：`INTERNAL_GROUP_NAME=Agent Internal Testing`）

自动推导规则：
1. `ASC_KEY_ID` 可从 `ASC_KEY_FILEPATH` 的文件名 `AuthKey_<KEY_ID>.p8` 自动提取；
2. `ASC_ISSUER_ID` 不能从 `.p8` 文件推导，仍需用户提供（或来自 memory/env）。

如果缺失项存在：
1. 一次性列出全部缺失项（不要分多轮零散追问）；
2. 引导用户按 `references/newbie-guide.md` 提供；
3. 用户补齐后再继续，不要强行发布。

资料清单模板：`references/materials-checklist.template.md`

### Step 3. 版本策略（先确认再执行）
规则：
1. bug/微小优化：`x.y.(z+1)`
2. 大功能模块优化：`x.(y+1).0`
3. 全新方向大版本：`(x+1).0.0`

执行要求：
1. 若用户明确给 `MARKETING_VERSION`，直接使用；
2. 若未给，基于当前版本给出建议版本并等待确认；
3. 未获得明确确认前，禁止真正构建上传。

建议命令：
```bash
bash scripts/release_internal.sh --project-root "$PWD" --change-type patch --dry-run
```
`--dry-run` 用于先展示将执行的版本与命令。

### Step 4. 发布（构建+上传+分发）
确认后运行：
```bash
bash scripts/release_internal.sh \
  --project-root "$PWD" \
  --marketing-version "1.8.2" \
  --group "Agent Internal Testing"
```

该脚本会：
1. 生成时间戳 build number（`YYYYMMDDHHmm`）；
2. 调用 `fastlane ios internal_release`；
3. 自动处理 ASC 导出合规（依赖项目 lane 内逻辑）；
4. 若测试者分配异常，执行 `assign_internal_tester` 再校验。

### Step 5. 发布后验真
运行：
```bash
python3 scripts/verify_distribution.py \
  --project-root "$PWD" \
  --group "Agent Internal Testing"
```

重点校验：
1. 最新 build 已进入 Internal Testing 可用状态；
2. 测试者已在目标组内；
3. 用户邮箱与设备 Apple ID 一致。

## 首次安装 vs 后续更新（必须告知用户）
1. 首次成为测试者时，可能需要在邮件/TestFlight 完成一次接受流程；
2. 首次完成后，后续新 build 在 TestFlight 内直接 `Update`；
3. 若看不到新包，按 `references/troubleshooting.md` 排查。

## 关键约束
1. 不泄露密钥内容；日志中仅展示掩码；
2. 未完成资料收集或版本确认时，不执行上传；
3. 优先复用 `data/memory.json`，减少重复提问；
4. 默认 Internal Group 为 `Agent Internal Testing`，除非用户明确覆盖；
5. 如果存在已连接 iPhone，可先尝试本地安装验证；无连接时走 TestFlight 远程分发。

## 资源索引
1. 新手资料获取：`references/newbie-guide.md`
2. 资料模板：`references/materials-checklist.template.md`
3. 故障排查：`references/troubleshooting.md`
4. 记忆存储：`data/memory.json` 与 `data/memory.md`
5. 执行脚本：
   - `scripts/bootstrap_fastlane.sh`
   - `scripts/preflight_scan.sh`
   - `scripts/resolve_materials.py`
   - `scripts/release_internal.sh`
   - `scripts/verify_distribution.py`
