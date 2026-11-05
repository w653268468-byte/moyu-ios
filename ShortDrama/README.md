# 看短剧 · iOS 首版

SwiftUI + AVKit，iOS 17+，MIT 开源。独立于上级目录的小说阅读器，无广告 SDK、无统计 SDK。

## 构建

在安装 Xcode 的 Mac 上安装 XcodeGen，然后在本目录执行：

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project ShortDrama.xcodeproj -scheme ShortDrama -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
open ShortDrama.xcodeproj
```

真机运行：在 Xcode 的 Signing & Capabilities 中选择自己的开发团队，修改 Bundle Identifier 后选择设备运行。当前未生成签名 IPA。

## 已实现

- HTTPS JSON 订阅、粘贴 JSON、系统文件选择器导入。
- 源内容校验、5 MB 限制、请求超时、失败保留旧数据。
- 按名称搜索已导入的剧集、详情选集、AVPlayer 播放。
- 收藏追剧、上次打开的分集记录、本地原子保存。
- 下拉更新及全部订阅更新，显示每个来源的错误和更新时间。
- 删除来源及相关收藏记录。

## 视频源协议

参见 `example-source.json`。源 URL 返回整个 JSON 目录；刷新时以服务端的新目录替换旧目录，因此剧集 ID、分集 ID 必须保持稳定。视频 URL 要求 HTTPS，内容需为系统播放器支持的 MP4/HLS 等格式。不能把普通网站首页直接当作源 URL。

本地 JSON 是快照，只有链接导入支持在线更新。示例使用保留域名 example.com，仅用于说明结构，不能实际播放。未内置可用短剧内容。

## 红果适配调研

- 候选：https://github.com/xiaoguan521/guoapp
- 2026-11-05 核查远程 HEAD：8a1bb86bda96566d55dcb3af0e10e73f2f8ad571。
- 项目 pubspec 声明了原生红果 GPL 许可证文件，不能未经核查直接复制到本 MIT 项目。
- 本项目没有复制该项目代码，没有接入红果接口，也没有验证红果视频播放。后续需核查源码许可、接口和真实分集播放链路。

## 验证状态与限制

开发环境为 Windows，无 Swift/Xcode，尚未完成编译、模拟器或真机验证。本版本是源码原型，不是可直接安装的成品。

尚未实现：红果及其他专有站点适配、后台自动更新、自动连播、秒级续播、下载、源脚本执行、需要登录或特殊请求头的视频。App 不插入广告，但无法去除视频自身的内嵌广告。

Mac 验收：导入示例检查列表；导入自有可播放 HTTPS 源检查播放；收藏后重启检查持久化；远端新增分集后刷新；断网刷新确认旧列表保留且提示错误；测试重复 ID、非 HTTPS、超过 5 MB 文件；删除源检查收藏同步清理。
