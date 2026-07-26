//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"
#import "VDTProcessManager.h"
#import "VDTShared.h"

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

#pragma mark - Darwin notification helpers

// Post a PID via Darwin notification state. Called by non-runningboardd processes
// to self-report their PID when they match the user's config.
static void notify_new_pid(const char *notificationName, uint64_t pid){
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        int token = 0;
        notify_register_check(notificationName, &token);
        notify_set_state(token, pid);
        notify_cancel(token);
        notify_post(notificationName);
    });
}

#pragma mark runningboardd

static int notify_pid_token;

// Core prefs reload logic. Must be called on vedette_serial_queue.
static void reloadPrefsSync(){

    NSDictionary *newPrefs = getPrefs();
    VDTSetPrefs(newPrefs);

    // Each resolved target carries its own percentage/interval/policy, so a
    // process can never be given another process's limits. Entries the user
    // switched off (or everything, when the global switch is off) resolve to
    // zero, which restores system defaults instead of applying a limit.
    NSArray<NSDictionary *> *configs = vdt_configs_from_prefs(newPrefs);
    HBLogDebug(@"Vedette configs: %@", configs);

    NSArray<NSDictionary *> *targets = vdt_resolve_targets(configs);
    HBLogDebug(@"Vedette targets: %@", targets);

    vdt_apply_targets(targets);
}

// Async wrapper — safe to call from any context (CFNotificationCallback, etc.)
static void reloadPrefs(){
    dispatch_async(vedette_serial_queue(), ^{
        reloadPrefsSync();
    });
}

static void restoreAllMonitors(){
    dispatch_async(vedette_serial_queue(), ^{
        // Force every entry from the uninstall snapshot to disabled, so each
        // resolved target takes the restore path and hands the process back to
        // the system. The previous implementation inferred app-vs-daemon from an
        // index comparison that mis-typed daemon entries whenever both sections
        // were populated.
        NSArray<NSDictionary *> *configs = vdt_configs_from_prefs(getTempPrefs());
        NSMutableArray<NSDictionary *> *restoreConfigs = [NSMutableArray array];
        for (NSDictionary *config in configs){
            NSMutableDictionary *restore = [config mutableCopy];
            restore[VDTConfigEnabledKey] = @NO;
            [restoreConfigs addObject:restore];
        }

        vdt_apply_targets(vdt_resolve_targets(restoreConfigs));

        [[NSFileManager defaultManager] removeItemAtPath:PREFS_PATH_TMP error:nil];
    });
}

static void prefsChangedCallback(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo){
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    reloadPrefs();
}

static void restoreAllMonitorsCallback(CFNotificationCenterRef center,
                                       void *observer,
                                       CFStringRef name,
                                       const void *object,
                                       CFDictionaryRef userInfo){
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    restoreAllMonitors();
}

%ctor{
    @autoreleasepool {
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            
            NSProcessInfo *procInfo = [objc_getClass("NSProcessInfo") processInfo];
            NSArray *args = [procInfo arguments];
            
            if (args.count != 0) {
                
                NSString *executablePath = args[0];
                if (executablePath){
                    
                    BOOL isApplication = ([executablePath rangeOfString:@"/Application"].location != NSNotFound) || ([executablePath rangeOfString:@"/CoreServices"].location != NSNotFound);
                    
                    NSString *processName = [executablePath lastPathComponent];
                    
                    if ([processName isEqualToString:@"runningboardd"]){
                        // --- runningboardd path ---
                        // Load prefs and apply monitoring to already-running processes
                        reloadPrefs();
                        // Listen for PID self-reports from other processes
                        notify_register_dispatch(NOTIFY_PID_NN, &notify_pid_token, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int token) {
                            uint64_t pid = 0;
                            notify_get_state(token, &pid);
                            if (pid > 0){
                                // Keep preference reloads, target resolution and
                                // CPU syscalls ordered on one queue.
                                dispatch_async(vedette_serial_queue(), ^{
                                    received_new_proc((pid_t)pid);
                                });
                            }
                        });
                        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, (CFStringRef)PREFS_CHANGED_NN, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, restoreAllMonitorsCallback, (CFStringRef)RESTORE_ALL_MONITORS_NN, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                    }else{
                        // --- App/daemon path ---
                        // Unconditionally self-report PID. Let runningboardd decide
                        // whether this process is in the config. This avoids relying
                        // on reading the prefs plist from the App process, which can
                        // fail on roothide when jbroot() resolves to a different path
                        // than what the settings UI wrote to.
                        if(isApplication && [[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.Preferences"]){
                            HBLogDebug(@"Yeah, just no.");
                            return;
                        }
                        HBLogDebug(@"Notify new pid: %d", [procInfo processIdentifier]);
                        notify_new_pid(NOTIFY_PID_NN, [procInfo processIdentifier]);
                    }
                    
                }
            }
        });
    }
    
}
