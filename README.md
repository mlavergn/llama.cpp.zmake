# llama.cpp.zmake

A Zig build system for [llama.cpp](https://github.com/ggerganov/llama.cpp),
replacing CMake.

The sources stay C, C++, and Objective-C. Nothing here ports code, and nothing
here modifies llama.cpp — this directory sits outside the checkout and reads it
from `./llama.cpp`.

## Layout

```
llama.cpp.zmake/          this repository
├── build.zig             the build graph
├── build.zig.zon
├── Makefile
├── zig/
│   ├── metal_embed.zig   flattens a Metal kernel for embedding
│   └── ui-stub/          stand-in for the generated web UI assets
└── llama.cpp/            the sources, fetched by `make clone` (gitignored)
```

Because the sources are untouched, the pinned tag can be changed or the
checkout replaced without reconciling anything.

## Use

```sh
make clone     # fetch llama.cpp at v0.3.0
make           # build everything for the host
make cli       # llama-cli only
make lib       # ggml and libllama only
make dist      # optimized
make run ARGS="-m model.gguf -ngl 99 -p 'hello' -st"
```

Per-platform builds of `llama-cli`, all arm64, each optimized and installed
under a prefix of its own so the three can coexist:

```sh
make macos     # -> zig-out/macos/bin/llama-cli
make ios       # -> zig-out/ios/bin/llama-cli
make linux     # -> zig-out/linux/bin/llama-cli
```

Requires Zig 0.16.0. `make macos` and `make ios` need the Xcode SDK — the
macosx and iphoneos ones respectively. `make linux` cross-compiles from any
host with no sysroot at all: Zig ships glibc and its own libc++.

## What it builds

`llama-cli` and everything it links: ggml with its CPU backend and, on Apple
platforms, its Metal backend; libllama with all 151 model architectures, the
vendored libraries, `common` including the Jinja engine, `mtmd`, and the server
implementation the CLI drives in-process.

`build.zig` derives its whole configuration from the OS in the target triple.
Everything the three platforms share matches the `-D` flags CMake was being
driven with: static libraries, BLAS and OpenMP off, no curl.

| | Metal | Accelerate | subprocess | target |
|--------|-------|------------|------------|--------|
| macOS  | on, embedded | on  | on  | `aarch64-macos.26.0` |
| iOS    | on, embedded | on  | off | `aarch64-ios.26.0`, cpu `apple_a18` |
| Linux  | off          | off | on  | `aarch64-linux-gnu`, `_GNU_SOURCE` |

**Verified:** on macOS the resulting `llama-cli` produces token-identical
output to a CMake + Apple-clang build of the same sources, on a fixed model,
prompt, and seed at `--temp 0`.

The iOS and Linux binaries are **not** runtime-verified. They compile and link
with no undefined symbols, the Linux one registers the CPU backend and contains
no Metal symbols, and the iOS one carries all twenty embedded shader libraries
and targets platform 2 at minos 26.0 — but by this project's own standard that
proves very little. Neither has been diffed against a CMake build on its own
platform, and until one is, treat them as unproven.

## What it does not build

The other ~90 CMake binaries — tests, benchmarks, and the other tools. They are
ordinary additions to the same pattern.

## The web UI is stubbed

`llama-cli` links `llama-server-impl`, which links `llama-ui`. Under CMake that
target runs a SvelteKit/npm build and then compiles a host tool to turn the
output into a C++ asset array. Driving npm from the build graph is possible but
was not the point, so `zig/ui-stub/` supplies the same interface with zero
assets.

`LLAMA_UI_HAS_ASSETS` is deliberately left undefined, which switches
`server-http.cpp` to its no-assets path. The declarations are still required,
because that file calls `llama_ui_get_assets()` outside the guard.

`llama-cli` is unaffected — it never serves a web UI. `llama-server` would
build and run but serve none.

## Fidelity notes

Things CMake does that are easy to miss, each of which cost real debugging:

- **`vendor/hash/sha1/sha1.c` is C++.** CMake sets `LANGUAGE CXX` on it
  (`vendor/hash/CMakeLists.txt:32`) because the file wraps itself in a
  namespace to avoid clashing with BoringSSL. Compiled as C it fails on
  `namespace`.
- **`src` must not be a global include path.** It holds a second `unicode.h`
  that shadows `common/unicode.h`, which `common/jinja/value.cpp` needs. CMake
  keeps `src` private to the `llama` target for the same reason.
- **`LLAMA_VERSION` and `LLAMA_COMMIT` are private to the `llama` target.**
  Passed globally they collide with the variables of those names in
  `build-info.cpp`.
- **`-fobjc-arc` must not be set.** The Metal sources use manual reference
  counting and bridge freely between `void *` and Objective-C object pointers.
- **The C sanitizers must be off.** These sources are not UBSan-clean, and Zig
  enables the sanitizers in Debug where CMake never did.
- **Never enable the non-embedded Metal path.** It needs `xcrun -sdk macosx
  metal`, which the Zig toolchain cannot replace. The embedded path is text
  processing plus an assemble step, which `zig/metal_embed.zig` does.
- **`LLAMA_SUBPROCESS` is off on iOS.** CMake turns it off on mobile and WASM
  targets, where spawning a subprocess is not sandbox-friendly
  (`CMakeLists.txt:104-110`). Defining it there would compile, and be wrong.
- **`_GNU_SOURCE` is required on Linux.** ggml reaches for the GNU CPU-affinity
  and allocation extensions (`ggml/src/CMakeLists.txt:152-155`). The
  POSIX-conformance macros CMake also sets globally — `_XOPEN_SOURCE=600` and
  `_DARWIN_C_SOURCE` — are deliberately *not* set here: the Apple builds are
  verified token-identical without them.
- **iOS and macOS both need a generated `zig libc` file.** Zig sets up the SDK
  include chain only for a *native* target. Name any triple — as both Apple
  builds do — and it treats the build as cross-compilation, after which its
  clang finds no `stdio.h` and its libc++ build dies on `mbstate_t`. Passing
  `-idirafter` to our own sources is not enough: Zig builds libc++ itself, and
  that internal build sees none of our flags. A libc file is the one knob that
  reaches it. Do not substitute `--sysroot`: with the libc file present it is
  unnecessary, and `b.sysroot` would also be applied to the host `metal_embed`
  tool.
- **The Apple deployment targets are 26.0, and lowering them breaks the build.**
  At 13.0 the Xcode 26 SDK produces 145 errors: Accelerate's Sparse headers
  annotate symbols as macOS 15.5+, and clang makes unguarded use of them an
  error, not a warning.
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
  226 dotprod and 22 i8mm instructions, zero SVE.

  The cost is device coverage — the binary now requires an A18 or newer, i.e.
  iPhone 16 and later, and will not run on the A13–A17 devices iOS 26 supports.