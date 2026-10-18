# 用户书源检查记录

检查日期：2026-10-18。此记录仅反映当前开发环境的访问结果，不代表网站永久失效，也不代表已验证 iPhone 网络状况。

| 用户提供的链接 | 当前结果 |
|---|---|
| `https://ghgo.xyz/https://raw.githubusercontent.com/XIU2/Yuedu/master/shuyuan` | 连接超时，未获得 JSON |
| `http://navo.top/MVvUbm` | 返回跳转至 `https://www.yckceo.com/yuedu/shuyuans/json/id/594.json`，随后连接超时 |
| `https://www.yckceo.com/yuedu/shuyuan/json/id/5283.json` | TLS 证书吊销检查服务不可达；浏览器访问亦被客户端阻止，未获得 JSON |
| `http://navo.top/UfaENb` | 返回跳转至 `https://www.yckceo.com/yuedu/shuyuans/json/id/596.json`，随后 TLS 证书吊销检查服务不可达 |
| `https://www.yckceo.com/yuedu/shuyuans/json/id/643.json` | TLS 证书吊销检查服务不可达，未获得 JSON |

另尝试直接访问第一个链接中给出的 GitHub 原始文件地址，也发生连接超时。未跳过证书校验，未取得这些书源内容，因此 **尚不能统计规则兼容性，或宣称搜索、目录、正文读取已通过真实网站验证**。

原始链接保存在 `Examples/booksource-links.txt`，可以复制到 App 的批量导入输入框。导入会逐条请求并报告失败，成功项先预览，再确认保存；失败项不会阻止其他链接继续处理。

## GitHub 连接恢复后的补充检查

随后通过已恢复的 GitHub 连接，成功读取了第一个链接对应的上游 `XIU2/Yuedu` 仓库 `master` 分支中的 `shuyuan` 文件。该次文件含 22 个书源。这里只读取和分析规则，没有将第三方书源内容打包进 App。

- 11 个书源在本应用使用的字段中包含脚本或模板表达式，5 个使用 JSONPath（两组有交叉）。
- 15 个搜索模板使用 POST 或脚本请求。
- 按 GET 与本应用实际使用字段初筛，有 5 个值得进一步验证的 HTML 书源：得奇小说网、快书网、天天看小说、独步小说网、铅笔小说。这只是规则候选，不等于网站可用。
- 为常见旧版索引、下一页文字选择和简单 `//meta[@property='…']/@content` / `//meta[@name='…']/@content` 形状增加了支持及测试；不代表实现了通用 XPath。

对这 5 个候选的搜索页做了有限网络检查：独步小说网返回 HTTP 200，但对测试关键词显示“没找到此书”；其余 4 个在当前网络请求中超时。**真实网站的“搜索 → 目录 → 正文”全链路仍未验证通过**。复杂 JavaScript、登录、验证码和 JSONPath 书源仍不支持。
