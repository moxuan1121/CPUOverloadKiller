# AwemeCPUGuard

RootHide 越狱插件：只监控抖音国际/中国版的目标 Bundle ID `com.ss.iphone.ugc.Aweme`。

## 行为

每秒读取目标进程所有线程累计的 user + system CPU 时间，计算整个进程的 CPU 使用率。

当总 CPU **达到或超过**手动设定的阈值并连续保持设定秒数时，插件会再次确认 PID、可执行文件路径、Bundle ID 和进程启动时间仍属于同一个 Aweme 实例，再发送 `SIGKILL`。CPU 低于阈值时，连续计时立即清零。

Bundle ID 直接从目标应用包内的 `Info.plist` 校验，不依赖 runningboardd 中可能不可用的 `LSApplicationProxy`。

## 设置

- 启用 CPU 保护
- 总 CPU 上限：1–1000%，默认 80%，支持多核总 CPU 超过 100%
- 连续超标：1–3600 秒，默认 10 秒

没有其它目标选择、AltList 依赖、Throttle 或旧版 per-thread CPU monitor 模式。

## 构建

GitHub Actions 的 macOS-14 工作流构建并验证 RootHide `iphoneos-arm64e` `.deb`，构建产物以 Actions artifact 上传。

## 来源与许可

此项目以 [doimty/vedette](https://github.com/doimty/vedette) 为基础重写精简，遵守其 GPLv3 许可证。
