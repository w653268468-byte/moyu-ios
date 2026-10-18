# 墨屿 · Moyu

面向 iPhone / iPad 的原生 SwiftUI 小说阅读器，参考「阅读 / Legado」的书源使用方式。独立实现，不是安卓版移植，也不隶属于 Legado。

**当前状态：开发版本。已提供源码、Xcode 工程、解析测试和云端 IPA 工作流；当前 Windows 环境仅完成工程结构检查，尚未运行 Swift 编译、单元测试、真实网站联调或真机安装。仓库中没有已签名 IPA。**

## 已实现

- 本地书架：TXT 批量导入，书名搜索、排序、继续阅读和删除。
- TXT：UTF-8、带 BOM 的 UTF-16、GB18030 / 常见 GBK，单本最大 20 MB。
- 本地阅读：章节识别、文本分段翻页、字体/行距、四种主题、书签和正文搜索。
- 书源：通过 HTTP/HTTPS JSON 链接、`legado://…?src=…` 链接、JSON 文件或粘贴文本导入；支持单对象和数组、导入预览与按地址更新。链接可每行一个批量粘贴，一次最多 20 个，单个失败不会中断其余链接。
- 在线小说：选择书源搜索、粘贴同域名小说详情/目录链接、获取章节目录、加入书架、逐章阅读和本机缓存。
- 在线目录和正文分页，限制请求次数并检测循环。在线阅读进度保存到章节；尚不保存章内滚动位置。
- 数据使用 JSON 原子写入，并保留上一个索引备份。小说和书源保存在本机；使用书源时直接访问目标网站。

## 书源兼容范围

本版本是 **Legado 3.x JSON 结构的 CSS 子集**，不是完整的 Legado 规则解释器。大量现有书源包含脚本，可能无法使用。导入成功只代表 JSON 可读取，不代表网站可访问或规则一定正确。

| 能力 | 当前支持 |
|---|---|
| 搜索 | GET 请求，`{{key}}`、`{{page}}` 和 `searchKey` 模板；仅第一页，最多 100 本 |
| 提取 | CSS、`@css:`、简单 `class.xxx` / `id.xxx` / `tag.xxx`，`@` 后代选择 |
| 字段 | `@text`、`@ownText`、`@textNodes`（以 ownText 近似）、`@html`、`@href`、其他属性 |
| 组合 | 字段规则的 `||` 首个非空结果、`##正则##替换` |
| 章节 | `ruleToc` 及 `nextTocUrl`，最多 30 个目录页 / 20000 章 |
| 正文 | `ruleContent.content` 及 `nextContentUrl`，最多 20 个分页 / 单章 4 MB |
| 编码 | UTF-8、带 BOM 的 UTF-16、GB18030 / 常见 GBK；不根据网页 charset 强行转码 |
| 请求头 | 静态 JSON 字符串；不发送 Cookie、Authorization 和自定义 Host |
| 暂未支持 | JS、XPath、JSONPath、POST、登录、验证码、动态网页、探索页、跨源聚合搜索、听书、EPUB、整本批量下载、iCloud 同步 |

`Examples/booksource.example.json` 是 **虚构域名的规则模板，不是可以阅读小说的真实书源**。要验证真实兼容性，需要提供你实际使用的书源 JSON 和目标网站。不要将示例地址当作内置资源。

App 不执行书源中的脚本，不实现付费解锁、验证码绕过或网站登录。目标网站可能因规则、网络、反爬或权限而无法读取。支持 HTTP 是为兼容旧书源，HTTP 内容不加密；建议使用 HTTPS。

## 只有 Windows 和 iPhone：安装路径

详见 [Windows 安装指南](docs/WINDOWS_INSTALL.md)。流程是：

1. 将完整项目提交到你自己的 GitHub 仓库（包括 `.github` 文件夹）。
2. 在仓库 Actions 中运行 **Build iOS IPA**。
3. 云端 macOS 运行测试和 Xcode 构建，成功后下载 `Moyu-iOS-unsigned` 构建产物并解压出 IPA。
4. 按 AltStore Classic 的 Windows 官方流程安装 AltServer / AltStore。
5. 使用 AltStore 以你自己的 Apple ID 签名并安装 IPA。

**未签名 IPA 不能直接点开安装。免费 Apple ID 通常需要每 7 天续签。** Apple ID、密码、签名证书均不需要提交到本项目或 GitHub Actions。

这条流程尚未在当前会话实际运行。若构建失败，请保留 Actions 的错误日志以便修复；不要把源码 ZIP 当成 IPA。

## 有 Mac：开发与真机安装

- iOS / iPadOS 17.0 及以上，Xcode 16 或更新版本；Swift 5 语言模式。
- 打开 `Moyu.xcodeproj`，等待 Swift Package Manager 下载 SwiftSoup 2.7.7。
- 选择 Moyu target，在 Signing & Capabilities 中选择自己的 Team，并设置唯一 Bundle Identifier。
- 连接 iPhone、信任电脑、按系统提示开启开发者模式，选择手机为运行设备并点击 Run。
- 无需 XcodeGen、CocoaPods、后端服务器或 API key。

```sh
# macOS：独立测试文本及书源规则
swift test --parallel

# macOS：无签名模拟器编译
xcodebuild -project Moyu.xcodeproj -scheme Moyu \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

# Windows / macOS：结构验证（不能代替编译）
python scripts/validate.py
```

新增/删除 Swift 文件后，运行 `python scripts/generate_project.py` 更新 Xcode 工程。该命令也会重新生成原创 App 图标。

## 数据和备份

在 iPhone「文件 → 我的 iPhone → 墨屿」中备份：

- `Moyu/`：本地书架索引、备份索引及小说文档。
- `MoyuOnline/`：书源、在线书架索引、备份索引及已读章节缓存。

完整恢复时，关闭 App 后将两个文件夹放回原处再重新打开。不要混合不同时间的索引与文档。卸载 App 会删除这些数据；免费签名到期时应刷新签名，避免通过卸载解决问题。

## 工程结构

```text
Sources/ReaderCore/       文本解析、书源数据、CSS 规则、网站请求
Sources/App/              SwiftUI 书架、书源、阅读器与持久化
Tests/ReaderCoreTests/    解析、编码、JSON、CSS、URL 和存储序列化测试
Resources/                Info.plist、隐私清单与原创图标
Moyu.xcodeproj/           可直接打开的 Xcode 工程和共享 scheme
.github/workflows/       macOS 测试、模拟器与 iPhone IPA 构建
scripts/                  工程/图标生成和结构校验
```

MIT 许可，见 [LICENSE](LICENSE)。第三方依赖 SwiftSoup 的许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。未复制 Legado 的源码、图标或品牌素材。
