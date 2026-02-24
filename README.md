# ios-testflight-remote-release

这个 Skill 用来让 Agent 帮你完成 iOS 的 TestFlight Internal 发布，适合你不在电脑旁、但需要快速推送内测版本的场景。

## 你可以直接让 Agent 做什么

- 自动检查当前项目是否具备发布条件（Xcode、fastlane、lane、项目元数据）
- 一次性收集发布所需材料（避免反复追问）
- 给出建议版本号并等待你确认
- 自动执行构建、上传、Internal Group 分发
- 发布后校验测试者是否可见最新 build

## 你怎么对 Agent 下指令

你可以直接说：

- `帮我发布到 TestFlight internal`
- `我现在不在电脑旁，帮我走远程内测发布`
- `执行 internal_release，发到 Agent Internal Testing`

## Agent 的执行流程（用户视角）

1. 先预检项目和环境，确认能发布。
2. 自动扫描并补齐材料，缺什么一次性告诉你。
3. 给出版本建议（patch/minor/major），你确认后才正式发布。
4. 执行构建上传和测试组分发。
5. 返回发布结果，并告诉你首装和后续更新的操作方式。

## 你需要提前准备

- iOS 项目可正常本地构建
- App Store Connect 相关信息（如 Issuer ID、Key 文件等）
- 目标测试者邮箱（可多个）

首次准备可参考：`references/newbie-guide.md`

## 结果你会拿到什么

- 本次发布的版本信息（`MARKETING_VERSION` / `BUILD_NUMBER`）
- Internal Group 分发状态
- 测试者可见性校验结果
- 首次安装与后续更新指引

## 安全说明

- 本仓库不包含真实密钥或生产凭证。
- `data/memory.json` 与 `data/memory.md` 是本地运行记忆，不会作为开源内容发布。
