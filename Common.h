#include <Foundation/Foundation.h>
#include <objc/runtime.h>
#include <roothide.h>

#define VEDETTE_IDENTIFIER @"com.moxuan.globalcpuguard"

static inline NSString *VDTPrefsPath(void) {
    // /var/mobile is the shared user-data volume, not a jailbreak-root path.
    // Applying jbroot() here can make Preferences and SpringBoard observe
    // different files under RootHide and silently fall back to defaults.
    return @"/var/mobile/Library/Preferences/com.moxuan.globalcpuguard.plist";
}

#define PREFS_PATH VDTPrefsPath()
#define PREFS_CHANGED_NN @"com.moxuan.globalcpuguard.prefschanged"
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
    AwemeCPUGuardStatusWaitingForForeground = 8,
};

static inline NSString *GCGStatusNotificationName(NSUInteger type, NSString *identifier) {
    NSData *data = [identifier dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    uint64_t hash = 1469598103934665603ULL;
    for (NSUInteger index = 0; index < data.length; index++) {
        hash ^= bytes[index];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"com.moxuan.globalcpuguard.status.%lu.%016llx",
            (unsigned long)type, (unsigned long long)hash];
}

static inline BOOL GCGIdentifierIsProtected(NSString *identifier) {
    NSString *lower = identifier.lowercaseString;
    if (!lower.length) return YES;
    static NSSet *exact;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ exact = [NSSet setWithArray:@[
        @"launchd", @"springboard", @"backboardd", @"runningboardd", @"kernel_task",
        @"installd", @"jailbreakd", @"xpcproxy", @"amfid", @"securityd", @"watchdogd",
        @"com.apple.springboard", @"com.apple.backboardd", @"com.apple.runningboard"
    ]]; });
    return [exact containsObject:lower] || [lower containsString:@"roothide"] ||
        [lower containsString:@"dopamine"] || [lower containsString:@"jailbreak"];
}

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
