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

#import "CHPDaemonList.h"
#import "CHPDaemonInfo.h"
#import "../../Common.h"

@implementation CHPDaemonList

+ (instancetype)sharedInstance
{
	static CHPDaemonList* sharedInstance = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^
	{
		//Initialise instance
		sharedInstance = [[CHPDaemonList alloc] init];
	});
	return sharedInstance;
}

- (instancetype)init
{
	self = [super init];

	_observers = [NSHashTable weakObjectsHashTable];

	return self;
}

- (BOOL)daemonList:(NSArray*)daemonList containsDisplayName:(NSString*)displayName
{
	for(CHPDaemonInfo* info in daemonList)
	{
		if([info.displayName isEqualToString:displayName])
		{
			return YES;
		}
	}

	return NO;
}

- (void)updateDaemonListIfNeeded
{
	if(_loaded || _loading)
	{
		return;
	}

	_loading = YES;

	NSMutableArray<NSURL*>* daemonPlists = [([[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:@"/System/Library/LaunchDaemons"] includingPropertiesForKeys:nil options:0 error:nil] ?: @[]) mutableCopy];

	[daemonPlists addObjectsFromArray:[[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:@"/System/Library/NanoLaunchDaemons"] includingPropertiesForKeys:nil options:0 error:nil] ?: @[]];

	[daemonPlists addObjectsFromArray:[[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:VDT_JBROOT_PATH("/Library/LaunchDaemons")] includingPropertiesForKeys:nil options:0 error:nil] ?: @[]];

	for(NSURL* daemonPlistURL in [daemonPlists reverseObjectEnumerator])
	{
		if(![daemonPlistURL.pathExtension isEqualToString:@"plist"])
		{
			[daemonPlists removeObject:daemonPlistURL];
		}
	}

	NSMutableArray* daemonListM = [NSMutableArray new];

	for(NSURL* daemonPlistURL in daemonPlists)
	{
		NSDictionary* daemonDictionary = [NSDictionary dictionaryWithContentsOfURL:daemonPlistURL];

		CHPDaemonInfo* info = [[CHPDaemonInfo alloc] init];

		info.executablePath = [daemonDictionary objectForKey:@"Program"];

		if(!info.executablePath)
		{
			NSArray* programArguments = [daemonDictionary objectForKey:@"ProgramArguments"];
			if(programArguments.count > 0)
			{
				info.executablePath = programArguments.firstObject;
			}
		}

		info.plistIdentifier = [daemonPlistURL lastPathComponent].stringByDeletingPathExtension;

		if(info.executablePath && [[NSFileManager defaultManager] fileExistsAtPath:info.executablePath] && ![info.plistIdentifier hasSuffix:@"Jetsam"] && ![info.plistIdentifier hasSuffix:@"SimulateCrash"] && ![info.plistIdentifier hasSuffix:@"_v2"] && ![info.plistIdentifier isEqualToString:@"com.apple.SpringBoard"]) //Filter out some useless entries
		{
			if(![self daemonList:daemonListM containsDisplayName:info.displayName])
			{
				[daemonListM addObject:info];
			}
		}
	}

	[daemonListM sortUsingComparator:^NSComparisonResult(CHPDaemonInfo* a, CHPDaemonInfo* b)  //Sort alphabetically
	{
		return [[a displayName] localizedCaseInsensitiveCompare:[b displayName]];
	}];

	_daemonList = [daemonListM copy];
	_loading = NO;
	_loaded = YES;

	[self sendReloadToObservers];
}

- (void)addObserver:(id<CHPDaemonListObserver>)observer
{
	if(![_observers containsObject:observer])
	{
		[_observers addObject:observer];
	}
}

- (void)sendReloadToObservers
{
	for(id<CHPDaemonListObserver> observer in _observers)
	{
		dispatch_async(dispatch_get_main_queue(), ^
		{
			[observer daemonListDidUpdate:self];
		});
	}
}

@end
