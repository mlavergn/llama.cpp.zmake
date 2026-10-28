###############################################
#
# Makefile
#
# Zig build system for llama.cpp.
#
# The sources are not modified. This directory sits outside them and reads
# them from ./llama.cpp, which `make clone` fetches.
#
###############################################

.DEFAULT_GOAL := build

.PHONY: clone build dist lib cli run clean distclean macos ios linux linux-x86_64 windows-x86_64

# Pinned deliberately. A port against a moving target does not converge.
LLAMA_CPP_TAG ?= v0.4.0

# The platform targets: arm64 everywhere, and x86_64 on Linux and Windows.
# build.zig derives its whole configuration -- backends, source lists,
# feature-test macros -- from the triple, so these are the only knob the
# platform targets turn.
#
# Both Apple deployment targets are 26.0. Naming an older one is not free: at
# 13.0 the Xcode 26 SDK fails the build outright, because Accelerate's Sparse
# headers annotate symbols as macOS 15.5+ and clang makes unguarded use of them
# an error rather than a warning.
MACOS_TARGET ?= aarch64-macos.26.0
IOS_TARGET   ?= aarch64-ios.26.0
LINUX_TARGET ?= aarch64-linux-gnu
LINUX_X86_TARGET ?= x86_64-linux-gnu
WINDOWS_X86_TARGET ?= x86_64-windows-gnu
X86_CPU ?= x86_64_v3

# iOS pins a CPU; the other arm64 targets do not need to.
#
# Zig's aarch64 baseline already implies DOTPROD and FP16_VECTOR_ARITHMETIC for
# macOS and Linux. build.zig makes the baseline the default CPU, so naming a
# triple for macOS changes no ggml kernel -- under Zig 0.17 "native" on an M5
# would add i8mm. The iOS baseline is bare NEON, which would drop the dotprod
# quant kernels entirely.
#
# apple_a18 targets the iPhone 17 Pro Max, whose SoC is the A19 Pro. Zig 0.16
# modelled Apple cores only up to apple_a18, so the A19 Pro could not be named
# (0.17 adds apple_a19; moving the pin is a separate decision); A18
# is its immediate predecessor and a strict subset, so the code generated here
# runs correctly on it and uses every feature ggml can consume. What is given
# up is A19-specific instruction scheduling, not instructions.
#
# What this buys over the old apple_a13 pin is MATMUL_INT8 -- i8mm, used at 12
# sites in ggml-cpu/arch/arm/quants.c and 15 in repack.cpp -- plus BF16 and
# SME/SME2, which ggml only reports rather than generates code for. Notably it
# does NOT enable SVE, which Apple cores do not implement; upstream's own
# apple_m4 variant spells that out as NOSVE (ggml-cpu/CMakeLists.txt:539).
#
# The cost is device coverage: this binary now requires an A18 or newer, i.e.
# iPhone 16 and later. It will not run on the A13-A17 devices iOS 26 supports.
IOS_CPU ?= apple_a18

# Passed to every platform target. Override to build unoptimized, e.g.
#   make linux RELEASE=
RELEASE ?= --release=fast

# The model `make cli` chats with.
MODEL ?= Qwen3.5-2B-Q4_K_M.gguf

# VULKAN=1 adds ggml's Vulkan backend to any target below, e.g.
#   make lib VULKAN=1
# It needs glslc on PATH (or GLSLC=<path>), the Vulkan and SPIR-V headers
# (/usr/include on Linux; VULKAN_INCLUDE=<dir> elsewhere), and libvulkan to
# link llama-cli. The glslc and headers decide which C++ compiles, so build
# both sides of a comparison with the same ones. See build.zig, `-Dvulkan`.
VULKAN_FLAGS = $(if $(VULKAN),-Dvulkan) $(if $(GLSLC),-Dglslc=$(GLSLC)) \
               $(foreach d,$(VULKAN_INCLUDE),-Dvulkan-include=$(d))

# Fetch the sources this build compiles.
clone:
	git clone https://github.com/ggerganov/llama.cpp.git
	cd llama.cpp; git checkout $(LLAMA_CPP_TAG)

# Everything: ggml, libllama, and llama-cli.
build:
	zig build $(VULKAN_FLAGS)

# Optimized.
dist:
	zig build --release=fast $(VULKAN_FLAGS)

# ggml and libllama only.
lib:
	zig build lib $(VULKAN_FLAGS)

# Build llama-cli optimized and start an interactive chat with $(MODEL).
# Extra flags go in ARGS, e.g.
#   make cli MODEL=other.gguf ARGS="-c 4096"
cli:
	zig build cli $(RELEASE) $(VULKAN_FLAGS)
	./zig-out/bin/llama-cli -m $(MODEL) $(ARGS)

# Per-platform builds of llama-cli: arm64 everywhere, and x86_64 on Linux
# and Windows.
#
# Each installs to a prefix of its own so they can coexist -- a single
# zig-out would have them overwrite each other's llama-cli and libggml.a.

# macOS: Metal, Accelerate, subprocess. Requires the macosx SDK.
macos:
	zig build cli $(RELEASE) -Dtarget=$(MACOS_TARGET) -p zig-out/macos $(VULKAN_FLAGS)

# iOS: the same as macOS minus subprocess, which CMake turns off on mobile
# because spawning one is not sandbox-friendly. Requires the iphoneos SDK.
# The binary is unsigned and links no app bundle; it is a build artifact for
# embedding, not something to run from a shell.
ios:
	zig build cli $(RELEASE) -Dtarget=$(IOS_TARGET) -Dcpu=$(IOS_CPU) -p zig-out/ios $(VULKAN_FLAGS)

# Linux: CPU backend only. Cross-compiles from any host -- Zig ships glibc
# and its own libc++, so no sysroot is needed.
linux:
	zig build cli $(RELEASE) -Dtarget=$(LINUX_TARGET) -p zig-out/linux $(VULKAN_FLAGS)

# Linux on x86_64: the CPU backend's arch/x86 sources. A static build
# compiles one SIMD level; X86_CPU picks it, AVX2 (x86-64-v3) by default and
# x86_64_v4 for AVX-512.
linux-x86_64:
	zig build cli $(RELEASE) -Dtarget=$(LINUX_X86_TARGET) -Dcpu=$(X86_CPU) -p zig-out/linux-x86_64 $(VULKAN_FLAGS)

# Windows on x86_64: MinGW, the only Windows ABI Zig ships a libc for. The
# same arch/x86 sources and X86_CPU as Linux; CPU backend only.
windows-x86_64:
	zig build cli $(RELEASE) -Dtarget=$(WINDOWS_X86_TARGET) -Dcpu=$(X86_CPU) -p zig-out/windows-x86_64 $(VULKAN_FLAGS)

# Run llama-cli. Pass arguments with ARGS, e.g.
#   make run ARGS="-m model.gguf -p 'hello' -ngl 99"
run:
	zig build run -- $(ARGS)

# Remove build output, keeping the sources.
clean:
	rm -rf zig-out .zig-cache

# Also remove the fetched sources.
distclean: clean
	rm -rf llama.cpp
