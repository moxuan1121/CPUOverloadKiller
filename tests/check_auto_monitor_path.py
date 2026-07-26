#!/usr/bin/env python3
"""Static contract checks for Vedette's automatic process-monitoring path.

The host C tests cover process identity primitives. These checks cover the
Objective-C wiring that cannot run on the Linux host: every PID must be resolved
against an enabled user config before a CPU syscall, and a target must carry its
own policy/percentage/interval instead of relying on parallel arrays.
"""

from pathlib import Path
import re
import sys

REPO_ROOT = Path(__file__).resolve().parent.parent
MANAGER = (REPO_ROOT / "VDTProcessManager.mm").read_text()
TWEAK = (REPO_ROOT / "Vedette.xm").read_text()
HEADER = (REPO_ROOT / "VDTProcessManager.h").read_text()
DAEMON_INFO = (REPO_ROOT / "vedetteprefs/ChoicyPreferences/CHPDaemonInfo.m").read_text()
DAEMON_LIST = (REPO_ROOT / "vedetteprefs/ChoicyPreferences/CHPDaemonListController.m").read_text()


def fail(message: str) -> None:
    print(f"auto-monitor contract failed: {message}", file=sys.stderr)
    sys.exit(1)


def extract_function(text: str, signature: str) -> str:
    start = text.find(signature)
    if start < 0:
        fail(f"missing function {signature}")

    opening = text.find("{", start)
    if opening < 0:
        fail(f"missing body for {signature}")

    depth = 0
    for index in range(opening, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]

    fail(f"unterminated function {signature}")
    raise AssertionError("unreachable")


def require(text: str, pattern: str, description: str) -> int:
    match = re.search(pattern, text, re.DOTALL)
    if not match:
        fail(f"missing {description}")
    return match.start()


def forbid(text: str, token: str, description: str) -> None:
    if token in text:
        fail(f"found {description}: {token}")


def check_new_process_gate() -> None:
    body = extract_function(MANAGER, "void received_new_proc(pid_t pid)")

    require(body, r"if\s*\(pid\s*<=\s*0\)\s*return", "invalid-PID guard")
    prefs = require(body, r"VDTGetPrefs\s*\(\s*\)", "runningboardd prefs snapshot")
    configs = require(body, r"vdt_configs_from_prefs\s*\(", "typed config normalisation")
    resolve = require(body, r"vdt_targets_for_pid\s*\(", "single-PID config resolution")
    no_match = require(
        body,
        r"if\s*\(targets\.count\s*==\s*0\).*?@\"notConfigured\".*?return\s*;",
        "unconfigured-process early return",
    )
    disabled = require(
        body,
        r"if\s*\(\[target\[VDTConfigPolicyKey\]\s+unsignedLongValue\]\s*==\s*VDTViolationPolicyNone\).*?@\"configuredButDisabled\".*?return\s*;",
        "disabled-config early return",
    )
    apply_call = require(body, r"vdt_apply_targets\s*\(targets\)", "target application")

    if not (prefs < configs < resolve < no_match < disabled < apply_call):
        fail("config resolution or skip guards are ordered after application")

    # The callback must not recreate the old implicit 80/120 fatal fallback.
    for token in ("proc_set_cpumon_params_fatal", "proc_setcpu_percentage", "@80", "@120"):
        forbid(body, token, "direct/default CPU policy in received_new_proc")


def check_target_binding() -> None:
    target_body = extract_function(MANAGER, "static NSDictionary *target_for_pid")
    apply_body = extract_function(MANAGER, "void vdt_apply_targets")

    require(target_body, r"VDTTargetPidKey\s*:\s*@\(pid\)", "PID stored in target")
    require(
        target_body,
        r"target\[VDTTargetExecutablePathKey\]\s*=\s*executablePath",
        "resolved executable path bound to target",
    )
    identity_guard = require(
        apply_body,
        r"if\s*\(!target_identity_is_current\(target,\s*pid\)\).*?continue\s*;",
        "pre-syscall target identity revalidation",
    )
    first_cpu_syscall = min(
        require(apply_body, r"proc_setcpu_percentage\s*\(", "throttle syscall"),
        require(apply_body, r"proc_set_cpumon_params_fatal\s*\(", "fatal-monitor syscall"),
        require(apply_body, r"proc_clear_cpulimits\s*\(", "CPU-limit clear syscall"),
    )
    if identity_guard > first_cpu_syscall:
        fail("target identity is revalidated after a CPU syscall")

    for key in ("VDTConfigPercentageKey", "VDTConfigIntervalKey", "VDTConfigPolicyKey"):
        require(target_body, rf"{key}\s*:", f"{key} stored in target")
        require(apply_body, rf"target\s*\[\s*{key}\s*\]", f"{key} read from the same target")

    # M10 regression guard: the target's percentage/interval/policy must come
    # from the matched config dictionary, not from a hardcoded literal.
    require(
        target_body,
        r"NSNumber\s*\*percentage\s*=\s*enabled\s*\?\s*vdt_number\(matched\[VDTConfigPercentageKey\]\)\s*:\s*@0",
        "target percentage sourced from matched config (not hardcoded)",
    )
    require(
        target_body,
        r"NSNumber\s*\*interval\s*=\s*enabled\s*\?\s*vdt_number\(matched\[VDTConfigIntervalKey\]\)\s*:\s*@0",
        "target interval sourced from matched config (not hardcoded)",
    )
    require(
        target_body,
        r"NSNumber\s*\*policy\s*=\s*enabled\s*\?\s*vdt_number\(matched\[VDTConfigPolicyKey\]\)\s*:\s*@\(VDTViolationPolicyNone\)",
        "target policy sourced from matched config (not hardcoded)",
    )

    # Policy changes must retire the previous policy before applying the new one.
    require(
        apply_body,
        r"if\s*\(policy\s*==\s*VDTViolationPolicyThrottle.*?proc_disable_cpumon\(pid\).*?proc_set_cpumon_defaults\(pid\).*?proc_resume_cpumon\(pid\).*?proc_setcpu_percentage\(pid",
        "fatal monitor cleared before throttle",
    )
    require(
        apply_body,
        r"if\s*\(policy\s*==\s*VDTViolationPolicyMonitorAndTerminate.*?proc_clear_cpulimits\(pid\).*?proc_disable_cpumon\(pid\).*?proc_set_cpumon_params_fatal\(pid",
        "throttle cleared before fatal monitor",
    )
    require(
        apply_body,
        r"Restore path:.*?proc_clear_cpulimits\(pid\).*?proc_disable_cpumon\(pid\).*?proc_set_cpumon_defaults\(pid\).*?proc_resume_cpumon\(pid\)",
        "all Vedette CPU policies cleared on restore",
    )

    require(target_body, r"VDTCopyLastPathComponent\s*\(", "full executable-name derivation")
    require(target_body, r"VDTProcessNameMatches\s*\(", "daemon identity comparison")
    require(
        DAEMON_INFO,
        r"return\s+\[self\.executablePath\s+lastPathComponent\]",
        "preference-side full executable name",
    )
    require(
        DAEMON_LIST,
        r"setProperty:\[info\s+displayName\]\s+forKey:@\"daemonName\"",
        "stored daemon-name source",
    )

    combined = MANAGER + TWEAK + HEADER
    for token in (
        "pids_with_identifier_and_type",
        "monitor_pids",
        "throttle_pids",
        "objectsAtIndexes",
    ):
        forbid(combined, token, "parallel-array monitor API")


def check_process_scan_and_plist_guards() -> None:
    scan_body = extract_function(MANAGER, "NSArray<NSDictionary *>* vdt_resolve_targets")
    require(scan_body, r"if\s*\(listBytes\s*<=\s*0\)\s*return", "proc_listpids size guard")
    require(scan_body, r"if\s*\(!buffer\)\s*return", "PID buffer allocation guard")
    require(
        scan_body,
        r"pidCount\s*=\s*writtenBytes\s*/\s*\(int\)sizeof\(int\)",
        "byte-count to PID-count conversion",
    )
    require(scan_body, r"idx\s*<\s*pidCount", "PID-count loop bound")

    for helper in ("vdt_array", "vdt_dictionary", "vdt_nonEmptyString"):
        require(MANAGER, rf"static\s+.*?\b{helper}\s*\(", f"plist guard {helper}")

    identity_body = extract_function(MANAGER, "static BOOL target_identity_is_current")
    require(identity_body, r"executable_path_for_pid\s*\(", "full-path identity re-read")
    require(identity_body, r"isEqualToString:expectedPath", "full-path identity equality")

    require(
        MANAGER,
        r"globallyEnabled\s*&&\s*vdt_bool\(entry\[@\"enabled\"\],\s*NO\)\s*&&\s*parametersValid",
        "global, per-process and valid-parameter opt-in folding",
    )
    require(
        MANAGER,
        r"if\s*\(!value\)\s*\{\s*\*outValue\s*=\s*defaultValue;\s*return\s+YES;",
        "defaults only for absent numeric preference values",
    )
    require(
        MANAGER,
        r"if\s*\(!\[scanner\s+scanLongLong:&parsed\]\s*\|\|\s*!scanner\.isAtEnd\)\s*return\s+NO",
        "strict numeric-string parsing",
    )
    require(
        MANAGER,
        r"CFGetTypeID\(\(__bridge\s+CFTypeRef\)number\)\s*==\s*CFBooleanGetTypeID\(\)",
        "boolean rejected as numeric parameter",
    )
    require(
        MANAGER,
        r"!isfinite\(numericValue\)\s*\|\|\s*numericValue\s*!=\s*\(double\)parsed",
        "fractional and non-finite numeric rejection",
    )
    require(
        MANAGER,
        r"parametersValid\s*=\s*percentageValid\s*&&\s*percentage\s*>\s*0\s*&&\s*policyValid",
        "non-positive or malformed parameter rejection",
    )


def check_callback_serialisation() -> None:
    require(
        TWEAK,
        r"dispatch_async\(vedette_serial_queue\(\),\s*\^\{\s*received_new_proc",
        "serialised new-process callback",
    )
    forbid(TWEAK, "(CFNotificationCallback)reloadPrefs", "invalid CF callback cast")
    forbid(TWEAK, "(CFNotificationCallback)restoreAllMonitors", "invalid CF callback cast")
    require(TWEAK, r"prefsChangedCallback", "typed prefs callback")
    require(TWEAK, r"restoreAllMonitorsCallback", "typed restore callback")


def main() -> None:
    check_new_process_gate()
    check_target_binding()
    check_process_scan_and_plist_guards()
    check_callback_serialisation()
    print("automatic monitor contract checks passed")


if __name__ == "__main__":
    main()
