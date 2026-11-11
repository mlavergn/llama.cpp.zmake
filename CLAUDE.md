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

## The sources are read-only

The sources are the `llama_cpp` package in `build.zig.zon`: upstream's release
tarball, pinned by URL and content hash. `zig build` fetches it on first use
and unpacks it into `zig-pkg/<hash>/`. That directory is **not part of this
repository** — it is gitignored, and nothing here may modify it. Upstream
ships no `build.zig`, so the package contributes files only; `build.zig`
reaches every one of them through `Config.src`.

This is the whole design. Because the build system sits outside the sources
rather than being patched into them, the pin can move with nothing to
reconcile: `make pin LLAMA_CPP_TAG=<tag>` rewrites the URL and hash, and only
`build.zig`'s `version`, `ggml_version`, `commit` and `build_number` still
need updating by hand. If something in llama.cpp seems to need
changing to make the build work, that is a signal the build description is
wrong, not the source.

```
build.zig, build.zig.zon, Makefile   the build system
zig/metal_embed.zig                  flattens a Metal kernel for embedding
zig/ui-stub/                         stand-in for the web UI when none is embedded
zig/ui_embed.zig                     embeds a built web UI (`-Dui`)
zig/xcframework/                     packs the Apple slices into llama.xcframework
zig/verify.sh                        diffs two llama-cli builds' tokens (`make verify`)
zig-pkg/<hash>/                      sources (gitignored, fetched by zig build)
```

## Commands

```sh
make fetch     # fetch the pinned sources ahead of time (any build does it too)
make pin LLAMA_CPP_TAG=v0.10.0  # re-pin build.zig.zon to another release
make srcdir    # print the pinned sources' directory
make           # everything for the host: ggml, libllama, llama-cli
make cli       # llama-cli, optimized, then chat with $(MODEL)
make lib       # ggml and libllama only
make dist      # optimized (zig build --release=fast)
make ui        # build the web UI with npm into .ui/dist
make server    # llama-server, the UI embedded when .ui/dist exists
make web       # both, then serve $(MODEL) on $(PORT) (default 8080)
make run ARGS="-m model.gguf -ngl 99 -p 'hello' -st"
make ref       # the CMake reference llama-cli, macOS, into .ref (CMAKE=<cmake>)
make verify    # llama-cli's tokens against it: 3 prompts, GPU and CPU (REF=<binary>)
make clean     # build output only
make distclean # also removes zig-pkg; the tarball stays in Zig's global cache

make macos     # llama-cli, arm64, optimized -> zig-out/macos/bin/
make ios       #                             -> zig-out/ios/bin/
make linux     #                             -> zig-out/linux/bin/
make linux-x86_64 # x86_64, AVX2 by default     -> zig-out/linux-x86_64/bin/
make cuda      # llama-cli with CUDA, this Linux host -> zig-out/cuda/bin/

make xcframework  # upstream's 7 Apple slices -> zig-out/xcframework/llama.xcframework
```

The three platform targets each install under a prefix of their own; a single
`zig-out` would have them overwrite each other's `llama-cli` and `libggml.a`.
They differ only in `-Dtarget` — `build.zig` derives everything else from the
OS in the triple — so adding a fourth platform is a `Platform` variant and a
Makefile line, not a restructuring.

Requires Zig **0.17.0**. `macos` and `ios` need the Xcode SDK, the macosx and
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

Three platforms, distinguished by the `Platform` enum in `build.zig`, all arm64 --
and Linux on x86_64 too, where `ArchSources.forArch` swaps ggml-cpu's `arch/arm` pair for
`arch/x86` (`ggml/src/ggml-cpu/CMakeLists.txt:240`). Added for llamazig's x86 port
under an explicit grant; `-Dcpu` picks the SIMD level, `x86_64_v3` (AVX2) by the
Makefile's default.

Everything they share matches the `-D` flags CMake was being driven with:
static libraries, BLAS and OpenMP off, no curl. `-Dblas` turns on ggml's BLAS
backend over Accelerate, as upstream's Apple builds do by default; only the
xcframework uses it.

`Platform` also has `tvos` and `visionos`, and Apple targets accept the
simulator ABI and x86_64 on macOS and the simulators. These exist for
`make xcframework` alone, which builds only the libraries for them; no
`llama-cli` is built or verified there. tvOS and visionOS keep
`LLAMA_SUBPROCESS`, as CMake does, though nothing those libraries compile
reads it.

**Vulkan, optional:** `-Dvulkan` (`make … VULKAN=1`) adds ggml's Vulkan
backend on any platform, as CMake's `GGML_VULKAN` does. It needs what CMake
needs: `glslc` (`-Dglslc`, else the one on `PATH`), the Vulkan and SPIR-V
headers (`-Dvulkan-include`, default `/usr/include` on Linux), and `libvulkan`
to link `llama-cli`. `build.zig` asks `glslc` which shader extensions it
accepts, as `ggml-vulkan/CMakeLists.txt` does, and builds upstream's own
`vulkan-shaders-gen` to compile the 155 shader files -- 1,119 variants with
no optional extension, 1,541 with all of them (counted at v0.5.0). Those answers and the header
version decide which C++ compiles, so two builds compared on bits must use
the same `glslc` and headers. Added for llamazig's Vulkan port under an
explicit grant.

**CUDA, optional:** `-Dcuda` (`make cuda`) adds ggml's CUDA backend on Linux,
for the host's own architecture. The 147 `.cu` files are compiled by the
toolkit's `nvcc` with its default host compiler, g++ -- CMake's exact command
lines, including its unnormalized include spellings, so the objects match a
CMake build's byte for byte except nvcc's `tmpxft_<pid>` temp name in one
local symbol. Zig's clang cannot be nvcc's host: CUDA 13.0's
`math_functions.hpp` clashes with libc++ 22's `isnan`/`isinf`. So the
executables link `libstdc++.so` and `libgcc.a` (g++'s arm64 outline atomics)
by path, beside the shared `cudart`, `cublas`, `cublasLt`, static `culibos`
and the `libcuda` stub, with an rpath to the toolkit, as CMake's link line
has. `-Dcuda-path` (default `$CUDA_PATH`, else `/usr/local/cuda`),
`-Dcuda-arch` (CMake's `CMAKE_CUDA_ARCHITECTURES` spelling; default its
non-native list, `make cuda` passes `121a-real` for the GB10) and
`-Dcuda-fa-quants` (`GGML_CUDA_FA_QUANTS`). Verified on the GB10 (CUDA 13.0)
against `cmake -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=121a-real`:
token-identical at `-ngl 99`, 3 of 3. `-ngl 0` exercises the Linux CPU
path, which is gcc in CMake and Zig's clang here, and is not verified.
Added under an explicit grant.

| | Metal | Accelerate | subprocess | target |
|--------|-------|------------|------------|--------|
| macOS  | on, embedded | on  | on  | `aarch64-macos.26.0` |
| iOS    | on, embedded | on  | off | `aarch64-ios.26.0`, cpu `apple_a18` |
| Linux  | off          | off | on  | `aarch64-linux-gnu`, `_GNU_SOURCE` |
| Linux x86_64 | off    | off | on  | `x86_64-linux-gnu`, cpu `x86_64_v3`, `_GNU_SOURCE` |

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
# The same bytes the Zig build compiles: zig-pkg/<hash>.
SRC=$(make -s srcdir)
mkdir -p /tmp/ref && cd /tmp/ref
cmake "$SRC" -G "Unix Makefiles" \
  -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_OSX_SYSROOT=macosx \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_ACCELERATE=ON -DGGML_BLAS=OFF -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF \
  -DBUILD_SHARED_LIBS=OFF -DLLAMA_CURL=OFF
make -j"$(sysctl -n hw.logicalcpu)" llama-cli
```

Then run both binaries with greedy sampling and a fixed seed, and diff:

```sh
ARGS="-m model.gguf -ngl 99 --temp 0 -s 42 -n 48 -st -p 'Explain gravity in one sentence:'"
/tmp/ref/bin/llama-cli $ARGS 2>/dev/null > /tmp/a.txt
./zig-out/bin/llama-cli $ARGS 2>/dev/null > /tmp/b.txt
diff /tmp/a.txt /tmp/b.txt
```

Strip the banner and the throughput line before comparing — the build id and
tokens/sec differ by design and say nothing about correctness. Strip the
`Loading model...` line too: its spinner goes to stdout, one frame per tick,
so its length follows load time and two runs of the same binary can differ.

`make ref` and `make verify` do all of the above. `make ref` is the CMake
build, into `.ref/`; `make verify` builds `llama-cli` and runs `zig/verify.sh`
against it: three prompts, each with `-ngl 99` and `-ngl 0` (`VERIFY_NGL`),
stripping exactly those three lines and failing on the traps below. Any
`llama-cli` can be the reference (`REF=<binary>`), or the one under test, by
running `zig/verify.sh <ref> <test> <model> [ngl ...]` directly. Last run,
after `MTMD_VIDEO`: 6 of 6.

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

A bit-for-bit comparison of two `zig build` outputs proves less than it
seems, in both directions. A change to the build graph -- `build.zig`, or a
build-time tool such as `zig/metal_embed.zig` -- moves the `.zig-cache/o/<hash>`
directories, and with them two things: the path each Metal stub's debug info
records, and the order of same-named members in `libggml.a` (`ggml.o` from
`ggml.c` and `ggml.cpp`, the two `repack.o`, the two `ggml-metal-device.o`).
That reorders the link, so `llama-cli` differs although every compiled object
is identical. When the binaries differ, compare the archives member by member
and the tokens; neither alone settles it.

## Conventions

- Zig **0.17.0** APIs. `std.Build.Module` options rather than the older compile
  step setters; `.language` on `addCSourceFiles` rather than `-x c++` flags,
  which Zig places after the file where they have no effect.
- Source lists are kept **relative to the sources** and each `addCSourceFiles`
  call passes `.root = self.src.path("")`. This keeps the lists byte-identical
  to CMake's, so they can be diffed against it directly.
- Where CMake globs a directory, `appendGlob` reads it too, rather than
  freezing a list that would go stale on the next sync.
- The Zig follows `../styleguide/ZIGSTYLE.md`. Every function's doc comment
  is a summary of what it does, then one `` - `name`: `` bullet per parameter
  and a `- Returns:` line when it returns a value; paragraphs between the two
  explain **why** rather than restating the code. Every struct opens with
  `const Self = @This();`, every file has a `std.log.scoped(.llamacpp_<file>)`
  logger, and no deprecated std API is used -- they are marked in doc comments
  only, so the compiler does not report them; check `ZIGMIGRATE.md`.
- `build.zig` is `Config`: `Config.init` resolves the target and every `-D`
  option, and its methods (`addGgml`, `addLlama`, `addMtmd`, `addCli`, ...)
  declare the targets from it. `pub fn build` only calls them and registers
  steps. The tools in `zig/` are each a struct (`MetalEmbed`, `UiEmbed`) behind
  a `main`.
- Where this repository departs from ZIGSTYLE, Zig or the build forces it:
  `build` and `main` are free functions because Zig requires them; `zig/` has
  no `module.zig` barrel because its files are separate programs, not a
  package; and only the tools trace function entry with `@src()`. Those traces
  are debug-level, and the tools set `std_options` to info. `build.zig` cannot
  set `std_options`, and the configurer that runs it logs at debug, so the
  same traces there would print on every `zig build`.
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
- **`MTMD_VIDEO` follows `LLAMA_SUBPROCESS`.** CMake turns mtmd's video
  input on by default and forces it off without subprocess support
  (`tools/mtmd/CMakeLists.txt:5-11`), so a stock CMake build has it everywhere
  but iOS. It changes what mtmd reports it can do, not text tokens, which is
  how its absence here long went unnoticed. `-Dmtmd-video=false` turns
  it off; `make xcframework` does for every slice but macOS, as
  `build-xcframework.sh` does.
- **`_GNU_SOURCE` is required on Linux** — ggml reaches for the GNU
  CPU-affinity and allocation extensions (`ggml/src/CMakeLists.txt:152-155`).
  The POSIX-conformance macros CMake also sets globally, `_XOPEN_SOURCE=600`
  and `_DARWIN_C_SOURCE`, are deliberately *not* set here: the Apple builds are
  verified token-identical without them, and adding a feature-test macro to a
  build that already matches can only move it.
- **Every Apple platform needs a generated `zig libc` file**
  (`writeAppleLibcFile`). Zig sets up the SDK include chain only for a *native*
  target. Name any triple — as every Apple build now does — and it treats the
  build as cross-compilation, after which its clang finds no `stdio.h` and its
  libc++ build dies on `mbstate_t`. Passing `-idirafter` to our own sources is
  *not* enough: Zig builds libc++ itself, and that internal build sees none of
  our flags. The libc file is the one knob that reaches it. Do not substitute
  `--sysroot` — with the libc file present it is unnecessary, and `b.sysroot`
  is global, so it would also hit the host `metal_embed` tool. Note `libc_file`
  lives on `Step.Compile`, not on `Module`, which is why
  `addLibrary`/`addExecutable` wrap the builtins instead of `baseModule`
  handling it.
- **Every platform links Zig's bundled libc++.** Under Zig 0.16 the Apple
  platforms linked the SDK's `libc++.tbd` instead, because 0.16 could not
  build its own against the 27.x SDKs: `random.cpp` under a hardcoded
  `-std=c++23` turned clang's `modules` feature on, and SDK 27's `<math.h>`
  then withheld `INFINITY`, which libc++'s `__random/clamp_to_integral.h`
  uses. Zig 0.17 builds it cleanly, so `link_libcpp` is on everywhere again.
  Zig's libc++ is 22.1.8 against the SDK's 22.1.6, with the same ABI
  configuration (version 1, no CityHash fix); the CMake reference still links
  Apple's, which is a difference worth remembering when diffing tokens.
- **The Apple deployment targets are 26.0 by choice**: the floor this project
  needs, not a limit of the build. An earlier note said lowering them broke the
  build with 145 errors at 13.0, from Accelerate's Sparse headers marking
  symbols macOS 15.5+. That no longer reproduces: under Zig 0.17 with the libc
  file, `llama-cli` compiles and links at macOS 13.0 and 13.3, and the
  xcframework's libraries did too before it settled on 26.0. Nothing at those
  versions has been run. The libc file is needed at every version: without it
  you get `CF_BRIDGED_TYPE` redefinitions and a missing `libDER/DERItem.h`,
  the include-chain problem above.
- **iOS pins `-Dcpu=apple_a18`; everything else defaults to the baseline.**
  Zig's aarch64 baseline already implies `DOTPROD` and `FP16_VECTOR_ARITHMETIC`
  on macOS and Linux. Under Zig 0.16 that was also what a native macOS build
  selected; Zig 0.17 recognises the M5 as `apple_m5`, with i8mm, and a native
  build compiled 158 i8mm instructions into `libggml.a`. So `build.zig` makes
  the baseline the default CPU, and naming a triple for macOS again changes no
  ggml kernel. `-Dcpu=native` opts back in. The iOS baseline is bare NEON,
  which drops the dotprod quant kernels entirely.

  The pin targets the iPhone 17 Pro Max, whose SoC is the A19 Pro. Zig 0.16
  modelled Apple cores only up to `apple_a18`, so the A19 Pro could not be
  named (0.17 adds `apple_a19`; moving the pin is a separate decision);
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

## The web UI

`llama-server-impl` links `llama-ui`. Under CMake that target provisions the
SvelteKit bundle -- `npm ci` and `npm run build` under `LLAMA_BUILD_UI`, or a
download from a Hugging Face bucket under `LLAMA_USE_PREBUILT_UI` -- and
`scripts/ui-assets.cmake`'s `emit_files` writes every file of it into
`tools/ui/ui.h.in` and `ui.cpp.in` as byte arrays.

Here the two halves are split:

- **`make ui`** is the npm half. It copies `zig-pkg/<hash>/tools/ui` to
  `.ui/src` (npm writes `node_modules` and `.svelte-kit` beside its sources,
  and the sources are read-only), runs `npm ci` and `npm run build` with
  `LLAMA_UI_OUT_DIR` and the build number in the environment as CMake does,
  and leaves the bundle in `.ui/dist`. Needs node and npm; nothing else does.
- **`zig build server -Dui=.ui/dist`** embeds it: `zig/ui_embed.zig` is
  `emit_files` -- sorted file list, `_gzip/` excluded, the required-asset
  check, gzip with a zero timestamp (`-Dui-gzip`, default on, as
  `LLAMA_UI_GZIP`), ETag = quoted SHA-256 of the embedded bytes, the same
  MIME table, the same templates. `make server` passes `-Dui` when the bundle
  exists; `make web` builds both and serves `$(MODEL)` on `$(PORT)`.

Without `-Dui`, `zig/ui-stub/` supplies the same interface with zero assets
and `LLAMA_UI_HAS_ASSETS` undefined, which switches `server-http.cpp` to its
no-assets path; the declarations are still required, because that file calls
`llama_ui_get_assets()` outside the guard. `llama-cli` always builds that way
-- it never serves a UI.

Three things to know:

- **The gzip bytes are this compressor's, not libarchive's**, so a gzip
  build's ETags differ from a CMake build's. Nothing compares them.
- **`npm run build` is not reproducible.** SvelteKit stamps
  `_app/version.json` with the build time, and the hashed bundle names,
  `index.html` and `sw.js` follow it. Two builds compared byte for byte must
  embed the same `.ui/dist`, not two runs of `make ui`.
- **Every directory of the bundle is a configure input.** A rebuilt bundle
  renames `_app/immutable/bundle.*.js`; with only the top directory watched,
  Zig 0.17 reused the old graph and failed on the vanished file.

llamazig's `build/ui.zig` runs `zig/ui_embed.zig` for its own reference
server, beside its port's generator over the same bundle and the same
compressor, so change its arguments in both places.

Verified: all 70 assets of a build served by `llama-server` and gunzipped
equal the bundle's files; `If-None-Match` (plain and `W/`) gives 304; a
client without `Accept-Encoding: gzip` gets upstream's 415.

## The xcframework

`make xcframework` builds `zig-out/xcframework/llama.xcframework`: upstream's
`build-xcframework.sh` framework -- its seven slices (iOS, macOS, tvOS and
visionOS, devices and simulators), headers, module map, `Info.plist`, install
names and dSYMs -- with the libraries built by `build.zig`. It has the same
shape as llamazig's `xcframework/`, whose framework holds the Zig port, so the
two can be compared. `XCF_BUILDS=macos` builds a subset.

Per slice architecture, `zig build xcframework -Dblas` builds what
`combine_static_libraries` force-loads: ggml with the BLAS backend
(`GGML_BLAS_DEFAULT` is on for Apple), libllama, mtmd and vendor-hash. Then
`zig/xcframework/xcframework.mk` prelinks those with `ld -r` and links them as
the framework's dylib, and `bundle.sh` (a copy of llamazig's) lays out the
bundle. Where it differs from upstream's framework, and why, is in that
file's header. In short:

- **Minimum OS 26.0 everywhere** (`XCF_MIN`), not upstream's 13.3/16.4/1.0.
- **Zig's libc++, libc++abi and compiler_rt are inside the binary, hidden**:
  only `exports.txt`'s prefixes are exported. Upstream's links the OS's
  libc++, which objects compiled against Zig's unannotated libc++ headers
  cannot safely do at an older minimum.
- **Per-architecture kernels.** Upstream's two-architecture slices fall to
  `GGML_CPU_GENERIC`; here each architecture builds its own arch sources.
  The arm64 CPUs are Apple clang's defaults at 26.0 (`apple_a12` iOS and
  visionOS, `apple_a7` tvOS, `apple_m1` macOS and simulators), the x86_64
  ones `x86_64_v3`.
- **The dSYM misses six objects per architecture.** Zig names archive members
  by basename, so `ggml.c`/`ggml.cpp`, the two `quants.c`, the two `repack.cpp`,
  `ggml-cpu.c`/`.cpp`, `ggml-metal-device.cpp`/`.m` and the two `llama.cpp`
  collide, and dsymutil skips them. The code is unaffected.

Verified on macOS: a C driver linked through the framework and the same
driver linked by Zig against the slice's static libraries produce identical
greedy tokens, Metal and CPU, two prompts each. Every slice reports its
platform and minos 26.0, with no libc++ dependency and no C++ exports. The
other slices are not run.

## Adding a target

The pattern is the same every time, and `Config.addCli` shows it several times
over. A new target is a `Config` method:

1. Find the target in its `CMakeLists.txt` and copy its source list verbatim.
2. `self.baseModule()` for the shared settings, then `self.addCommonIncludes(mod)`.
3. Add whatever include paths CMake gives it, keeping `PRIVATE` ones private.
4. `addCSourceFiles` with `.root = self.src.path("")` and the right flag set.
5. `linkLibrary` for each CMake `target_link_libraries` entry.
6. Verify by diffing tokens, not by seeing it link.

Finish with `self.addLibrary(name, mod)` rather than `b.addLibrary`, so the
Apple libc file is attached. Pass `self.c` / `self.cxx` / `self.objc` rather
than a comptime `c_flags ++ defines`: the defines vary by platform and are
folded in at configure time.

## Adding a platform

1. Add a `Platform` variant and map the OS tag in `Platform.detect`.
2. Find what CMake defines for it. The three that have already cost debugging
   are `_GNU_SOURCE`, `LLAMA_SUBPROCESS`, and the Accelerate trio; append them
   to the define lists in `Config.init`, not to `base_defines`.
3. Decide whether `isApple` still means what its doc comment says. It gates
   Metal, Accelerate, the Objective-C sources, and the frameworks together
   because on macOS and iOS they genuinely do travel together. A platform with
   one and not the others needs the predicate split, not a new caller.
4. If Zig cannot find that platform's libc on its own, it needs a libc file the
   way iOS does — and that has to be attached to every `Step.Compile`.
5. Add the Makefile target, installing under `zig-out/<platform>`.
6. Verify by diffing tokens on that platform, not by seeing it link.

