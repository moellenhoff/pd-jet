# jet - GPU-native render chains for Pure Data (Metal, macOS/arm64).
#
# Layout:  src/     objects (one .mm per Pd object) + jet_shared.h
#          help/    help patches (installed next to the bundles)
#          assets/  small media files the help patches reference
#          build/   compiled bundles (generated)
#
# Every src/jet_*.mm becomes its own build/jet_*.pd_darwin bundle -
# no object list to maintain. Bundles resolve each other's exported
# functions (jet_shared.h) at load time via -undefined dynamic_lookup,
# the same way objects reach into a host application.

PD_APP     ?= /Applications/Pd-0.56-2.app
PD_INCLUDE  = $(PD_APP)/Contents/Resources/src

ARCH               = arm64
MACOSX_VERSION_MIN = 11.0

CXX      = clang++
CXXFLAGS = -std=c++14 -O2 -fPIC -Wall -Wno-unused-parameter \
           -arch $(ARCH) -mmacosx-version-min=$(MACOSX_VERSION_MIN)
INCLUDES = -I$(PD_INCLUDE)

LDFLAGS  = -arch $(ARCH) -bundle -undefined dynamic_lookup \
           -mmacosx-version-min=$(MACOSX_VERSION_MIN) \
           -framework Cocoa -framework Metal -framework QuartzCore \
           -framework CoreGraphics -framework ImageIO -framework Foundation \
           -framework AVFoundation -framework CoreMedia -framework CoreVideo \
           -framework Accelerate

SRC_DIR   = src
BUILD_DIR = build

OBJECTS = $(basename $(notdir $(wildcard $(SRC_DIR)/jet_*.mm)))
TARGETS = $(OBJECTS:%=$(BUILD_DIR)/%.pd_darwin)
HEADERS = $(wildcard $(SRC_DIR)/*.h)

PD_EXTERNALS_DIR ?= $(HOME)/Documents/Pd/externals/jet

.PHONY: all clean install shadertest

all: $(TARGETS)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/%.pd_darwin: $(BUILD_DIR)/%.o
	$(CXX) $(LDFLAGS) -o $@ $^

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.mm $(HEADERS) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -c $< -o $@

# compiles every shader embedded in src/*.mm with Metal's runtime
# compiler, the same path Pd takes when an object loads - catches
# broken MSL (and things like a mangled #include) at build time instead
# of as a silent blank window. needs a Metal-capable machine and
# python3; does not need the offline Metal toolchain.
shadertest: $(BUILD_DIR)/msltest
	python3 tools/extract_msl.py $(SRC_DIR) $(BUILD_DIR)/msl
	$(BUILD_DIR)/msltest $(BUILD_DIR)/msl/*.metal

$(BUILD_DIR)/msltest: tools/msltest.mm | $(BUILD_DIR)
	$(CXX) -fobjc-arc -framework Metal -framework Foundation $< -o $@

# bundles, help patches and assets all go flat into one externals
# folder - Pd finds an object's -help.pd and a patch's relative media
# paths next to the bundle
install: all shadertest
	mkdir -p "$(PD_EXTERNALS_DIR)"
	cp $(TARGETS) "$(PD_EXTERNALS_DIR)/"
	cp help/*.pd "$(PD_EXTERNALS_DIR)/"
	cp assets/* "$(PD_EXTERNALS_DIR)/"

clean:
	rm -rf $(BUILD_DIR)
