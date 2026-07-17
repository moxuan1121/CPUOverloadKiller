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
#include <objc/message.h>

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

#pragma mark - Runtime introspection for Plan C diagnostic
// Dump class name, properties, and key methods of an object to a plist.
// Only runs for the first N launches to avoid disk spam.

static NSUInteger dumpCount = 0;
#define VDT_MAX_DUMPS 5

static NSString *VDTDumpPath(void){
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Use same dir as working Vedette prefs (jbroot preferences)
        path = jbroot(@"/var/mobile/Library/Preferences/com.udevs.vedette.rbdump.plist");
    });
    return path;
}

static NSArray *introspectProperties(Class cls){
    NSMutableArray *props = [NSMutableArray array];
    while (cls && cls != [NSObject class]) {
        unsigned int count = 0;
        objc_property_t *propList = class_copyPropertyList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = property_getName(propList[i]);
            const char *attrs = property_getAttributes(propList[i]);
            [props addObject:@{
                @"name": [NSString stringWithUTF8String:name],
                @"attributes": attrs ? [NSString stringWithUTF8String:attrs] : @"?",
                @"class": NSStringFromClass(cls)
            }];
        }
        if (propList) free(propList);
        cls = class_getSuperclass(cls);
    }
    return props;
}

static NSArray *introspectMethods(Class cls, NSArray *selNames){
    NSMutableArray *results = [NSMutableArray array];
    for (NSString *selName in selNames) {
        SEL sel = NSSelectorFromString(selName);
        BOOL responds = [cls instancesRespondToSelector:sel];
        [results addObject:@{@"selector": selName, @"responds": @(responds)}];
    }
    return results;
}

static void dumpRBObjects(id result, RBSLaunchRequest *request, NSString *bundleID, NSString *daemonName){
    if (dumpCount >= VDT_MAX_DUMPS) return;
    dumpCount++;

    @try {

    NSMutableDictionary *dump = [NSMutableDictionary dictionary];
    dump[@"dumpIndex"] = @(dumpCount);
    dump[@"timestamp"] = [[NSDate date] description];
    dump[@"bundleID"] = bundleID ?: @"(nil)";
    dump[@"daemonName"] = daemonName ?: @"(nil)";
    dump[@"dumpPath"] = VDTDumpPath(); // record for verification

    // --- result object (return value of executeLaunchRequest) ---
    if (result) {
        NSMutableDictionary *resultInfo = [NSMutableDictionary dictionary];
        resultInfo[@"className"] = NSStringFromClass([result class]);
        // Use safe description: truncate and sanitize for plist
        @try {
            NSString *desc = [result description];
            if (desc.length > 500) desc = [desc substringToIndex:500];
            resultInfo[@"description"] = desc ?: @"(nil)";
        } @catch (NSException *e) {
            resultInfo[@"description"] = @"(description threw exception)";
        }
        resultInfo[@"properties"] = introspectProperties([result class]);

        // Check pid-related selectors
        NSArray *pidSelectors = @[@"pid", @"processIdentifier", @"processID",
                                  @"process", @"identity", @"bundleIdentifier",
                                  @"executablePath", @"token", @"auditToken"];
        resultInfo[@"methodProbe"] = introspectMethods([result class], pidSelectors);

        // Try to read pid if available — use valueForKey to avoid PAC issues with objc_msgSend
        for (NSString *pidKey in @[@"pid", @"processIdentifier", @"processID"]) {
            if ([result respondsToSelector:NSSelectorFromString(pidKey)]) {
                @try {
                    id val = [result valueForKey:pidKey];
                    resultInfo[[NSString stringWithFormat:@"%@_value", pidKey]] = val ?: @"(nil)";
                } @catch (NSException *e) {
                    resultInfo[[NSString stringWithFormat:@"%@_error", pidKey]] = e.reason ?: @"unknown";
                }
            }
        }

        // Try to get nested process object
        if ([result respondsToSelector:NSSelectorFromString(@"process")]) {
            @try {
                id proc = [result valueForKey:@"process"];
                if (proc) {
                    NSMutableDictionary *procInfo = [NSMutableDictionary dictionary];
                    procInfo[@"className"] = NSStringFromClass([proc class]);
                    @try {
                        NSString *pdesc = [proc description];
                        if (pdesc.length > 500) pdesc = [pdesc substringToIndex:500];
                        procInfo[@"description"] = pdesc ?: @"(nil)";
                    } @catch (NSException *e) {
                        procInfo[@"description"] = @"(threw)";
                    }
                    procInfo[@"properties"] = introspectProperties([proc class]);
                    procInfo[@"methodProbe"] = introspectMethods([proc class], pidSelectors);
                    for (NSString *pidKey in @[@"pid", @"processIdentifier", @"processID"]) {
                        if ([proc respondsToSelector:NSSelectorFromString(pidKey)]) {
                            @try {
                                id val = [proc valueForKey:pidKey];
                                procInfo[[NSString stringWithFormat:@"%@_value", pidKey]] = val ?: @"(nil)";
                            } @catch (NSException *e) {
                                procInfo[[NSString stringWithFormat:@"%@_error", pidKey]] = e.reason ?: @"unknown";
                            }
                        }
                    }
                    resultInfo[@"nestedProcess"] = procInfo;
                }
            } @catch (NSException *e) {
                resultInfo[@"processAccessError"] = e.reason ?: @"unknown";
            }
        }

        dump[@"result"] = resultInfo;
    } else {
        dump[@"result"] = @"(nil)";
    }

    // --- launchRequest.context ---
    if (request.context) {
        NSMutableDictionary *ctxInfo = [NSMutableDictionary dictionary];
        ctxInfo[@"className"] = NSStringFromClass([request.context class]);
        ctxInfo[@"properties"] = introspectProperties([request.context class]);
        dump[@"launchContext"] = ctxInfo;
    }

    // --- launchRequest itself ---
    if (request) {
        NSMutableDictionary *reqInfo = [NSMutableDictionary dictionary];
        reqInfo[@"className"] = NSStringFromClass([request class]);
        reqInfo[@"properties"] = introspectProperties([request class]);
        dump[@"launchRequest"] = reqInfo;
    }

    // Write to plist (append to array)
    NSMutableArray *allDumps = [NSMutableArray array];
    NSArray *existing = [NSArray arrayWithContentsOfFile:VDTDumpPath()];
    if (existing) [allDumps addObjectsFromArray:existing];
    [allDumps addObject:dump];
    BOOL wrote = [allDumps writeToFile:VDTDumpPath() atomically:YES];
    if (!wrote) {
        // Fallback: try /var/root
        [allDumps writeToFile:@"/var/root/vedette-rbdump.plist" atomically:YES];
    }

    } @catch (NSException *e) {
        // Last resort: write crash info
        NSDictionary *crashDump = @{@"crash": e.reason ?: @"unknown", @"name": e.name ?: @"?"};
        [@[crashDump] writeToFile:@"/var/root/vedette-rbdump-crash.plist" atomically:YES];
    }
}

#pragma mark - RBProcessManager hook (Choicy-style event-driven process detection)

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

    // Plan C: diagnostic dump for first N launches
    // Also write a canary file to confirm hook is firing at all
    if (dumpCount == 0) {
        [@{@"hookFired": @YES, @"time": [[NSDate date] description]} writeToFile:@"/var/tmp/vedette-hook-canary.plist" atomically:YES];
    }
    if (dumpCount < VDT_MAX_DUMPS) {
        dumpRBObjects(result, launchRequest, bundleID, daemonName);
    }

    // Fast path: skip immediately if this process is not in the configured list.
    BOOL appMatch = isIdentifierConfigured(bundleID, YES);
    BOOL daemonMatch = (daemonName && ![daemonName isEqualToString:@"runningboardd"]) 
                       ? isIdentifierConfigured(daemonName, NO) : NO;

    if (appMatch || daemonMatch) {
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
        // === FIRST: canary to prove dylib loaded ===
        // Use jbroot preferences path (same as working Vedette prefs)
        NSString *procName = [[[NSProcessInfo processInfo] arguments] firstObject];
        NSDictionary *canary = @{@"loaded": @YES,
           @"time": [[NSDate date] description],
           @"pid": @((int)[[NSProcessInfo processInfo] processIdentifier]),
           @"process": procName ?: @"unknown",
           @"processName": [[NSProcessInfo processInfo] processName] ?: @"unknown"};
        // Write to same dir as working Vedette prefs
        [canary writeToFile:jbroot(@"/var/mobile/Library/Preferences/com.udevs.vedette.canary.plist") atomically:YES];
        [canary writeToFile:@"/var/root/vedette-canary.plist" atomically:YES];

        // === Install hooks (may fail if class not found) ===
        @try {
            %init();
            [@{@"initOK": @YES, @"time": [[NSDate date] description]}
              writeToFile:jbroot(@"/var/mobile/Library/Preferences/com.udevs.vedette.initok.plist") atomically:YES];
            [@{@"initOK": @YES, @"time": [[NSDate date] description]}
              writeToFile:@"/var/root/vedette-initok.plist" atomically:YES];
        } @catch (NSException *e) {
            NSDictionary *fail = @{@"initFailed": @YES, @"reason": e.reason ?: @"unknown", @"name": e.name ?: @"?"};
            [fail writeToFile:jbroot(@"/var/mobile/Library/Preferences/com.udevs.vedette.initfail.plist") atomically:YES];
            [fail writeToFile:@"/var/root/vedette-initfail.plist" atomically:YES];
        }

        // Initial prefs load + apply monitoring to already-running processes
        reloadPrefs();

        // No more polling timer — process discovery is now event-driven
        // via the RBProcessManager hook above.

        // React to prefs changes from the settings UI
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)reloadPrefs, (CFStringRef)PREFS_CHANGED_NN, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)restoreAllMonitors, (CFStringRef)RESTORE_ALL_MONITORS_NN, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
