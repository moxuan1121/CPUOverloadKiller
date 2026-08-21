#include <Foundation/Foundation.h>
#include <HBLog.h>
#include <objc/runtime.h>
#include <roothide.h>

#define VEDETTE_IDENTIFIER @"com.moxuan.awemecpuguard"

static inline NSString *VDTPrefsPath(void) {
    // /var/mobile is the shared user-data volume, not a jailbreak-root path.
    // Applying jbroot() here can make Preferences and SpringBoard observe
    // different files under RootHide and silently fall back to defaults.
    return @"/var/mobile/Library/Preferences/com.moxuan.awemecpuguard.plist";
}

static inline NSString *VDTPrefsPathTmp(void) {
    return @"/var/tmp/com.moxuan.awemecpuguard.plist";
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

static inline uint64_t AwemeCPUGuardEncodeStatus(AwemeCPUGuardStatus status,
                                                  NSUInteger cpuTenths,
                                                  NSUInteger threshold,
                                                  NSUInteger exceededTenths) {
    return ((uint64_t)status & 0xffULL) |
        (((uint64_t)MIN(cpuTenths, 0xffffffU) & 0xffffffULL) << 8) |
        (((uint64_t)MIN(threshold, 0xffffU) & 0xffffULL) << 32) |
        (((uint64_t)MIN(exceededTenths, 0xffffU) & 0xffffULL) << 48);
}

static inline AwemeCPUGuardStatus AwemeCPUGuardDecodeStatus(uint64_t value) {
    return (AwemeCPUGuardStatus)(value & 0xffULL);
}

static inline NSUInteger AwemeCPUGuardDecodeCPUTenths(uint64_t value) {
    return (NSUInteger)((value >> 8) & 0xffffffULL);
}

static inline NSUInteger AwemeCPUGuardDecodeThreshold(uint64_t value) {
    return (NSUInteger)((value >> 32) & 0xffffULL);
}

static inline NSUInteger AwemeCPUGuardDecodeExceededTenths(uint64_t value) {
    return (NSUInteger)((value >> 48) & 0xffffULL);
}
