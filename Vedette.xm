//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"
#import "VDTProcessManager.h"
#import "VDTShared.h"
#import "VDTProbe.h"

#include <notify.h>

#pragma mark - Serial queue for prefs/monitoring work
// All prefs reload and process scanning work is serialized here to prevent
// concurrent reloadPrefs calls from racing on PID lookups and syscalls.

static dispatch_queue_t vedette_serial_queue(){
    static dispatch_once_t once;
    static dispatch_queue_t q;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.udevs.vedette.serial", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

#pragma mark runningboardd

// Core prefs reload logic. Must be called on vedette_serial_queue.
static void reloadPrefsSync(){

    NSDictionary *newPrefs = getPrefs();
    VDTSetPrefs(newPrefs);
    
    id enabledVal = valueForKeyWithPrefs(@"enabled", newPrefs);
    BOOL enabled = enabledVal ? [enabledVal boolValue] : YES;
    
    NSMutableArray *percentages = [NSMutableArray array];
    NSMutableArray *intervals = [NSMutableArray array];
    NSMutableArray *identifiers = [NSMutableArray array];
    NSMutableArray *types = [NSMutableArray array];
    NSMutableArray *violationPolicies = [NSMutableArray array];

    NSArray *appConfigs = newPrefs[@"appConfigs"];
    HBLogDebug(@"appConfigs: %@", appConfigs);
    
    for (NSUInteger idx = 0; idx < appConfigs.count; idx++){
        NSString *bundleIdentifier = appConfigs[idx][@"bundleIdentifier"];
        if ([bundleIdentifier isEqualToString:@"com.apple.Preferences"]){
            continue;
        }
        [identifiers addObject:bundleIdentifier];
        [types addObject:@(VDTConfigTypeApp)];
        int percentage = [valueForProcessConfigKeyWithPrefs(bundleIdentifier, @"percentage", @80, VDTConfigTypeApp, newPrefs) intValue];
        int interval = [valueForProcessConfigKeyWithPrefs(bundleIdentifier, @"interval", @120, VDTConfigTypeApp, newPrefs) intValue];
        VDTViolationPolicy violationPolicy = (VDTViolationPolicy)[valueForProcessConfigKeyWithPrefs(bundleIdentifier, @"violationPolicy", @(VDTViolationPolicyMonitorAndTerminate), VDTConfigTypeApp, newPrefs) unsignedLongValue];
        BOOL processEnabled = [valueForProcessConfigKeyWithPrefs(bundleIdentifier, @"enabled", @NO, VDTConfigTypeApp, newPrefs) boolValue];
        [percentages addObject:@(enabled && processEnabled ? percentage : 0)];
        [intervals addObject:@(enabled && processEnabled ? interval : 0)];
        [violationPolicies addObject:@(enabled && processEnabled ? violationPolicy : VDTViolationPolicyNone)];
    }
    
    NSArray *daemonConfigs = newPrefs[@"daemonConfigs"];
    HBLogDebug(@"daemonConfigs: %@", daemonConfigs);
    
    for (NSUInteger idx = 0; idx < daemonConfigs.count; idx++){
        NSString *daemonName = daemonConfigs[idx][@"daemonName"];
        [identifiers addObject:daemonName];
        [types addObject:@(VDTConfigTypeDaemon)];
        int percentage = [valueForProcessConfigKeyWithPrefs(daemonName, @"percentage", @80, VDTConfigTypeDaemon, newPrefs) intValue];
        int interval = [valueForProcessConfigKeyWithPrefs(daemonName, @"interval", @120, VDTConfigTypeDaemon, newPrefs) intValue];
        VDTViolationPolicy violationPolicy = (VDTViolationPolicy)[valueForProcessConfigKeyWithPrefs(daemonName, @"violationPolicy", @(VDTViolationPolicyMonitorAndTerminate), VDTConfigTypeDaemon, newPrefs) unsignedLongValue];
        BOOL processEnabled = [valueForProcessConfigKeyWithPrefs(daemonName, @"enabled", @NO, VDTConfigTypeDaemon, newPrefs) boolValue];
        [percentages addObject:@(enabled && processEnabled ? percentage : 0)];
        [intervals addObject:@(enabled && processEnabled ? interval : 0)];
        [violationPolicies addObject:@(enabled && processEnabled ? violationPolicy : VDTViolationPolicyNone)];
    }
    
    NSIndexSet *monitorIndices = [violationPolicies indexesOfObjectsWithOptions:NSEnumerationConcurrent passingTest:^(NSNumber *violationPolicy, NSUInteger idx, BOOL *stop) {
        return [violationPolicy unsignedLongValue] == VDTViolationPolicyMonitorAndTerminate;
    }];
            
    NSArray *pids = pids_with_identifier_and_type([identifiers objectsAtIndexes:monitorIndices], [types objectsAtIndexes:monitorIndices]);
    monitor_pids(pids, [percentages objectsAtIndexes:monitorIndices], [intervals objectsAtIndexes:monitorIndices]);
    HBLogDebug(@"Monitor ** pids: %@ ** %@ ** %@", pids, [percentages objectsAtIndexes:monitorIndices], [intervals objectsAtIndexes:monitorIndices]);
    
    [identifiers removeObjectsAtIndexes:monitorIndices];
    [types removeObjectsAtIndexes:monitorIndices];
    [percentages removeObjectsAtIndexes:monitorIndices];
    [intervals removeObjectsAtIndexes:monitorIndices];

    pids = pids_with_identifier_and_type(identifiers, types);
    throttle_pids(pids, percentages);
}

// Async wrapper — safe to call from any context (CFNotificationCallback, etc.)
static void reloadPrefs(){
    dispatch_async(vedette_serial_queue(), ^{
        reloadPrefsSync();
    });
}

static void restoreAllMonitors(){
    dispatch_async(vedette_serial_queue(), ^{
        //restore_all_monitors();
        NSDictionary *tmpPrefs = getTempPrefs();
        NSMutableArray *identifiers = [NSMutableArray array];
        NSMutableArray *types = [NSMutableArray array];
        NSArray *appConfigs = tmpPrefs[@"appConfigs"];
        if (appConfigs.count > 0){
            [identifiers addObjectsFromArray:[appConfigs valueForKey:@"bundleIdentifier"]];
        }
        NSArray *daemonConfigs = tmpPrefs[@"daemonConfigs"];
        if (daemonConfigs.count > 0){
            [identifiers addObjectsFromArray:[daemonConfigs valueForKey:@"daemonName"]];
        }
        NSMutableArray *zeroesArray = [NSMutableArray array];
        for (NSUInteger idx = 0; idx < identifiers.count; idx++){
            [zeroesArray addObject:@0];
            if (idx < appConfigs.count){
                [types addObject:@(VDTConfigTypeApp)];
            }else{
                [types addObject:@(VDTConfigTypeDaemon)];
            }
        }
        
        //Restore all monitors and cpu limits
        NSArray *pids = pids_with_identifier_and_type(identifiers, types);
        monitor_pids(pids, zeroesArray, zeroesArray);
        throttle_pids(pids, zeroesArray);

        [[NSFileManager defaultManager] removeItemAtPath:PREFS_PATH_TMP error:nil];
    });
}

#pragma mark - Periodic process discovery timer
// Lightweight polling to catch newly launched configured processes.
// Runs reloadPrefsSync every 60 seconds on the serial queue.
// Much cheaper than the RBProcessManager hook approach which adds
// overhead to every single process launch in the system.

static dispatch_source_t processDiscoveryTimer = NULL;

static void startProcessDiscoveryTimer(){
    if (processDiscoveryTimer) return;
    processDiscoveryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, vedette_serial_queue());
    // 60-second interval, 5-second leeway for power efficiency
    dispatch_source_set_timer(processDiscoveryTimer, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), 60 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(processDiscoveryTimer, ^{
        reloadPrefsSync();
    });
    dispatch_resume(processDiscoveryTimer);
}

%ctor{
    @autoreleasepool {
        // Initial prefs load + apply monitoring to already-running processes
        reloadPrefs();

        // Start periodic discovery for newly launched processes
        startProcessDiscoveryTimer();

        // React to prefs changes from the settings UI
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)reloadPrefs, (CFStringRef)PREFS_CHANGED_NN, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)restoreAllMonitors, (CFStringRef)RESTORE_ALL_MONITORS_NN, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
