# 墨屿 Moyu · iOS 阅读器

原生 SwiftUI 小说阅读器，iOS 17+，MIT 开源。以 Android 阅读/Legado 为开发目标；**当前 2.0 重构预览不等同 Legado 完整功能或完整规则兼容性**。

## 本次重构

- 四个入口：书架、找书、书源管理、设置。
- 书源：链接/文件/文本导入；按名称/网址/分组搜索；启用/禁用、JSON 编辑、导出、多选删除；搜索→目录→首章校验，可取消。
- 删除被小说使用的书源也可执行，书架记录及缓存保留；未缓存章节需重新导入对应书源。
- CSS/旧式选择器、基础 JSONPath（字段/索引/通配符）、UTF-8 静态 GET/POST、目录和正文分页。导出保留未识别的原始 Legado 字段。
- HTTP 状态、域名解析、超时、证书错误分别提示。采用移动浏览器 UA 与书源 Referer。
- 本地 TXT、EPUB、PDF、MD、HTML、RTF、DOCX。EPUB 依阅读顺序读取章节；PDF 按页提取文字；其他富文本转为文字重排。
- 阅读：八种主题、四种系统字形、字号/字重/字距/行距/段距、上下左右边距、缩进、标题、页面亮度、常亮、预览及重置；本地和在线共用。
- 听书：系统中文语音，当前分段/章节朗读、暂停、继续、停止、语速调整。
- 本地目录、书签、正文搜索、阅读进度；在线已读章节缓存。
- 完整 JSON 备份/恢复：书架、文字书、进度、书签、书源、章节缓存和阅读设置。恢复先校验并暂存原目录用于失败回滚。
- 按用户要求移除番茄专用入口与解析接口。旧记录保留；已缓存章节仍能读，未缓存章节需重新导入通用书源。

## 明确的未完成项

复杂 JavaScript 与 Java/Android 桥、通用 XPath、JSONPath 过滤器、WebView 登录验证、发现分类、自动换源、仿真翻页、全本离线下载、在线精确滚动位置、跨设备/WebDAV 同步、EPUB 图片原版式、扫描 PDF OCR、MOBI/AZW3、DRM 保护正文。

导入书源不等于网站可用；“规则可识别”也不代表真实链路已通过。截图中的网易云/17K 等脚本书源目前仍有兼容缺口。

## 安装和构建

在仓库 Releases 下载通过 CI 的 `Moyu-unsigned.ipa`，Windows 使用已配置的 Sideloadly 签名安装。免费 Apple 账号通常需每 7 天续签。同一账号/包名覆盖安装可保留数据；**先导出备份，不要先删除手机 App**。

Actions 在 macOS 上运行测试、模拟器构建、arm64 iPhone Release 构建后打包。Windows 的 `scripts/validate.py` 只做结构检查，不能代替 Swift/Xcode 编译。

```sh
swift test --parallel
xcodebuild -project Moyu.xcodeproj -scheme Moyu -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

需求清单见 [docs/REBUILD.md](docs/REBUILD.md)，历史网站检查见 [docs/SOURCE_CHECKS.md](docs/SOURCE_CHECKS.md)。历史记录不代表当前手机网络或新版本验收。

## 格式限制

单文件不超过 100 MB；纯文本解码不超过 20 MB。EPUB 解压文字不超过 40 MB、单个章节文件不超过 20 MB。PDF 需要文字层，不保留原版式。MD 保留文字标记。备份内容上限 200 MB。

依赖 SwiftSoup 2.7.7、ZIPFoundation 0.9.19（均为 MIT）。无内置第三方书源、账号、广告或阅读统计；书源请求直接访问所选网站。
