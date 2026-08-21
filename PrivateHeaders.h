//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"

@interface _LSQueryResult : NSObject
@end

@interface LSResourceProxy : _LSQueryResult
@end

@interface LSBundleProxy : LSResourceProxy
@property (nonatomic,readonly) NSString * bundleIdentifier;
@property (nonatomic,readonly) NSString * bundleExecutable;
@property (nonatomic,readonly) NSURL * bundleURL;
@property (nonatomic,readonly) NSURL * bundleContainerURL;
@property (nonatomic,readonly) NSURL * dataContainerURL;
@end

@interface LSApplicationProxy : LSBundleProxy
+(id)applicationProxyForBundleURL:(NSURL *)bundleURL;
+(id)applicationProxyForIdentifier:(NSString *)identifier;
@end

@interface LSApplicationWorkspace : NSObject
+(id)defaultWorkspace;
-(NSArray <LSApplicationProxy *>*)allApplications;
@end
