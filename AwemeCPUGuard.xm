#import "Common.h"
#import "VDTShared.h"
#import <UIKit/UIKit.h>

#include <libproc/libproc.h>
#include <libproc/libproc_internal.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <notify.h>
#include <signal.h>
#include <atomic>
#include <time.h>

static NSString * const kAwemeBundleIdentifier = @"com.ss.iphone.ugc.Aweme";
static const uint64_t kNanosecondsPerSecond = 1000000000ULL;
static const uint64_t kIdleSampleNanoseconds = 60ULL * NSEC_PER_SEC;
static const uint64_t kNearThresholdSampleNanoseconds = 1ULL * NSEC_PER_SEC;
static const uint64_t kExceededSampleNanoseconds = NSEC_PER_MSEC * 500ULL;
static dispatch_source_t gMonitorTimer;
static dispatch_queue_t gMonitorQueue;
static int gPreferencesNotificationToken = -1;
static std::atomic_bool gAwemeIsFrontmost(false);

@interface SpringBoard : UIApplication
- (id)_accessibilityFrontMostApplication;
@end

@interface NSObject (AwemeCPUGuardApplicationIdentity)
- (NSString *)bundleIdentifier;
@end

static void schedule_next_check(uint64_t delayNanoseconds) {
    if (!gMonitorTimer) return;
    dispatch_source_set_timer(gMonitorTimer,
        delayNanoseconds == DISPATCH_TIME_FOREVER
            ? DISPATCH_TIME_FOREVER
            : dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNanoseconds),
        DISPATCH_TIME_FOREVER,
        NSEC_PER_MSEC * 50ULL);
}

static BOOL read_aweme_frontmost_on_main_thread(void) {
    // SpringBoard's accessibility frontmost lookup enters SceneManager and
    // must never be called from the CPU monitor queue on iOS 15.
    if (![NSThread isMainThread]) return NO;
    UIApplication *springBoard = [UIApplication sharedApplication];
    if (![springBoard respondsToSelector:@selector(_accessibilityFrontMostApplication)]) return NO;
    id application = [(SpringBoard *)springBoard _accessibilityFrontMostApplication];
    if (![application respondsToSelector:@selector(bundleIdentifier)]) return NO;
    return [[application bundleIdentifier] isEqualToString:kAwemeBundleIdentifier];
}

static void publish_status(AwemeCPUGuardStatus status, double cpuPercent,
                           NSUInteger threshold, double exceededSeconds) {
    static int token = -1;
    static uint64_t previous = UINT64_MAX;
    NSUInteger cpuTenths = (NSUInteger)MAX(0.0, MIN(cpuPercent * 10.0, 16777215.0));
    NSUInteger exceededTenths = (NSUInteger)MAX(0.0, MIN(exceededSeconds * 10.0, 65535.0));
    uint64_t encoded = AwemeCPUGuardEncodeStatus(status, cpuTenths, threshold, exceededTenths);
    if (encoded == previous) return;
    if (token < 0 && notify_register_check(AWEME_CPU_GUARD_STATUS_NN, &token) != NOTIFY_STATUS_OK) {
        token = -1;
        return;
    }
    if (notify_set_state(token, encoded) == NOTIFY_STATUS_OK) {
        previous = encoded;
        notify_post(AWEME_CPU_GUARD_STATUS_NN);
    }
}

typedef struct {
    uint8_t uuid[16];
    uint64_t userTime;
    uint64_t systemTime;
    uint64_t packageIdleWakeups;
    uint64_t interruptWakeups;
    uint64_t pageins;
    uint64_t wiredSize;
    uint64_t residentSize;
    uint64_t physicalFootprint;
    uint64_t processStartAbsoluteTime;
    uint64_t processExitAbsoluteTime;
} aweme_rusage_info_v0;

static uint64_t monotonic_nanoseconds(void) {
    struct timespec value = {0};
    clock_gettime(CLOCK_MONOTONIC, &value);
    return ((uint64_t)value.tv_sec * kNanosecondsPerSecond) + (uint64_t)value.tv_nsec;
}

static BOOL aweme_pid_is_current(pid_t pid) {
    char executablePath[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (pid <= 0 || proc_pidpath(pid, executablePath, sizeof(executablePath)) <= 0) return NO;

    NSString *path = [NSString stringWithUTF8String:executablePath];
    NSRange appRange = [path rangeOfString:@".app/" options:NSBackwardsSearch];
    if (appRange.location == NSNotFound) return NO;
    NSString *bundlePath = [path substringToIndex:appRange.location + 4];
    // LSApplicationProxy is not reliable from runningboardd on every
    // RootHide setup. The bundle's Info.plist is the authoritative identity
    // source and is readable without depending on LaunchServices state.
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bundleIdentifier = [info[@"CFBundleIdentifier"] isKindOfClass:[NSString class]]
        ? info[@"CFBundleIdentifier"] : nil;
    return [bundleIdentifier isEqualToString:kAwemeBundleIdentifier];
}

static double mach_ticks_to_nanoseconds(uint64_t ticks) {
    static mach_timebase_info_data_t timebase = {0};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (mach_timebase_info(&timebase) != KERN_SUCCESS ||
            timebase.numer == 0 || timebase.denom == 0) {
            timebase.numer = 1;
            timebase.denom = 1;
        }
    });
    return ((double)ticks * (double)timebase.numer) / (double)timebase.denom;
}

static BOOL read_aweme_identity(pid_t pid, NSString **outPath, uint64_t *outStartTime) {
    if (pid <= 0 || !aweme_pid_is_current(pid)) return NO;

    char executablePath[PROC_PIDPATHINFO_MAXSIZE] = {0};
    aweme_rusage_info_v0 usage = {};
    if (proc_pidpath(pid, executablePath, sizeof(executablePath)) <= 0 ||
        proc_pid_rusage(pid, RUSAGE_INFO_V0, &usage) != 0) {
        return NO;
    }

    NSString *path = [NSString stringWithUTF8String:executablePath];
    if (!path.length || usage.processStartAbsoluteTime == 0) return NO;
    if (outPath) *outPath = path;
    if (outStartTime) *outStartTime = usage.processStartAbsoluteTime;
    return YES;
}

static BOOL aweme_pid_matches_identity(pid_t pid, NSString *expectedPath, uint64_t expectedStartTime) {
    NSString *currentPath = nil;
    uint64_t currentStartTime = 0;
    return expectedPath.length && expectedStartTime != 0 &&
        read_aweme_identity(pid, &currentPath, &currentStartTime) &&
        currentStartTime == expectedStartTime &&
        [currentPath isEqualToString:expectedPath];
}

static pid_t find_aweme_pid(void) {
    int byteCount = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (byteCount <= 0) return 0;
    int *pids = (int *)calloc(1, (size_t)byteCount);
    if (!pids) return 0;
    int returned = proc_listpids(PROC_ALL_PIDS, 0, pids, byteCount);
    pid_t result = 0;
    for (int offset = 0; offset < returned / (int)sizeof(int); offset++) {
        if (pids[offset] > 0 && aweme_pid_is_current((pid_t)pids[offset])) {
            result = (pid_t)pids[offset];
            break;
        }
    }
    free(pids);
    return result;
}

static BOOL read_total_cpu_nanoseconds(pid_t pid, uint64_t *outCPU) {
    if (!outCPU || pid <= 0) return NO;
    aweme_rusage_info_v0 usage = {};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V0, &usage) != 0) return NO;
    *outCPU = usage.userTime + usage.systemTime;
    return YES;
}

static int validated_integer(id value, int fallback, int lower, int upper) {
    NSInteger parsed = fallback;
    if ([value respondsToSelector:@selector(integerValue)]) parsed = [value integerValue];
    if (parsed < lower || parsed > upper) return fallback;
    return (int)parsed;
}

static uint64_t run_aweme_cpu_guard(void) {
    static pid_t trackedPID = 0;
    static NSString *trackedPath = nil;
    static uint64_t trackedStartTime = 0;
    static uint64_t previousCPU = 0;
    static uint64_t previousWall = 0;
    static uint64_t exceededNanoseconds = 0;
    static BOOL wasExceeding = NO;

    NSDictionary *prefs = getPrefs() ?: @{};
    BOOL enabled = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : YES;
    int threshold = validated_integer(prefs[@"cpuThreshold"], 80, 1, 1000);
    int duration = validated_integer(prefs[@"durationSeconds"], 10, 1, 3600);
    if (!enabled) {
        trackedPID = 0;
        trackedPath = nil;
        trackedStartTime = 0;
        previousCPU = 0;
        previousWall = 0;
        exceededNanoseconds = 0;
        wasExceeding = NO;
        publish_status(AwemeCPUGuardStatusDisabled, 0, threshold, 0);
        return DISPATCH_TIME_FOREVER;
    }

    if (!gAwemeIsFrontmost.load(std::memory_order_acquire)) {
        // Background time must never contribute to either the CPU baseline or
        // the continuous-over-limit duration. No target CPU syscall is made.
        trackedPID = 0;
        trackedPath = nil;
        trackedStartTime = 0;
        previousCPU = 0;
        previousWall = 0;
        exceededNanoseconds = 0;
        wasExceeding = NO;
        publish_status(AwemeCPUGuardStatusWaitingForForeground, 0, threshold, 0);
        return kIdleSampleNanoseconds;
    }

    if (trackedPID <= 0 || !aweme_pid_matches_identity(trackedPID, trackedPath, trackedStartTime)) {
        trackedPID = find_aweme_pid();
        trackedPath = nil;
        trackedStartTime = 0;
        previousCPU = 0;
        previousWall = 0;
        exceededNanoseconds = 0;
        wasExceeding = NO;
        NSString *newPath = nil;
        uint64_t newStartTime = 0;
        if (trackedPID > 0 && read_aweme_identity(trackedPID, &newPath, &newStartTime)) {
            trackedPath = newPath;
            trackedStartTime = newStartTime;
            HBLogInfo(@"AwemeCPUGuard: tracking Aweme PID %d", trackedPID);
        } else {
            trackedPID = 0;
            trackedPath = nil;
            trackedStartTime = 0;
        }
    }
    if (trackedPID <= 0) {
        publish_status(AwemeCPUGuardStatusWaitingForProcess, 0, threshold, 0);
        // No CPU sampling occurs while Aweme is absent. This low-frequency
        // discovery pass preserves automatic monitoring after a relaunch.
        return kIdleSampleNanoseconds;
    }

    uint64_t currentCPU = 0;
    uint64_t currentWall = monotonic_nanoseconds();
    if (!read_total_cpu_nanoseconds(trackedPID, &currentCPU)) {
        trackedPID = 0;
        trackedPath = nil;
        trackedStartTime = 0;
        previousCPU = 0;
        previousWall = 0;
        exceededNanoseconds = 0;
        wasExceeding = NO;
        publish_status(AwemeCPUGuardStatusCPUReadFailed, 0, threshold, 0);
        return kIdleSampleNanoseconds;
    }
    if (previousWall == 0 || currentWall <= previousWall || currentCPU < previousCPU) {
        previousCPU = currentCPU;
        previousWall = currentWall;
        publish_status(AwemeCPUGuardStatusMonitoring, 0, threshold, 0);
        return kNearThresholdSampleNanoseconds;
    }

    uint64_t cpuDelta = currentCPU - previousCPU;
    uint64_t wallDelta = currentWall - previousWall;
    // ri_user_time and ri_system_time are Mach absolute-time units, while
    // CLOCK_MONOTONIC is represented here in nanoseconds. Convert the CPU
    // delta using the device timebase before comparing percentages.
    double cpuDeltaNanoseconds = mach_ticks_to_nanoseconds(cpuDelta);
    double totalCPUPercent = (cpuDeltaNanoseconds * 100.0) / (double)wallDelta;
    previousCPU = currentCPU;
    previousWall = currentWall;

    if (totalCPUPercent >= threshold) {
        // A long idle sample can only establish that CPU is high now; it
        // cannot prove that the whole preceding 60-second gap was above the
        // limit. Start continuous timing here, then verify every 500 ms.
        if (wasExceeding) {
            exceededNanoseconds += wallDelta;
        } else {
            exceededNanoseconds = 0;
            wasExceeding = YES;
        }
        double exceededSeconds = (double)exceededNanoseconds / (double)kNanosecondsPerSecond;
        publish_status(AwemeCPUGuardStatusThresholdExceeded, totalCPUPercent, threshold, exceededSeconds);
        if (exceededNanoseconds >= (uint64_t)duration * kNanosecondsPerSecond &&
            gAwemeIsFrontmost.load(std::memory_order_acquire) &&
            aweme_pid_matches_identity(trackedPID, trackedPath, trackedStartTime)) {
            HBLogInfo(@"AwemeCPUGuard: SIGKILL pid %d; total CPU %.1f%% reached %d%% for %d seconds", trackedPID, totalCPUPercent, threshold, duration);
            errno = 0;
            int killResult = kill(trackedPID, SIGKILL);
            publish_status(killResult == 0 ? AwemeCPUGuardStatusKilled : AwemeCPUGuardStatusKillFailed,
                totalCPUPercent, threshold, exceededSeconds);
            trackedPID = 0;
            trackedPath = nil;
            trackedStartTime = 0;
            exceededNanoseconds = 0;
            previousCPU = 0;
            previousWall = 0;
            wasExceeding = NO;
            return kIdleSampleNanoseconds;
        }
        return kExceededSampleNanoseconds;
    } else {
        exceededNanoseconds = 0;
        wasExceeding = NO;
        publish_status(AwemeCPUGuardStatusMonitoring, totalCPUPercent, threshold, 0);
        return totalCPUPercent >= ((double)threshold * 0.5)
            ? kNearThresholdSampleNanoseconds
            : kIdleSampleNanoseconds;
    }
}


%hook SpringBoard

- (void)frontDisplayDidChange:(id)newDisplay {
    %orig;
    BOOL isFrontmost = read_aweme_frontmost_on_main_thread();
    gAwemeIsFrontmost.store(isFrontmost, std::memory_order_release);
    if (gMonitorQueue) {
        dispatch_async(gMonitorQueue, ^{
            // Wake immediately on foreground/background transitions; the
            // guard itself remains the authority for the current frontmost ID.
            schedule_next_check(NSEC_PER_MSEC * 100ULL);
        });
    }
}

%end

%ctor {
    @autoreleasepool {
        if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            gAwemeIsFrontmost.store(read_aweme_frontmost_on_main_thread(), std::memory_order_release);
            gMonitorQueue = dispatch_queue_create("com.moxuan.awemecpuguard.monitor", DISPATCH_QUEUE_SERIAL);
            gMonitorTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gMonitorQueue);
            dispatch_source_set_event_handler(gMonitorTimer, ^{
                @autoreleasepool {
                    schedule_next_check(run_aweme_cpu_guard());
                }
            });
            schedule_next_check(NSEC_PER_SEC);
            dispatch_resume(gMonitorTimer);
            notify_register_dispatch([PREFS_CHANGED_NN UTF8String], &gPreferencesNotificationToken, gMonitorQueue, ^(int token) {
                schedule_next_check(NSEC_PER_MSEC * 100ULL);
            });
            publish_status(AwemeCPUGuardStatusWaitingForProcess, 0, 0, 0);
            HBLogInfo(@"AwemeCPUGuard: total CPU monitor started in SpringBoard");
        });
    }
}
