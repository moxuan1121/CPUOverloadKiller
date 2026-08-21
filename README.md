# CPUOverloadKiller

面向 iOS 15、Dopamine、RootHide 和 arm64e 的轻量全局 CPU 超限终止工具。

## 功能

- 用户从可搜索列表中明确选择并启用应用或守护程序，不依赖 AltList。
- 应用显示系统图标；每个应用默认只在前台监控，也可独立开启后台继续监控。
- 守护程序只要进程运行且配置已启用就持续监控。
- 每个目标独立设置 CPU 阈值、连续超限时间和低负载采样间隔。
- 低于阈值 50% 时使用低负载间隔，接近阈值时每 1 秒采样，超限后每 0.5 秒采样。
- 目标共用一个串行队列和动态定时器；全部目标都处于长间隔时不会固定高频唤醒。
- PID 退出由进程事件立即清理；重新启动后自动发现并建立新基线。
- `SIGKILL` 前重新核对 PID、启动时间、可执行路径以及 Bundle ID 或 daemon name，防止 PID reuse。
- launchd、SpringBoard、backboardd、runningboardd、kernel_task、installd、jailbreakd 及 RootHide/Dopamine 核心目标禁止启用。
- 不保存历史、不绘图、不使用数据库、不进行高频日志输出。

## 构建

GitHub Actions 使用 RootHide Theos 构建并验证 `iphoneos-arm64e` 软件包。
