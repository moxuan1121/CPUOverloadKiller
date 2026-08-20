#include <Foundation/Foundation.h>
#include <HBLog.h>
#include <objc/runtime.h>
#include <roothide.h>

#define VEDETTE_IDENTIFIER @"com.moxuan.awemecpuguard"

static inline NSString *VDTPrefsPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = jbroot(@"/var/mobile/Library/Preferences/com.moxuan.awemecpuguard.plist");
    });
    return path;
}

#define PREFS_PATH VDTPrefsPath()
#define PREFS_CHANGED_NN @"com.moxuan.awemecpuguard.prefschanged"
#define VDT_JBROOT_PATH(path) jbroot(@(path))
