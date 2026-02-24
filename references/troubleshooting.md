# 故障排查手册（TestFlight Internal）

## 1) TestFlight 看不到新版本

可能原因：
1. build 仍在 processing；
2. tester 不在目标 Internal Group；
3. 手机 TestFlight 账号与 tester 邮箱不一致；
4. 首次测试者尚未完成接受流程。

处理：
1. 在 App Store Connect 的 TestFlight 页面确认 build 状态为 `Testing`；
2. 执行 `assign_internal_tester` 再次绑定 tester；
3. 校验邮箱是否在 `Users and Access -> People` 且已接受邀请；
4. 退出并重新登录 TestFlight，对应 Apple ID 必须一致。

## 2) 报错：`Tester(s) cannot be assigned`

说明：
1. 该邮箱不是可分配的内部测试用户；
2. 用户还未在 `People` 中完成邀请与权限配置。

处理：
1. 先在 `People` 添加并完成接受；
2. 给该用户分配 App 访问权限；
3. 重新执行分发脚本。

## 3) 报错：`MISSING_EXPORT_COMPLIANCE`

说明：
上传后缺少导出合规声明，build 无法进入可测状态。

处理：
1. 使用带自动修复逻辑的 lane（项目中已处理）；
2. 如果仍失败，在 App Store Connect 手工确认加密声明；
3. 再次触发 build 状态轮询。

## 4) 已收到邀请邮件，但仍需 Redeem code

说明：
通常出现在“不是内部用户”或“通过 app-specific 测试邀请路径”场景。

处理：
1. 优先改为 Internal Testing（People 用户）；
2. 完成一次首次接受后，后续一般直接在 TestFlight 内更新。

## 5) 远程场景没有 USB，是否可安装？

结论：
1. 无法通过本地直装方式安装；
2. 可以通过 TestFlight 分发实现远程安装更新；
3. 前提是已完成签名、上传、分发与 tester 授权。

## 6) 构建成功但版本号不符合预期

原因：
1. 未明确传入 `MARKETING_VERSION`；
2. 仅更新了 build number（时间戳）。

处理：
1. 先确认版本策略（patch/minor/major）；
2. 传入明确版本后再发布；
3. 保持 build number 使用时间戳，避免重复。
