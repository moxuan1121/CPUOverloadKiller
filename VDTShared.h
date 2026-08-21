//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"

typedef NS_ENUM(NSUInteger, VDTConfigType) {
    VDTConfigTypeApp,
    VDTConfigTypeDaemon
};

#ifdef __cplusplus
extern "C" {
#endif

NSDictionary* getPrefs();
id valueForKey(NSString *key);
void setValueForKey(NSString *key, id value);
id valueForProcessConfigKey(NSString *identifier, NSString *key, id defaultValue, VDTConfigType type);
void setValueForProcessConfigKey(NSString *identifier, NSString *key, id value, VDTConfigType type);

#ifdef __cplusplus
}
#endif

