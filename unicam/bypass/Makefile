# Makefile — UnicoBypass: in-process JB/anti-debug bypass dylib (rootless ElleKit).
#   make package SYSROOT=$HOME/theos/sdks/iPhoneOS16.5.sdk
#   make clean

ifeq ($(origin CC),default)
CC := clang
endif
LDID ?= ldid
DPKG ?= dpkg-deb

SYSROOT ?= $(HOME)/theos/sdks/iPhoneOS16.5.sdk
ARCH    ?= arm64
TARGET  ?= arm64-apple-ios16.2
FUSE_LD ?= lld

DYLIB    := UnicoBypass.dylib
INSTALL  := /var/jb/Library/MobileSubstrate/DynamicLibraries/$(DYLIB)
BUILD    := build
OBJ      := $(BUILD)/Bypass.o
BIN      := $(BUILD)/$(DYLIB)
STAGE    := $(BUILD)/stage
DEB      := $(BUILD)/com.local.unicobypass_1.0.0_iphoneos-arm64.deb

CFLAGS  := -target $(TARGET) -isysroot $(SYSROOT) -arch $(ARCH) \
           -fobjc-arc -Wall -O2 -Wno-deprecated-declarations
LDFLAGS := -target $(TARGET) -isysroot $(SYSROOT) -arch $(ARCH) \
           -dynamiclib -fuse-ld=$(FUSE_LD) -fobjc-arc \
           -install_name $(INSTALL) -framework Foundation -framework UIKit -lobjc

.PHONY: all package clean
all: $(BIN)

$(OBJ): src/Bypass.m
	@mkdir -p $(dir $@)
	@echo "CC src/Bypass.m -> $@"
	@$(CC) $(CFLAGS) -c $< -o $@

$(BIN): $(OBJ)
	@echo "LD $@"
	@$(CC) $(LDFLAGS) $^ -o $@
	@echo "SIGN $@"
	@$(LDID) -S $@

package: $(BIN)
	@rm -rf $(STAGE)
	@mkdir -p $(STAGE)
	@cp -a layout/. $(STAGE)/
	@cp $(BIN) $(STAGE)/var/jb/Library/MobileSubstrate/DynamicLibraries/$(DYLIB)
	@echo "PACK $(DEB)"
	@$(DPKG) --root-owner-group -Zgzip -b $(STAGE) $(DEB)
	@echo "Built: $(DEB)"

clean:
	rm -rf $(BUILD)
