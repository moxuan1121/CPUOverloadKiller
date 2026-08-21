// Copyright (c) 2019-2021 Lars Fröder

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#import "CHPDaemonListController.h"

#import "CHPDaemonInfo.h"
#import "CHPDaemonList.h"
#import "../VDTProcessConfiguration.h"
#import "../GCGTargetCell.h"
#import "../../VDTShared.h"

@implementation CHPDaemonListController

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if([self valueForKey:@"_specifiers"]) [self reloadSpecifiers];
}

- (void)viewDidLoad
{
	[self applySearchControllerHideWhileScrolling:NO];
	self.navigationItem.title=@"守护程序";
	[[CHPDaemonList sharedInstance] addObserver:self];

	if(![CHPDaemonList sharedInstance].loaded)
	{
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
		{
			[[CHPDaemonList sharedInstance] updateDaemonListIfNeeded];
		});
	}
	[super viewDidLoad];
}

- (NSMutableArray*)specifiers
{
	NSMutableArray* specifiers = [self valueForKey:@"_specifiers"];

	if(!specifiers)
	{
		specifiers = [NSMutableArray new];

        if (@available(iOS 11.0, *)){
        }else{
			[specifiers addObject:[PSSpecifier emptyGroupSpecifier]];
			[specifiers addObject:[PSSpecifier emptyGroupSpecifier]];
		}

		if(![CHPDaemonList sharedInstance].loaded)
		{
			PSSpecifier* loadingIndicator = [PSSpecifier preferenceSpecifierNamed:@""
							target:self
							set:nil
							get:nil
							detail:nil
							cell:[PSTableCell cellTypeFromString:@"PSSpinnerCell"]
							edit:nil];

			[specifiers addObject:loadingIndicator];
		}
		else
		{
			NSArray<CHPDaemonInfo*>* daemonList = [CHPDaemonList sharedInstance].daemonList;

			for(CHPDaemonInfo* info in daemonList)
			{
				@autoreleasepool
				{
					if(_searchKey && ![_searchKey isEqualToString:@""])
					{
						if(![[info displayName] localizedStandardContainsString:_searchKey] &&
						   ![info.plistIdentifier localizedStandardContainsString:_searchKey] &&
						   ![info.executablePath.lastPathComponent localizedStandardContainsString:_searchKey])
						{
							continue;
						}
					}
					
					PSSpecifier* specifier = [PSSpecifier preferenceSpecifierNamed:[info displayName]
								target:self
								set:nil
								get:nil
								detail:[VDTProcessConfiguration class]
								cell:PSLinkListCell
								edit:nil];
                    [specifier setProperty:@(VDTConfigTypeDaemon) forKey:@"configurationType"];
					[specifier setProperty:GCGTargetCell.class forKey:@"cellClass"];

					[specifier setProperty:@YES forKey:@"enabled"];
					[specifier setProperty:[info displayName] forKey:@"daemonName"];
					[specifier setProperty:info forKey:@"daemonInfo"];
					[specifier setProperty:(info.plistIdentifier.length?info.plistIdentifier:info.executablePath.lastPathComponent) forKey:@"subtitle"];
					[specifier setProperty:GCGDaemonIcon() forKey:@"iconImage"];

					[specifiers addObject:specifier];
				}
			}
		}

		[self setValue:specifiers forKey:@"_specifiers"];
	}

	return specifiers;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    PSSpecifier *specifier=[self specifierAtIndex:[self indexForIndexPath:indexPath]];
    NSString *identifier=[specifier propertyForKey:@"daemonName"];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if(!identifier.length)return;
    if(GCGIdentifierIsProtected(identifier)){
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"禁止添加" message:@"该目标属于关键系统或越狱核心进程，不能启用 CPU 终止监控。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    CHPDaemonInfo *info=[specifier propertyForKey:@"daemonInfo"];
    if(info.executablePath.length)setValueForProcessConfigKey(identifier,@"executablePath",info.executablePath,VDTConfigTypeDaemon);
    setValueForProcessConfigKey(identifier,@"enabled",@YES,VDTConfigTypeDaemon);
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)daemonListDidUpdate:(CHPDaemonList*)list
{
	[self reloadSpecifiers];
}

@end
