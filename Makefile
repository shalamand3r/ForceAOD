TARGET := iphone:clang:16.5:16.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ForceAOD
ForceAOD_FILES = ForceAOD.m
ForceAOD_CFLAGS = -fobjc-arc -Wall -Wextra -Werror \
	-Xclang -fno-constant-nsnumber-literals \
	-Xclang -fno-constant-nsarray-literals \
	-Xclang -fno-constant-nsdictionary-literals
ForceAOD_FRAMEWORKS = Foundation CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

before-package::
	@find "$(THEOS_STAGING_DIR)" -type d -exec chmod 755 {} +
	@find "$(THEOS_STAGING_DIR)" -type f -exec chmod 644 {} +
	@find "$(THEOS_STAGING_DIR)" -type f -name '*.dylib' -exec chmod 755 {} +
