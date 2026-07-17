//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"
#import "VDTProcessManager.h"
#import "VDTShared.h"
#import "VDTProbe.h"

#include <notify.h>
#include <objc/runtime.h>

#pragma mark - RunningBoard private headers
// Choicy (opa334) reference: RBProcessManager.executeLaunchRequest:withError:
// gives us the process launch event with bundleIdentifier from the launch context.

@interface RBSProcessIdentity : NSObject
@property (readonly, copy, nonatomic) NSString *executablePath;
@property (readonly, copy, nonatomic) NSString *embeddedApplicationIdentifier;
@end

@interface RBSLaunchContext : NSObject
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) RBSProcessIdentity *identity;
@end

@interface RBSLaunchRequest : NSObject
@property (nonatomic, readonly) RBSLaunchContext *context;
@end

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
    rebuildConfiguredIdentifiers(newPrefs);
    
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

// Cached set of configured identifiers for fast O(1) lookup in the hook path.
// Updated whenever prefs are reloaded. Protected by vedette_serial_queue.
static NSSet *configuredAppBundleIDs = nil;
static NSSet *configuredDaemonNames = nil;

static void rebuildConfiguredIdentifiers(NSDictionary *prefs){
    NSMutableSet *apps = [NSMutableSet set];
    NSMutableSet *daemons = [NSMutableSet set];

    id enabledVal = valueForKeyWithPrefs(@"enabled", prefs);
    BOOL enabled = enabledVal ? [enabledVal boolValue] : YES;
    if (!enabled) {
        configuredAppBundleIDs = [NSSet set];
        configuredDaemonNames = [NSSet set];
        return;
    }

    for (NSDictionary *cfg in prefs[@"appConfigs"]) {
        NSString *bid = cfg[@"bundleIdentifier"];
        if (bid && [valueForProcessConfigKeyWithPrefs(bid, @"enabled", @NO, VDTConfigTypeApp, prefs) boolValue]) {
            [apps addObject:bid];
        }
    }
    for (NSDictionary *cfg in prefs[@"daemonConfigs"]) {
        NSString *dn = cfg[@"daemonName"];
        if (dn && [valueForProcessConfigKeyWithPrefs(dn, @"enabled", @NO, VDTConfigTypeDaemon, prefs) boolValue]) {
            [daemons addObject:dn];
        }
    }
    configuredAppBundleIDs = [apps copy];
    configuredDaemonNames = [daemons copy];
}

// Quick check — called on the hook path BEFORE dispatching any work.
// Must be very cheap: no syscalls, no PID lookup, just set membership test.
static BOOL isIdentifierConfigured(NSString *identifier, BOOL isApp){
    if (!identifier) return NO;
    return isApp ? [configuredAppBundleIDs containsObject:identifier]
                 : [configuredDaemonNames containsObject:identifier];
}

// Apply monitoring/throttling to a single process identified by bundleID or daemon name.
// Called from the RBProcessManager hook when a new process launches.
// Runs on vedette_serial_queue. Only called for configured identifiers.
static void applyPolicyForIdentifier(NSString *identifier, BOOL isApp){
    NSDictionary *localPrefs = VDTGetPrefs();
    if (!localPrefs) return;

    VDTConfigType type = isApp ? VDTConfigTypeApp : VDTConfigTypeDaemon;

    int percentage = [valueForProcessConfigKeyWithPrefs(identifier, @"percentage", @80, type, localPrefs) intValue];
    int interval = [valueForProcessConfigKeyWithPrefs(identifier, @"interval", @120, type, localPrefs) intValue];
    VDTViolationPolicy violationPolicy = (VDTViolationPolicy)[valueForProcessConfigKeyWithPrefs(identifier, @"violationPolicy", @(VDTViolationPolicyMonitorAndTerminate), type, localPrefs) unsignedLongValue];

    if (violationPolicy == VDTViolationPolicyNone) return;

    // Single-target PID lookup — only runs for configured processes
    NSArray *pids = pids_with_identifier_and_type(@[identifier], @[@(type)]);
    if (pids.count == 0) return;

    HBLogDebug(@"Vedette: hook-driven apply for %@ (pid %@, policy %lu, pct %d)",
               identifier, pids[0], (unsigned long)violationPolicy, percentage);

    switch (violationPolicy) {
        case VDTViolationPolicyMonitorAndTerminate:
            monitor_pids(pids, @[@(percentage)], @[@(interval)]);
            break;
        case VDTViolationPolicyThrottle:
            throttle_pids(pids, @[@(percentage)]);
            break;
        default:
            break;
    }
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

#pragma mark - RBProcessManager hook (Choicy-style event-driven process detection)
// Hook the process launch path inside runningboardd.
// Every app/daemon launch goes through RBProcessManager.executeLaunchRequest:withError:.
// After %orig succeeds, we do a single targeted PID lookup for that specific
// bundleIdentifier instead of polling all PIDs every 10 seconds.

%hook RBProcessManager

- (id)executeLaunchRequest:(RBSLaunchRequest *)launchRequest withError:(NSError **)errorOut
{
    id result = %orig;
    if (!result) return result; // launch failed, nothing to do

    RBSLaunchContext *ctx = launchRequest.context;
    NSString *bundleID = nil;
    if ([ctx respondsToSelector:@selector(bundleIdentifier)]) {
        bundleID = ctx.bundleIdentifier;
    }
    if (!bundleID && [ctx respondsToSelector:@selector(identity)]) {
        bundleID = ctx.identity.embeddedApplicationIdentifier;
    }

    // Also try to extract daemon executable name from identity path
    NSString *daemonName = nil;
    if ([ctx respondsToSelector:@selector(identity)] && ctx.identity) {
        NSString *execPath = nil;
        if ([ctx.identity respondsToSelector:@selector(executablePath)]) {
            execPath = ctx.identity.executablePath;
        }
        if (execPath) {
            daemonName = execPath.lastPathComponent;
        }
    }

    // Fast path: skip immediately if this process is not in the configured list.
    // isIdentifierConfigured() is O(1) set lookup — no syscalls, no PID scan.
    BOOL appMatch = isIdentifierConfigured(bundleID, YES);
    BOOL daemonMatch = (daemonName && ![daemonName isEqualToString:@"runningboardd"]) 
                       ? isIdentifierConfigured(daemonName, NO) : NO;

    if (appMatch || daemonMatch) {
        // Small delay lets the kernel finish process setup so PID is findable
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), vedette_serial_queue(), ^{
            if (appMatch) {
                applyPolicyForIdentifier(bundleID, YES);
            }
            if (daemonMatch) {
                applyPolicyForIdentifier(daemonName, NO);
            }
        });
    }

    return result;
}

%end

%ctor{
    @autoreleasepool {
        // Filter.Executables = ("runningboardd") ensures this only loads in runningboardd.

        // Initial prefs load + apply monitoring to already-running processes
        reloadPrefs();

        // No more polling timer — process discovery is now event-driven
        // via the RBProcessManager hook above.

        // React to prefs changes from the settings UI
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)reloadPrefs, (CFStringRef)PREFS_CHANGED_NN, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)restoreAllMonitors, (CFStringRef)RESTORE_ALL_MONITORS_NN, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
