# Windows + iPhone 安装Gavin

本项目是原生 iOS App，需要先编译，再对 IPA 签名。已经在 GitHub 云端 macOS 成功生成包含番茄导入功能的 IPA，你不需要自己拥有 Mac。**IPA 尚未签名，实际真机安装仍需你自己的 Apple ID，当前尚未完成真机运行验证。**

已有仓库和安装包：[打开成功构建](https://github.com/w653268468-byte/moyu-ios/actions/runs/39138850107)，在页面底部 Artifacts 下载 `Moyu-iOS-unsigned`，解压出 IPA，然后直接从本文“二、在 Windows 上安装 AltStore Classic”继续。以下第一部分用于以后自行重新构建。

## 一、使用 GitHub 云端生成 IPA

1. 注册或登录自己的 GitHub 账号。
2. 使用 GitHub Desktop 将本项目文件夹作为仓库提交并发布，或使用 Git 命令推送。确认仓库根目录能看到 `Moyu.xcodeproj`、`Package.swift`、`Sources`、`Resources` 和 `.github/workflows/ios.yml`。如果通过网页上传，不要只上传一个源码 ZIP，也不要多套一层文件夹。
3. 打开仓库网页的 **Actions**。若 GitHub 提示启用 workflows，启用它。
4. 选择 **Build iOS IPA → Run workflow → Run workflow**。
5. 等待测试、模拟器编译、iPhone 编译全部通过。如果失败，点开红色步骤，保留完整错误日志。
6. 成功后在该次运行页面底部的 **Artifacts** 下载 `Moyu-iOS-unsigned`。
7. 解压下载的构建产物 ZIP，得到 `Moyu-unsigned.ipa`。这是为 iPhone 编译的未签名包，还需下一步签名。

GitHub Actions 的可用额度和权限以你的账号为准。工作流只读仓库，不需要 Apple ID、开发者证书或任何仓库 secret。

## 二、在 Windows 上安装 AltStore Classic

请按 [AltStore 官方 Windows 安装指南](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) 操作，版本要求变化时以官方指南为准：

1. 从 AltStore 官网获取 **AltServer for Windows / AltStore Classic**。这里使用 Classic，不是欧盟地区的 AltStore PAL。
2. 按官方文档配置 iTunes、iCloud 及相关依赖。官方标准流程要求从 Apple 下载相应版本；Microsoft Store 版的兼容步骤见其故障指南。
3. USB 连接 iPhone，解锁并点“信任此电脑”。按官方流程配置 Wi-Fi 同步。
4. 运行 AltServer，在 Windows 托盘中选择 **Install AltStore → 你的 iPhone**。
5. 在官方签名工具中输入你自己的 Apple ID 并完成验证；不要将密码发送给他人或填进书源/本项目。
6. 在 iPhone「设置 → 通用 → VPN 与设备管理」中信任对应开发者；若系统提示，则开启开发者模式并重启。

## 三、安装Gavin IPA

1. 将 `Moyu-unsigned.ipa` 传到 iPhone 的“文件”App（例如个人网盘或 iCloud Drive）。
2. 保持电脑 AltServer 运行，电脑与手机按官方要求连接。
3. 在 iPhone 打开 AltStore Classic → **My Apps → +**，选择这个 IPA。
4. 等待 AltStore 重新签名并安装，随后在主屏幕打开「Gavin」。
5. 免费 Apple ID 的签名通常 7 天到期，需要通过 AltServer 定期刷新；免费账号也有活动 App 和 App ID 数量限制，AltStore 本身会占用名额。

参见 [AltStore 使用与刷新说明](https://faq.altstore.io/altstore-classic/your-altstore) 和 [Apple 免费开发账号限制](https://developer.apple.com/help/account/basics/about-your-developer-account)。

## 四、导入阅读书源

1. 打开Gavin → 底部 **书源** → 右上角 **+**。
2. 粘贴返回 Legado 3.x JSON 的书源链接并点“获取并预览书源”，也可以选择 JSON 文件或粘贴 JSON。
3. 查看兼容提示，点“确认导入”。
4. 在“使用书源”中选择对应书站，输入书名搜索；或粘贴该站的小说详情/目录链接。
5. 打开结果 → 查看目录 → 继续阅读或加入书架。已读正文会缓存，可离线重读。

本版本只兼容部分 CSS 规则。如果提示 JS/XPath/JSONPath 不支持，换用兼容书源或为该站编写 CSS 规则；如果正文为空，检查网站改版、网络和访问权限。`Examples` 内的 JSON 是开发模板，不是真实书源。

番茄小说可直接使用「书源 → 番茄小说 · 分享链接导入」，无需先导入第三方番茄 JSON 书源。详见 [番茄导入说明](FANQIE.md)。

## 常见问题

- **下载只有源码**：应下载 Actions 成功运行的 Artifact，不是 Code → Download ZIP。
- **IPA 点开没反应**：未签名 IPA 必须经 AltStore 签名安装，不能作为普通文件直接安装。
- **无法验证完整性**：检查签名、设备信任、开发者模式和账号名额；按 AltStore 官方 [故障指南](https://faq.altstore.io/altstore-classic/troubleshooting-guide) 排查。
- **安装后无法打开**：iOS 版本至少为 17；确认签名仍有效并完成系统要求。
- **7 天后打不开**：通过 AltServer 刷新，先备份数据，避免直接卸载 App。
- **想长期分发给其他人**：需要你自己的 Apple Developer Program、签名配置与 TestFlight / App Store 发布流程；本工程尚未配置这些发行凭据。
