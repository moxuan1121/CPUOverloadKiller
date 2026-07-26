//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTProcessManager.h"
#import "VDTShared.h"
#import "VDTProbe.h"
#import "PrivateHeaders.h"
#import "VDTProcessIdentity.h"

#include <os/lock.h>

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

#pragma mark - Process helpers

static LSApplicationProxy* appproxy_from_bundle_path(NSString *path){
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return nil;

    NSURL *bundleURL = [NSURL fileURLWithPath:path];
    Class proxyClass = objc_getClass("LSApplicationProxy");
    if (!bundleURL || ![proxyClass respondsToSelector:@selector(applicationProxyForBundleURL:)]) return nil;

    return [proxyClass applicationProxyForBundleURL:bundleURL];
}

static LSApplicationProxy* appproxy_from_pid(pid_t pid){
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
    if (!VDTCopyProcessInfoString(pid, pathBuffer, sizeof(pathBuffer), proc_pidpath)) return nil;

    NSString *executablePath = [NSString stringWithUTF8String:pathBuffer];
    if (executablePath.length == 0) return nil;

    NSString *possibleBundlePath = executablePath.stringByDeletingLastPathComponent;
    return appproxy_from_bundle_path(possibleBundlePath);
}

static NSString* name_from_pid(pid_t pid){
    char nameBuffer[256];
    if (!VDTCopyProcessInfoString(pid, nameBuffer, sizeof(nameBuffer), proc_name)) return nil;

    NSString *name = [NSString stringWithUTF8String:nameBuffer];
    return name.length > 0 ? name : nil;
}

/*
static NSArray* all_running_pids(){
    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    int *buffer = (int *)malloc(sizeof(int)*n);
    int k = proc_listpids(PROC_ALL_PIDS, 0, buffer, n*sizeof(int));
    
    NSMutableArray *pids = [NSMutableArray array];
    for (int i = 0; i < k; i++) {
        int pid = buffer[i];
        if (pid == 0) continue;
        [pids addObject:@(pid)];
    }
    return pids;
}
*/

#pragma mark - PID lookup (optimized)

NSArray* pids_with_identifier_and_type(NSArray <NSString *>*identifiers, NSArray <NSNumber *> *types){
    if (!identifiers.count) return @[];

    // Pre-compute which lookup types we need to avoid unnecessary work
    BOOL needsAppLookup = NO;
    BOOL needsDaemonLookup = NO;
    NSMutableSet *daemonNameSet = [NSMutableSet set];
    NSMutableSet *appBundleIdSet = [NSMutableSet set];

    for (NSUInteger idx = 0; idx < identifiers.count; idx++){
        if ([types[idx] unsignedLongValue] == VDTConfigTypeApp){
            needsAppLookup = YES;
            [appBundleIdSet addObject:identifiers[idx]];
        }else{
            needsDaemonLookup = YES;
            [daemonNameSet addObject:identifiers[idx]];
        }
    }

    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    int *buffer = (int *)malloc(sizeof(int)*n);
    int k = proc_listpids(PROC_ALL_PIDS, 0, buffer, n*sizeof(int));
    
    NSMutableArray *pids = [NSMutableArray array];
    for (int i = 0; i < k; i++) {
        int pid = buffer[i];
        if (pid == 0) continue;
        
        BOOL matched = NO;

        // Try daemon name match first (cheap: only proc_name syscall)
        if (needsDaemonLookup && !matched){
            NSString *daemonName = name_from_pid(pid);
            if ([daemonNameSet containsObject:daemonName]){
                [pids addObject:@(pid)];
                matched = YES;
            }
        }

        // Only do expensive app proxy lookup if we have app identifiers to match
        if (needsAppLookup && !matched){
            LSApplicationProxy *appProxy = appproxy_from_pid(pid);
            if (appProxy.bundleIdentifier && [appBundleIdSet containsObject:appProxy.bundleIdentifier]){
                [pids addObject:@(pid)];
                matched = YES;
            }
        }
    }
    if (buffer) free(buffer);
    VDTProbeRecord(@"runningboardd.pidLookup", @{
        @"identifiers": identifiers ?: @[],
        @"types": types ?: @[],
        @"matchedPids": pids ?: @[]
    });
    return pids; // only existing pids are returned
}

#pragma mark - Monitor / throttle

void monitor_pids(NSArray <NSNumber *> *pids, NSArray <NSNumber *> *percentages, NSArray <NSNumber *> *intervals){
    
    for (NSUInteger idx = 0; idx < pids.count; idx++){
        pid_t pid = [pids[idx] intValue];
        if (pid > 0){
            int percentage = [percentages[idx] intValue];
            int interval = [intervals[idx] intValue];
            int disableRet = proc_disable_cpumon(pid);
            int setRet = -999;
            int resumeRet = -999;
            
            if (percentage > 0 && interval > 0){
                setRet = proc_set_cpumon_params_fatal(pid, percentage, interval);
                if (setRet == 0){
                    HBLogDebug(@"Monitoring pid %d with percentage %d%% and interval %ds", pid, percentage, interval);
                }
            }else{
                setRet = proc_set_cpumon_defaults(pid);
                if (setRet == 0){
                    HBLogDebug(@"Restore CPU limits for pid: %d", pid);
                }
            }
            
            resumeRet = proc_resume_cpumon(pid);
            
            VDTProbeRecord(@"runningboardd.monitorSyscall", @{
                @"pid": @(pid),
                @"name": name_from_pid(pid) ?: @"",
                @"percentage": @(percentage),
                @"interval": @(interval),
                @"disableRet": @(disableRet),
                @"setRet": @(setRet),
                @"resumeRet": @(resumeRet)
            });
        }
    }
}

void throttle_pids(NSArray <NSNumber *> *pids, NSArray <NSNumber *> *percentages){
    
    for (NSUInteger idx = 0; idx < pids.count; idx++){
        pid_t pid = [pids[idx] intValue];
        if (pid > 0){
            int percentage = [percentages[idx] intValue];
            int setRet = 0;
            int clearRet = 0;
            
            if (percentage > 0){
                errno = 0;
                setRet = proc_setcpu_percentage(pid, PROC_SETCPU_ACTION_THROTTLE, percentage);
                if (setRet == 0){
                    HBLogDebug(@"Throttled pid %d with percentage %d%% ", pid, percentage);
                }
            }else{
                errno = 0;
                clearRet = proc_clear_cpulimits(pid);
                if (clearRet == 0){
                    HBLogDebug(@"Restored CPU limits for pid %d ", pid);
                }
            }
            
            VDTProbeRecord(@"runningboardd.throttleSyscall", @{
                @"pid": @(pid),
                @"name": name_from_pid(pid) ?: @"",
                @"requestedPercentage": @(percentage),
                @"setRet": @(setRet),
                @"setErrno": @(errno),
                @"clearRet": @(clearRet)
            });
        }
    }
}

#pragma mark - New process handler

void received_new_proc(pid_t pid){
    if (pid <= 0) return;

    // Snapshot prefs for thread safety
    NSDictionary *localPrefs = VDTGetPrefs();
    
    int percentage = 80;
    int interval = 120;
    NSString *daemonName = nil;
    
    LSApplicationProxy *appProxy = appproxy_from_pid(pid);
    NSString *bundleIdentifier = appProxy.bundleIdentifier;
    VDTViolationPolicy violationPolicy = VDTViolationPolicyMonitorAndTerminate;
    
    if (bundleIdentifier.length > 0){ //isApplication
        percentage = [valueForProcessConfigKeyWithPrefs(bundleIdentifier, @"percentage", @80, VDTConfigTypeApp, localPrefs) intValue];
        interval = [valueForProcessConfigKeyWithPrefs(bundleIdentifier, @"interval", @120, VDTConfigTypeApp, localPrefs) intValue];
        violationPolicy = (VDTViolationPolicy)[valueForProcessConfigKeyWithPrefs(bundleIdentifier, @"violationPolicy", @(VDTViolationPolicyMonitorAndTerminate), VDTConfigTypeApp, localPrefs) unsignedLongValue];
    }else{ //isDaemon
        daemonName = name_from_pid(pid);
        if (daemonName.length == 0) {
            VDTProbeRecord(@"runningboardd.receivedNewProcSkipped", @{
                @"pid": @(pid),
                @"reason": @"processIdentityUnavailable"
            });
            return;
        }
        percentage = [valueForProcessConfigKeyWithPrefs(daemonName, @"percentage", @80, VDTConfigTypeDaemon, localPrefs) intValue];
        interval = [valueForProcessConfigKeyWithPrefs(daemonName, @"interval", @120, VDTConfigTypeDaemon, localPrefs) intValue];
        violationPolicy = (VDTViolationPolicy)[valueForProcessConfigKeyWithPrefs(daemonName, @"violationPolicy", @(VDTViolationPolicyMonitorAndTerminate), VDTConfigTypeDaemon, localPrefs) unsignedLongValue];

    }
    
    VDTProbeRecord(@"runningboardd.receivedNewProcResolved", @{
        @"pid": @(pid),
        @"name": daemonName ?: name_from_pid(pid) ?: @"",
        @"bundleIdentifier": bundleIdentifier ?: @"",
        @"percentage": @(percentage),
        @"interval": @(interval),
        @"violationPolicy": @(violationPolicy)
    });
    
    switch (violationPolicy) {
        case VDTViolationPolicyMonitorAndTerminate:
            monitor_pids(@[@(pid)], @[@(percentage)], @[@(interval)]);
            break;
        case VDTViolationPolicyThrottle:
            throttle_pids(@[@(pid)], @[@(percentage)]);
            break;
        default:
            break;
    }
}

/*
void restore_all_monitors(){
    NSArray *pids = all_running_pids();
    NSMutableArray *zerosArray = [NSMutableArray array];
    for (NSUInteger idx = 0; idx < pids.count; idx++){
        [zerosArray addObject:@0];
    }
    monitor_pids(pids, zerosArray, zerosArray);
}
*/
