TARGET := iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES :=

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := MultitaskFloat

MultitaskFloat_FILES := Tweak.xm
MultitaskFloat_SWIFT_FILES := OpenAnimation.swift
MultitaskFloat_CFLAGS := -fobjc-arc
MultitaskFloat_FRAMEWORKS := UIKit CoreText

include $(THEOS_MAKE_PATH)/tweak.mk
