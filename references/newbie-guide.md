# 新手指引：如何获取 ASC 资料并完成 Internal 发布准备

## 1. 获取 `ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_FILEPATH`

### Step 1: 进入 API Keys 页面
1. 打开 [App Store Connect](https://appstoreconnect.apple.com/)。
2. 进入 `Users and Access`。
3. 切换到 `Integrations` 标签页。
4. 在 `App Store Connect API` 区域点击 `Keys`。

### Step 2: 创建 Key（如果还没有）
1. 点击 `+` 新建 Key。
2. 填写名称，例如 `Fastlane Release`。
3. 角色建议 `App Manager`（至少覆盖上传与 TestFlight 分发所需权限）。
4. 创建后下载 `.p8` 文件。

### Step 3: 对应三个字段（其中 `ASC_KEY_ID` 可自动推导）
1. `ASC_KEY_FILEPATH`：本机 `.p8` 文件绝对路径（例如 `/Users/you/Downloads/AuthKey_72L73DSSFC.p8`）。
2. `ASC_ISSUER_ID`：同页面顶部显示的 Issuer ID（UUID）。
3. `ASC_KEY_ID`：
   - 若文件名是 `AuthKey_<KEY_ID>.p8`，脚本可自动从文件名提取；
   - 若你改过文件名，不再符合该格式，则手动提供 `ASC_KEY_ID`。

## 2. 配置 Internal Tester（避免“看得到邮件看不到版本”）

### Step 1: 先保证用户是内部成员
1. 进入 `Users and Access` -> `People`。
2. 确认测试邮箱已存在且已接受邀请。
3. 该用户需要能访问当前 App（All Apps 或指定 App）。

### Step 2: 在 TestFlight 配置组
1. 进入目标 App -> `TestFlight`。
2. 创建/确认 Internal Group：`Agent Internal Testing`。
3. 将目标内部用户加入该组。

### Step 3: 首次安装注意事项
1. 首次成为测试者，可能需要通过邮件或 TestFlight 完成一次“接受测试”流程。
2. 完成首次后，后续新版本通常可在 TestFlight 内直接 `Update`，无需再次 Redeem code。

## 3. 终端变量设置示例

```bash
export ASC_ISSUER_ID="00000000-0000-0000-0000-000000000000"
export ASC_KEY_FILEPATH="/Users/you/Downloads/AuthKey_72L73DSSFC.p8"
export TESTER_EMAILS="466257277@qq.com"
export INTERNAL_GROUP_NAME="Agent Internal Testing"
# 可选：若文件名非 AuthKey_<KEY_ID>.p8，再补这一项
# export ASC_KEY_ID="72L73DSSFC"
```

## 4. 常见误区

1. 仅收到“build processed”邮件不代表 tester 已在组内。
2. tester 不在 `People` 中时，API 可能只能发送邀请流程，无法实现“直接自动可见”。
3. 手机 TestFlight 登录 Apple ID 与 tester 邮箱不一致时，App 不会显示。
