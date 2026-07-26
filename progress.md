# Vedette runningboardd crash fix + monitor opt-in gate

## Baseline

- Branch/worktree: `main`, HEAD `7b35db8`, clean for tracked files; existing untracked Chinese localization files are user work and must remain untouched.
- Device crash artifact: `runningboardd-2026-07-24-213604.ips`.
- Loaded Vedette arm64e UUID: `4F783AF6-2147-312F-9626-914D1F21201C`.
- UUID matches cloud-delivered `com.udevs.vedette_1.1.5_iphoneos-arm64e.deb` in `/tmp/vedette-release/`.
- Crash chain: `+[NSURL fileURLWithPath:]` -> Vedette -> `received_new_proc+84`.
- Source path: `VDTProcessManager.mm::appproxy_from_pid` ignores `proc_pidpath()` failure and converts an unvalidated buffer to NSString/NSURL.

## Hypothesis

A process posts its PID and exits before runningboardd handles the Darwin notification. `proc_pidpath()` then returns 0. Vedette still constructs a bundle path and calls `fileURLWithPath:`, raising an Objective-C exception in runningboardd.

## Success criteria

- PID path resolution rejects invalid PID, `proc_pidpath <= 0`, non-NUL/invalid UTF-8 data, and empty parent path without calling NSURL.
- PID name resolution rejects failed/empty results.
- `received_new_proc` skips a PID when neither a valid application proxy nor daemon name can be resolved.
- Valid app and daemon paths retain existing monitoring behavior.
- Regression checks pass, cloud roothide build succeeds on pinned Xcode 15.4 / system iPhoneOS 17.5 SDK, package is arm64e, and cloud logs contain no `incompatible arm64e` warning.

## Independent failure signals

- A failed `proc_pidpath()` can still reach `fileURLWithPath:`.
- An unresolved PID can still reach config lookup or CPU monitor syscalls.
- Valid process resolution is accidentally skipped.
- Cloud build uses a floating Xcode/SDK, emits chained fixups unexpectedly, or logs an incompatible arm64e ABI warning.

## Evidence plan

1. Match crash UUID to delivered binary.
2. Add/run a source-level regression checker for all required guards and ordering.
3. Compile/package in GitHub Actions with pinned toolchain.
4. Inspect nonempty cloud logs, package metadata, Mach-O UUID/arch/load commands, and forbidden warning strings.
5. Device verification remains the final runtime signal.

## Release

- `1.1.6`: crash fix on branch `fix/proc-identity-guard`.
- `1.1.7`: withdrawn. The added prefs opt-in gates regressed roothide automatic monitoring;
  manual reload still worked, but newly launched processes were not guarded.
- `1.1.8`: restores the exact 1.1.5 automatic-launch semantics while retaining all 1.1.6
  stale-PID/path crash guards.
- `1.1.5` is already deployed on device, so no fix may reuse that version string.

## Corrected diagnosis: automatic launch path

- `f227e2e` intentionally made App processes self-report every PID without reading prefs,
  because App-process prefs reads are unreliable on roothide. The runningboardd callback is
  the automatic guard path; `reloadPrefsSync` is the manual/config-reload path.
- The 1.1.7 review incorrectly treated the absence of `enabled` gates in
  `received_new_proc` as a proven defect. That was a code-level risk hypothesis without a
  device reproduction. Adding the gates made the automatic path depend on a successful
  config match and reproduced the old 1.1.4 symptom.
- Device evidence: on 1.1.7, newly launched processes were not guarded, while manual trigger
  remained effective. This isolates the regression to the new-process callback, not the CPU
  syscalls, process scanner, or stored limits.
- 1.1.8 removes only the 1.1.7 prefs/global/per-process gates. It retains PID <= 0 rejection,
  validated `proc_pidpath`/`proc_name`, empty-path checks, and identity-unavailable early exit.
- `tests/check_auto_monitor_path.py` is red on 1.1.7 (`per-process opt-in gate blocks the
  automatic launch path`) and green after the rollback. The incorrect
  `tests/check_monitor_gates.py` has been deleted.
- Do not redesign global/per-process launch semantics again without targeted on-device
  telemetry proving both the config source and desired behavior.

## Reviewed and intentionally not changed

- `VDTProbeRecord` remains active in release builds and costs an extra `proc_name` call per
  monitored PID. Cosmetic overhead, not a correctness issue; out of scope for this fix.
- `malloc(0)` when `proc_listpids` returns 0 in `pids_with_identifier_and_type` is safe here
  because `free(NULL)` is defined and the loop body never executes.
- The App branch now keys on `bundleIdentifier.length > 0` instead of a nil check, so an empty
  bundle identifier falls through to daemon-name matching. Intentional: an empty identifier
  can never match a stored app config.

## Status

- [x] Crash artifact and deployed binary matched.
- [x] Root-cause call chain identified.
- [x] Regression check added and observed red (missing implementation, then guard failures).
- [x] Production patch applied.
- [x] Regression check green.
- [x] Local arm64e compile smoke check passed (local package not deliverable: `incompatible arm64e ABI compiler` warnings).
- [x] 1.1.8 cloud build and artifact verification complete.
- [ ] 1.1.8 device verification complete.

## 1.1.8 cloud evidence

- Successful run: `30190940314` at source commit `7e68d189abe55549e811b7e206b774c1218e290b`.
- Package: `com.udevs.vedette_1.1.8_iphoneos-arm64e.deb`.
- SHA256: `39753b7d44eb6d4857f810bc16298ea797c5edebead06bc3c3cf3fec100c606a`.
- SHA512: `4b938d0472cc5bb2d68ab871843edd509e60245385d33de5cd86595fd554c98af68179121156fdeea9c1383305637fe4bf32fda1251ad954361284ab18bf64a3`.
- Both host checks passed in CI; actual build output contains no incompatible arm64e warning.
- `Vedette.dylib` and `VedettePrefs` both contain arm64 and arm64e slices.
- Shipped `Vedette.dylib` retains `_VDTCopyProcessInfoString` and
  `processIdentityUnavailable`; 1.1.7 markers `prefsUnavailable`, `globallyDisabled`, and
  `processNotEnabled` are absent.
- The shipped source blobs match the locally reviewed files; the incorrect gate test is
  absent remotely.
- `received_new_proc` matches the 1.1.6 implementation except for comments/whitespace, so
  this is specifically 1.1.5/1.1.6 auto-monitor behavior plus the stale-PID crash guard.

## 1.1.6 cloud evidence

- Successful run: `30184288005` at source commit `131b9b63cdcd126820eb09d77f180fc1fdf68371`.
- Toolchain: macOS 14 runner, Xcode 15.4 (15F31d), Apple clang 15.0.0, system iPhoneOS SDK 17.5; the project intentionally compiles against the pinned Theos iPhoneOS16.5 SDK.
- Host regression test passed in CI.
- Package: `com.udevs.vedette_1.1.6_iphoneos-arm64e.deb`.
- SHA256: `314e4fd870c4ebfc4c61eb7cb9d2800075f74c7f5e1bdfb7534bba6b0ce935ef`.
- SHA512: `3aff039e74b8461b11197754108137cd8f42ba17a408c18f38aee9a9720afaa3007d9ce06f80820dffa490a6f3dbd77471bda6c45c399ba3054747ab1264494d`.
- `Vedette.dylib` architectures: arm64 and arm64e; arm64e UUID `65D241A3-D14B-3A72-824A-FA8353D5CB41`.
- `VedettePrefs` architectures: arm64 and arm64e.
- Actual build output contains no `incompatible arm64e ABI compiler` warning.
- Mach-O uses `LC_DYLD_CHAINED_FIXUPS`, matching the validated, deployed 1.1.5 baseline.
- Extracted plists and package control scripts pass syntax validation; remote source blobs match the locally reviewed files.
