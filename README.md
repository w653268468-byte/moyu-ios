# Gavin · iOS 阅读器

原生 SwiftUI 小说阅读器，iOS 17+，主程序 MIT 开源，libmobi 为 LGPL-3.0-or-later。以 Android 阅读/Legado 为开发目标；**当前 2.0 重构预览不等同 Legado 完整功能或完整规则兼容性**。

## 本次重构

- 四个入口：书架、找书、书源管理、设置。
- 书源：链接/文件/文本导入；按名称/网址/分组搜索；启用/禁用、JSON 编辑、导出、多选删除；搜索→目录→首章校验，可取消。
- 两个粘贴框均自动识别网址或完整 JSON；20 个限制仅适用于待获取的网址，不适用于 JSON 行数。设置和导入页显示构建编号，便于核对已安装的包。
- 删除被小说使用的书源也可执行，书架记录及缓存保留；未缓存章节需重新导入对应书源。
- CSS/旧式选择器、XPath 1.0、JSONPath（字段/索引/通配符、过滤、切片、并集、递归）、UTF-8/GBK 静态 GET/POST、目录和正文分页。导出保留未识别的原始 Legado 字段。
- HTTP 状态、域名解析、超时、证书错误分别提示。采用移动浏览器 UA 与书源 Referer。
- JavaScript：QuickJS 解释执行，提供选择器、Jsoup 常用集合、变量、Base64/MD5/SHA256、HTTP GET/POST/ajax、动态网址/请求头和行内表达式；完整 Android 桥仍未完成。
- 平移或原生仿真卷页；全屏按屏幕分页，滑动/点击两侧翻页，中心切换菜单；调整排版后重排，记忆章节内分页位置。
- 本地 TXT、EPUB、PDF、MD、HTML、RTF、DOCX 与未加密 MOBI/AZW3/KF8。新 EPUB 保留原文件、图片、CSS 与目录；MOBI/AZW3 重建为 EPUB；PDF 按页提取文字，无文字层时尝试本机 OCR；其他富文本转为文字重排。
- 阅读：八种主题、四种系统字形、字号/字重/字距/行距/段距、上下左右边距、缩进、标题、页面亮度、常亮、预览及重置；本地和在线共用。
- 听书：系统中文语音，当前分段/章节朗读、暂停、继续、停止、语速调整。
- 本地目录、书签、正文搜索、阅读进度；在线已读章节缓存；小说详情可逐章缓存全书并随时停止。
- 完整 JSON 备份/恢复：书架、文字书、原始 EPUB、进度、书签、书源、章节缓存和阅读设置。恢复先校验并暂存原目录用于失败回滚。
- 按用户要求移除番茄专用入口与解析接口。旧记录保留；已缓存章节仍能读，未缓存章节需重新导入通用书源。
- 可直接导入用户提供的 `https://github.com/52liulian/yuanc`，识别其书源索引并下载实际 JSON；GitHub blob 文件链接会转换为原始文件链接。索引最多跟随 20 个链接、限制一层，书源合集最大 20 MB / 5000 项。

## 明确的未完成项

完整 Legado Java/Android 桥及全部脚本书源兼容性仍未完成。发现分类、自动/手动换源、仿真卷页、在线滚动恢复、WebDAV 完整快照、EPUB 图片/样式和未加密 MOBI/AZW3 已有实现，验收状态见 [功能对照表](docs/PARITY_STATUS.md)。新增功能必须完成对应测试及 iOS 集成检查；代码存在不代表真机已经验收。DRM 已按用户要求移除。

导入书源不等于网站可用；“规则可识别”也不代表真实链路已通过。截图中的网易云/17K 等脚本书源目前仍有兼容缺口。

## 安装和构建

在仓库 Releases 或通过全部检查的 Actions 构建产物中下载 `Gavin-unsigned.ipa`，Windows 使用已配置的 Sideloadly 签名安装。免费 Apple 账号通常需每 7 天续签。同一账号/包名覆盖安装可保留数据；**先导出备份，不要先删除手机 App**。

Actions 在 macOS 上运行测试、模拟器构建、arm64 iPhone Release 构建后打包。Windows 的 `scripts/validate.py` 只做结构检查，不能代替 Swift/Xcode 编译。

```sh
swift test --parallel -Xcc "-I$(xcrun --show-sdk-path)/usr/include/libxml2"
xcodebuild -project Moyu.xcodeproj -scheme Moyu -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

需求清单见 [docs/REBUILD.md](docs/REBUILD.md)，历史网站检查见 [docs/SOURCE_CHECKS.md](docs/SOURCE_CHECKS.md)。历史记录不代表当前手机网络或新版本验收。

## 格式限制

单文件不超过 100 MB；纯文本解码不超过 20 MB。EPUB 解压资源上限 200 MB、文字上限 40 MB、单个资源上限 40 MB。PDF 不保留原版式；扫描页 OCR 的准确率取决于清晰度，不能保证逐字正确。MD 保留文字标记。备份内容上限 200 MB。

依赖 SwiftSoup 2.7.7、ZIPFoundation 0.9.19、QuickJS-Swift 固定提交（MIT），及内置 libmobi 0.12 固定提交（LGPL-3.0-or-later），见 [第三方声明](THIRD_PARTY_NOTICES.md)。无内置第三方书源、账号、广告或阅读统计；书源请求直接访问所选网站。

## 实际联网检查

2026-10-19，macOS CI 实际通过 Project Gutenberg 的搜索 → 详情 → HTML 正文，并成功导入其公版 EPUB（30 个阅读节、562 个文本分段）。示例规则在 `Examples/gutenberg-public-domain.json`，可用 `Frankenstein` 搜索；此例把整本 HTML 作为一个在线阅读节，不代表已实现该网站的细分章节。

用户提供的 yuanc 索引包含两条外部订阅；当前开发网络读取到 jsDelivr 文件 194 个规则，yckceo 重定向后连接重置。以最新 `Gavin-live-source-check` CI 日志中的实际导入和兼容统计为准。统计不等于每个小说网站的搜索/目录/正文均可用。

XPath 使用 Apple 平台系统 libxml2，封装代码在 `Sources/CReaderXML`；禁用网络加载外部文档，不提供 XPath 扩展函数。

## WebDAV 与旧版数据

在设置中保存自己的 HTTPS WebDAV 文件夹及账号（钥匙串存储），再检查同步。同步采用完整快照；版本冲突时选择保留本机或云端，上传使用强 ETag 防止覆盖他人更新，下载前保留本机恢复副本。没有配置服务器时不会上传。

旧版只保存文字的 EPUB 需重新导入原文件才能恢复图片和原书样式；现有 TXT、在线书架及缓存继续使用原存储目录。
