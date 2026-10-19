第 61 次原生检查已通过：打包脚本 AES/RSA、嵌套提取、Keychain 登录头写入/读回、源导入/重定向/保存重开、动态 WebView，以及实际点击的网页登录、验证码回传和取消。6 项界面测试中 5 项通过；导入预览项因先前样例占用列表首屏而未找到离屏行，已改为滚动查找，须经新构建验证后发布。第 61 次未发布安装包。

公开合集扩测发现并修复两处真实兼容问题：格格党 `<js>` 前置动作后的字面 POST 网址，以及笔趣阁属性正则内 `https?://` 被误判 XPath。新增对应回归，专项检查已通过。链路校验进一步优先读取编号章节，避免长感谢词或人物资料被当成故事正文；不修改原书目录。

最新验证：提交 `7b28abb4c4c78f0c0732604b5fb136e618976e42` 的 56 项专项回归通过，覆盖 Hutool gzip 的独立已知向量、OkHttp 压缩请求、JavaImporter/Cipher、RSA/OpenSSL 对照、尾部 @put、脚本内模板和共享链路校验器。32 个真实域名有 4 个通过搜索→目录→正文（2 个脚本源），详见 SOURCE_VALIDATION.md。iOS 原生集成仍以最新安装包检查结果为准。

模拟器权限校验读取可执行文件的 `__TEXT,__entitlements`：Xcode 日志确认这些是模拟运行身份，ad-hoc codesign 的权限字典可以为空；签名完整性仍另行检查，Keychain 实际保存与读回也保留在原生导入检查中。iPhone 目标不注入模拟器测试身份。

# 复杂书源与真实网站专项

当前任务仅处理书源兼容和真实搜索→目录→正文；书架、排版、听书等其他功能暂停迭代。

App 内“校验书源”和云端审计现共用 SourceValidator，统一作者测试词、同名书优先、前三章短序言处理、200 字正文门槛与 45 秒总预算，修复 App 仅拿到短提示文字也报通过的问题。新增真实请求通道的通过/拒绝回归。

第 50/51 次原生检查阻止发布：未签名模拟器 App 的 Keychain 调用返回 -34018，设备日志确认缺少 application-identifier/keychain-access-groups。仅对 iphonesimulator 使用专用测试身份的临时签名，并检查最终签名权限；真实 iPhone IPA 仍为待用户签名的未签名包，不带模拟器测试身份。钥匙串检查及保密存储保留，未降级明文。

为公开脚本实际导入的 Hutool/OkHttp 包补充显式适配：Base64、摘要/HMac、StrUtil/CharsetUtil、ZipUtil gzip、Request/RequestBody/MediaType/OkHttpClient 的同步 GET/POST 构建和响应。压缩走系统 zlib，二进制请求不经 UTF-8 损坏；继续使用同一受限网络通道、请求头校验和取消机制。此为接口子集，不支持任意 JVM、拦截器、文件或线程；新增 Node 对照及 Swift 网络回归待确认。

iOS 构建恢复使用第 46 次已成功的 macos-15 Apple Silicon 环境。Intel 临时替代环境的第 47 次任务耗尽 35 分钟，不能把容量排队问题改成长期超时；保留 Xcode 16.4 固定工具链及架构自适应的模拟器 Swift/WebKit 路径。

按旧 JSON 书源中的实际写法补充尾部 @put、脚本内选择器模板、脚本结果接字面网址模板（同时保留原 JSON 选择器作用域）；脚本标记识别避开引号与模板内部，JS 正则中的未闭合字面 {{ 不误当模板。新增独立的规则回归，尚待云端确认。

第 52 次审计已实际使用 WebView 检查动态源；32 个域名有 4 个完整链路通过，其中“错层小说网”只取得 82 字，未加入推荐样例，仍需排查是否为提示/占位正文。“天天小说 ttk.tw”的 TypeError 已定位为 connect 响应缺少 raw().request().url()；补充该响应链与对应回归。当前通过数不视为兼容工作已完成。

动态请求头同样应用于脚本 ajax/get/post 与共享脚本下载；搜索头获得实际 key/page，嵌套请求模板保存并恢复外层 key/page/result，嵌套设置全局变量不得重置外层执行预算。增加动态头与嵌套请求回归。

第 50 次提交对应的审计已取得 3/32 个完整链路，通过的规则及精确记录在 SOURCE_VALIDATION.md 与 Examples/verified-sources.json。新增近期维护的 cjj200011222/legado-booksource 公开集合，并给 macOS 审计接入独立、临时 Cookie 存储的 WKWebView：动态源不再仅因命令行缺少浏览器而跳过，报告标记 usedWebView；交互式登录仍须用户在 App 内完成。

公开样本中 14 个源使用 JavaImporter，22 处调用 toNumChapter。新增显式 Java 兼容包：JavaImporter、SecretKeySpec/IvParameterSpec、Cipher、RSA KeyFactory/EncodedKeySpec、Signature、MessageDigest、Base64、Arrays、ByteArrayOutputStream、String 字节构造和中文章节数字；只实现列出的接口，不暴露任意 Java/Android 类。Node 中使用真实 JavaImporter/with 解密流程对照独立 OpenSSL AES 结果，Swift/iOS 与 RSA 向量检查另行验证；OkHttp、Hutool、字体反混淆等尚需真实案例适配。

第 49 次真实集合抽样已生成报告：32 个域名中 1 个通过完整链路，2 个需本人登录，1 个需 WebView，其余有网络、网站响应和兼容问题；不能把审计任务绿色当作 32 个源均可用。本地复核确认 leeyegy 返回域名广告跳转、kuaishu5 返回 ParkLogic 页面，增加网站响应诊断。qsyz 搜索同时返回衍生作品与原作，审计优先选同名书，并可先用作者提供的 checkKeyWord。

针对真实神话之后书源，正文“下一”会继续跳到下一章：目录现在保存下一章边界，正文分页只合并本章页面，不把后续章节不断拼入。新增边界持久化回归。详情 init 的返回结果现在成为后续元数据与目录解析输入，修正仅执行脚本却丢弃转换结果的问题。第 48 次检查发现 CSS 属性中的 @ 在二次转换被拆分，及系统 RSA PKCS1 解密的错误密钥未可靠拒绝，已分别修正分隔和增加原始块填充校验；待新检查确认。

审计集合也包含 52liulian/yuanc 的 books.json 所列 yckceo 和 tickmao/Novel 地址。集合介绍中的“实时可用”等描述不作为验证结果；下载、解析与真实网站链路分别记录。

java.webView 桥接已接入现有 WebKit 渲染器，支持提供 HTML、基准 URL、提取脚本和缓存优先选项，并共享 Cookie 与源登录头。后台脚本等待可取消，主线程不得同步等待；未配备 WebKit 的命令行审计标为 requires_webview，不能计入通过。原生 Cookie 检查同时验证动态请求选项和 java.webView 调用。

交互式 startBrowserAwait 与 getVerificationCode 已接入原生验证窗口：显示网站或验证码，完成后把 Cookie、页面或输入结果回传原任务；支持取消与 180 秒等待上限，同时出现的验证窗口串行展示。默认验证后重新请求原地址，refetchAfterSuccess=false 返回当前页面。补充单元检查及真实按钮输入/取消的 XCUITest；这些新增 Swift/iOS 检查仍待云端执行，未标记为已通过。命令行无交互窗口时记录 requires_login。

共享脚本 importScript/cacheFile 支持 HTTP/HTTPS 下载与按源持久缓存、有效期、响应大小限制；不自动执行脚本文本。源静态头也应用到脚本网络请求。get/post 保留 3xx 响应，connect/ajax 跟随重定向；响应支持 header、headers().get 和 statusCode。下载私有本地路径、任意 Android 类、字体反混淆等仍需按真实案例补齐，不能宣称任意 Java API 都可运行。

HTTP 兼容：get/post/connect 可读取非 2xx 响应的状态与正文；ajax 保留明确 HTTP 失败。书源显式配置的 Authorization/Cookie 和请求选项头按源请求应用，Host 不允许覆盖，头部值经过换行检查；source 登录头保存在本机钥匙串并复用到该源后续请求。采样任务使用与 App 相同的浏览器 User-Agent 和 60 秒下载预算，超过 20 MB 的合集单独记录为导入限制。

本轮接入固定版本 CryptoJS 4.2.0 和独立实现的 Legado 适配层，补充 AES/DES/TripleDES、字节编码、source/book/chapter 变量、按源隔离的限额缓存及 Cookie 辅助接口；支持嵌套 getString/getElements，保存并恢复外层脚本状态，嵌套不能重新获得执行预算。所有新增项须通过 Swift/iOS 检查后才能认定集成通过，RSA 和其余 Android 平台接口另行补齐。

RSA 适配已进入测试：基于系统 Security，接入 PKCS#1/PKCS#8/SPKI 密钥、PKCS#1/NoPadding/OAEP、分块加解密与 MD5/SHA 系列 RSA 签名验签；默认公钥/私钥选择与 Android 接口保持一致。独立 Node/OpenSSL 测试密钥及密文仅用于回归，不用于实际账号。尚未通过云端检查前不标记为已完成。

HTML 索引增加闭区间、反向/步长、逗号并集、排除和旧式多索引；链式选择中每个父元素独立应用索引，带引号/方括号的 CSS 属性中的 `@` 不再被误拆。与 JSONPath 的区间语义分别处理。原生 App 导入检查会加载打包的脚本资源并运行 AES、RSA、嵌套提取与钥匙串登录头检查。

真实网站审计使用 `scripts/fetch_source_corpus.py` 下载公开合集，包括用户 yiove 合集、XIU2/Yuedu 及 aoaostar/legado 发布的多个合集。记录下载地址、重定向地址、SHA-256 和条目数；规则不内置到 App。按独立域名、不同集合和脚本/静态规则分层抽样，最多 3 源并发、每源完整链路 45 秒预算，阶段之间间隔 500 ms。每个样本记录搜索、目录、正文阶段与错误分类。

只有真实搜索得到书籍、解析到目录并取得至少 200 字正文才记为完整链路通过。合集导入、规则识别、审计任务执行成功均不等于网站通过。登录/验证码、限速、域名失效和解析器缺口分别记录；不跳过 TLS 证书校验，不代替用户完成网站验证。

审计跳过作者明确禁用的规则；对公开合集内硬编码的个人登录会话 Cookie 不予复用，记录为需要本人登录。普通无账号公开请求和书源自带的非会话配置照常检查。

原始网站会变化，审计结果只说明对应时间、网络和选定书籍的读取情况。报告作为 `Gavin-real-source-audit` 工件保存，不以“所有书源永远可用”为完成声明。
