TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES :=

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := MultitaskFloat

MultitaskFloat_FILES := Tweak.xm
MultitaskFloat_CFLAGS := -fobjc-arc
MultitaskFloat_FRAMEWORKS := UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
