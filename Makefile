ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VcamLite
VcamLite_FILES = VcamLite.m

VcamLite_CFLAGS = \
    -fobjc-arc \
    -O2 \
    -Wno-deprecated-declarations \
    -Wno-unused-variable \
    -Wno-unused-function \
    -Wno-nullability-completeness

VcamLite_FRAMEWORKS = \
    UIKit Foundation AVFoundation CoreMedia CoreVideo \
    VideoToolbox CoreImage CoreGraphics ImageIO PhotosUI

include $(THEOS_MAKE_PATH)/tweak.mk
