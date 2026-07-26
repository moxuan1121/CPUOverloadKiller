#!/usr/bin/env python3
"""Structural regression check for received_new_proc opt-in gates.

Processes self-report their PID unconditionally from Vedette.xm, so
received_new_proc is the only place that decides whether a process opted in.
If any CPU syscall can be reached before the enabled gates, an unconfigured
process gets a fatal CPU monitor. That regression is invisible at compile time,
so assert the structure here.
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
    print(f"gate check failed: {message}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    text = SOURCE.read_text()
    body = extract_function(text)

    def position(pattern: str) -> int:
        match = re.search(pattern, body)
        if not match:
            fail(f"missing required guard: {pattern}")
        return match.start()

    prefs_guard = position(r"if \(!localPrefs\)")
    global_gate = position(r"if \(!enabled\)")
    process_gate = position(r"if \(!processEnabled\)")

    # PIDs can arrive before the async prefs snapshot is published, so the
    # handler must fall back to a direct read instead of silently skipping.
    position(r"VDTGetPrefs\(\) \?: getPrefs\(\)")

    syscall_positions = [
        match.start()
        for match in re.finditer(r"\b(monitor_pids|throttle_pids)\s*\(", body)
    ]
    if not syscall_positions:
        fail("no monitor_pids/throttle_pids call found; check is stale")

    first_syscall = min(syscall_positions)

    for label, offset in (
        ("prefs availability", prefs_guard),
        ("global enabled", global_gate),
        ("per-process enabled", process_gate),
    ):
        if offset > first_syscall:
            fail(f"{label} gate runs after a CPU syscall")

    # Each gate must bail out rather than fall through.
    for label, offset in (
        ("prefs availability", prefs_guard),
        ("global enabled", global_gate),
        ("per-process enabled", process_gate),
    ):
        block = body[offset:first_syscall]
        if "return;" not in block:
            fail(f"{label} gate does not return early")

    # processEnabled must default to a deny value.
    if not re.search(r"BOOL processEnabled = NO;", body):
        fail("processEnabled must default to NO")

    # Both identity branches must read the per-process enabled key.
    enabled_reads = re.findall(r"valueForProcessConfigKeyWithPrefs\([^;]*?@\"enabled\"", body)
    if len(enabled_reads) != 2:
        fail(
            "expected exactly one per-process enabled read per identity branch, "
            f"found {len(enabled_reads)}"
        )

    print("received_new_proc gate checks passed")


if __name__ == "__main__":
    main()
