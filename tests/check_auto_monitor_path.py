#!/usr/bin/env python3
"""Lock Vedette's roothide auto-monitoring behavior.

App processes report every new PID unconditionally because reading Vedette's
prefs from the App process is unreliable on roothide. The runningboardd
callback must therefore resolve the process and apply configured values or the
legacy fallback without requiring an enabled/config-membership gate. Manual
reload is a separate path and cannot substitute for this callback.
"""

import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = REPO_ROOT / "VDTProcessManager.mm"
FUNCTION_START = "void received_new_proc(pid_t pid){"


def extract_function(text: str) -> str:
    start = text.index(FUNCTION_START)
    depth = 0
    for index in range(start, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
    raise AssertionError("unterminated received_new_proc body")


def fail(message: str) -> None:
    print(f"auto-monitor check failed: {message}", file=sys.stderr)
    sys.exit(1)


def require(body: str, pattern: str, description: str) -> int:
    match = re.search(pattern, body)
    if not match:
        fail(f"missing {description}")
    return match.start()


def main() -> None:
    body = extract_function(SOURCE.read_text())

    require(body, r"if \(pid <= 0\) return;", "invalid-PID guard")
    identity_guard = require(
        body,
        r'@"reason": @"processIdentityUnavailable"',
        "stale process identity guard",
    )
    monitor_call = require(body, r"\bmonitor_pids\s*\(", "automatic monitor call")
    throttle_call = require(body, r"\bthrottle_pids\s*\(", "automatic throttle call")

    if identity_guard > min(monitor_call, throttle_call):
        fail("stale process identity guard runs after a CPU syscall")

    # These tokens identify the 1.1.7 regression: the launch callback returned
    # before applying a policy whenever its prefs lookup did not match.
    forbidden = {
        "processEnabled": "per-process opt-in gate",
        'valueForKeyWithPrefs(@"enabled"': "global opt-in gate",
        'valueForProcessConfigKeyWithPrefs(bundleIdentifier, @"enabled"': "app opt-in lookup",
        'valueForProcessConfigKeyWithPrefs(daemonName, @"enabled"': "daemon opt-in lookup",
        '@"processNotEnabled"': "process-not-enabled early return",
        '@"globallyDisabled"': "global-disabled early return",
    }
    for token, description in forbidden.items():
        if token in body:
            fail(f"{description} blocks the automatic launch path")

    for key in ("percentage", "interval", "violationPolicy"):
        count = body.count(f'@"{key}"')
        if count < 2:
            fail(f"expected app and daemon {key} lookups, found {count}")

    print("received_new_proc automatic monitor path checks passed")


if __name__ == "__main__":
    main()
