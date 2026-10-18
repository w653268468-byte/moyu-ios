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
