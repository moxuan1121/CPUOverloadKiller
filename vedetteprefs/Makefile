ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
TARGET := iphone:clang:16.5:15.0
else
TARGET := iphone:clang:latest:15.0
endif

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CPUOverloadKillerPrefs
CPUOverloadKillerPrefs_FILES = VDTRootListController.m VDTApplicationListSubcontrollerController.m VDTProcessConfiguration.m GCGTargetCell.m ../VDTShared.mm isosversion_stub.m \
    ChoicyPreferences/CHPListController.m ChoicyPreferences/CHPDaemonInfo.m ChoicyPreferences/CHPDaemonList.m ChoicyPreferences/CHPDaemonListController.m
CPUOverloadKillerPrefs_FRAMEWORKS = UIKit
CPUOverloadKillerPrefs_PRIVATE_FRAMEWORKS = Preferences
CPUOverloadKillerPrefs_INSTALL_PATH = /Library/PreferenceBundles
CPUOverloadKillerPrefs_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUOverloadKillerPrefs_LDFLAGS += -F$(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks
endif

include $(THEOS_MAKE_PATH)/bundle.mk
