#import "VDTApplicationListSubcontrollerController.h"
#import "VDTProcessConfiguration.h"
#import "GCGTargetCell.h"
#import "../PrivateHeaders.h"
#import "../VDTShared.h"
#import <objc/message.h>

static NSString *VDTDisplayName(LSApplicationProxy *proxy){
    NSBundle *bundle = [NSBundle bundleWithURL:proxy.bundleURL];
    NSString *name = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
    if (!name.length) name = [bundle objectForInfoDictionaryKey:@"CFBundleName"];
    if (!name.length) name = proxy.bundleExecutable;
    return name.length ? name : proxy.bundleIdentifier;
}

static UIImage *VDTIcon(NSString *identifier){
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:selector]) return nil;
    typedef UIImage *(*IconFunction)(id, SEL, NSString *, NSInteger, CGFloat);
    return GCGResizeIcon(((IconFunction)objc_msgSend)(UIImage.class, selector, identifier, 2, UIScreen.mainScreen.scale));
}

@implementation VDTApplicationListSubcontrollerController

- (void)viewWillAppear:(BOOL)animated{ [super viewWillAppear:animated]; if(_specifiers)[self reloadSpecifiers]; }

- (void)viewDidLoad{
    NSMutableArray *apps = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (LSApplicationProxy *proxy in [[objc_getClass("LSApplicationWorkspace") defaultWorkspace] allApplications]){
        if (!proxy.bundleIdentifier.length || [seen containsObject:proxy.bundleIdentifier]) continue;
        [seen addObject:proxy.bundleIdentifier];
        [apps addObject:proxy];
    }
    [apps sortUsingComparator:^NSComparisonResult(LSApplicationProxy *left, LSApplicationProxy *right) {
        return [VDTDisplayName(left) localizedCaseInsensitiveCompare:VDTDisplayName(right)];
    }];
    _applications = apps.copy;
    [self applySearchControllerHideWhileScrolling:YES];
    [super viewDidLoad];
}

- (NSString *)topTitle{ return @"应用程序"; }
- (NSString *)plistName{ return nil; }

- (NSMutableArray *)specifiers{
    if (!_specifiers){
        NSMutableArray *result = [NSMutableArray array];
        for (LSApplicationProxy *proxy in _applications){
            NSString *identifier = proxy.bundleIdentifier;
            NSString *name = VDTDisplayName(proxy);
            if (_searchKey.length && ![name localizedStandardContainsString:_searchKey] &&
                ![identifier localizedStandardContainsString:_searchKey]) continue;
            PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name target:self set:nil
                get:@selector(previewStringForSpecifier:) detail:[VDTProcessConfiguration class]
                cell:PSLinkListCell edit:nil];
            [specifier setProperty:GCGTargetCell.class forKey:@"cellClass"];
            [specifier setProperty:identifier forKey:@"applicationIdentifier"];
            [specifier setProperty:@(VDTConfigTypeApp) forKey:@"configurationType"];
            [specifier setProperty:identifier forKey:@"subtitle"];
            UIImage *icon = VDTIcon(identifier);
            if (icon) [specifier setProperty:icon forKey:@"iconImage"];
            [result addObject:specifier];
        }
        _specifiers = result;
    }
    self.navigationItem.title = [self topTitle];
    return _specifiers;
}

- (id)previewStringForSpecifier:(PSSpecifier *)specifier{
    return [valueForProcessConfigKey([specifier propertyForKey:@"applicationIdentifier"], @"enabled", @NO,
        VDTConfigTypeApp) boolValue] ? @"已启用" : @"";
}

- (PSSpecifier *)specifierForApplicationWithIdentifier:(NSString *)identifier{
    for (PSSpecifier *specifier in [self specifiers]){
        if ([[specifier propertyForKey:@"applicationIdentifier"] isEqualToString:identifier]) return specifier;
    }
    return nil;
}
@end
