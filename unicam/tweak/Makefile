# Makefile — build UniCam tweak (camera-frame injector) as a rootless ElleKit
# dylib and package as a .deb. Linux (Kali/WSL2): clang + ld64.lld + ldid.
#
#   make package SYSROOT=$HOME/theos/sdks/iPhoneOS16.5.sdk
#   make clean
#
# Install the .deb on a Dopamine/roothide (rootless) device; depends on ellekit.

ifeq ($(origin CC),default)
CC := clang
endif
LDID  ?= ldid
DPKG  ?= dpkg-deb

SYSROOT ?= $(HOME)/theos/sdks/iPhoneOS16.5.sdk
ARCH    ?= arm64
TARGET  ?= arm64-apple-ios16.2
FUSE_LD ?= lld

DYLIB     := UniCam.dylib
INSTALL   := /var/jb/Library/MobileSubstrate/DynamicLibraries/$(DYLIB)
TWEAKDIR  := layout/var/jb/Library/MobileSubstrate/DynamicLibraries
BUILD     := build
OBJ       := $(BUILD)/Tweak.o
BIN       := $(BUILD)/$(DYLIB)
STAGE     := $(BUILD)/stage
DEB       := $(BUILD)/com.local.unicam_1.0.0_iphoneos-arm64.deb

FRAMEWORKS := -framework Foundation -framework AVFoundation -framework CoreMedia \
              -framework CoreVideo -framework CoreImage -framework QuartzCore

CFLAGS  := -target $(TARGET) -isysroot $(SYSROOT) -arch $(ARCH) \
           -fobjc-arc -Wall -O2 -Wno-deprecated-declarations

LDFLAGS := -target $(TARGET) -isysroot $(SYSROOT) -arch $(ARCH) \
           -dynamiclib -fuse-ld=$(FUSE_LD) -fobjc-arc \
           -install_name $(INSTALL) $(FRAMEWORKS) -lobjc

.PHONY: all package clean

all: $(BIN)

$(OBJ): src/Tweak.m
	@mkdir -p $(dir $@)
	@echo "CC src/Tweak.m -> $@ ($(ARCH))"
	@$(CC) $(CFLAGS) -c $< -o $@

$(BIN): $(OBJ)
	@echo "LD $@ ($(ARCH))"
	@$(CC) $(LDFLAGS) $^ -o $@
	@echo "SIGN $@"
	@$(LDID) -S $@

package: $(BIN)
	@echo "STAGE -> $(STAGE)"
	@rm -rf $(STAGE)
	@mkdir -p $(STAGE)
	@cp -a layout/. $(STAGE)/
	@cp $(BIN) $(STAGE)/var/jb/Library/MobileSubstrate/DynamicLibraries/$(DYLIB)
	@chmod 0644 $(STAGE)/var/jb/Library/MobileSubstrate/DynamicLibraries/UniCam.plist
	@echo "PACK $(DEB)"
	@$(DPKG) --root-owner-group -Zgzip -b $(STAGE) $(DEB)
	@echo "Built: $(DEB)"

clean:
	rm -rf $(BUILD)
