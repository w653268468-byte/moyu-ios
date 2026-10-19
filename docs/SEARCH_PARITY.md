# 搜索改版验收

对照目标为 Android 阅读的搜索流程；参考其公开的 [SearchViewModel](https://github.com/LegadoTeam/legado/blob/master/app/src/main/java/io/legado/app/ui/book/search/SearchViewModel.kt) 和 [JavaScript 接口说明](https://github.com/LegadoTeam/legado/blob/master/app/src/main/assets/web/help/md/jsHelp.md)。本工程使用独立 Swift 实现，不复制 Android 源码。列表不是“九成完成”的统计依据。

- 搜索框直接输入书名/作者，提交后收起键盘；搜索中可提交新词，旧任务结果不得污染新查询。
- 全部已启用、分组、指定书源；搜索规则单独检查，正文规则不兼容不应禁止搜索。
- 渐进结果、可配置并发和单源等待、停止后保留结果并继续未完成书源。
- 同名同作者聚合，保留每个来源；不同作者及未知作者不自动混合。
- 相关度、书源数、书名、搜索耗时及返回顺序排序；书名/作者及精准筛选。
- 书源各自分页、重复页停止、失败页单源/批量重试，重试不能丢失其他未完成任务。
- 搜索历史最多 30 项、去重、删除、清空及关闭记录；历史和配置纳入备份。
- 显示可提取的封面、作者、分类、字数、最新章节、简介、书源及书架标记。
- 公共脚本库跨规则共享，普通规则的 let/const 使用局部作用域；java.put/get 显式持久化。

自动检查：核心测试覆盖聚合边界、精准筛选、排序、历史、并发与超时；XCUITest 覆盖多源搜索→聚合→选择来源→加载下一页→重启后的历史。模拟网页只证明 App 行为；真实网站、复杂 Java/Android 桥、验证码和各站目录/正文必须另行验证。尚未完成完整 Android 运行环境，也不保证任意源可用。
