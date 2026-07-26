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
- Cloud build uses a floating Xcode/SDK, loses the device-validated chained-fixups load-command shape, or logs an incompatible arm64e ABI warning.

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
- `1.1.8`: restored the 1.1.5 automatic-launch behavior while retaining the 1.1.6
  stale-PID/path crash guards, but still applied fallback limits to unconfigured PIDs.
- `1.1.9`: exact-config redesign. Unconfigured or invalid targets are skipped; each
  configured target carries and applies only its own validated policy and parameters.
- Released or cloud-built version strings are not reused.

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
- The old `pids_with_identifier_and_type` allocation and parallel-array path is superseded.
  The replacement treats both `proc_listpids` return values as byte counts and derives the
  loop bound with `writtenBytes / sizeof(int)`.
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

## 2026-07-26 exact-config redesign (in progress)

### Corrected product contract

- Every App/daemon may still self-report its PID because App-process prefs reads are unreliable on roothide.
- Self-reporting is not permission to control the process. `runningboardd` must resolve the PID against its own validated prefs snapshot first.
- No matching config means no target and zero CPU-limit syscalls.
- Matching but globally/per-process disabled or invalid parameters means no monitoring on launch. A prefs reload may restore limits previously applied by Vedette.
- Matching and enabled means the target carries that exact config's percentage, interval and policy through to the syscall layer.

### New root causes addressed

- The preference bundle stores a daemon's full executable filename, while `proc_name` returns a possibly truncated `p_comm`; exact full-name matching therefore uses `proc_pidpath` plus its last path component.
- If the full path is unavailable, `proc_name` is exact-match only. Prefix matching fails closed because two processes can share the truncated prefix.
- The old parallel PID/percentage/interval/policy arrays allowed index drift. Targets now bind PID and config in one dictionary.
- `proc_listpids` returns bytes, not PID count; scan bounds now divide returned bytes by `sizeof(int)`.
- User-writable plist collections and scalars are type-checked. Missing fields retain UI defaults only for an explicitly enabled config; explicit empty/malformed/non-positive parameters disable enforcement.
- A resolved target binds the executable path (or exact `proc_name` fallback) observed during lookup and revalidates it immediately before CPU syscalls, so an exited or reused PID fails closed.
- Policy transitions retire the previous policy first: throttle clears any fatal monitor; terminate clears any throttle; disabled entries clear both on reload.

### Verification status

- [x] Host process-identity test passes.
- [x] Automatic-monitor source contract passes.
- [x] Identity mutants are killed: ignoring full executable name, unconditional prefix matching, authoritative mismatch fallthrough, and path-component off-by-one.
- [x] Contract mutants are killed: missing config gate, hardcoded percentage, skipped identity revalidation, wrong PID byte count, and retained prior policy.
- [x] Local arm64 + arm64e clean compile passes; local arm64e ABI warnings make this output non-deliverable.
- [x] Independent runtime-safety review complete: no P0/P1; all five safety invariants hold.
- [x] Independent diff/CI review complete: no P0; host suites and workflow gates verified.
- [x] Version bumped to 1.1.9.
- [x] Commit and push complete: `fa6d4f9` on `fix/proc-identity-guard`.
- [x] Pinned macOS/Xcode cloud build and artifact evidence complete:
  - CI runs `30199072929` and `30199075033`, both green; artifact taken from `30199075033`.
  - SHA256: `81eb9138df84b0a12fbcbe33be024d7cc7b1400844e69c2764c5d8112b72a9b1`
  - `lipo -verify_arch arm64 arm64e`: pass (dylib + prefs)
  - `LC_DYLD_CHAINED_FIXUPS`: present; `LC_DYLD_INFO_ONLY`: absent
  - Cloud logs: no `incompatible arm64e` warnings
- [ ] Device verification complete.
