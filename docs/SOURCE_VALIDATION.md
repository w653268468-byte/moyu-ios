# 真实书源验证记录

更新时间：2026-10-20（北京时间）。测试使用公开网页与公开规则，不复用合集内个人登录会话。

构建提交 `10df7f3fec2556779fef314e351602c826727808` 的 [真实书源审计第 5 次](https://github.com/w653268468-byte/moyu-ios/actions/runs/39287245807)完成 32 个独立域名的抽样。3 个通过、26 个失败、2 个需本人登录、1 个当时缺少 WebView 运行环境。审计任务本身成功不代表网站都成功。

| 书源 | 搜索词 / 选中书籍 | 目录章数 | 取得正文字数 | 脚本规则 |
| --- | --- | ---: | ---: | --- |
| 奇异网（qsyz.net） | 三国演义 / 三国演义 | 120 | 4747 | 是 |
| 笔趣阁⁵（bixiange.top） | 三国演义 / 萌娘三国演义 | 883 | 2668 | 否 |
| 神话之后（shenhuazhihou.com） | 三国演义 / 三国演义 | 120 | 4739 | 否 |

可导入规则在 [Examples/verified-sources.json](../Examples/verified-sources.json)，保留原作者信息及规则。规则来源为 [52liulian/yuanc 所列公开合集](https://github.com/52liulian/yuanc/blob/main/data/legado/books.json)中的 yckceo 与 tickmao/Novel；导出前逐一比对本地合集与云端报告的 SHA-256，二者一致。此文件只表示上述样本在相应时间、网络、ReaderCore 提交下通过；不保证站点今后不变，也不等于新安装包已通过全部 iOS 检查。

复现过程：先运行 scripts/fetch_source_corpus.py，设置 GAVIN_SOURCE_AUDIT=1 执行 SourceCorpusAuditTests。按来源集合、脚本/静态类型和域名抽样，以作者 checkKeyWord 或通用书名搜索，优先同名书，取得目录后读取首章，正文至少 50 字。每个源有 45 秒总预算，最多 3 源并发。原始结果与下载来源哈希在对应工作流的 Gavin-real-source-audit 工件。

已确认的失败原因与修复：

- leeyegy 返回域名广告跳转，kuaishu5 返回 ParkLogic 停放页，二者当前响应不是小说数据；增加响应诊断，不能通过补 JSONPath 让已停放域名恢复。
- 神话之后的“下一”会跳到下一章，现用目录边界停止本章分页；第 5 次审计已取得完整首章。
- 奇异网搜索先给出无目录的衍生作品，改为优先同名书后取得 120 章目录及正文。
- 多数 HTTP 403、域名失效、空搜索结果仍待逐项核对；空结果不直接认定解析器有错，也不标记为可用。

详情转换 init、CSS 属性中的 @、RSA 错误密钥拒绝、JavaImporter、交互式登录/验证码和动态 WebKit 审计的新增回归状态见 [SOURCE_COMPATIBILITY.md](SOURCE_COMPATIBILITY.md)。只以实际测试结果更新完成状态。
