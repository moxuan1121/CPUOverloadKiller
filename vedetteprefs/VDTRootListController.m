#import "VDTRootListController.h"
#import "../VDTShared.h"
#include <notify.h>

@implementation VDTRootListController

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *items = [NSMutableArray array];

    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"抖音 CPU 保护" target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
    [group setProperty:@"只监控 com.ss.iphone.ugc.Aweme。进程所有线程的 CPU 总和达到或超过阈值并连续保持设定秒数后，将终止抖音进程。" forKey:@"footerText"];
    [items addObject:group];

    PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:@"启用 CPU 保护" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
    [enabled setProperty:@"enabled" forKey:@"key"];
    [enabled setProperty:@YES forKey:@"default"];
    [enabled setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
    [enabled setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
    [items addObject:enabled];

    PSSpecifier *status = [PSSpecifier preferenceSpecifierNamed:@"当前状态" target:self set:nil get:@selector(readRuntimeStatus:) detail:nil cell:PSTitleValueCell edit:nil];
    self.runtimeStatusSpecifier = status;
    [items addObject:status];

    PSSpecifier *refreshStatus = [PSSpecifier preferenceSpecifierNamed:@"刷新当前状态" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    [refreshStatus setButtonAction:@selector(refreshRuntimeStatus)];
    [items addObject:refreshStatus];

    PSSpecifier *conditions = [PSSpecifier preferenceSpecifierNamed:@"触发条件" target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
    [conditions setProperty:@"三个数值均可手动输入。CPU 低于阈值时，连续超标计时会立即清零；低于阈值 50% 时使用低负载采样间隔。" forKey:@"footerText"];
    [items addObject:conditions];

    PSSpecifier *threshold = [PSSpecifier preferenceSpecifierNamed:@"总 CPU 上限 (%)" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSEditTextCell edit:nil];
    [threshold setProperty:@(UIKeyboardTypeNumberPad) forKey:@"keyboardType"];
    [threshold setProperty:@"cpuThreshold" forKey:@"key"];
    [threshold setProperty:@80 forKey:@"default"];
    [threshold setProperty:@"80" forKey:@"placeholder"];
    [threshold setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
    [threshold setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
    [items addObject:threshold];

    PSSpecifier *duration = [PSSpecifier preferenceSpecifierNamed:@"连续超标 (秒)" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSEditTextCell edit:nil];
    [duration setProperty:@(UIKeyboardTypeNumberPad) forKey:@"keyboardType"];
    [duration setProperty:@"durationSeconds" forKey:@"key"];
    [duration setProperty:@10 forKey:@"default"];
    [duration setProperty:@"10" forKey:@"placeholder"];
    [duration setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
    [duration setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
    [items addObject:duration];

    PSSpecifier *idleSample = [PSSpecifier preferenceSpecifierNamed:@"低负载采样间隔 (秒)" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSEditTextCell edit:nil];
    [idleSample setProperty:@(UIKeyboardTypeNumberPad) forKey:@"keyboardType"];
    [idleSample setProperty:@"idleSampleSeconds" forKey:@"key"];
    [idleSample setProperty:@60 forKey:@"default"];
    [idleSample setProperty:@"60" forKey:@"placeholder"];
    [idleSample setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
    [idleSample setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
    [items addObject:idleSample];

    _specifiers = items;
    return _specifiers;
}

- (void)refreshRuntimeStatus {
    // Wake the monitor even if it is currently in the configurable low-load
    // sleep, then refresh the value after it has had time to publish status.
    notify_post([PREFS_CHANGED_NN UTF8String]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 350), dispatch_get_main_queue(), ^{
        if (self.runtimeStatusSpecifier) {
            [self reloadSpecifier:self.runtimeStatusSpecifier animated:YES];
        }
    });
}

- (id)readRuntimeStatus:(PSSpecifier *)specifier {
    int token = -1;
    uint64_t state = AwemeCPUGuardStatusUnknown;
    if (notify_register_check(AWEME_CPU_GUARD_STATUS_NN, &token) == NOTIFY_STATUS_OK) {
        notify_get_state(token, &state);
        notify_cancel(token);
    }
    AwemeCPUGuardStatus status = AwemeCPUGuardDecodeStatus(state);
    double cpu = (double)AwemeCPUGuardDecodeCPUTenths(state) / 10.0;
    NSUInteger threshold = AwemeCPUGuardDecodeThreshold(state);
    double exceeded = (double)AwemeCPUGuardDecodeExceededTenths(state) / 10.0;
    switch (status) {
        case AwemeCPUGuardStatusDisabled: return @"已停用";
        case AwemeCPUGuardStatusWaitingForProcess: return @"等待抖音启动";
        case AwemeCPUGuardStatusMonitoring:
            return [NSString stringWithFormat:@"正在监控：%.1f%% / 阈值 %lu%%", cpu, (unsigned long)threshold];
        case AwemeCPUGuardStatusThresholdExceeded:
            return [NSString stringWithFormat:@"已超限：%.1f%%，连续 %.1f 秒", cpu, exceeded];
        case AwemeCPUGuardStatusKilled:
            return [NSString stringWithFormat:@"已终止抖音：%.1f%%", cpu];
        case AwemeCPUGuardStatusCPUReadFailed: return @"CPU 读取失败";
        case AwemeCPUGuardStatusWaitingForForeground: return @"等待抖音进入前台";
        case AwemeCPUGuardStatusKillFailed:
            return [NSString stringWithFormat:@"终止失败：%.1f%%", cpu];
        default: return @"插件未在 SpringBoard 中运行";
    }
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return valueForKey(specifier.properties[@"key"]) ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    if ([key isEqualToString:@"cpuThreshold"] || [key isEqualToString:@"durationSeconds"] || [key isEqualToString:@"idleSampleSeconds"]) {
        NSInteger number = [value integerValue];
        NSInteger minimum = [key isEqualToString:@"cpuThreshold"] ? 1 : 1;
        NSInteger maximum = [key isEqualToString:@"cpuThreshold"] ? 1000 : 3600;
        if (number < minimum) number = minimum;
        if (number > maximum) number = maximum;
        value = @(number);
    }
    setValueForKey(key, value);
}
@end
