# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## The goal

**Replace llama.cpp's CMake build with `build.zig`. Nothing else.**

The sources stay C, C++, and Objective-C, compiled exactly as upstream ships
them. This project does not port code to Zig, does not fix bugs in llama.cpp,
and does not change its behaviour. The only thing being replaced is the build
description.

The test of success is narrow and strict: a binary built here must produce
**token-identical output** to the same sources built by CMake.

## `llama.cpp/` is read-only

The sources live in `llama.cpp/`, fetched by `make clone` at the pinned tag.
That directory is **not part of this repository** — it is gitignored, and
nothing here may modify it.

This is the whole design. Because the build system sits outside the sources
rather than being patched into them, the pinned tag can move or the checkout be
replaced with nothing to reconcile. If something in llama.cpp seems to need
changing to make the build work, that is a signal the build description is
wrong, not the source.

```
build.zig, build.zig.zon, Makefile   the build system
zig/metal_embed.zig                  flattens a Metal kernel for embedding
zig/ui-stub/                         stand-in for the generated web UI assets
llama.cpp/                           sources (gitignored, `make clone`)
```

## Commands

```sh
make clone     # fetch llama.cpp at $(LLAMA_CPP_TAG), currently v0.3.0
make           # everything for the host: ggml, libllama, llama-cli
make cli       # llama-cli only
make lib       # ggml and libllama only
make dist      # optimized (zig build --release=fast)
make run ARGS="-m model.gguf -ngl 99 -p 'hello' -st"
make clean     # build output only
make distclean # also removes the fetched sources

make macos     # llama-cli, arm64, optimized -> zig-out/macos/bin/
make ios       #                             -> zig-out/ios/bin/
make linux     #                             -> zig-out/linux/bin/
```

The three platform targets each install under a prefix of their own; a single
`zig-out` would have them overwrite each other's `llama-cli` and `libggml.a`.
They differ only in `-Dtarget` — `build.zig` derives everything else from the
OS in the triple — so adding a fourth platform is a `Platform` variant and a
Makefile line, not a restructuring.

Requires Zig **0.16.0**. `macos` and `ios` need the Xcode SDK, the macosx and
iphoneos ones respectively. `linux` cross-compiles from any host with no
sysroot: Zig ships glibc and its own libc++.

## Scope

Builds `llama-cli` and everything it links. The chain, from CMake:

```
llama-cli -> llama-cli-impl -> llama-server-impl -> {server-context, llama-ui, cpp-httplib}
                                                 -> {llama-common, mtmd} -> {llama, ggml, vendor}
```

The CLI pulls in the whole server because `cli-context.cpp` drives it
in-process. That is not a design choice made here; it is how upstream is wired.

Three arm64 platforms, distinguished by the `Platform` enum in `build.zig`.
Everything they share matches the `-D` flags CMake was being driven with:
static libraries, BLAS and OpenMP off, no curl.

| | Metal | Accelerate | subprocess | target |
|--------|-------|------------|------------|--------|
| macOS  | on, embedded | on  | on  | `aarch64-macos.26.0` |
| iOS    | on, embedded | on  | off | `aarch64-ios.26.0`, cpu `apple_a18` |
| Linux  | off          | off | on  | `aarch64-linux-gnu`, `_GNU_SOURCE` |

Only macOS is verified token-identical against CMake. iOS and Linux compile and
link cleanly but have not been diffed on their own platforms — see **How to
verify a change**, which applies to them exactly as it does to macOS.

**Not built:** the other ~90 CMake binaries — tests, benchmarks, and the other
tools. They are ordinary additions to the same pattern; nothing structural
stands in the way.

## How to verify a change

Compiling and linking proves very little here. Any real change should be
checked by diffing generated tokens against a CMake build of the same sources.

```sh
# Reference build, Apple clang via CMake. Note -G "Unix Makefiles": the Xcode
# generator drives xcodebuild, which ignores CMAKE_C_COMPILER.
mkdir -p /tmp/ref && cd /tmp/ref
cmake $OLDPWD/llama.cpp -G "Unix Makefiles" \
  -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_OSX_SYSROOT=macosx \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_ACCELERATE=ON -DGGML_BLAS=OFF -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF \
  -DBUILD_SHARED_LIBS=OFF -DLLAMA_CURL=OFF
make -j llama-cli
```

Then run both binaries with greedy sampling and a fixed seed, and diff:

```sh
ARGS="-m model.gguf -ngl 99 --temp 0 -s 42 -n 48 -st -p 'Explain gravity in one sentence:'"
/tmp/ref/bin/llama-cli $ARGS 2>/dev/null > /tmp/a.txt
./zig-out/bin/llama-cli $ARGS 2>/dev/null > /tmp/b.txt
diff /tmp/a.txt /tmp/b.txt
```

Strip the banner and the throughput line before comparing — the build id and
tokens/sec differ by design and say nothing about correctness.

There is no script for this in the repository yet. Adding one would be welcome.

The recipe above is the macOS one; the same shape applies to the other two.
For Linux, drop the Darwin/Metal/Accelerate flags and run both binaries on an
arm64 Linux box. For iOS there is no shell to run either binary from, so the
comparison has to happen inside a host app — which is why neither is verified
yet. Until they are, a change touching only the Apple path can still be cleared
by the macOS diff alone; a change to `Platform`, the shared define lists, or
`baseModule` cannot.

**Two traps, both of which have produced false passes before:**

- **Check the exit codes.** A driver that crashes after printing can still
  produce matching output. Compare exit status as well as text.
- **Check the files are non-empty.** Two empty files diff clean.

## Conventions

- Zig **0.16.0** APIs. `std.Build.Module` options rather than the older compile
  step setters; `.language` on `addCSourceFiles` rather than `-x c++` flags,
  which Zig places after the file where they have no effect.
- Source lists are kept **relative to the checkout** and each `addCSourceFiles`
  call passes `.root = b.path(src_root)`. This keeps the lists byte-identical
  to CMake's, so they can be diffed against it directly.
- Where CMake globs a directory, `appendGlob` reads it too, rather than
  freezing a list that would go stale on the next sync.
- Doc comments carry a `Parameters:` list and a `Return:` line on any function
  whose contract is not obvious, and explain **why** rather than restating the
  code.
- Every non-obvious flag, define, or ordering decision cites the CMake line it
  came from, so it can be checked.

## Fidelity notes

Six CMake behaviours that are easy to miss. Each of these cost real debugging;
`README.md` carries the same list for users.

- **`vendor/hash/sha1/sha1.c` is C++.** CMake sets `LANGUAGE CXX` on it
  (`vendor/hash/CMakeLists.txt:32`) because the file wraps itself in a
  namespace to avoid clashing with BoringSSL. Compiled as C it fails on
  `namespace`.
- **`src` must not be a global include path.** It holds a second `unicode.h`
  that shadows `common/unicode.h`, which `common/jinja/value.cpp` needs. CMake
  keeps `src` private to the `llama` target for the same reason.
- **`LLAMA_VERSION` and `LLAMA_COMMIT` are private to the `llama` target.**
  Passed globally they collide with the variables of those names in
  `build-info.cpp`, which fails to compile.
- **`-fobjc-arc` must not be set.** The Metal sources use manual reference
  counting and bridge freely between `void *` and Objective-C object pointers;
  ARC rejects them outright.
- **The C sanitizers must be off** (`.sanitize_c = .off`). These sources are not
  UBSan-clean — they rely on pointer arithmetic that is technically undefined
  but universally works — and Zig enables the sanitizers in Debug where CMake
  never did. The symptom is an abort in `llama-graph.cpp` on a null-pointer
  offset.
- **Never enable the non-embedded Metal path.** It requires `xcrun -sdk macosx
  metal`, which the Zig toolchain cannot replace. The embedded path is text
  processing plus an assemble step, which is why `zig/metal_embed.zig` can do
  it: with `GGML_METAL_EMBED_LIBRARY` the `.metal` *source* is flattened and
  `.incbin`-ed into a `__DATA,__ggml_metallib` section, and the Metal driver
  compiles it at load time. It is also why the same code works for iOS
  unchanged — nothing in the flattening is host-specific.
- **`LLAMA_SUBPROCESS` is off on iOS.** CMake turns it off on mobile and WASM
  targets, where spawning a subprocess is not sandbox-friendly
  (`CMakeLists.txt:104-110`). Defining it there would compile, and be wrong.
- **`_GNU_SOURCE` is required on Linux** — ggml reaches for the GNU
  CPU-affinity and allocation extensions (`ggml/src/CMakeLists.txt:152-155`).
  The POSIX-conformance macros CMake also sets globally, `_XOPEN_SOURCE=600`
  and `_DARWIN_C_SOURCE`, are deliberately *not* set here: the Apple builds are
  verified token-identical without them, and adding a feature-test macro to a
  build that already matches can only move it.
- **Both Apple platforms need a generated `zig libc` file**
  (`writeAppleLibcFile`). Zig sets up the SDK include chain only for a *native*
  target. Name any triple — as both Apple builds now do — and it treats the
  build as cross-compilation, after which its clang finds no `stdio.h` and its
  libc++ build dies on `mbstate_t`. Passing `-idirafter` to our own sources is
  *not* enough: Zig builds libc++ itself, and that internal build sees none of
  our flags. The libc file is the one knob that reaches it. Do not substitute
  `--sysroot` — with the libc file present it is unnecessary, and `b.sysroot`
  is global, so it would also hit the host `metal_embed` tool. Note `libc_file`
  lives on `Step.Compile`, not on `Module`, which is why
  `addLibrary`/`addExecutable` wrap the builtins instead of `baseModule`
  handling it.
- **The Apple deployment targets are 26.0, and lowering them breaks the build.**
  At 13.0 the Xcode 26 SDK produces 145 errors: Accelerate's Sparse headers
  annotate symbols as macOS 15.5+, and clang makes unguarded use of them an
  error, not a warning. Note the failure mode changes with the version — at
  26.0 without a libc file you instead get `CF_BRIDGED_TYPE` redefinitions and
  a missing `libDER/DERItem.h`, which is the include-chain problem above, not
  an availability one. They are two separate faults and both must be fixed.
- **iOS pins `-Dcpu=apple_a18`; macOS and Linux need no pin.** Zig's aarch64
  baseline already implies `DOTPROD` and `FP16_VECTOR_ARITHMETIC` on macOS and
  Linux — the same feature set the native build selects, which is why naming a
  triple for macOS changes no ggml kernel. The iOS baseline is bare NEON, which
  drops the dotprod quant kernels entirely.

  The pin targets the iPhone 17 Pro Max, whose SoC is the A19 Pro. Zig 0.16
  models Apple cores only up to `apple_a18`, so the A19 Pro cannot be named;
  A18 is its immediate predecessor and a strict subset, so the generated code
  runs correctly on it and uses every feature ggml can consume. Only
  A19-specific scheduling is given up, not instructions.

  It buys `MATMUL_INT8` — i8mm, used at 12 sites in `ggml-cpu/arch/arm/quants.c`
  and 15 in `repack.cpp` — plus `BF16` and `SME`/`SME2`, which ggml reports but
  generates no code for outside kleidiai. It does **not** enable SVE, which
  Apple cores do not implement; upstream's own `apple_m4` variant spells that
  out as `NOSVE` (`ggml-cpu/CMakeLists.txt:539`). Verified in the disassembly:
  226 dotprod and 22 i8mm instructions, zero SVE. Check it with `otool -tv`
  after any change to the pin; the bare-NEON build shows 0 of all three, which
  is what a silently-dropped pin looks like.

  The cost is device coverage — the binary now requires an A18 or newer, i.e.
  iPhone 16 and later, and will not run on the A13–A17 devices iOS 26 supports.

## The web UI is stubbed

`llama-server-impl` links `llama-ui`, which under CMake runs a SvelteKit/npm
build and then compiles a host tool to turn the output into a C++ asset array.
Driving npm from the build graph is possible but was not the point of this
project, so `zig/ui-stub/` supplies the same interface with zero assets.

`LLAMA_UI_HAS_ASSETS` is deliberately left **undefined**, which switches
`server-http.cpp` to its no-assets path. The declarations are still required,
because that file calls `llama_ui_get_assets()` outside the guard.

`llama-cli` is unaffected — it never serves a web UI. `llama-server` would
build and run but serve none. Making the UI real means either driving npm or
using CMake's prebuilt-asset path (`LLAMA_USE_PREBUILT_WEBUI`), and is the
largest single piece of unfinished parity.

## Adding a target

The pattern is the same every time, and `addCli` shows it several times over:

1. Find the target in its `CMakeLists.txt` and copy its source list verbatim.
2. `baseModule(b, cfg)` for the shared settings, then `addCommonIncludes`.
3. Add whatever include paths CMake gives it, keeping `PRIVATE` ones private.
4. `addCSourceFiles` with `.root = b.path(src_root)` and the right flag set.
5. `linkLibrary` for each CMake `target_link_libraries` entry.
6. Verify by diffing tokens, not by seeing it link.

Note steps 2 and 4 changed shape when the platform targets landed: use
`addLibrary(b, cfg, name, mod)` rather than `b.addLibrary` so the iOS libc file
is attached, and pass `cfg.c` / `cfg.cxx` / `cfg.objc` rather than a comptime
`c_flags ++ defines` — the defines now vary by platform and are folded in at
configure time.

## Adding a platform

1. Add a `Platform` variant and map the OS tag in `Platform.detect`.
2. Find what CMake defines for it. The three that have already cost debugging
   are `_GNU_SOURCE`, `LLAMA_SUBPROCESS`, and the Accelerate trio; append them
   to the define lists in `build`, not to `base_defines`.
3. Decide whether `isApple` still means what its doc comment says. It gates
   Metal, Accelerate, the Objective-C sources, and the frameworks together
   because on macOS and iOS they genuinely do travel together. A platform with
   one and not the others needs the predicate split, not a new caller.
4. If Zig cannot find that platform's libc on its own, it needs a libc file the
   way iOS does — and that has to be attached to every `Step.Compile`.
5. Add the Makefile target, installing under `zig-out/<platform>`.
6. Verify by diffing tokens on that platform, not by seeing it link.

