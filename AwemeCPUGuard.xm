#import "Common.h"
#import "PrivateHeaders.h"
#import "VDTShared.h"

#include <libproc/libproc.h>
#include <libproc/libproc_internal.h>
#include <signal.h>
#include <time.h>

static NSString * const kAwemeBundleIdentifier = @"com.ss.iphone.ugc.Aweme";
static const uint64_t kNanosecondsPerSecond = 1000000000ULL;
static dispatch_source_t gMonitorTimer;

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
    LSApplicationProxy *proxy = [objc_getClass("LSApplicationProxy") applicationProxyForBundleURL:[NSURL fileURLWithPath:bundlePath]];
    return [proxy.bundleIdentifier isEqualToString:kAwemeBundleIdentifier];
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

static void run_aweme_cpu_guard(void) {
    static pid_t trackedPID = 0;
    static uint64_t previousCPU = 0;
    static uint64_t previousWall = 0;
    static uint64_t exceededSince = 0;

    NSDictionary *prefs = getPrefs() ?: @{};
    BOOL enabled = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : YES;
    int threshold = validated_integer(prefs[@"cpuThreshold"], 80, 1, 100);
    int duration = validated_integer(prefs[@"durationSeconds"], 10, 1, 3600);
    if (!enabled) {
        trackedPID = 0;
        exceededSince = 0;
        return;
    }

    if (trackedPID <= 0 || !aweme_pid_is_current(trackedPID)) {
        trackedPID = find_aweme_pid();
        previousCPU = 0;
        previousWall = 0;
        exceededSince = 0;
        if (trackedPID > 0) HBLogInfo(@"AwemeCPUGuard: tracking Aweme PID %d", trackedPID);
    }
    if (trackedPID <= 0) return;

    uint64_t currentCPU = 0;
    uint64_t currentWall = monotonic_nanoseconds();
    if (!read_total_cpu_nanoseconds(trackedPID, &currentCPU)) {
        trackedPID = 0;
        exceededSince = 0;
        return;
    }
    if (previousWall == 0 || currentWall <= previousWall || currentCPU < previousCPU) {
        previousCPU = currentCPU;
        previousWall = currentWall;
        return;
    }

    uint64_t cpuDelta = currentCPU - previousCPU;
    uint64_t wallDelta = currentWall - previousWall;
    double totalCPUPercent = ((double)cpuDelta * 100.0) / (double)wallDelta;
    previousCPU = currentCPU;
    previousWall = currentWall;

    if (totalCPUPercent > threshold) {
        if (exceededSince == 0) exceededSince = currentWall;
        uint64_t elapsed = currentWall - exceededSince;
        if (elapsed >= (uint64_t)duration * kNanosecondsPerSecond && aweme_pid_is_current(trackedPID)) {
            HBLogInfo(@"AwemeCPUGuard: SIGKILL pid %d; total CPU %.1f%% exceeded %d%% for %d seconds", trackedPID, totalCPUPercent, threshold, duration);
            kill(trackedPID, SIGKILL);
            trackedPID = 0;
            exceededSince = 0;
            previousCPU = 0;
            previousWall = 0;
        }
    } else {
        exceededSince = 0;
    }
}

%ctor {
    @autoreleasepool {
        if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"runningboardd"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_queue_t queue = dispatch_queue_create("com.moxuan.awemecpuguard.monitor", DISPATCH_QUEUE_SERIAL);
            gMonitorTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
            dispatch_source_set_timer(gMonitorTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_MSEC * 100);
            dispatch_source_set_event_handler(gMonitorTimer, ^{ @autoreleasepool { run_aweme_cpu_guard(); } });
            dispatch_resume(gMonitorTimer);
            HBLogInfo(@"AwemeCPUGuard: total CPU monitor started in runningboardd");
        });
    }
}
