//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "../Common.h"
#import "ChoicyPreferences/CHPListController.h"

@interface VDTApplicationListSubcontrollerController : CHPListController {
    NSArray *_applications;
}

- (PSSpecifier *)specifierForApplicationWithIdentifier:(NSString *)applicationID;
@end

