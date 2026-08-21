#import "VDTProcessConfiguration.h"
#import "../VDTShared.h"
#include <notify.h>

@implementation VDTProcessConfiguration

- (VDTConfigType)type { return (VDTConfigType)[[[self specifier] propertyForKey:@"configurationType"] unsignedIntegerValue]; }
- (NSString *)identifier { return [[self specifier] propertyForKey:[self type]==VDTConfigTypeApp?@"applicationIdentifier":@"daemonName"]; }
- (BOOL)protectedTarget { return GCGIdentifierIsProtected([self identifier]); }

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *items=[NSMutableArray array];
    PSSpecifier *group=[PSSpecifier groupSpecifierWithName:[self type]==VDTConfigTypeApp?@"应用 CPU 保护":@"守护程序 CPU 保护"];
    [group setProperty:@"此目标已开启监控。返回主页左滑删除可关闭监控。" forKey:@"footerText"];
    [items addObject:group];
    if([self type]==VDTConfigTypeApp){PSSpecifier *background=[PSSpecifier preferenceSpecifierNamed:@"后台继续监控" target:self set:@selector(setValue:specifier:) get:@selector(readValue:) detail:nil cell:PSSwitchCell edit:nil];[background setProperty:@"monitorInBackground" forKey:@"key"];[background setProperty:@NO forKey:@"default"];[items addObject:background];}
    PSSpecifier *parameters=[PSSpecifier groupSpecifierWithName:@"触发条件"];[parameters setProperty:@"CPU 上限支持 2–1000%，可覆盖多核负载。只有连续超限达到设定时间才会终止进程。" forKey:@"footerText"];[items addObject:parameters];
    NSArray *fields=@[@[@"CPU 上限 (%)",@"cpuThreshold",@80,@"80"],@[@"连续超限 (秒)",@"durationSeconds",@10,@"10"],@[@"采样策略",@"__group__",@0,@""],@[@"低负载采样间隔 (秒)",@"idleSampleSeconds",@60,@"60"],@[@"接近阈值下限 (%)",@"nearThresholdPercent",@53,@"53"],@[@"接近阈值采样间隔 (秒)",@"nearSampleSeconds",@15,@"15"],@[@"超限采样间隔 (秒)",@"exceedSampleSeconds",@1,@"1"]];
    for(NSArray *field in fields){if([field[1] isEqual:@"__group__"]){PSSpecifier *sampling=[PSSpecifier groupSpecifierWithName:@"采样策略"];[sampling setProperty:@"低于接近阈值使用低负载间隔；达到接近阈值后使用接近阈值间隔；达到 CPU 上限后使用超限间隔并累计连续超限时间。超限采样间隔不能大于连续超限时间。" forKey:@"footerText"];[items addObject:sampling];continue;}PSTextFieldSpecifier *s=[PSTextFieldSpecifier preferenceSpecifierNamed:field[0] target:self set:@selector(setValue:specifier:) get:@selector(readValue:) detail:nil cell:PSEditTextCell edit:nil];[s setKeyboardType:UIKeyboardTypeNumberPad autoCaps:UITextAutocapitalizationTypeNone autoCorrection:UITextAutocorrectionTypeNo];[s setProperty:field[1] forKey:@"key"];[s setProperty:field[2] forKey:@"default"];[s setPlaceholder:field[3]];[items addObject:s];}
    PSSpecifier *statusGroup=[PSSpecifier groupSpecifierWithName:@"运行状态"];[statusGroup setProperty:@"监控端会持续记录状态，但本页面不会自动刷新。需要查看最新状态时请点按刷新。" forKey:@"footerText"];[items addObject:statusGroup];
    PSSpecifier *status=[PSSpecifier preferenceSpecifierNamed:@"当前状态" target:self set:nil get:@selector(readStatus:) detail:nil cell:PSTitleValueCell edit:nil];status.identifier=@"runtimeStatus";[items addObject:status];
    PSSpecifier *refresh=[PSSpecifier preferenceSpecifierNamed:@"刷新当前状态" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];[refresh setButtonAction:@selector(refreshStatus)];[items addObject:refresh];
    for(PSSpecifier *s in items)if([s propertyForKey:@"key"]){[s setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];[s setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];}
    _specifiers=items;self.navigationItem.title=[self identifier];return _specifiers;
}

- (id)readValue:(PSSpecifier *)specifier { return valueForProcessConfigKey([self identifier],[specifier propertyForKey:@"key"],[specifier propertyForKey:@"default"],[self type]); }
- (void)setValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key=[specifier propertyForKey:@"key"];
    if(![key isEqual:@"enabled"]&&![key isEqual:@"monitorInBackground"]){
        NSInteger n=[value integerValue];
        NSInteger max=[key isEqual:@"cpuThreshold"]?1000:3600;
        if([key isEqual:@"cpuThreshold"]&&n<2)n=2;
        else if(n<1)n=1;
        if(n>max)n=max;
        if([key isEqual:@"nearThresholdPercent"]){NSInteger threshold=[[self readValueForKey:@"cpuThreshold"] integerValue];if(threshold<2)threshold=80;if(n>=threshold)n=threshold-1;}
        if([key isEqual:@"exceedSampleSeconds"]){NSInteger duration=[[self readValueForKey:@"durationSeconds"] integerValue];if(duration<1)duration=10;if(n>duration)n=duration;}
        value=@(n);
    }
    if([self type]==VDTConfigTypeDaemon){id info=[[self specifier] propertyForKey:@"daemonInfo"];NSString *path=[info respondsToSelector:@selector(executablePath)]?[info executablePath]:nil;if(path.length)setValueForProcessConfigKey([self identifier],@"executablePath",path,[self type]);}
    setValueForProcessConfigKey([self identifier],key,value,[self type]);
    if([key isEqual:@"cpuThreshold"]){NSInteger threshold=[value integerValue];NSInteger near=[[self readValueForKey:@"nearThresholdPercent"] integerValue];if(near>=threshold)setValueForProcessConfigKey([self identifier],@"nearThresholdPercent",@(MAX(1,threshold-1)),[self type]);}
    if([key isEqual:@"durationSeconds"]){NSInteger duration=[value integerValue];NSInteger exceed=[[self readValueForKey:@"exceedSampleSeconds"] integerValue];if(exceed>duration)setValueForProcessConfigKey([self identifier],@"exceedSampleSeconds",@(duration),[self type]);}
}
- (id)readValueForKey:(NSString *)key{return valueForProcessConfigKey([self identifier],key,nil,[self type]);}
- (id)readStatus:(PSSpecifier *)specifier {
    NSString *name=GCGStatusNotificationName([self type],[self identifier]);int token=-1;uint64_t state=0;if(notify_register_check(name.UTF8String,&token)==NOTIFY_STATUS_OK){notify_get_state(token,&state);notify_cancel(token);}
    AwemeCPUGuardStatus status=AwemeCPUGuardDecodeStatus(state);double cpu=AwemeCPUGuardDecodeCPUTenths(state)/10.0;double exceeded=AwemeCPUGuardDecodeExceededTenths(state)/10.0;
    switch(status){case AwemeCPUGuardStatusWaitingForProcess:return @"等待进程启动";case AwemeCPUGuardStatusWaitingForForeground:return @"等待进入前台";case AwemeCPUGuardStatusMonitoring:return [NSString stringWithFormat:@"正在监控：%.1f%%",cpu];case AwemeCPUGuardStatusThresholdExceeded:return [NSString stringWithFormat:@"已超限：%.1f%% / %.1f 秒",cpu,exceeded];case AwemeCPUGuardStatusKilled:return @"已终止";case AwemeCPUGuardStatusCPUReadFailed:return @"CPU 读取失败";case AwemeCPUGuardStatusKillFailed:return @"终止失败";default:return [self protectedTarget]?@"系统保护":@"尚无运行状态";}
}
- (void)refreshStatus { notify_post(PREFS_CHANGED_NN.UTF8String);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_MSEC*400),dispatch_get_main_queue(),^{[self reloadSpecifierID:@"runtimeStatus" animated:YES];}); }
@end
