# 示例：一次完整内部发布输出

## 预检摘要
1. 检测到 `fastlane/Fastfile`，包含 `internal_release` 与 `assign_internal_tester`。
2. 自动发现：
   - `IOS_WORKSPACE=ReadFast.xcworkspace`
   - `IOS_SCHEME=ReadFast`
   - `IOS_APP_IDENTIFIER=com.chaojifeng.ReadFast`
3. 缺失项：无。

## 版本策略
1. 当前版本：`1.8.1`
2. 变更类型：`patch`
3. 建议版本：`1.8.2`
4. 用户确认：`1.8.2`

## 执行结果
1. 构建：成功
2. 上传：成功
3. 状态：`Testing`
4. Group：`Agent Internal Testing`
5. Tester：`466257277@qq.com`（已确认在组内）

## 用户提示
1. 首次安装：若首次被加入测试，请先在邮件/TestFlight 完成接受。
2. 后续更新：直接在 TestFlight 点 `Update`。
