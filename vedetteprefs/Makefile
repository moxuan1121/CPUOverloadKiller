ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
TARGET := iphone:clang:16.5:15.0
else
TARGET := iphone:clang:latest:15.0
endif

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AwemeCPUGuardPrefs
AwemeCPUGuardPrefs_FILES = VDTRootListController.m ../VDTShared.mm isosversion_stub.m
AwemeCPUGuardPrefs_FRAMEWORKS = UIKit
AwemeCPUGuardPrefs_PRIVATE_FRAMEWORKS = Preferences
AwemeCPUGuardPrefs_INSTALL_PATH = /Library/PreferenceBundles
AwemeCPUGuardPrefs_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
AwemeCPUGuardPrefs_LDFLAGS += -F$(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks
endif

include $(THEOS_MAKE_PATH)/bundle.mk
