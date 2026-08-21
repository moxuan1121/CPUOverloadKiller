#import "VDTApplicationListSubcontrollerController.h"
#import "VDTProcessConfiguration.h"
#import "GCGTargetCell.h"
#import "../PrivateHeaders.h"
#import "../VDTShared.h"
static NSString *VDTDisplayName(LSApplicationProxy *proxy){
    NSString *name = [proxy respondsToSelector:@selector(localizedName)] ? proxy.localizedName : nil;
    if (!name.length) name = proxy.bundleExecutable;
    return name.length ? name : proxy.bundleIdentifier;
}

@implementation VDTApplicationListSubcontrollerController

- (void)viewWillAppear:(BOOL)animated{ [super viewWillAppear:animated]; if(_specifiers)[self reloadSpecifiers]; }

- (void)viewDidLoad{
    _loadingApplications=YES;
    [self applySearchControllerHideWhileScrolling:YES];
    [super viewDidLoad];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        @autoreleasepool{
            NSMutableArray *apps=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
            for(LSApplicationProxy *proxy in [[objc_getClass("LSApplicationWorkspace") defaultWorkspace] allApplications]){
                if(!proxy.bundleIdentifier.length||[seen containsObject:proxy.bundleIdentifier])continue;
                [seen addObject:proxy.bundleIdentifier];[apps addObject:proxy];
            }
            [apps sortUsingComparator:^NSComparisonResult(LSApplicationProxy *left,LSApplicationProxy *right){return [VDTDisplayName(left) localizedCaseInsensitiveCompare:VDTDisplayName(right)];}];
            dispatch_async(dispatch_get_main_queue(),^{self->_applications=apps.copy;self->_loadingApplications=NO;self->_specifiers=nil;[self reloadSpecifiers];});
        }
    });
}

- (NSString *)topTitle{ return @"应用程序"; }
- (NSString *)plistName{ return nil; }

- (NSMutableArray *)specifiers{
    if (!_specifiers){
        NSMutableArray *result = [NSMutableArray array];
        if(_loadingApplications){PSSpecifier *spinner=[PSSpecifier preferenceSpecifierNamed:@"" target:self set:nil get:nil detail:nil cell:[PSTableCell cellTypeFromString:@"PSSpinnerCell"] edit:nil];[result addObject:spinner];}
        for (LSApplicationProxy *proxy in _applications){
            NSString *identifier = proxy.bundleIdentifier;
            NSString *name = VDTDisplayName(proxy);
            if (_searchKey.length && ![name localizedStandardContainsString:_searchKey] &&
                ![identifier localizedStandardContainsString:_searchKey]) continue;
            PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name target:self set:nil
                get:nil detail:[VDTProcessConfiguration class]
                cell:PSLinkListCell edit:nil];
            [specifier setProperty:GCGTargetCell.class forKey:@"cellClass"];
            [specifier setProperty:@YES forKey:@"enabled"];
            [specifier setProperty:identifier forKey:@"applicationIdentifier"];
            [specifier setProperty:@(VDTConfigTypeApp) forKey:@"configurationType"];
            [specifier setProperty:identifier forKey:@"subtitle"];
            [result addObject:specifier];
        }
        _specifiers = result;
    }
    self.navigationItem.title = [self topTitle];
    return _specifiers;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
    PSSpecifier *specifier=[self specifierAtIndex:[self indexForIndexPath:indexPath]];
    NSString *identifier=[specifier propertyForKey:@"applicationIdentifier"];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if(!identifier.length)return;
    setValueForProcessConfigKey(identifier,@"enabled",@YES,VDTConfigTypeApp);
    [self.navigationController popViewControllerAnimated:YES];
}

@end
