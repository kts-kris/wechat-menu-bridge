# 微信桥 · WeChat Menu Bridge

微信桥是一个 macOS 菜单栏应用，通过本机小禾 MCP 连接微信。可以为不同会话配置只拟稿、自动回复和风控策略。安装包自带引擎，不包含小禾服务、模型、账号、聊天记录或凭据，也不需要单独安装 Bun 来运行。

## 安装与更新

从 [GitHub Releases](https://github.com/kts-kris/wechat-menu-bridge/releases/latest) 下载 `WeChatMenuBridge-arm64.zip`，解压后将 App 移到「应用程序」。目标平台为 Apple Silicon，最低 macOS 13。发布包有更新用的 Ed25519 签名，但没有 Apple Developer ID 签名或公证，首次打开可能受 macOS 安全策略限制。

从 **2.1.0** 起，控制台「连接与设置 → 软件更新与热更新资产 → 检查更新」默认使用 GitHub 的稳定版更新源，安装前校验 ZIP 的 SHA-256 和 Ed25519 签名。已有自定义更新源会保留；可点击「恢复内置更新源」切回官方源。

旧版没有内置地址，可直接下载 ZIP 升级；已有更新界面的旧版也可以手动填写：

- 更新源：`https://github.com/kts-kris/wechat-menu-bridge/releases/latest/download/appcast.json`
- Ed25519 公钥：`VStTm0b59AmB7fVgfgB5B7nS6u6OxOMVh3Hn616+ptY=`

## 配置会话

1. 在「连接与设置」填写小禾为本 App 提供的本机 MCP 地址，配置回复模型。模型及 MCP 凭据按端点保存在 macOS 钥匙串。
2. 在「会话与策略」加入一个知情会话。建议先试拟脱敏例句，再用「只拟稿」确认真实权限和回复口吻。
3. 在该会话的「风控策略」选档并保存。**日常推荐**跳过命中资金、凭据、隐私等高风险规则的来信；**严格**在命中保守规则时暂停会话；**极简**主要由模型判断，敏感来信也可能交给所选模型。新会话默认「日常推荐」，升级不会未经选择改掉已有会话的策略。
4. 查看该会话的处理轨迹，区分「入站规则」「模型建议转人工」「出站草稿规则」。风控轨迹记录类别和处理动作，不附命中的消息或草稿原文。

所有档位都保留对方叫停、身份披露及未知提交不自动重发的保护。规则与模型都可能漏判；风控不是脱敏器。使用云模型前请确认数据去向。发送检查和提交之间到达的叫停仍可能来不及阻止本次发送。App 重启后不会自动恢复自动发信授权。

运行状态位于 `~/Library/Application Support/WeChatMenuBridge/`。退出不会删除本机状态或钥匙串条目。

## 从源码构建

在 Apple Silicon Mac 上安装 Xcode 和 Bun，然后运行：

```sh
bash scripts/package.sh
```

产物在 `dist/`。首次安装构建依赖后，可运行 `bash scripts/selftest.sh dist/qa-new`（输出目录必须尚不存在），离线重建、验证解包一致性和签名，并运行隔离的 Swift 和引擎测试；测试不用真实微信或模型凭据。原生 UI 测试可在已解锁的桌面会话运行 `bash scripts/uitest.sh dist/qa-new/WeChatMenuBridge-arm64.zip`。
