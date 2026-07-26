//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTProcessManager.h"
#import "VDTShared.h"
#import "VDTProbe.h"
#import "PrivateHeaders.h"
#import "VDTProcessIdentity.h"

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <os/lock.h>
#include <stdlib.h>

#pragma mark - Thread-safe prefs storage

static NSDictionary *_prefs;
static os_unfair_lock _prefsLock = OS_UNFAIR_LOCK_INIT;

void VDTSetPrefs(NSDictionary *newPrefs){
    os_unfair_lock_lock(&_prefsLock);
    _prefs = newPrefs;
    os_unfair_lock_unlock(&_prefsLock);
}

NSDictionary *VDTGetPrefs(void){
    os_unfair_lock_lock(&_prefsLock);
    NSDictionary *snapshot = _prefs;
    os_unfair_lock_unlock(&_prefsLock);
    return snapshot;
}

#pragma mark - Untrusted plist accessors
//
// The prefs plist is user-writable and can be hand-edited or partially written.
// Every read below is type-checked: an unexpected type must never reach an
// Objective-C selector or a collection literal, because this code runs inside
// runningboardd and an uncaught exception there takes the process down.

static NSArray *vdt_array(id value){
    return [value isKindOfClass:[NSArray class]] ? (NSArray *)value : nil;
}

static NSDictionary *vdt_dictionary(id value){
    return [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : nil;
}

static NSString *vdt_nonEmptyString(id value){
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *string = (NSString *)value;
    return string.length > 0 ? string : nil;
}

static NSNumber *vdt_number(id value){
    return [value isKindOfClass:[NSNumber class]] ? (NSNumber *)value : nil;
}

static BOOL vdt_int(id value, int defaultValue, int *outValue){
    if (!outValue) return NO;
    if (!value) {
        *outValue = defaultValue;
        return YES;
    }

    long long parsed = 0;
    if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *number = (NSNumber *)value;
        if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) return NO;

        double numericValue = number.doubleValue;
        parsed = number.longLongValue;
        if (!isfinite(numericValue) || numericValue != (double)parsed) return NO;
    } else if ([value isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:(NSString *)value];
        if (![scanner scanLongLong:&parsed] || !scanner.isAtEnd) return NO;
    } else {
        return NO;
    }

    if (parsed < INT_MIN || parsed > INT_MAX) return NO;
    *outValue = (int)parsed;
    return YES;
}

static BOOL vdt_bool(id value, BOOL defaultValue){
    if (!value) return defaultValue;
    if (![value isKindOfClass:[NSNumber class]]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return NO;
    return [(NSNumber *)value boolValue];
}

static BOOL vdt_policy(id value, VDTViolationPolicy *outPolicy){
    if (!outPolicy) return NO;
    if (!value) {
        *outPolicy = VDTViolationPolicyMonitorAndTerminate;
        return YES;
    }

    int raw = 0;
    if (!vdt_int(value, 0, &raw)) return NO;
    switch ((VDTViolationPolicy)raw) {
        case VDTViolationPolicyMonitorAndTerminate:
        case VDTViolationPolicyThrottle:
            *outPolicy = (VDTViolationPolicy)raw;
            return YES;
        default:
            return NO;
    }
}

#pragma mark - Process helpers

static LSApplicationProxy* appproxy_from_bundle_path(NSString *path){
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return nil;

    NSURL *bundleURL = [NSURL fileURLWithPath:path];
    Class proxyClass = objc_getClass("LSApplicationProxy");
    if (!bundleURL || ![proxyClass respondsToSelector:@selector(applicationProxyForBundleURL:)]) return nil;

    return [proxyClass applicationProxyForBundleURL:bundleURL];
}

// Full executable path. Empty string when unavailable, never partial data.
static BOOL executable_path_for_pid(pid_t pid, char *buffer, uint32_t bufferSize){
    return VDTCopyProcessInfoString(pid, buffer, bufferSize, proc_pidpath);
}

// The preference bundle stores a daemon's full executable name, so this is the
// identity that can actually be matched against the user's config.
static BOOL executable_name_for_pid(pid_t pid, char *out, uint32_t outSize){
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
    if (!executable_path_for_pid(pid, pathBuffer, sizeof(pathBuffer))) {
        if (outSize > 0) out[0] = '\0';
        return NO;
    }
    return VDTCopyLastPathComponent(pathBuffer, out, outSize);
}

// proc_name returns the kernel's possibly truncated p_comm. It is only an exact-
// match fallback when the full executable path is unavailable.
static BOOL proc_comm_for_pid(pid_t pid, char *out, uint32_t outSize){
    return VDTCopyProcessInfoString(pid, out, outSize, proc_name);
}

// Best-effort display name for telemetry only. Never used for matching.
static NSString* display_name_for_pid(pid_t pid){
    char nameBuffer[PROC_PIDPATHINFO_MAXSIZE];
    if (executable_name_for_pid(pid, nameBuffer, sizeof(nameBuffer))) {
        NSString *name = [NSString stringWithUTF8String:nameBuffer];
        if (name.length > 0) return name;
    }
    if (proc_comm_for_pid(pid, nameBuffer, sizeof(nameBuffer))) {
        NSString *name = [NSString stringWithUTF8String:nameBuffer];
        if (name.length > 0) return name;
    }
    return nil;
}

#pragma mark - Config normalisation

NSString * const VDTConfigIdentifierKey = @"identifier";
NSString * const VDTConfigTypeKey = @"type";
NSString * const VDTConfigPercentageKey = @"percentage";
NSString * const VDTConfigIntervalKey = @"interval";
NSString * const VDTConfigPolicyKey = @"policy";
NSString * const VDTConfigEnabledKey = @"enabled";
NSString * const VDTTargetPidKey = @"pid";
NSString * const VDTTargetNameKey = @"name";
NSString * const VDTTargetExecutablePathKey = @"executablePath";
NSString * const VDTTargetProcCommKey = @"procComm";

static NSArray<NSDictionary *> *configs_from_section(NSDictionary *prefs,
                                                     NSString *sectionKey,
                                                     NSString *identifierKey,
                                                     VDTConfigType type,
                                                     BOOL globallyEnabled){
    NSMutableArray<NSDictionary *> *configs = [NSMutableArray array];
    NSArray *section = vdt_array(prefs[sectionKey]);

    for (id rawEntry in section) {
        NSDictionary *entry = vdt_dictionary(rawEntry);
        if (!entry) continue;

        NSString *identifier = vdt_nonEmptyString(entry[identifierKey]);
        if (!identifier) continue;

        // The Settings app hosts the preference bundle itself; throttling it
        // would lock the user out of their own configuration.
        if (type == VDTConfigTypeApp && [identifier isEqualToString:@"com.apple.Preferences"]) continue;

        int percentage = 0;
        int interval = 0;
        VDTViolationPolicy policy = VDTViolationPolicyNone;
        BOOL percentageValid = vdt_int(entry[@"percentage"], 80, &percentage);
        BOOL intervalValid = vdt_int(entry[@"interval"], 120, &interval);
        BOOL policyValid = vdt_policy(entry[@"violationPolicy"], &policy);
        BOOL parametersValid = percentageValid && percentage > 0 && policyValid &&
            (policy == VDTViolationPolicyThrottle || (intervalValid && interval > 0));
        BOOL enabled = globallyEnabled && vdt_bool(entry[@"enabled"], NO) && parametersValid;

        [configs addObject:@{
            VDTConfigIdentifierKey: identifier,
            VDTConfigTypeKey: @(type),
            VDTConfigPercentageKey: @(percentageValid ? percentage : 0),
            VDTConfigIntervalKey: @(intervalValid ? interval : 0),
            VDTConfigPolicyKey: @(policyValid ? policy : VDTViolationPolicyNone),
            // Missing values use the preference UI's defaults. Explicitly empty,
            // malformed or non-positive values fail closed instead of turning
            // into an implicit fatal monitor.
            VDTConfigEnabledKey: @(enabled)
        }];
    }

    return configs;
}

NSArray<NSDictionary *>* vdt_configs_from_prefs(NSDictionary *prefs){
    NSDictionary *validatedPrefs = vdt_dictionary(prefs);
    if (!validatedPrefs) return @[];

    BOOL globallyEnabled = vdt_bool(validatedPrefs[@"enabled"], YES);

    NSMutableArray<NSDictionary *> *configs = [NSMutableArray array];
    [configs addObjectsFromArray:configs_from_section(validatedPrefs, @"appConfigs", @"bundleIdentifier",
                                                     VDTConfigTypeApp, globallyEnabled)];
    [configs addObjectsFromArray:configs_from_section(validatedPrefs, @"daemonConfigs", @"daemonName",
                                                     VDTConfigTypeDaemon, globallyEnabled)];
    return configs;
}

#pragma mark - Target resolution

static void split_configs(NSArray<NSDictionary *> *configs,
                         NSMutableDictionary<NSString *, NSDictionary *> *appConfigsById,
                         NSMutableArray<NSDictionary *> *daemonConfigs){
    for (id rawConfig in configs) {
        NSDictionary *config = vdt_dictionary(rawConfig);
        NSString *identifier = vdt_nonEmptyString(config[VDTConfigIdentifierKey]);
        NSNumber *typeValue = vdt_number(config[VDTConfigTypeKey]);
        if (!identifier || !typeValue) continue;

        VDTConfigType type = (VDTConfigType)typeValue.unsignedLongValue;
        if (type == VDTConfigTypeApp) {
            // Preserve the preference API's first-entry-wins behavior if a
            // hand-edited plist contains duplicate identifiers.
            if (!appConfigsById[identifier]) appConfigsById[identifier] = config;
        } else if (type == VDTConfigTypeDaemon) {
            [daemonConfigs addObject:config];
        }
    }
}

// Resolves one PID against the configured set. Returns nil when the process is
// not configured, which is the signal to leave it completely alone.
static NSDictionary *target_for_pid(pid_t pid,
                                    NSDictionary<NSString *, NSDictionary *> *appConfigsById,
                                    NSArray<NSDictionary *> *daemonConfigs){
    if (pid <= 0) return nil;

    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
    BOOL hasExecutablePath = executable_path_for_pid(pid, pathBuffer, sizeof(pathBuffer));
    NSString *executablePath = hasExecutablePath ? [NSString stringWithUTF8String:pathBuffer] : nil;
    if (executablePath.length == 0) executablePath = nil;

    char executableName[PROC_PIDPATHINFO_MAXSIZE];
    BOOL hasExecutableName = hasExecutablePath &&
        VDTCopyLastPathComponent(pathBuffer, executableName, sizeof(executableName));

    NSDictionary *matched = nil;
    NSString *matchedName = nil;
    NSString *fallbackProcComm = nil;

    // App identity takes priority over an executable-name collision with a
    // daemon config. (The baseline scan path checked daemons first; this order
    // is intentionally reversed because a verified bundle identifier is a
    // stronger identity than a file name match.)
    if (appConfigsById.count > 0 && executablePath) {
        LSApplicationProxy *appProxy = appproxy_from_bundle_path(executablePath.stringByDeletingLastPathComponent);
        NSString *bundleIdentifier = appProxy.bundleIdentifier;
        if ([bundleIdentifier isKindOfClass:[NSString class]] && bundleIdentifier.length > 0) {
            NSDictionary *config = appConfigsById[bundleIdentifier];
            if (config) {
                matched = config;
                matchedName = bundleIdentifier;
            }
        }
    }

    if (!matched && daemonConfigs.count > 0) {
        char procComm[256];
        BOOL hasProcComm = !hasExecutableName && proc_comm_for_pid(pid, procComm, sizeof(procComm));
        if (!hasExecutableName && !hasProcComm) return nil;
        if (hasProcComm) {
            fallbackProcComm = [NSString stringWithUTF8String:procComm];
            if (fallbackProcComm.length == 0) return nil;
        }

        for (NSDictionary *config in daemonConfigs) {
            NSString *configuredName = config[VDTConfigIdentifierKey];
            const char *configured = configuredName.UTF8String;
            if (!configured) continue;
            if (VDTProcessNameMatches(configured,
                                      hasExecutableName ? executableName : NULL,
                                      hasProcComm ? procComm : NULL)) {
                matched = config;
                matchedName = configuredName;
                break;
            }
        }
    }

    if (!matched) return nil;

    NSNumber *enabledValue = vdt_number(matched[VDTConfigEnabledKey]);
    if (!enabledValue) return nil;

    BOOL enabled = enabledValue.boolValue;
    NSNumber *percentage = enabled ? vdt_number(matched[VDTConfigPercentageKey]) : @0;
    NSNumber *interval = enabled ? vdt_number(matched[VDTConfigIntervalKey]) : @0;
    NSNumber *policy = enabled ? vdt_number(matched[VDTConfigPolicyKey]) : @(VDTViolationPolicyNone);
    if (!percentage || !interval || !policy) return nil;

    NSMutableDictionary *target = [@{
        VDTTargetPidKey: @(pid),
        VDTTargetNameKey: matchedName ?: @"",
        // A disabled entry resolves to zero, which the syscall layer treats as
        // "restore system defaults" rather than "apply a fatal limit".
        VDTConfigPercentageKey: percentage,
        VDTConfigIntervalKey: interval,
        VDTConfigPolicyKey: policy
    } mutableCopy];

    // Bind the identity observed during resolution to the target. The syscall
    // layer re-checks it immediately before applying a CPU policy, closing the
    // exited/reused-PID window during a full process scan.
    if (executablePath) {
        target[VDTTargetExecutablePathKey] = executablePath;
    } else if (fallbackProcComm) {
        target[VDTTargetProcCommKey] = fallbackProcComm;
    } else {
        return nil;
    }
    return target;
}

NSArray<NSDictionary *>* vdt_resolve_targets(NSArray<NSDictionary *> *configs){
    if (configs.count == 0) return @[];

    NSMutableDictionary<NSString *, NSDictionary *> *appConfigsById = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *daemonConfigs = [NSMutableArray array];
    split_configs(configs, appConfigsById, daemonConfigs);
    if (appConfigsById.count == 0 && daemonConfigs.count == 0) return @[];

    // proc_listpids reports a byte count, not an element count.
    int listBytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (listBytes <= 0) return @[];

    int *buffer = (int *)malloc((size_t)listBytes);
    if (!buffer) return @[];

    int writtenBytes = proc_listpids(PROC_ALL_PIDS, 0, buffer, listBytes);
    if (writtenBytes <= 0) {
        free(buffer);
        return @[];
    }
    if (writtenBytes > listBytes) writtenBytes = listBytes;

    int pidCount = writtenBytes / (int)sizeof(int);
    NSMutableArray<NSDictionary *> *targets = [NSMutableArray array];

    for (int idx = 0; idx < pidCount; idx++) {
        pid_t pid = (pid_t)buffer[idx];
        if (pid <= 0) continue;
        NSDictionary *target = target_for_pid(pid, appConfigsById, daemonConfigs);
        if (target) [targets addObject:target];
    }

    free(buffer);

    VDTProbeRecord(@"runningboardd.resolveTargets", @{
        @"configCount": @(configs.count),
        @"scannedPids": @(pidCount),
        @"matchedTargets": @(targets.count)
    });

    return targets;
}

NSArray<NSDictionary *>* vdt_targets_for_pid(pid_t pid, NSArray<NSDictionary *> *configs){
    if (pid <= 0 || configs.count == 0) return @[];

    NSMutableDictionary<NSString *, NSDictionary *> *appConfigsById = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *daemonConfigs = [NSMutableArray array];
    split_configs(configs, appConfigsById, daemonConfigs);

    NSDictionary *target = target_for_pid(pid, appConfigsById, daemonConfigs);
    return target ? @[target] : @[];
}

#pragma mark - Monitor / throttle

static BOOL target_identity_is_current(NSDictionary *target, pid_t pid){
    NSString *expectedPath = vdt_nonEmptyString(target[VDTTargetExecutablePathKey]);
    if (expectedPath) {
        char currentPath[PROC_PIDPATHINFO_MAXSIZE];
        if (!executable_path_for_pid(pid, currentPath, sizeof(currentPath))) return NO;

        NSString *current = [NSString stringWithUTF8String:currentPath];
        return current.length > 0 && [current isEqualToString:expectedPath];
    }

    NSString *expectedComm = vdt_nonEmptyString(target[VDTTargetProcCommKey]);
    if (expectedComm) {
        char currentComm[256];
        if (!proc_comm_for_pid(pid, currentComm, sizeof(currentComm))) return NO;

        NSString *current = [NSString stringWithUTF8String:currentComm];
        return current.length > 0 && [current isEqualToString:expectedComm];
    }

    return NO;
}

void vdt_apply_targets(NSArray<NSDictionary *> *targets){
    for (id rawTarget in targets) {
        NSDictionary *target = vdt_dictionary(rawTarget);
        NSNumber *pidValue = vdt_number(target[VDTTargetPidKey]);
        NSNumber *percentageValue = vdt_number(target[VDTConfigPercentageKey]);
        NSNumber *intervalValue = vdt_number(target[VDTConfigIntervalKey]);
        NSNumber *policyValue = vdt_number(target[VDTConfigPolicyKey]);
        if (!target || !pidValue || !percentageValue || !intervalValue || !policyValue) continue;

        pid_t pid = (pid_t)pidValue.intValue;
        if (pid <= 0) continue;

        if (!target_identity_is_current(target, pid)) {
            VDTProbeRecord(@"runningboardd.targetSkipped", @{
                @"pid": @(pid),
                @"name": target[VDTTargetNameKey] ?: @"",
                @"reason": @"identityChangedOrUnavailable"
            });
            continue;
        }

        int percentage = percentageValue.intValue;
        int interval = intervalValue.intValue;
        VDTViolationPolicy policy = (VDTViolationPolicy)policyValue.unsignedLongValue;

        if (percentage < 0) percentage = 0;
        if (interval < 0) interval = 0;

        if (policy == VDTViolationPolicyThrottle && percentage > 0) {
            // A process may have been using the terminate policy before this
            // reload. Remove that monitor before installing the throttle.
            int disableRet = proc_disable_cpumon(pid);
            int defaultsRet = proc_set_cpumon_defaults(pid);
            int resumeRet = proc_resume_cpumon(pid);

            errno = 0;
            int setRet = proc_setcpu_percentage(pid, PROC_SETCPU_ACTION_THROTTLE, percentage);
            int setErrno = errno;
            if (setRet == 0) {
                HBLogDebug(@"Throttled pid %d with percentage %d%%", pid, percentage);
            }
            VDTProbeRecord(@"runningboardd.throttleSyscall", @{
                @"pid": @(pid),
                @"name": target[VDTTargetNameKey] ?: @"",
                @"requestedPercentage": @(percentage),
                @"disableRet": @(disableRet),
                @"defaultsRet": @(defaultsRet),
                @"resumeRet": @(resumeRet),
                @"setRet": @(setRet),
                @"setErrno": @(setErrno)
            });
            continue;
        }

        if (policy == VDTViolationPolicyMonitorAndTerminate && percentage > 0 && interval > 0) {
            // Likewise, remove an earlier throttle before arming the fatal CPU
            // monitor so only the currently selected policy remains active.
            int clearRet = proc_clear_cpulimits(pid);
            int disableRet = proc_disable_cpumon(pid);
            int setRet = proc_set_cpumon_params_fatal(pid, percentage, interval);
            if (setRet == 0) {
                HBLogDebug(@"Monitoring pid %d with percentage %d%% and interval %ds", pid, percentage, interval);
            }
            int resumeRet = proc_resume_cpumon(pid);
            VDTProbeRecord(@"runningboardd.monitorSyscall", @{
                @"pid": @(pid),
                @"name": target[VDTTargetNameKey] ?: @"",
                @"percentage": @(percentage),
                @"interval": @(interval),
                @"clearRet": @(clearRet),
                @"disableRet": @(disableRet),
                @"setRet": @(setRet),
                @"resumeRet": @(resumeRet)
            });
            continue;
        }

        // Restore path: the entry exists but is switched off, so undo whatever
        // this tweak previously applied and hand the process back to the system.
        errno = 0;
        int clearRet = proc_clear_cpulimits(pid);
        int disableRet = proc_disable_cpumon(pid);
        int defaultsRet = proc_set_cpumon_defaults(pid);
        int resumeRet = proc_resume_cpumon(pid);
        HBLogDebug(@"Restored CPU limits for pid %d", pid);
        VDTProbeRecord(@"runningboardd.restoreSyscall", @{
            @"pid": @(pid),
            @"name": target[VDTTargetNameKey] ?: @"",
            @"clearRet": @(clearRet),
            @"disableRet": @(disableRet),
            @"defaultsRet": @(defaultsRet),
            @"resumeRet": @(resumeRet),
            @"errno": @(errno)
        });
    }
}

#pragma mark - New process handler

void received_new_proc(pid_t pid){
    if (pid <= 0) return;

    // Every process self-reports its PID, because reading the prefs plist from an
    // App process is unreliable on roothide. That makes this handler the place
    // where the user's opt-in is enforced: a process the user never configured
    // must not receive any CPU limit at all.
    NSDictionary *prefs = VDTGetPrefs();
    if (!prefs) {
        VDTProbeRecord(@"runningboardd.receivedNewProcSkipped", @{
            @"pid": @(pid),
            @"reason": @"prefsUnavailable"
        });
        return;
    }

    NSArray<NSDictionary *> *configs = vdt_configs_from_prefs(prefs);
    if (configs.count == 0) return;

    NSArray<NSDictionary *> *targets = vdt_targets_for_pid(pid, configs);
    if (targets.count == 0) {
        VDTProbeRecord(@"runningboardd.receivedNewProcSkipped", @{
            @"pid": @(pid),
            @"name": display_name_for_pid(pid) ?: @"",
            @"reason": @"notConfigured"
        });
        return;
    }

    NSDictionary *target = targets.firstObject;
    if ([target[VDTConfigPolicyKey] unsignedLongValue] == VDTViolationPolicyNone) {
        // Configured but switched off. Nothing to enforce, and a freshly launched
        // process already starts from the system defaults.
        VDTProbeRecord(@"runningboardd.receivedNewProcSkipped", @{
            @"pid": @(pid),
            @"name": target[VDTTargetNameKey] ?: @"",
            @"reason": @"configuredButDisabled"
        });
        return;
    }

    VDTProbeRecord(@"runningboardd.receivedNewProcResolved", @{
        @"pid": @(pid),
        @"name": target[VDTTargetNameKey] ?: @"",
        @"percentage": target[VDTConfigPercentageKey] ?: @0,
        @"interval": target[VDTConfigIntervalKey] ?: @0,
        @"violationPolicy": target[VDTConfigPolicyKey] ?: @0
    });

    vdt_apply_targets(targets);
}
