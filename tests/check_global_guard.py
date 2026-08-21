from pathlib import Path

root = Path(__file__).resolve().parents[1]
core = (root / "GlobalCPUGuard.xm").read_text(encoding="utf-8")
common = (root / "Common.h").read_text(encoding="utf-8")
config = (root / "vedetteprefs/VDTProcessConfiguration.m").read_text(encoding="utf-8")
app_list = (root / "vedetteprefs/VDTApplicationListSubcontrollerController.m").read_text(encoding="utf-8")
daemon_list = (root / "vedetteprefs/ChoicyPreferences/CHPDaemonListController.m").read_text(encoding="utf-8")
root_list = (root / "vedetteprefs/VDTRootListController.m").read_text(encoding="utf-8")
target_cell = (root / "vedetteprefs/GCGTargetCell.m").read_text(encoding="utf-8")

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
assert "启用监控" not in config
assert "低负载采样间隔" in config
assert "刷新当前状态" in config
assert "QOS_CLASS_USER_INITIATED" in app_list and "_loadingApplications" in app_list
assert "_applicationIconImageForBundleIdentifier" in target_cell
assert "NSCache" in target_cell and "iconQueue" in target_cell
assert "UISearch" in (root / "vedetteprefs/ChoicyPreferences/CHPListController.h").read_text(encoding="utf-8")
assert 'setValueForProcessConfigKey(identifier,@"enabled",@YES' in app_list
assert 'setValueForProcessConfigKey(identifier,@"enabled",@YES' in daemon_list
assert "commitEditingStyle" in root_list and '@"enabled",@NO' in root_list
assert "添加进程" in root_list and "UIAlertControllerStyleActionSheet" in root_list
assert "GCGIconPointSize = 28.0" in target_cell
for scale_name in ["GlobalCPUGuard.png", "GlobalCPUGuard@2x.png", "GlobalCPUGuard@3x.png"]:
    assert (root / "vedetteprefs/Resources" / scale_name).is_file(), f"missing icon asset: {scale_name}"
for obsolete_name in ["Vedette.png", "PayPal.png", "Reddit.png", "Twitter.png"]:
    assert not (root / "vedetteprefs/Resources" / obsolete_name).exists(), f"obsolete resource remains: {obsolete_name}"
assert "sqlite" not in core.lower()
assert "HBLog" not in core

print("GlobalCPUGuard structural invariants: OK")
