# iOS Remote TestFlight 资料清单模板

> 目标：第一次执行前，一次性确认最小必需资料。  
> 原则：本地可自动发现的字段优先自动发现；无法发现才向用户收集。

## A. 发布最小必需资料（必须有）

| 字段 | 是否已准备 | 示例/格式 | 来源与获取方式 |
|---|---|---|---|
| `ASC_KEY_ID` | [ ] | `72L73DSSFC` | 可选：若 `ASC_KEY_FILEPATH` 文件名为 `AuthKey_<KEY_ID>.p8`，可自动提取；不符合命名时再手动提供 |
| `ASC_ISSUER_ID` | [ ] | UUID | 同页面顶部 Issuer ID |
| `ASC_KEY_FILEPATH` | [ ] | `/Users/you/Downloads/AuthKey_xxx.p8` | 创建 API Key 时下载 `.p8` 文件（仅下载一次） |
| `TESTER_EMAILS` | [ ] | `a@b.com,c@d.com` | Internal tester 邮箱，建议与手机 TestFlight 登录账号一致 |

## B. 项目元数据（优先自动发现，必要时人工补）

| 字段 | 是否已准备 | 默认/示例 | 自动发现来源 |
|---|---|---|---|
| `IOS_WORKSPACE` | [ ] | `ReadFast.xcworkspace` | 项目根目录 `*.xcworkspace` |
| `IOS_SCHEME` | [ ] | `ReadFast` | `xcodebuild -list` |
| `IOS_APP_IDENTIFIER` | [ ] | `com.example.app` | `fastlane/Appfile` |
| `XCODEPROJ_PATH` | [ ] | `ReadFast.xcodeproj` | 项目根目录 `*.xcodeproj` |
| `APPLE_ID` | [ ] | `your@email.com` | `fastlane/Appfile` |
| `TEAM_ID` | [ ] | `DYGN8HZFL9` | `fastlane/Appfile` |

## C. 发布策略参数（建议）

| 字段 | 是否已准备 | 默认/建议值 | 说明 |
|---|---|---|---|
| `INTERNAL_GROUP_NAME` | [ ] | `Agent Internal Testing` | 目标 Internal Group |
| `CHANGE_TYPE` | [ ] | `patch`/`minor`/`major` | 未指定版本时用于建议版本 |
| `MARKETING_VERSION` | [ ] | `1.8.2` | 可由用户直接指定 |

## D. 版本规则（未指定版本时）

1. bug/微小优化：`x.y.(z+1)`
2. 大功能模块优化：`x.(y+1).0`
3. 全新方向大版本：`(x+1).0.0`

## E. 首次发布前一次性确认

1. `TESTER_EMAILS` 对应邮箱已在 App Store Connect `People` 中，具备 App 访问权限。
2. 已创建或允许自动创建 Internal Group：`Agent Internal Testing`。
3. 测试者首次若未显示 build，先完成一次 TestFlight 接受流程；后续直接在 App 内更新。
