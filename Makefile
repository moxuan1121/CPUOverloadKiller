export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = roothide
export DEBUG = 0
export FINALPACKAGE = 1
export PREFIX ?= $(THEOS)/toolchain/Xcode11.xctoolchain/usr/bin/

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
TARGET := iphone:clang:16.5:15.0
else
TARGET := iphone:clang:latest:15.0
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GlobalCPUGuard
GlobalCPUGuard_FILES = GlobalCPUGuard.xm VDTShared.mm
GlobalCPUGuard_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)
GlobalCPUGuard_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += vedetteprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
