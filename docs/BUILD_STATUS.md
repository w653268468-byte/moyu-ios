# 构建验证记录

日期：2026-10-18（北京时间）。

| 项目 | 结果 |
|---|---|
| 代码版本 | `994f5fdce0fe145f82cb832cca1623bea6cefd9c` |
| GitHub Actions | [Build iOS IPA #3](https://github.com/w653268468-byte/moyu-ios/actions/runs/39138850107) 成功 |
| 工程结构检查 | 通过 |
| Swift 单元及请求流程测试 | 27 项通过 |
| iOS Simulator Debug 编译 | 通过 |
| iPhone Release arm64 编译 | 通过 |
| IPA 打包和上传 | 成功，产物名 `Moyu-iOS-unsigned` |
| Apple ID 签名、iPhone 安装和实际运行 | 尚未验证 |
| 真实书源全链路 | 尚未验证通过，参见 SOURCE_CHECKS.md |

番茄功能的测试包括官方域名与分享 ID 识别、目录顺序和去重、普通正文、特殊字体提示。一个公开官网样例返回 100 个章节链接，但其正文需官方网页字体，因此走官方网页阅读入口。测试通过和编译成功不代表支持番茄全站作品的原生正文提取或整本离线下载。

随后只更新文档时可能使用 `[skip ci]` 提交；上述代码版本对应已验证的应用源码。签名证书、Apple ID 密码不存放在仓库或 Actions 中。
