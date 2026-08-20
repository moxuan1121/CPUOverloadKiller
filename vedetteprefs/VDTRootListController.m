#import "VDTRootListController.h"
#import "../VDTShared.h"

@implementation VDTRootListController

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *items = [NSMutableArray array];

    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"抖音 CPU 保护" target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
    [group setProperty:@"只监控 com.ss.iphone.ugc.Aweme。进程所有线程的 CPU 总和连续超过阈值达到设定秒数后，将终止抖音进程。" forKey:@"footerText"];
    [items addObject:group];

    PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:@"启用 CPU 保护" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
    [enabled setProperty:@"enabled" forKey:@"key"];
    [enabled setProperty:@YES forKey:@"default"];
    [enabled setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
    [enabled setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
    [items addObject:enabled];

    PSSpecifier *conditions = [PSSpecifier preferenceSpecifierNamed:@"触发条件" target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
    [conditions setProperty:@"两个数值均可手动输入。CPU 低于阈值时，连续超标计时会立即清零。" forKey:@"footerText"];
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

    _specifiers = items;
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return valueForKey(specifier.properties[@"key"]) ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    if ([key isEqualToString:@"cpuThreshold"] || [key isEqualToString:@"durationSeconds"]) {
        NSInteger number = [value integerValue];
        NSInteger minimum = [key isEqualToString:@"cpuThreshold"] ? 1 : 1;
        NSInteger maximum = [key isEqualToString:@"cpuThreshold"] ? 100 : 3600;
        if (number < minimum) number = minimum;
        if (number > maximum) number = maximum;
        value = @(number);
    }
    setValueForKey(key, value);
}
@end
