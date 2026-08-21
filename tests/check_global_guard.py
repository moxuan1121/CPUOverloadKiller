from pathlib import Path

root = Path(__file__).resolve().parents[1]
core = (root / "GlobalCPUGuard.xm").read_text(encoding="utf-8")
common = (root / "Common.h").read_text(encoding="utf-8")
config = (root / "vedetteprefs/VDTProcessConfiguration.m").read_text(encoding="utf-8")
app_list = (root / "vedetteprefs/VDTApplicationListSubcontrollerController.m").read_text(encoding="utf-8")
daemon_list = (root / "vedetteprefs/ChoicyPreferences/CHPDaemonListController.m").read_text(encoding="utf-8")

required_core = [
    "proc_pid_rusage", "mach_timebase_info", "DISPATCH_SOURCE_TYPE_PROC",
    "DISPATCH_PROC_EXIT", "dispatch_source_set_timer", "DISPATCH_TIME_FOREVER",
    "monitorInBackground", "frontmostID", "identity(s)", "kill(s.pid,SIGKILL)",
    "processStartAbsoluteTime", "expectedPath", "bundle_for_path",
]
for item in required_core:
    assert item in core, f"missing core invariant: {item}"

for item in ["launchd", "springboard", "runningboardd", "roothide", "dopamine"]:
    assert item in common.lower(), f"missing protected target: {item}"

assert "后台继续监控" in config
assert "低负载采样间隔" in config
assert "刷新当前状态" in config
assert "_applicationIconImageForBundleIdentifier" in app_list
assert "UISearch" in (root / "vedetteprefs/ChoicyPreferences/CHPListController.h").read_text(encoding="utf-8")
assert "VDTProcessConfiguration" in daemon_list
assert "sqlite" not in core.lower()
assert "HBLog" not in core

print("GlobalCPUGuard structural invariants: OK")
