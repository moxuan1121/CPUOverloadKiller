# Vedette runningboardd crash fix

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

- Fix ships as `1.1.6` on branch `fix/proc-identity-guard`.
- `1.1.5` is already deployed on device, so the fix must not reuse that version string.

## Status

- [x] Crash artifact and deployed binary matched.
- [x] Root-cause call chain identified.
- [x] Regression check added and observed red (missing implementation, then guard failures).
- [x] Production patch applied.
- [x] Regression check green.
- [x] Local arm64e compile smoke check passed (local package not deliverable: `incompatible arm64e ABI compiler` warnings).
- [ ] Cloud build and artifact verification complete.
- [ ] Device verification complete.
