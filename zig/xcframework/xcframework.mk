###############################################
#
# xcframework.mk
#
# llama.xcframework from the stock sources: the same name, module, slices,
# architectures, headers, module map, Info.plist, install names and dSYMs as
# the framework upstream's build-xcframework.sh builds -- the libraries
# compiled by build.zig rather than CMake. Laid out like llamazig's
# xcframework/, whose framework holds the Zig port, so the two can be set
# side by side.
#
# Run from the repository root, through the root Makefile:
#
#   make xcframework                 all seven slices -> zig-out/xcframework/llama.xcframework
#   make xcframework XCF_BUILDS=macos   one slice only (any subset of XCF_BUILDS)
#
# Per slice architecture (target `part`):
#
#   1. `zig build xcframework -Dblas -Dtarget=... -Dcpu=... --release=fast`:
#      libggml (with the BLAS backend), libllama, libmtmd, libvendor-hash --
#      the libraries upstream's `combine_static_libraries` force-loads.
#   2. A probe link with --verbose-link names the libc++.a, libc++abi.a and
#      libcompiler_rt.a Zig builds for the target; the build API exposes none
#      of them.
#   3. `ld -r` prelinks the four libraries and the three runtimes into one
#      object, exporting only what exports.txt names; `clang -dynamiclib`
#      links it with upstream's install name.
#
# Then per slice: bundle.sh, lipo, vtool on device binaries, dsymutil,
# strip -S; and `xcodebuild -create-xcframework` over all of them.
#
# Where it is not upstream's framework:
#
# - The minimum OS is 26.0 on every platform, not upstream's 13.3 / 16.4 /
#   1.0: as low as this project needs to go (XCF_MIN overrides it).
# - Zig's libc++ is inside the binary, hidden, where upstream's links the
#   OS's libc++.1.dylib. These objects are compiled against Zig's libc++
#   headers, which carry none of Apple's availability markup, so linking
#   them against the OS's could bind symbols an older OS lacks. It is also
#   what every executable this build makes links. The cost is that only
#   exports.txt's prefixes are exported, where upstream's binary exports
#   everything it holds -- every function the shipped headers declare
#   among them.
# - compiler_rt is inside the binary too, as in every `zig cc` link, so
#   expf, logf and friends compute what llama-cli built here computes, not
#   what Apple's libm does.
# - Each architecture is compiled for itself. Upstream's universal slices
#   name two architectures in CMAKE_OSX_ARCHITECTURES, which
#   ggml_get_system_arch (ggml/cmake/common.cmake) matches as neither ARM
#   nor x86, so they get GGML_CPU_GENERIC's scalar kernels. Here arm64 gets
#   the arm kernels and x86_64 the x86 ones at x86_64_v3 (AVX2).
#
###############################################

# Every recipe line under -e and pipefail. macOS's /usr/bin/make is GNU Make
# 3.81, which ignores .SHELLFLAGS, so there the flags go in SHELL.
ifeq ($(MAKE_VERSION),3.81)
SHELL := /bin/bash -eo pipefail
else
SHELL := /bin/bash
.SHELLFLAGS := -eo pipefail -c
endif

# The checkout's path may hold a space, which make splits on. Every path
# below is relative to the repository root, where this file runs, and so
# holds none.
HERE      := zig/xcframework
B         := zig-out/xcframework
XCF       := $(B)/llama.xcframework
ZIG       ?= zig
# The pinned sources, for the headers; the root Makefile passes it.
LLAMA_CPP_DIR ?= $(error LLAMA_CPP_DIR is unset; run this through the root Makefile's `make xcframework`)

# Every platform's minimum. Upstream's are iOS 16.4, macOS 13.3, tvOS 16.4
# and visionOS 1.0 (build-xcframework.sh:7-10); this project goes no lower
# than 26.0, which Apple's renumbering made the same version everywhere.
XCF_MIN      ?= 26.0
IOS_MIN      ?= $(XCF_MIN)
MACOS_MIN    ?= $(XCF_MIN)
TVOS_MIN     ?= $(XCF_MIN)
VISIONOS_MIN ?= $(XCF_MIN)

# upstream's build order (build-xcframework.sh:57)
XCF_BUILDS ?= ios-sim ios-device macos visionos visionos-sim tvos-sim tvos-device

# The arm64 CPU of each build is the one Apple clang picks for its target at
# 26.0 when nothing names one -- which is what upstream's CMake does with
# GGML_NATIVE off -- measured with `clang -###`: apple-a12 for iOS and
# visionOS, apple-a7 for tvOS, apple-m1 for macOS and the simulators. It
# decides which ggml kernel arms compile, and the oldest device the slice runs
# on. Note `make ios` pins apple_a18 for a single target device; a framework
# is for every device the OS supports. x86_64 is x86_64_v3 (AVX2), the floor
# of every Intel Mac macOS 26 supports.
XCF_X86_CPU ?= x86_64_v3

# mtmd's video input (MTMD_VIDEO): build-xcframework.sh passes
# -DMTMD_VIDEO=OFF to every build but macOS, which keeps CMake's default, on.
macos_MTMD_VIDEO := true

# Per build: architectures; the Zig OS and ABI; the arm64 CPU; SDK; the
# `ld -platform_version` name; the clang OS for `-target`; the platform
# bundle.sh takes; minimum OS; and the `vtool -set-build-version` platform
# upstream re-marks device binaries with.
ios-sim_ARCHS        := arm64 x86_64
ios-sim_OS           := ios.$(IOS_MIN)-simulator
ios-sim_CPU          := apple_m1
ios-sim_SDK          := iphonesimulator
ios-sim_LD           := ios-simulator
ios-sim_CLANG_OS     := ios$(IOS_MIN)-simulator
ios-sim_BUNDLE       := ios
ios-sim_MIN          := $(IOS_MIN)

ios-device_ARCHS     := arm64
ios-device_OS        := ios.$(IOS_MIN)
ios-device_CPU       := apple_a12
ios-device_SDK       := iphoneos
ios-device_LD        := ios
ios-device_CLANG_OS  := ios$(IOS_MIN)
ios-device_BUNDLE    := ios
ios-device_MIN       := $(IOS_MIN)
ios-device_VTOOL     := ios

macos_ARCHS          := arm64 x86_64
macos_OS             := macos.$(MACOS_MIN)
macos_CPU            := apple_m1
macos_SDK            := macosx
macos_LD             := macos
macos_CLANG_OS       := macos$(MACOS_MIN)
macos_BUNDLE         := macos
macos_MIN            := $(MACOS_MIN)

visionos_ARCHS       := arm64
visionos_OS          := visionos.$(VISIONOS_MIN)
visionos_CPU         := apple_a12
visionos_SDK         := xros
visionos_LD          := xros
visionos_CLANG_OS    := xros$(VISIONOS_MIN)
visionos_BUNDLE      := visionos
visionos_MIN         := $(VISIONOS_MIN)
visionos_VTOOL       := visionos

visionos-sim_ARCHS   := arm64 x86_64
visionos-sim_OS      := visionos.$(VISIONOS_MIN)-simulator
visionos-sim_CPU     := apple_m1
visionos-sim_SDK     := xrsimulator
visionos-sim_LD      := xros-simulator
visionos-sim_CLANG_OS := xros$(VISIONOS_MIN)-simulator
visionos-sim_BUNDLE  := visionos
visionos-sim_MIN     := $(VISIONOS_MIN)

tvos-sim_ARCHS       := arm64 x86_64
tvos-sim_OS          := tvos.$(TVOS_MIN)-simulator
tvos-sim_CPU         := apple_m1
tvos-sim_SDK         := appletvsimulator
tvos-sim_LD          := tvos-simulator
tvos-sim_CLANG_OS    := tvos$(TVOS_MIN)-simulator
tvos-sim_BUNDLE      := tvos
tvos-sim_MIN         := $(TVOS_MIN)

tvos-device_ARCHS    := arm64
tvos-device_OS       := tvos.$(TVOS_MIN)
tvos-device_CPU      := apple_a7
tvos-device_SDK      := appletvos
tvos-device_LD       := tvos
tvos-device_CLANG_OS := tvos$(TVOS_MIN)
tvos-device_BUNDLE   := tvos
tvos-device_MIN      := $(TVOS_MIN)
tvos-device_VTOOL    := tvos

# The binary's path inside the bundle and its install name, as upstream's
# `combine_static_libraries` sets them.
bin_path     = $(if $(filter macos,$(1)),Versions/A/llama,llama)
install_name = $(if $(filter macos,$(1)),@rpath/llama.framework/Versions/Current/llama,@rpath/llama.framework/llama)

zig_arch = $(if $(filter arm64,$(1)),aarch64,x86_64)
# $(1): build, $(2): arch
part_cpu = $(if $(filter arm64,$(2)),$($(1)_CPU),$(XCF_X86_CPU))

.PHONY: all part $(XCF_BUILDS)

all: $(XCF_BUILDS)
	@printf '\n== xcframework ==\n'
	rm -rf $(XCF)
	xcrun xcodebuild -create-xcframework \
	    $(foreach s,$(XCF_BUILDS),-framework $(B)/$(s)/framework/llama.framework -debug-symbols "$(CURDIR)/$(B)/$(s)/dSYMs/llama.dSYM") \
	    -output $(XCF)

# One architecture of one build: `make -f ... part BUILD=<build> ARCH=<arch>`.
P = $(B)/$(BUILD)/$(ARCH)
part:
	@printf '\n== %s %s: zig build xcframework -Dtarget=%s-%s -Dcpu=%s ==\n' $(BUILD) $(ARCH) \
	    $(call zig_arch,$(ARCH)) $($(BUILD)_OS) $(call part_cpu,$(BUILD),$(ARCH))
	$(ZIG) build xcframework -Dblas -Dmtmd-video=$(or $($(BUILD)_MTMD_VIDEO),false) \
	    -Dtarget=$(call zig_arch,$(ARCH))-$($(BUILD)_OS) \
	    -Dcpu=$(call part_cpu,$(BUILD),$(ARCH)) --release=fast -p $(P)/zig
	@# The probe needs the SDK's libc, for the reason build.zig's
	@# writeAppleLibcFile gives, and the same file is what lets Zig build
	@# libc++ for the target at all; the step above installs the very file
	@# the libraries were compiled with. The link itself may fail -- Zig's
	@# linker and the simulator SDKs do not always agree -- after the
	@# runtimes are built and the line naming them is printed, which is all
	@# the probe is for; the count check below catches a probe that got
	@# nowhere. The line is split on spaces, so Zig's global cache path
	@# must hold none.
	rm -rf $(P)/rt && mkdir -p $(P)/rt
	printf 'int main(void) { return 0; }\n' > $(P)/rt/probe.cpp
	{ $(ZIG) build-exe $(P)/rt/probe.cpp -lc++ -target $(call zig_arch,$(ARCH))-$($(BUILD)_OS) \
	    -mcpu $(call part_cpu,$(BUILD),$(ARCH)) -OReleaseFast --libc $(P)/zig/apple-libc.txt \
	    --cache-dir $(P)/rt/cache -femit-bin=$(P)/rt/probe --verbose-link 2>&1 || true; } \
	    | tr ' ' '\n' | grep -E '/lib(c\+\+|c\+\+abi|compiler_rt)\.a$$' | sort -u > $(P)/rt/paths.txt || true
	test "$$(wc -l < $(P)/rt/paths.txt)" -eq 3 || { echo "FAIL: probe found: $$(cat $(P)/rt/paths.txt)"; exit 1; }
	while read -r f; do cp "$$f" $(P)/rt/; done < $(P)/rt/paths.txt
	@printf -- '-- prelink and link\n'
	xcrun ld -r -arch $(ARCH) -platform_version $($(BUILD)_LD) $($(BUILD)_MIN) $$(xcrun --sdk $($(BUILD)_SDK) --show-sdk-version) \
	    -exported_symbols_list $(HERE)/exports.txt \
	    -force_load $(P)/zig/lib/libggml.a -force_load $(P)/zig/lib/libllama.a \
	    -force_load $(P)/zig/lib/libmtmd.a -force_load $(P)/zig/lib/libvendor-hash.a \
	    $(P)/rt/libc++.a $(P)/rt/libc++abi.a $(P)/rt/libcompiler_rt.a -o $(P)/llama.o
	xcrun --sdk $($(BUILD)_SDK) clang -dynamiclib -target $(ARCH)-apple-$($(BUILD)_CLANG_OS) \
	    -isysroot "$$(xcrun --sdk $($(BUILD)_SDK) --show-sdk-path)" $(P)/llama.o \
	    -framework Foundation -framework Metal -framework Accelerate \
	    -install_name $(call install_name,$(BUILD)) -o $(P)/llama.dylib

# A build: its architectures, joined, in upstream's bundle, with its dSYM.
$(XCF_BUILDS): %:
	@for a in $($*_ARCHS); do $(MAKE) --no-print-directory -f $(HERE)/xcframework.mk part BUILD=$* ARCH=$$a; done
	@printf '\n== %s: framework ==\n' $*
	rm -rf $(B)/$*/framework $(B)/$*/dSYMs && mkdir -p $(B)/$*/framework $(B)/$*/dSYMs
	$(HERE)/bundle.sh $(LLAMA_CPP_DIR) $(B)/$*/framework $($*_MIN) $($*_BUNDLE)
	BIN=$(B)/$*/framework/llama.framework/$(call bin_path,$*); \
	xcrun lipo -create $(foreach a,$($*_ARCHS),$(B)/$*/$(a)/llama.dylib) -output "$$BIN"; \
	if [ -n "$($*_VTOOL)" ]; then \
	    xcrun vtool -set-build-version $($*_VTOOL) $($*_MIN) $($*_MIN) -replace -output "$$BIN" "$$BIN"; \
	fi; \
	xcrun dsymutil "$$BIN" -o $(B)/$*/dSYMs/llama.dSYM; \
	xcrun strip -S "$$BIN" -o $(B)/$*/stripped && mv $(B)/$*/stripped "$$BIN"
