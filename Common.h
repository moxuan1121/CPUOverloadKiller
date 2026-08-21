#include <Foundation/Foundation.h>
#include <HBLog.h>
#include <objc/runtime.h>
#include <roothide.h>

#define VEDETTE_IDENTIFIER @"com.moxuan.awemecpuguard"

static inline NSString *VDTPrefsPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = jbroot(@"/var/mobile/Library/Preferences/com.moxuan.awemecpuguard.plist");
    });
    return path;
}

static inline NSString *VDTPrefsPathTmp(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = jbroot(@"/var/tmp/com.moxuan.awemecpuguard.plist");
    });
    return path;
}

#define PREFS_PATH VDTPrefsPath()
#define PREFS_PATH_TMP VDTPrefsPathTmp()
#define PREFS_CHANGED_NN @"com.moxuan.awemecpuguard.prefschanged"
#define AWEME_CPU_GUARD_STATUS_NN "com.moxuan.awemecpuguard.status"
#define VDT_JBROOT_PATH(path) jbroot(@(path))

typedef NS_ENUM(uint64_t, AwemeCPUGuardStatus) {
    AwemeCPUGuardStatusUnknown = 0,
    AwemeCPUGuardStatusDisabled = 1,
    AwemeCPUGuardStatusWaitingForProcess = 2,
    AwemeCPUGuardStatusMonitoring = 3,
    AwemeCPUGuardStatusThresholdExceeded = 4,
    AwemeCPUGuardStatusKilled = 5,
    AwemeCPUGuardStatusCPUReadFailed = 6,
    AwemeCPUGuardStatusKillFailed = 7,
};
