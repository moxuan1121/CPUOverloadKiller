#import "VDTRootListController.h"
#import "VDTApplicationListSubcontrollerController.h"
#import "VDTProcessConfiguration.h"
#import "ChoicyPreferences/CHPDaemonListController.h"
#import "GCGTargetCell.h"
#import "../VDTShared.h"
#import "../PrivateHeaders.h"
#import <objc/message.h>

static UIImage *GCGIcon(NSString *identifier){SEL selector=NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");if(![UIImage respondsToSelector:selector])return nil;typedef UIImage *(*Fn)(id,SEL,NSString*,NSInteger,CGFloat);return GCGResizeIcon(((Fn)objc_msgSend)(UIImage.class,selector,identifier,2,UIScreen.mainScreen.scale));}
static NSString *GCGAppName(NSString *identifier){Class proxyClass=NSClassFromString(@"LSApplicationProxy");id proxy=[proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)]?[proxyClass applicationProxyForIdentifier:identifier]:nil;NSURL *bundleURL=[proxy respondsToSelector:@selector(bundleURL)]?[proxy bundleURL]:nil;NSBundle *bundle=bundleURL?[NSBundle bundleWithURL:bundleURL]:nil;return [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"]?:[bundle objectForInfoDictionaryKey:@"CFBundleName"]?:identifier;}

@implementation VDTRootListController
- (NSArray *)specifiers {
    if(_specifiers)return _specifiers;NSMutableArray *items=[NSMutableArray array];
    PSSpecifier *main=[PSSpecifier groupSpecifierWithName:@"全局 CPU 守护"];
    [main setProperty:@"只监控用户明确启用的应用和守护程序。应用默认仅在前台监控，可在单项设置中开启后台继续监控。" forKey:@"footerText"];[items addObject:main];
    PSSpecifier *enabled=[PSSpecifier preferenceSpecifierNamed:@"启用全局保护" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];[enabled setProperty:@"enabled" forKey:@"key"];[enabled setProperty:@YES forKey:@"default"];[enabled setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];[enabled setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];[items addObject:enabled];
    PSSpecifier *targets=[PSSpecifier groupSpecifierWithName:@"添加和管理目标"];[targets setProperty:@"点击添加进程后选择应用程序或守护程序。列表支持搜索；进入目标后可设置阈值、连续超限时间和低负载采样间隔。" forKey:@"footerText"];[items addObject:targets];
    PSSpecifier *add=[PSSpecifier preferenceSpecifierNamed:@"添加进程" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];[add setButtonAction:@selector(addProcess)];[items addObject:add];
    NSDictionary *prefs=getPrefs()?:@{};PSSpecifier *configured=[PSSpecifier groupSpecifierWithName:@"正在监控目标"];[configured setProperty:@"列表中的目标均已开启监控。左滑目标并删除即可关闭监控。" forKey:@"footerText"];[items addObject:configured];
    for(NSDictionary *config in [prefs[@"appConfigs"] isKindOfClass:NSArray.class]?prefs[@"appConfigs"]:@[]){NSString *identifier=config[@"bundleIdentifier"];if(!identifier.length||![config[@"enabled"] boolValue])continue;PSSpecifier *s=[PSSpecifier preferenceSpecifierNamed:GCGAppName(identifier) target:self set:nil get:nil detail:VDTProcessConfiguration.class cell:PSLinkCell edit:nil];[s setProperty:GCGTargetCell.class forKey:@"cellClass"];[s setProperty:identifier forKey:@"applicationIdentifier"];[s setProperty:@(VDTConfigTypeApp) forKey:@"configurationType"];UIImage *icon=GCGIcon(identifier);if(icon)[s setProperty:icon forKey:@"iconImage"];[s setProperty:identifier forKey:@"subtitle"];[items addObject:s];}
    for(NSDictionary *config in [prefs[@"daemonConfigs"] isKindOfClass:NSArray.class]?prefs[@"daemonConfigs"]:@[]){NSString *identifier=config[@"daemonName"];if(!identifier.length||![config[@"enabled"] boolValue])continue;PSSpecifier *s=[PSSpecifier preferenceSpecifierNamed:identifier target:self set:nil get:nil detail:VDTProcessConfiguration.class cell:PSLinkCell edit:nil];[s setProperty:GCGTargetCell.class forKey:@"cellClass"];[s setProperty:identifier forKey:@"daemonName"];[s setProperty:@(VDTConfigTypeDaemon) forKey:@"configurationType"];[s setProperty:@"守护程序" forKey:@"subtitle"];[s setProperty:GCGDaemonIcon() forKey:@"iconImage"];[items addObject:s];}
    PSSpecifier *about=[PSSpecifier groupSpecifierWithName:@"说明"];[about setProperty:@"CPU 低于阈值 50% 时使用低负载间隔；接近阈值每 1 秒检测；超限后每 0.5 秒检测。终止前重新校验 PID、路径、标识和启动时间。关键系统及越狱核心进程禁止启用。" forKey:@"footerText"];[items addObject:about];
    _specifiers=items;return _specifiers;
}
- (void)addProcess{
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"选择目标" message:@"选择添加的进程类型" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf=self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"应用程序" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[weakSelf.navigationController pushViewController:[VDTApplicationListSubcontrollerController new] animated:YES];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"守护程序" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[weakSelf.navigationController pushViewController:[CHPDaemonListController new] animated:YES];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover=sheet.popoverPresentationController;if(popover){popover.sourceView=self.view;popover.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMaxY(self.view.bounds)-1,1,1);}
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)viewWillAppear:(BOOL)animated{[super viewWillAppear:animated];if(_specifiers){_specifiers=nil;[self reloadSpecifiers];}}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath{
    PSSpecifier *specifier=[self specifierAtIndex:[self indexForIndexPath:indexPath]];
    return [specifier propertyForKey:@"configurationType"]!=nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath{return @"删除";}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath{
    if(editingStyle!=UITableViewCellEditingStyleDelete)return;
    PSSpecifier *specifier=[self specifierAtIndex:[self indexForIndexPath:indexPath]];
    NSNumber *typeNumber=[specifier propertyForKey:@"configurationType"];
    if(!typeNumber)return;
    VDTConfigType type=(VDTConfigType)typeNumber.unsignedIntegerValue;
    NSString *identifier=[specifier propertyForKey:type==VDTConfigTypeApp?@"applicationIdentifier":@"daemonName"];
    if(identifier.length)setValueForProcessConfigKey(identifier,@"enabled",@NO,type);
    _specifiers=nil;[self reloadSpecifiers];
}
- (id)readPreferenceValue:(PSSpecifier *)specifier{return valueForKey([specifier propertyForKey:@"key"])?:[specifier propertyForKey:@"default"];}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier{setValueForKey([specifier propertyForKey:@"key"],value);}
@end
