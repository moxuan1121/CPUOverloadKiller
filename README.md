# AwemeCPUGuard

RootHide 越狱插件：只监控抖音国际/中国版的目标 Bundle ID `com.ss.iphone.ugc.Aweme`。

## 行为

只在抖音位于前台时，使用单一自适应定时器读取目标进程累计的 user + system CPU 时间：CPU 低于阈值的 50% 时每 60 秒采样一次，接近阈值时每 1 秒一次，发现超限后每 0.5 秒一次。抖音进入后台会立即清除采样基线和连续超限计时，不再读取目标 CPU；返回前台时由 SpringBoard 前台应用切换事件唤醒。抖音退出后停止 CPU 采样；保护关闭后定时器完全休眠，由设置变更通知唤醒。

当总 CPU **达到或超过**手动设定的阈值并连续保持设定秒数时，插件会再次确认 PID、可执行文件路径、Bundle ID 和进程启动时间仍属于同一个 Aweme 实例，再发送 `SIGKILL`。CPU 低于阈值时，连续计时立即清零。

监控器运行在 SpringBoard 中；Bundle ID 直接从目标应用包内的 `Info.plist` 校验，不依赖 runningboardd 中可能不可用的 `LSApplicationProxy`。设置页的“当前状态”可显示等待进程、正在监控、超限计时、终止成功以及系统调用失败。

偏好文件使用共享的 `/var/mobile/Library/Preferences` 数据路径，不对该路径调用 `jbroot()`；状态页会显示监控器实际测得的 CPU 和实际生效阈值。

`proc_pid_rusage()`返回的用户态和内核态CPU时间按设备的Mach timebase转换成纳秒后再计算百分比，不使用固定倍率修正。

## 设置

- 启用 CPU 保护
- 总 CPU 上限：1–1000%，默认 80%，支持多核总 CPU 超过 100%
- 连续超标：1–3600 秒，默认 10 秒

没有其它目标选择、AltList 依赖、Throttle 或旧版 per-thread CPU monitor 模式。

## 构建

GitHub Actions 的 macOS-14 工作流构建并验证 RootHide `iphoneos-arm64e` `.deb`，构建产物以 Actions artifact 上传。

## 来源与许可

此项目以 [doimty/vedette](https://github.com/doimty/vedette) 为基础重写精简，遵守其 GPLv3 许可证。
