#import "VDTRootListController.h"
#import "VDTApplicationListSubcontrollerController.h"
#import "ChoicyPreferences/CHPDaemonListController.h"
#import "../VDTShared.h"

@implementation VDTRootListController
- (NSArray *)specifiers {
    if(_specifiers)return _specifiers;NSMutableArray *items=[NSMutableArray array];
    PSSpecifier *main=[PSSpecifier groupSpecifierWithName:@"全局 CPU 守护"];
    [main setProperty:@"只监控用户明确启用的应用和守护程序。应用默认仅在前台监控，可在单项设置中开启后台继续监控。" forKey:@"footerText"];[items addObject:main];
    PSSpecifier *enabled=[PSSpecifier preferenceSpecifierNamed:@"启用全局保护" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];[enabled setProperty:@"enabled" forKey:@"key"];[enabled setProperty:@YES forKey:@"default"];[enabled setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];[enabled setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];[items addObject:enabled];
    PSSpecifier *targets=[PSSpecifier groupSpecifierWithName:@"添加和管理目标"];[targets setProperty:@"列表支持搜索。进入目标后可设置阈值、连续超限时间和低负载采样间隔。已启用目标会在列表右侧显示。" forKey:@"footerText"];[items addObject:targets];
    PSSpecifier *apps=[PSSpecifier preferenceSpecifierNamed:@"应用程序" target:self set:nil get:nil detail:VDTApplicationListSubcontrollerController.class cell:PSLinkCell edit:nil];[items addObject:apps];
    PSSpecifier *daemons=[PSSpecifier preferenceSpecifierNamed:@"守护程序" target:self set:nil get:nil detail:CHPDaemonListController.class cell:PSLinkCell edit:nil];[items addObject:daemons];
    PSSpecifier *about=[PSSpecifier groupSpecifierWithName:@"说明"];[about setProperty:@"CPU 低于阈值 50% 时使用低负载间隔；接近阈值每 1 秒检测；超限后每 0.5 秒检测。终止前重新校验 PID、路径、标识和启动时间。关键系统及越狱核心进程禁止启用。" forKey:@"footerText"];[items addObject:about];
    _specifiers=items;return _specifiers;
}
- (id)readPreferenceValue:(PSSpecifier *)specifier{return valueForKey([specifier propertyForKey:@"key"])?:[specifier propertyForKey:@"default"];}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier{setValueForKey([specifier propertyForKey:@"key"],value);}
@end
