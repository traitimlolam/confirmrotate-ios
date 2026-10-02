TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ConfirmRotate
ConfirmRotate_FILES = Tweak.x
ConfirmRotate_CFLAGS = -fobjc-arc
ConfirmRotate_FRAMEWORKS = UIKit CoreGraphics AudioToolbox
ConfirmRotate_PRIVATE_FRAMEWORKS = SpringBoard

include $(THEOS_MAKE_PATH)/tweak.mk
