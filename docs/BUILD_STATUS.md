# 构建状态

最新已验证集成：构建 65，提交 `096b0875a65ff637176673794d2470adc0e4f6ee`，[Actions](https://github.com/w653268468-byte/moyu-ios/actions/runs/39346110320)、[安装包与配套源码](https://github.com/w653268468-byte/moyu-ios/releases/tag/v2.0.0-preview.65)。核心回归、16 项脚本运行时测试、3 项联网测试、8 份原生检查报告及 6 项 XCUITest 通过。新增原生证据包括打包 AES/RSA、嵌套规则、Keychain 登录头保存/读回、网页登录、验证码回传与取消、内置样例预览确认，以及导入后重开保留。听书报告仅验证模拟音频状态，未验证实际声音。

IPA 为 arm64、org.moyu.reader、构建 65；IPA/源码 SHA-256 已核对，源码 213 个文件与构建提交逐一匹配。三个 JS 资源和内置样例也已从 IPA 取出核对。模拟器测试身份只用于模拟器，不进入待用户签名的 iPhone IPA。

完整 JVM/Android 类和所有脚本书源仍不保证兼容；本轮公开验证覆盖 55 个站点地址、56 条配置，9 个完整链路通过（5 个脚本源），8 条通用样例见 [扩展实测书源](../Examples/verified-sources-expanded.json)。失败、空搜索及登录限制不算通过。真实网站结果见 SOURCE_VALIDATION.md。
