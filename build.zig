//! Zig build system for llama.cpp, replacing CMake.
//!
//! Builds the stock C, C++, and Objective-C sources unmodified. Nothing here
//! ports code -- the only thing being replaced is the build description.
//!
//! # Scope
//!
//! Everything `llama-cli` needs, which is most of the library surface:
//! ggml with its CPU backend and, on Apple platforms, its Metal backend;
//! libllama, the vendored libraries, `common`, `mtmd`, and the server
//! implementation that the CLI links against. Not built: the other ~90 CMake
//! binaries (tests, benchmarks, the other tools) and the SvelteKit web UI --
//! see `zig/ui-stub/ui.h`.
//!
//! # Configuration
//!
//! Three arm64 platforms, selected by `-Dtarget` and distinguished by
//! `Platform`. Everything else matches the `-D` flags CMake was being driven
//! with: static libraries, BLAS off, OpenMP off, no curl.
//!
//!   macOS  Metal on, shader library embedded, Accelerate on, subprocess on
//!   iOS    the same, minus subprocess -- CMake turns it off on mobile
//!   Linux  CPU backend only, no Metal, no Accelerate, `_GNU_SOURCE` on
//!
//! The Makefile drives all three; it owns the deployment targets and the one
//! `-Dcpu` pin, none of which this file needs to know about.
//!
//! `-Dvulkan` adds ggml's Vulkan backend on any of them. It needs three things
//! from outside the Zig toolchain, as CMake's build does: `glslc` to compile
//! the shaders (`-Dglslc`, else the one on PATH), the Vulkan and SPIR-V
//! headers (`-Dvulkan-include`, default `/usr/include` on Linux), and
//! `libvulkan` to link (`-Dvulkan-lib` for a directory Zig does not search).
//! Which shader extensions that `glslc` accepts decides which C++ compiles, so
//! the same `glslc` and headers must build both sides of any comparison.
//!
//! # Steps
//!
//!   zig build            everything below
//!   zig build cli        llama-cli
//!   zig build lib        ggml + libllama only
//!   zig build run -- ... build and run llama-cli

const std = @import("std");
const builtin = @import("builtin");

/// Where the llama.cpp checkout lives, relative to this build root.
///
/// The build system sits outside the sources rather than inside them: this
/// directory is its own repository, and `make clone` fetches llama.cpp into a
/// subdirectory. Nothing in the checkout is modified, so it can be replaced or
/// re-pinned without touching anything here.
const src_root = "llama.cpp";

/// A path inside the llama.cpp checkout.
fn srcPath(b: *std.Build, sub: []const u8) std.Build.LazyPath {
    return b.path(b.fmt("{s}/{s}", .{ src_root, sub }));
}

/// What CMake configures `ggml-version.h`, `llama-version.h` and
/// `build-info.cpp` with at the pinned release tag.
///
/// `version` is `LLAMA_VERSION` with `LLAMA_BUILD_IS_DEV` off, as for a
/// release tag (CMakeLists.txt:6-21); `ggml_version` is ggml's own
/// (ggml/CMakeLists.txt:6-31), which is not llama.cpp's. `commit` is
/// `git rev-parse --short HEAD` and `build_number` the build tag's number
/// (`git describe --tags --match 'b*'`), as cmake/build-info.cmake derives
/// them.
const version = "0.4.0";
const ggml_version = "0.23.0";
const commit = "5266f24da";
const build_number = 10809;

/// The platforms this build knows how to configure.
///
/// CMake branches on `APPLE`, `CMAKE_SYSTEM_NAME`, and the `GGML_*` options
/// its caller passes. Those branches collapse to this enum, because the option
/// set is fixed: which backends exist, which sources compile, and which
/// feature-test macros are defined all follow from the target OS.
const Platform = enum {
    macos,
    ios,
    linux,
    windows,

    /// Maps a resolved target onto a configuration this build supports.
    ///
    /// Parameters:
    /// - `target`: the target `-Dtarget` resolved to.
    ///
    /// Return: the platform, or null if this build has no configuration for
    /// that OS. The caller reports it; `detect` has no `*std.Build` to log
    /// through.
    fn detect(target: std.Target) ?Platform {
        return switch (target.os.tag) {
            .macos => .macos,
            .ios => .ios,
            .linux => .linux,
            .windows => .windows,
            else => null,
        };
    }

    /// Whether the Metal backend and the Accelerate framework are available.
    ///
    /// The two travel together: both come from the Apple SDK, and CMake
    /// defaults `GGML_METAL` and the Accelerate lookup off the same `APPLE`
    /// check (`ggml/CMakeLists.txt:96`, `ggml-cpu/CMakeLists.txt:60`).
    fn isApple(self: Platform) bool {
        return self == .macos or self == .ios;
    }
};

/// Warnings that fire on these sources under Zig's clang and bundled libc++
/// but say nothing useful. Silenced so real diagnostics stay visible.
const quiet = [_][]const u8{
    "-Wno-nullability-completeness",
    "-Wno-deprecated-declarations",
    "-Wno-unused-function",
    "-Wno-unused-variable",
    "-Wno-unused-but-set-variable",
};

const c_std = [_][]const u8{"-std=c11"} ++ quiet;
const cxx_std = [_][]const u8{"-std=c++17"} ++ quiet;

/// CMake's own dialects. `CMAKE_C_STANDARD 11` and `cxx_std_17` leave
/// `C_EXTENSIONS`/`CXX_EXTENSIONS` at their default, on, so CMake passes
/// `-std=gnu11` and `-std=gnu++17` everywhere. The other platforms keep the
/// strict ones above, which they were verified with and which llamazig's
/// bit-exact gates are calibrated against. Windows takes these, because MinGW's
/// `<math.h>` withholds `M_PI` under `__STRICT_ANSI__` and
/// `tools/mtmd/mtmd-audio.cpp` defines `_USE_MATH_DEFINES` only after its own
/// header has already included `<cmath>`.
const gnu_c_std = [_][]const u8{"-std=gnu11"} ++ quiet;
const gnu_cxx_std = [_][]const u8{"-std=gnu++17"} ++ quiet;
// ARC stays off: the Metal sources use manual reference counting and bridge
// freely between void* and Objective-C object pointers.
const objc_std = [_][]const u8{"-std=c11"} ++ quiet;

/// Backend selection and build metadata that every platform shares.
const base_defines = [_][]const u8{
    "-DGGML_USE_CPU",
    "-DGGML_SCHED_MAX_COPIES=4",
    "-DGGML_USE_LLAMAFILE",
    // GGML_CPU_REPACK defaults ON upstream (ggml/CMakeLists.txt:152).
    // Without it ggml-cpu.cpp never registers the repack buffer type and
    // repack.cpp is unreachable. This build is the bit-exact reference
    // for llamazig's ops-diff/node-diff/parity-port, so it has to match.
    "-DGGML_USE_CPU_REPACK",
};

/// The Metal backend and the Accelerate BLAS, from `ggml/CMakeLists.txt:96`
/// and `ggml/src/ggml-cpu/CMakeLists.txt:60-67`.
const apple_defines = [_][]const u8{
    "-DGGML_USE_METAL",
    "-DGGML_METAL_EMBED_LIBRARY",
    "-DGGML_USE_ACCELERATE",
    "-DACCELERATE_NEW_LAPACK",
    "-DACCELERATE_LAPACK_ILP64",
};

/// Required by the server tools and the server's router mode. CMake turns it
/// on everywhere except the mobile and WASM targets, where spawning a
/// subprocess is not sandbox-friendly (`CMakeLists.txt:104-110`).
const subprocess_defines = [_][]const u8{"-DLLAMA_SUBPROCESS"};

/// CPU affinity and some allocation interfaces are GNU extensions on Linux.
/// From `ggml/src/CMakeLists.txt:152-155`.
///
/// The POSIX-conformance macros CMake also sets globally (`_XOPEN_SOURCE=600`,
/// `_DARWIN_C_SOURCE`) are deliberately absent: the Apple builds are verified
/// token-identical without them, and adding a feature-test macro to a build
/// that already matches can only move it.
const linux_defines = [_][]const u8{"-D_GNU_SOURCE"};

/// From `CMakeLists.txt:81` and `ggml/src/CMakeLists.txt:182`, both `if
/// (WIN32)`. The target is MinGW (`x86_64-windows-gnu`), the only Windows ABI
/// Zig ships a libc for; CMake's MinGW arms otherwise only pick static linking,
/// which this build always does.
const windows_defines = [_][]const u8{"-D_CRT_SECURE_NO_WARNINGS"};

/// cpp-httplib's tuning, from vendor/cpp-httplib/CMakeLists.txt:29.
const httplib_defines = [_][]const u8{
    "-DCPPHTTPLIB_FORM_URL_ENCODED_PAYLOAD_MAX_LENGTH=1048576",
    "-DCPPHTTPLIB_LISTEN_BACKLOG=512",
    "-DCPPHTTPLIB_REQUEST_URI_MAX_LENGTH=32768",
    "-DCPPHTTPLIB_TCP_NODELAY=1",
};

// -----------------------------------------------------------------------------
// Source lists
//
// Taken from the CMakeLists.txt each target lives in. Files the CMake adds
// only for an option this build leaves off are omitted, and noted where the
// omission is not obvious.

const ggml_c_sources = [_][]const u8{
    "ggml/src/ggml.c",
    "ggml/src/ggml-alloc.c",
    "ggml/src/ggml-quants.c",
    "ggml/src/ggml-cpu/ggml-cpu.c",
    "ggml/src/ggml-cpu/quants.c",
};

const ggml_cxx_sources = [_][]const u8{
    "ggml/src/ggml.cpp",
    "ggml/src/ggml-backend.cpp",
    "ggml/src/ggml-backend-meta.cpp",
    "ggml/src/ggml-opt.cpp",
    "ggml/src/ggml-threading.cpp",
    "ggml/src/gguf.cpp",
    "ggml/src/ggml-backend-dl.cpp",
    "ggml/src/ggml-backend-reg.cpp",
    "ggml/src/ggml-cpu/ggml-cpu.cpp",
    "ggml/src/ggml-cpu/repack.cpp",
    "ggml/src/ggml-cpu/iqp.cpp",
    "ggml/src/ggml-cpu/hbm.cpp",
    "ggml/src/ggml-cpu/traits.cpp",
    "ggml/src/ggml-cpu/binary-ops.cpp",
    "ggml/src/ggml-cpu/unary-ops.cpp",
    "ggml/src/ggml-cpu/vec.cpp",
    "ggml/src/ggml-cpu/ops.cpp",
    // amx compiles to nothing on ARM but CMake lists it unconditionally.
    "ggml/src/ggml-cpu/amx/amx.cpp",
    "ggml/src/ggml-cpu/amx/mmq.cpp",
    "ggml/src/ggml-cpu/llamafile/sgemm.cpp",
};

/// The CPU backend's per-architecture sources, one pair per
/// `GGML_SYSTEM_ARCH` (ggml/src/ggml-cpu/CMakeLists.txt:79, 240). On x86
/// CMake adds `arch/x86/cpu-feats.cpp` only for `GGML_BACKEND_DL`, which is
/// off here, and the `GGML_AVX*` definitions it pairs with the `-m` flags are
/// read by that file alone; the kernels test the compiler's own `__AVX2__`
/// and friends, which `-Dcpu` sets.
const ArchSources = struct { c: []const []const u8, cxx: []const []const u8 };

const ggml_arm_sources: ArchSources = .{
    .c = &.{"ggml/src/ggml-cpu/arch/arm/quants.c"},
    .cxx = &.{"ggml/src/ggml-cpu/arch/arm/repack.cpp"},
};

const ggml_x86_sources: ArchSources = .{
    .c = &.{"ggml/src/ggml-cpu/arch/x86/quants.c"},
    .cxx = &.{"ggml/src/ggml-cpu/arch/x86/repack.cpp"},
};

/// The arch sources for `arch`, or null for one this build has no list for.
fn archSources(arch: std.Target.Cpu.Arch) ?ArchSources {
    return switch (arch) {
        .aarch64 => ggml_arm_sources,
        .x86_64 => ggml_x86_sources,
        else => null,
    };
}

/// The Metal backend's C++ layer. Apple platforms only.
const metal_cxx_sources = [_][]const u8{
    "ggml/src/ggml-metal/ggml-metal.cpp",
    "ggml/src/ggml-metal/ggml-metal-device.cpp",
    "ggml/src/ggml-metal/ggml-metal-common.cpp",
    "ggml/src/ggml-metal/ggml-metal-ops.cpp",
    "ggml/src/ggml-metal/ggml-metal-tuning.cpp",
};

/// The Metal backend's Objective-C layer. Apple platforms only.
const metal_objc_sources = [_][]const u8{
    "ggml/src/ggml-metal/ggml-metal-device.m",
    "ggml/src/ggml-metal/ggml-metal-context.m",
};

/// Metal shader libraries, mirroring the `GGML_METAL_LIBS` X-macro in
/// `ggml-metal-device.m`. Each becomes a `ggml_metallib_<name>_{start,end}`
/// symbol pair the Objective-C device layer reads at load time.
const metal_kernels = [_][]const u8{
    "fa",   "mul_mv",  "mul_mm",          "quantize",  "softmax",
    "norm", "unary",   "binbcast",        "reduce",    "tri",
    "ssm",  "wkv",     "gated_delta_net", "solve_tri", "rope",
    "conv", "upscale", "argsort",         "pool",      "misc",
};

const llama_sources = [_][]const u8{
    "src/llama.cpp",                    "src/llama-adapter.cpp",
    "src/llama-arch.cpp",               "src/llama-batch.cpp",
    "src/llama-chat.cpp",               "src/llama-context.cpp",
    "src/llama-cparams.cpp",            "src/llama-grammar.cpp",
    "src/llama-graph.cpp",              "src/llama-hparams.cpp",
    "src/llama-impl.cpp",               "src/llama-io.cpp",
    "src/llama-kv-cache.cpp",           "src/llama-kv-cache-iswa.cpp",
    "src/llama-kv-cache-dsa.cpp",       "src/llama-kv-cache-dsa-iswa.cpp",
    "src/llama-kv-cache-msa.cpp",       "src/llama-kv-cache-dsv4.cpp",
    "src/llama-memory.cpp",             "src/llama-memory-hybrid.cpp",
    "src/llama-memory-hybrid-iswa.cpp", "src/llama-memory-hybrid-idx.cpp",
    "src/llama-memory-recurrent.cpp",
    "src/llama-mmap.cpp",               "src/llama-model-loader.cpp",
    "src/llama-model-saver.cpp",        "src/llama-model.cpp",
    "src/llama-quant.cpp",              "src/llama-sampler.cpp",
    "src/llama-vocab.cpp",              "src/unicode-data.cpp",
    "src/unicode.cpp",
};

const common_sources = [_][]const u8{
    "common/arg.cpp",                      "common/chat-auto-parser-generator.cpp",
    "common/chat-auto-parser-helpers.cpp", "common/chat-diff-analyzer.cpp",
    "common/chat-peg-parser.cpp",          "common/chat.cpp",
    "common/common.cpp",                   "common/console.cpp",
    "common/debug.cpp",                    "common/download.cpp",
    "common/fit.cpp",                      "common/hf-cache.cpp",
    "common/imatrix-loader.cpp",           "common/json-schema-to-grammar.cpp",
    "common/json.cpp",                     "common/llguidance.cpp",
    "common/log.cpp",                      "common/ngram-cache.cpp",
    "common/ngram-map.cpp",                "common/ngram-mod.cpp",
    "common/peg-parser.cpp",               "common/preset.cpp",
    "common/reasoning-budget.cpp",         "common/sampling.cpp",
    "common/speculative.cpp",              "common/subproc.cpp",
    "common/trie.cpp",                     "common/unicode.cpp",
    "common/jinja/lexer.cpp",              "common/jinja/parser.cpp",
    "common/jinja/runtime.cpp",            "common/jinja/value.cpp",
    "common/jinja/string.cpp",             "common/jinja/caps.cpp",
};

/// mtmd's own sources. The per-architecture files under `models/` are globbed,
/// as CMake does, so a new architecture does not need a build change.
const mtmd_sources = [_][]const u8{
    "tools/mtmd/mtmd.cpp",
    "tools/mtmd/mtmd-audio.cpp",
    "tools/mtmd/mtmd-image.cpp",
    "tools/mtmd/mtmd-helper.cpp",
    "tools/mtmd/mtmd-helper-gen.cpp",
    "tools/mtmd/clip.cpp",
};

const server_context_sources = [_][]const u8{
    "tools/server/server-chat.cpp",    "tools/server/server-task.cpp",
    "tools/server/server-queue.cpp",   "tools/server/server-common.cpp",
    "tools/server/server-context.cpp", "tools/server/server-stream.cpp",
    "tools/server/server-tools.cpp",   "tools/server/server-mcp.cpp",
    "tools/server/server-schema.cpp",
};

const server_impl_sources = [_][]const u8{
    "tools/server/server.cpp",
    "tools/server/server-http.cpp",
    "tools/server/server-models.cpp",
};

const cli_impl_sources = [_][]const u8{
    "tools/cli/cli.cpp",
    "tools/cli/cli-client.cpp",
    "tools/cli/cli-context.cpp",
};

// -----------------------------------------------------------------------------

/// Everything the target-specific decisions were resolved into, computed once
/// in `build` and threaded through the `add*` functions.
const Config = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    platform: Platform,

    /// Apple SDK path. Null on Linux and Windows.
    sdk: ?[]const u8,

    /// A generated `zig libc` file pointing at the SDK's headers. Null on
    /// Linux and Windows, where Zig ships glibc and MinGW and needs no help.
    ///
    /// Both Apple platforms need one, because both are named by an explicit
    /// `-Dtarget`. Zig only sets up the SDK include chain for a *native*
    /// target; name any triple and it treats the build as cross-compilation,
    /// after which its clang finds no `stdio.h` and its libc++ build dies on
    /// `mbstate_t`. Passing `-idirafter` on our own sources is not enough --
    /// Zig builds libc++ itself, and that internal build sees none of our
    /// flags. A libc file is the one knob that reaches it.
    libc_file: ?std.Build.LazyPath,

    /// The bare C and C++ flags, without the platform's defines. For the
    /// vendored libraries CMake compiles without ggml's defines.
    c_std: []const []const u8,
    cxx_std: []const []const u8,

    /// Compiler flags per language, with the platform's defines already
    /// folded in.
    c: []const []const u8,
    cxx: []const []const u8,
    objc: []const []const u8,

    /// The Vulkan backend's configuration; null without `-Dvulkan`.
    vulkan: ?Vulkan,
};

/// Declares the build graph.
///
/// Parameters:
/// - `b`: the build graph the steps are registered on.
///
/// Return: nothing on success; propagates target, SDK resolution, and
/// directory-read failures.
pub fn build(b: *std.Build) !void {
    // Zig 0.17 recognises the M5 as `apple_m5`, with i8mm and SME, where 0.16
    // fell back to the macOS baseline (`apple_m1`). The native default would
    // therefore compile `__ARM_FEATURE_MATMUL_INT8` kernels into ggml-cpu --
    // 158 i8mm instructions, measured -- and stop matching a build that names
    // its triple. The default stays at the baseline; `-Dcpu=native` opts in.
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});
    const platform = Platform.detect(target.result) orelse {
        std.log.err(
            "no configuration for OS '{s}'; this build knows macos, ios, linux, and windows",
            .{@tagName(target.result.os.tag)},
        );
        return error.UnsupportedTarget;
    };
    // ggml's arch sources are listed for arm64 and x86_64 only. Anything else
    // would link a libggml with no quant kernels rather than fail outright,
    // so it is caught here instead. x86_64 is Linux and Windows only: no
    // Apple platform this build knows runs it.
    if (archSources(target.result.cpu.arch) == null or
        (target.result.cpu.arch == .x86_64 and platform.isApple()))
    {
        std.log.err(
            "no configuration for arch '{s}' on '{s}'; ggml's arch sources are arm64, and x86_64 on Linux and Windows",
            .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) },
        );
        return error.UnsupportedTarget;
    }

    const sdk = if (platform.isApple()) try resolveAppleSdk(b, target.result) else null;
    const vulkan = try configureVulkan(b, platform);

    var defs: std.ArrayList([]const u8) = .empty;
    try defs.appendSlice(b.allocator, &base_defines);
    if (platform.isApple()) try defs.appendSlice(b.allocator, &apple_defines);
    if (platform != .ios) try defs.appendSlice(b.allocator, &subprocess_defines);
    if (platform == .linux) try defs.appendSlice(b.allocator, &linux_defines);
    if (platform == .windows) try defs.appendSlice(b.allocator, &windows_defines);
    // Only `ggml-backend-reg.cpp` reads it, to register the backend.
    if (vulkan != null) try defs.append(b.allocator, "-DGGML_USE_VULKAN");

    const lang_c: []const []const u8 = if (platform == .windows) &gnu_c_std else &c_std;
    const lang_cxx: []const []const u8 = if (platform == .windows) &gnu_cxx_std else &cxx_std;

    const cfg = Config{
        .target = target,
        .optimize = optimize,
        .platform = platform,
        .sdk = sdk,
        .libc_file = if (sdk) |s| writeAppleLibcFile(b, s) else null,
        .c_std = lang_c,
        .cxx_std = lang_cxx,
        .c = try join(b, lang_c, defs.items),
        .cxx = try join(b, lang_cxx, defs.items),
        .objc = try join(b, &objc_std, defs.items),
        .vulkan = vulkan,
    };

    const ggml = try addGgml(b, cfg);
    const llama = try addLlama(b, cfg, ggml);

    const lib_step = b.step("lib", "Build ggml and libllama only");
    lib_step.dependOn(&b.addInstallArtifact(ggml, .{}).step);
    lib_step.dependOn(&b.addInstallArtifact(llama, .{}).step);

    const cli = try addCli(b, cfg, ggml, llama);
    b.installArtifact(cli);

    const cli_step = b.step("cli", "Build llama-cli");
    cli_step.dependOn(&b.addInstallArtifact(cli, .{}).step);

    const run = b.addRunArtifact(cli);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    const run_step = b.step("run", "Run llama-cli");
    run_step.dependOn(&run.step);
}

/// Concatenates two flag lists into one the build graph can hold onto.
fn join(b: *std.Build, a: []const []const u8, c: []const []const u8) ![]const []const u8 {
    const out = try b.allocator.alloc([]const u8, a.len + c.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], c);
    return out;
}

/// Locates the Apple SDK matching the target, for the header, framework, and
/// library search paths.
///
/// Parameters:
/// - `b`: the build graph, for its allocator and IO.
/// - `target`: the resolved target; selects `macosx` or `iphoneos`.
///
/// Return: the SDK path; `error.AppleSdkNotFound` when none is installed.
fn resolveAppleSdk(b: *std.Build, target: std.Target) ![]const u8 {
    return std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target) orelse
        error.AppleSdkNotFound;
}

/// Writes a `zig libc` file describing an Apple SDK.
///
/// Pointing both include directories at the SDK fixes the compile and, because
/// Zig feeds the same file to its internal libc++ build, the link as well. See
/// `Config.libc_file` for why a named triple needs this and a native one does
/// not.
///
/// Zig 0.17 requires two keys it did not before: `darwin_sdk_dir`, the SDK
/// root, and a non-empty `crt_dir`. Both take the values Zig's own native
/// detection writes (`LibCInstallation.findNative`), so a named triple sees the
/// same libc a native build does. The remaining keys are required by the file
/// format and empty by design: the MSVC and cc keys are for other platforms
/// entirely.
///
/// Parameters:
/// - `b`: the build graph, for its allocator and generated-file step.
/// - `sdk`: the macosx or iphoneos SDK root.
///
/// Return: a lazy path to the generated file, valid for the whole build.
fn writeAppleLibcFile(b: *std.Build, sdk: []const u8) std.Build.LazyPath {
    return b.addWriteFiles().add("apple-libc.txt", b.fmt(
        \\include_dir={s}/usr/include
        \\sys_include_dir={s}/usr/include
        \\crt_dir={s}/usr/lib
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\cc_dir=
        \\darwin_sdk_dir={s}
        \\
    , .{ sdk, sdk, sdk, sdk }));
}

/// Applies the settings every C/C++ target in this build shares.
fn baseModule(b: *std.Build, cfg: Config) *std.Build.Module {
    const mod = b.createModule(.{
        .target = cfg.target,
        .optimize = cfg.optimize,
        .link_libc = true,
        .link_libcpp = true,
        // These sources are not UBSan-clean -- they rely on pointer arithmetic
        // that is technically undefined but universally works -- and Zig turns
        // the C sanitizers on in Debug. CMake never enabled them.
        .sanitize_c = .off,
    });
    if (cfg.sdk) |sdk| {
        mod.addFrameworkPath(b.graph.cwdRelativePath(b.fmt("{s}/System/Library/Frameworks", .{sdk})));
        // Only iOS needs the library path spelled out; for macOS Zig already
        // searches the SDK, and this is the same directory it would find.
        mod.addLibraryPath(b.graph.cwdRelativePath(b.fmt("{s}/usr/lib", .{sdk})));
    }
    return mod;
}

/// Wraps `b.addLibrary`, attaching the libc file when the platform needs one.
///
/// `libc_file` lives on the compile step rather than the module, so it cannot
/// be set in `baseModule` and has to be applied at every construction site.
fn addLibrary(b: *std.Build, cfg: Config, name: []const u8, mod: *std.Build.Module) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{ .name = name, .root_module = mod, .linkage = .static });
    lib.setLibCFile(cfg.libc_file);
    return lib;
}

/// Wraps `b.addExecutable`, attaching the libc file when the platform needs
/// one. See `addLibrary`.
fn addExecutable(b: *std.Build, cfg: Config, name: []const u8, mod: *std.Build.Module) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    exe.setLibCFile(cfg.libc_file);
    return exe;
}

/// Adds the include paths shared by everything above ggml.
fn addCommonIncludes(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path(src_root));
    mod.addIncludePath(srcPath(b, "include"));
    // Note `src` is deliberately absent. It holds a second unicode.h, and
    // adding it here shadows common/unicode.h, which common/jinja needs.
    // CMake keeps it PRIVATE to the llama target for the same reason.
    mod.addIncludePath(srcPath(b, "common"));
    mod.addIncludePath(srcPath(b, "ggml/include"));
    mod.addIncludePath(srcPath(b, "ggml/src"));
    // Covers both <nlohmann/json.hpp> and <cpp-httplib/httplib.h>.
    mod.addIncludePath(srcPath(b, "vendor"));
}

/// The shader extensions `ggml/src/ggml-vulkan/CMakeLists.txt:65-113` asks
/// `glslc` about, in its order. Each one `glslc` accepts defines its macro for
/// the shader generator and for `ggml-vulkan.cpp`, and both compile
/// differently for it.
const VulkanFeature = struct {
    /// The extension named in `glslc`'s refusal.
    extension: []const u8,
    /// The test shader under `vulkan-shaders/feature-tests/`.
    test_shader: []const u8,
    /// The macro defined when `glslc` accepts it.
    define: []const u8,
};

const vulkan_features = [_]VulkanFeature{
    .{ .extension = "GL_KHR_cooperative_matrix", .test_shader = "coopmat.comp", .define = "GGML_VULKAN_COOPMAT_GLSLC_SUPPORT" },
    .{ .extension = "GL_NV_cooperative_matrix2", .test_shader = "coopmat2.comp", .define = "GGML_VULKAN_COOPMAT2_GLSLC_SUPPORT" },
    .{ .extension = "GL_NV_cooperative_matrix_decode_vector", .test_shader = "coopmat2_decode_vector.comp", .define = "GGML_VULKAN_COOPMAT2_DECODE_VECTOR_GLSLC_SUPPORT" },
    .{ .extension = "GL_EXT_integer_dot_product", .test_shader = "integer_dot.comp", .define = "GGML_VULKAN_INTEGER_DOT_GLSLC_SUPPORT" },
    .{ .extension = "GL_EXT_bfloat16", .test_shader = "bfloat16.comp", .define = "GGML_VULKAN_BFLOAT16_GLSLC_SUPPORT" },
    .{ .extension = "GL_EXT_float_e2m1", .test_shader = "float_e2m1.comp", .define = "GGML_VULKAN_FLOAT_E2M1_GLSLC_SUPPORT" },
    .{ .extension = "GL_EXT_float_e4m3", .test_shader = "float_e4m3.comp", .define = "GGML_VULKAN_FLOAT_E4M3_GLSLC_SUPPORT" },
};

/// The Vulkan shader sources and their generator, relative to the checkout.
const vulkan_shaders_dir = "ggml/src/ggml-vulkan/vulkan-shaders";

/// What `-Dvulkan` resolved to at configure time.
const Vulkan = struct {
    /// The `glslc` every shader is compiled with.
    glslc: []const u8,
    /// Directories holding `vulkan/` and `spirv/`, searched after libc's.
    include_dirs: []const []const u8,
    /// Extra directories to find `libvulkan` in.
    lib_dirs: []const []const u8,
    /// `-D` flags for the shader extensions `glslc` accepts.
    features: []const []const u8,
};

/// Builds ggml with its CPU backend -- and, on Apple platforms, its Metal
/// backend, and with `-Dvulkan` its Vulkan one -- as one static archive.
///
/// CMake splits the backends so they can be loaded dynamically. With static
/// linking and `GGML_BACKEND_DL` off that split carries no meaning:
/// `ggml-backend-reg.cpp` calls each backend's registration function directly
/// under an `#ifdef`, so one archive links identically.
fn addGgml(b: *std.Build, cfg: Config) !*std.Build.Step.Compile {
    const mod = baseModule(b, cfg);

    mod.addIncludePath(srcPath(b, "ggml/include"));
    mod.addIncludePath(srcPath(b, "ggml/src"));
    mod.addIncludePath(srcPath(b, "ggml/src/ggml-cpu"));
    // ggml/src/CMakeLists.txt:216, configure_file(ggml-version.h.in).
    mod.addConfigHeader(b.addConfigHeader(.{
        .style = .{ .cmake = srcPath(b, "ggml/src/ggml-version.h.in") },
        .include_path = "ggml-version.h",
    }, .{ .GGML_VERSION = ggml_version, .GGML_BUILD_COMMIT = commit }));

    mod.addCSourceFiles(.{ .root = b.path(src_root), .files = &ggml_c_sources, .flags = cfg.c });
    mod.addCSourceFiles(.{ .root = b.path(src_root), .files = &ggml_cxx_sources, .flags = cfg.cxx });
    const arch = archSources(cfg.target.result.cpu.arch).?;
    mod.addCSourceFiles(.{ .root = b.path(src_root), .files = arch.c, .flags = cfg.c });
    mod.addCSourceFiles(.{ .root = b.path(src_root), .files = arch.cxx, .flags = cfg.cxx });

    if (cfg.platform.isApple()) {
        mod.addIncludePath(srcPath(b, "ggml/src/ggml-metal"));
        mod.addCSourceFiles(.{ .root = b.path(src_root), .files = &metal_cxx_sources, .flags = cfg.cxx });
        mod.addCSourceFiles(.{ .root = b.path(src_root), .files = &metal_objc_sources, .flags = cfg.objc });

        for (metal_kernels) |kind| mod.addAssemblyFile(embedMetalKernel(b, kind));

        mod.linkFramework("Foundation", .{});
        mod.linkFramework("Metal", .{});
        mod.linkFramework("MetalKit", .{});
        mod.linkFramework("Accelerate", .{});
    }

    if (cfg.vulkan) |vk| try addVulkan(b, cfg, vk, mod);

    return addLibrary(b, cfg, "ggml", mod);
}

/// Reads the `-Dvulkan` options and asks `glslc` which shader extensions it
/// accepts, at configure time, as `ggml-vulkan/CMakeLists.txt:34-57` does.
///
/// CMake's test is the one reproduced: an extension is supported unless
/// `glslc`'s diagnostics contain `extension not supported: <name>` -- any
/// other failure still counts as support. Locating `glslc` poisons Zig's
/// configuration cache, so every build re-asks, and a `glslc` that changes
/// between builds cannot leave stale answers.
///
/// Parameters:
/// - `b`: the build graph, for its options, allocator and process spawning.
/// - `platform`: decides the default header directory.
///
/// Return: null without `-Dvulkan`; otherwise the configuration, or an error
/// when `glslc` or the headers cannot be found or a probe cannot run.
fn configureVulkan(b: *std.Build, platform: Platform) !?Vulkan {
    const enabled = b.option(bool, "vulkan", "Build ggml's Vulkan backend (needs glslc, the Vulkan and SPIR-V headers, and libvulkan)") orelse false;
    const glslc_opt = b.option([]const u8, "glslc", "The glslc to compile the Vulkan shaders with (default: glslc on PATH)");
    const include_opt = b.option([]const []const u8, "vulkan-include", "Directories holding vulkan/ and spirv/, searched after libc's headers (default on Linux: /usr/include)");
    const lib_opt = b.option([]const []const u8, "vulkan-lib", "Extra directories to find libvulkan in");
    if (!enabled) return null;

    const glslc = glslc_opt orelse b.findProgram(.{ .names = &.{"glslc"} }) orelse {
        std.log.err("-Dvulkan needs glslc: put it on PATH or pass -Dglslc=<path>", .{});
        return error.GlslcNotFound;
    };
    const include_dirs: []const []const u8 = include_opt orelse if (platform == .linux)
        &.{"/usr/include"}
    else {
        std.log.err("-Dvulkan on {s} needs -Dvulkan-include=<dir holding vulkan/ and spirv/>", .{@tagName(platform)});
        return error.VulkanHeadersNotFound;
    };

    // The probes below count any output but a refusal as support, so a
    // `glslc` that cannot run at all would pass every one of them: make sure
    // it runs first.
    switch (b.runFallible(&.{ glslc, "--version" }, .{ .stderr_behavior = .ignore })) {
        .success => {},
        else => {
            std.log.err("-Dvulkan: {s} does not run", .{glslc});
            return error.GlslcNotFound;
        },
    }

    var features: std.ArrayList([]const u8) = .empty;
    for (vulkan_features) |f| {
        const rel = b.fmt("{s}/{s}/feature-tests/{s}", .{ src_root, vulkan_shaders_dir, f.test_shader });
        b.dependOnFileContents(b.path(rel));
        const test_shader = try b.root.joinString(b.allocator, rel);
        // glslc's diagnostics go to stderr and it exits non-zero on the
        // refusal, so the shell folds both into a successful stdout.
        const out = switch (b.runFallible(&.{
            "sh",                                                                                       "-c",
            "\"$0\" -o - -fshader-stage=compute --target-env=vulkan1.3 \"$1\" 2>&1 >/dev/null; exit 0", glslc,
            test_shader,
        }, .{ .stderr_behavior = .ignore })) {
            .success => |stdout| stdout,
            else => {
                std.log.err("could not run {s} on {s}", .{ glslc, test_shader });
                return error.GlslcProbeFailed;
            },
        };
        const refusal = b.fmt("extension not supported: {s}", .{f.extension});
        if (std.mem.indexOf(u8, out, refusal) == null) {
            try features.append(b.allocator, b.fmt("-D{s}", .{f.define}));
        }
    }

    return .{
        .glslc = glslc,
        .include_dirs = include_dirs,
        .lib_dirs = lib_opt orelse &.{},
        .features = features.items,
    };
}

/// Adds ggml's Vulkan backend to `mod`: the shader generator, the SPIR-V it
/// embeds, and `ggml-vulkan.cpp`. `addCli` links `libvulkan`.
///
/// Replaces CMake's `ExternalProject` and custom commands
/// (`ggml-vulkan/CMakeLists.txt:149-259`) with the same two passes of the
/// same tool. `vulkan-shaders-gen` is upstream's generator, built for the host
/// with the extension macros: run once with no source it writes
/// `ggml-vulkan-shaders.hpp`, declaring every variant; run once per `.comp`
/// with `--glslc` it compiles that file's variants and writes a `.cpp`
/// holding their SPIR-V. Each run is a separate, cached step, so the 147
/// shader files compile in parallel and only a changed one recompiles.
///
/// Every `.comp` and `.glsl` is an input of every run: a shader's includes
/// are resolved by `glslc`, which Zig cannot see.
///
/// Parameters:
/// - `b`: the build graph.
/// - `cfg`: the platform's flags.
/// - `vk`: what `configureVulkan` resolved.
/// - `mod`: ggml's module, which gains the backend's sources and link.
///
/// Return: nothing; propagates directory-read failures.
fn addVulkan(b: *std.Build, cfg: Config, vk: Vulkan, mod: *std.Build.Module) !void {
    const gen_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .fast,
        .link_libc = true,
        .link_libcpp = true,
        .sanitize_c = .off,
    });
    gen_mod.addCSourceFile(.{
        .file = srcPath(b, vulkan_shaders_dir ++ "/vulkan-shaders-gen.cpp"),
        .flags = try join(b, &cxx_std, vk.features),
    });
    const gen = b.addExecutable(.{ .name = "vulkan-shaders-gen", .root_module = gen_mod });

    var comp: std.ArrayList([]const u8) = .empty;
    try appendGlob(b, &comp, vulkan_shaders_dir, ".comp");
    var glsl: std.ArrayList([]const u8) = .empty;
    try appendGlob(b, &glsl, vulkan_shaders_dir, ".glsl");

    // Pass 1: the header, which names every variant.
    const hdr_run = b.addRunArtifact(gen);
    hdr_run.addArg("--output-dir");
    _ = hdr_run.addOutputDirectoryArg("spv");
    hdr_run.addArg("--target-hpp");
    const header = hdr_run.addOutputFileArg("ggml-vulkan-shaders.hpp");
    mod.addIncludePath(header.dirname());

    // `-idirafter`, not `-I`: the header directory is usually `/usr/include`,
    // which must not shadow the libc headers Zig supplies.
    var vk_flags: std.ArrayList([]const u8) = .empty;
    try vk_flags.appendSlice(b.allocator, cfg.cxx);
    try vk_flags.appendSlice(b.allocator, vk.features);
    for (vk.include_dirs) |dir| try vk_flags.appendSlice(b.allocator, &.{ "-idirafter", dir });

    // Pass 2: one run per shader file, each writing that file's SPIR-V.
    for (comp.items) |file| {
        const run = b.addRunArtifact(gen);
        run.addArgs(&.{ "--glslc", vk.glslc });
        run.addArg("--source");
        run.addFileArg(srcPath(b, file));
        run.addArg("--output-dir");
        _ = run.addOutputDirectoryArg("spv");
        // Only its basename is used, for the generated `#include`.
        run.addArgs(&.{ "--target-hpp", "ggml-vulkan-shaders.hpp" });
        run.addArg("--target-cpp");
        const cpp = run.addOutputFileArg(b.fmt("{s}.cpp", .{std.fs.path.basename(file)}));
        for (comp.items) |f| run.addFileInput(srcPath(b, f));
        for (glsl.items) |f| run.addFileInput(srcPath(b, f));
        mod.addCSourceFile(.{ .file = cpp, .flags = cfg.cxx });
    }

    mod.addCSourceFiles(.{
        .root = b.path(src_root),
        .files = &.{"ggml/src/ggml-vulkan/ggml-vulkan.cpp"},
        .flags = vk_flags.items,
    });
    // `libvulkan` is linked by the executable, in `addCli`, not here: Zig
    // resolves a system library even for a static archive, which links
    // nothing, and a machine that only builds the archive -- for a harness
    // that links it itself -- need not have the loader installed.
}

/// Flattens one Metal kernel and returns the assembly stub that embeds it.
///
/// Replaces the `cat`/`sed` pipeline CMake runs under
/// `GGML_METAL_EMBED_LIBRARY`. The stub `.incbin`s the flattened shader
/// *source* into a `__DATA,__ggml_metallib` section; the Metal driver compiles
/// it at load time, so no `xcrun metal` step is involved. That is also why
/// this works unchanged for iOS: nothing here is host-specific.
///
/// Never switch to the non-embedded path: that one does need `xcrun metal`,
/// which the Zig toolchain cannot replace.
fn embedMetalKernel(b: *std.Build, kind: []const u8) std.Build.LazyPath {
    const tool = b.addExecutable(.{
        .name = "metal_embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/metal_embed.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });

    const run = b.addRunArtifact(tool);
    run.addArg(kind);
    _ = run.addOutputFileArg(b.fmt("ggml-metal-embed-{s}.metal", .{kind}));
    const out_asm = run.addOutputFileArg(b.fmt("ggml-metal-embed-{s}.s", .{kind}));

    run.addFileArg(srcPath(b, "ggml/src/ggml-common.h"));
    run.addFileArg(srcPath(b, "ggml/src/ggml-metal/ggml-metal-impl.h"));
    run.addFileArg(srcPath(b, "ggml/src/ggml-metal/kernels/common.h"));
    run.addFileArg(srcPath(b, "ggml/src/ggml-metal/kernels/dequantize.h"));
    run.addFileArg(srcPath(b, "ggml/src/ggml-metal/kernels/quantize.h"));
    run.addFileArg(srcPath(b, b.fmt("ggml/src/ggml-metal/kernels/{s}.metal", .{kind})));

    return out_asm;
}

/// Builds libllama, including every architecture under `src/models/`.
///
/// The architectures are read from the directory rather than listed, as
/// CMake's `file(GLOB)` does, so adding one needs no build change.
fn addLlama(b: *std.Build, cfg: Config, ggml: *std.Build.Step.Compile) !*std.Build.Step.Compile {
    const mod = baseModule(b, cfg);
    addCommonIncludes(b, mod);
    // Private to this target; see addCommonIncludes.
    mod.addIncludePath(srcPath(b, "src"));
    // src/CMakeLists.txt:55, configure_file(llama-version.h.in).
    mod.addConfigHeader(b.addConfigHeader(.{
        .style = .{ .cmake = srcPath(b, "src/llama-version.h.in") },
        .include_path = "llama-version.h",
    }, .{ .LLAMA_VERSION = version, .LLAMA_BUILD_COMMIT = commit }));

    var files: std.ArrayList([]const u8) = .empty;
    try files.appendSlice(b.allocator, &llama_sources);
    try appendGlob(b, &files, "src/models", ".cpp");

    mod.addCSourceFiles(.{
        .root = b.path(src_root),
        .files = files.items,
        .flags = cfg.cxx,
    });
    mod.linkLibrary(ggml);

    return addLibrary(b, cfg, "llama", mod);
}

/// Builds `llama-cli` and everything it links.
///
/// The dependency chain, from CMake: llama-cli -> llama-cli-impl ->
/// llama-server-impl -> {server-context, llama-ui, cpp-httplib} ->
/// {llama-common, mtmd} -> {llama, ggml, vendor}. The CLI pulls in the whole
/// server because `cli-context.cpp` drives it in-process.
fn addCli(
    b: *std.Build,
    cfg: Config,
    ggml: *std.Build.Step.Compile,
    llama: *std.Build.Step.Compile,
) !*std.Build.Step.Compile {
    // vendor::hash, needed by mtmd.
    const hash = blk: {
        const mod = baseModule(b, cfg);
        mod.addIncludePath(srcPath(b, "vendor"));
        mod.addIncludePath(srcPath(b, "vendor/hash"));
        mod.addCSourceFiles(.{
            .root = b.path(src_root),
            .files = &[_][]const u8{"vendor/hash/hash.cpp"},
            .flags = cfg.cxx_std,
        });
        // sha1.c is C++ despite the extension. CMake sets LANGUAGE CXX on it
        // (vendor/hash/CMakeLists.txt:32) because the file wraps itself in a
        // namespace to avoid clashing with boringssl's symbols.
        mod.addCSourceFiles(.{
            .root = b.path(src_root),
            .files = &[_][]const u8{"vendor/hash/sha1/sha1.c"},
            .flags = cfg.cxx_std,
            .language = .cpp,
        });
        mod.addCSourceFiles(.{
            .root = b.path(src_root),
            .files = &[_][]const u8{
                "vendor/hash/xxhash/xxhash.c",
                "vendor/hash/sha256/sha256.c",
            },
            .flags = cfg.c_std,
        });
        break :blk addLibrary(b, cfg, "vendor-hash", mod);
    };

    // cpp-httplib, needed by the server and by common's downloader.
    const httplib = blk: {
        const mod = baseModule(b, cfg);
        mod.addIncludePath(srcPath(b, "vendor"));
        mod.addIncludePath(srcPath(b, "vendor/cpp-httplib"));
        mod.addCSourceFiles(.{
            .root = b.path(src_root),
            .files = &[_][]const u8{"vendor/cpp-httplib/httplib.cpp"},
            .flags = try join(b, cfg.cxx_std, &httplib_defines),
        });
        // vendor/cpp-httplib/CMakeLists.txt:23, `WIN32 AND NOT MSVC`.
        if (cfg.platform == .windows) mod.linkSystemLibrary("ws2_32", .{});
        break :blk addLibrary(b, cfg, "cpp-httplib", mod);
    };

    // llama-common-base: just build-info.cpp, configured from upstream's
    // build-info.cpp.in as common/CMakeLists.txt does. The resolved target is
    // only known at configure time, so the triple is formatted.
    const build_info = b.addConfigHeader(.{
        .style = .{ .cmake = srcPath(b, "common/build-info.cpp.in") },
        .include_path = "build-info.cpp",
    }, .{
        .LLAMA_BUILD_NUMBER = build_number,
        .LLAMA_BUILD_COMMIT = commit,
        .BUILD_COMPILER = b.fmt("Zig {s} clang", .{builtin.zig_version_string}),
        .BUILD_TARGET = b.fmt("{s}-{s}", .{
            @tagName(cfg.target.result.cpu.arch),
            @tagName(cfg.target.result.os.tag),
        }),
    }).getOutputFile();

    const common_base = blk: {
        const mod = baseModule(b, cfg);
        addCommonIncludes(b, mod);
        mod.addCSourceFile(.{ .file = build_info, .flags = cfg.cxx });
        break :blk addLibrary(b, cfg, "llama-common-base", mod);
    };

    // mtmd: multimodal support. The CLI links it through server-context.
    const mtmd = blk: {
        const mod = baseModule(b, cfg);
        addCommonIncludes(b, mod);
        mod.addIncludePath(srcPath(b, "tools/mtmd"));
        mod.addIncludePath(srcPath(b, "vendor/hash"));

        var files: std.ArrayList([]const u8) = .empty;
        try files.appendSlice(b.allocator, &mtmd_sources);
        try appendGlob(b, &files, "tools/mtmd/models", ".cpp");

        mod.addCSourceFiles(.{ .root = b.path(src_root), .files = files.items, .flags = cfg.cxx });
        mod.linkLibrary(llama);
        mod.linkLibrary(ggml);
        mod.linkLibrary(hash);
        break :blk addLibrary(b, cfg, "mtmd", mod);
    };

    const common = blk: {
        const mod = baseModule(b, cfg);
        addCommonIncludes(b, mod);
        mod.addIncludePath(srcPath(b, "tools/mtmd"));
        mod.addCSourceFiles(.{ .root = b.path(src_root), .files = &common_sources, .flags = cfg.cxx });
        mod.linkLibrary(common_base);
        mod.linkLibrary(httplib);
        mod.linkLibrary(llama);
        mod.linkLibrary(ggml);
        break :blk addLibrary(b, cfg, "llama-common", mod);
    };

    // The web UI, stubbed. See zig/ui-stub/ui.h.
    const ui = blk: {
        const mod = baseModule(b, cfg);
        mod.addIncludePath(b.path("zig/ui-stub"));
        mod.addCSourceFiles(.{
            .files = &[_][]const u8{"zig/ui-stub/ui.cpp"},
            .flags = cfg.cxx_std,
        });
        break :blk addLibrary(b, cfg, "llama-ui", mod);
    };

    const server_context = blk: {
        const mod = baseModule(b, cfg);
        addCommonIncludes(b, mod);
        mod.addIncludePath(srcPath(b, "tools/mtmd"));
        mod.addIncludePath(srcPath(b, "tools/server"));
        mod.addCSourceFiles(.{ .root = b.path(src_root), .files = &server_context_sources, .flags = cfg.cxx });
        mod.linkLibrary(common);
        mod.linkLibrary(mtmd);
        break :blk addLibrary(b, cfg, "server-context", mod);
    };

    const server_impl = blk: {
        const mod = baseModule(b, cfg);
        addCommonIncludes(b, mod);
        mod.addIncludePath(srcPath(b, "tools/mtmd"));
        mod.addIncludePath(srcPath(b, "tools/server"));
        mod.addIncludePath(b.path("zig/ui-stub"));
        mod.addCSourceFiles(.{ .root = b.path(src_root), .files = &server_impl_sources, .flags = cfg.cxx });
        mod.linkLibrary(server_context);
        mod.linkLibrary(ui);
        mod.linkLibrary(httplib);
        break :blk addLibrary(b, cfg, "llama-server-impl", mod);
    };

    const cli_impl = blk: {
        const mod = baseModule(b, cfg);
        addCommonIncludes(b, mod);
        mod.addIncludePath(srcPath(b, "tools/cli"));
        mod.addIncludePath(srcPath(b, "tools/server"));
        mod.addIncludePath(srcPath(b, "tools/mtmd"));
        mod.addCSourceFiles(.{ .root = b.path(src_root), .files = &cli_impl_sources, .flags = cfg.cxx });
        mod.linkLibrary(server_impl);
        break :blk addLibrary(b, cfg, "llama-cli-impl", mod);
    };

    const mod = baseModule(b, cfg);
    addCommonIncludes(b, mod);
    mod.addIncludePath(srcPath(b, "tools/cli"));
    mod.addCSourceFiles(.{
        .root = b.path(src_root),
        .files = &[_][]const u8{"tools/cli/main.cpp"},
        .flags = cfg.cxx,
    });
    mod.linkLibrary(cli_impl);
    if (cfg.vulkan) |vk| {
        for (vk.lib_dirs) |dir| mod.addLibraryPath(b.graph.cwdRelativePath(dir));
        mod.linkSystemLibrary("vulkan", .{});
    }

    return addExecutable(b, cfg, "llama-cli", mod);
}

/// Appends every file in `dir` with the given extension, as CMake's
/// `file(GLOB)` does.
///
/// Parameters:
/// - `b`: the build graph, for its allocator and IO.
/// - `files`: list to append repo-relative paths to.
/// - `dir`: directory to read, relative to the build root.
/// - `ext`: extension to match, including the dot.
///
/// Return: nothing; propagates directory-read and allocation failures.
fn appendGlob(b: *std.Build, files: *std.ArrayList([]const u8), dir: []const u8, ext: []const u8) !void {
    // `dir` is relative to the checkout, and so are the paths appended, since
    // the source lists are resolved against `src_root`.
    const full = b.fmt("{s}/{s}", .{ src_root, dir });
    // Zig 0.17 reuses a configured build graph until one of its declared
    // inputs changes, and a directory listing is not one by default. A file
    // added to or removed from the checkout must reconfigure.
    b.dependOnDirectoryContents(b.path(full));
    var handle = try b.root.openDir(b.graph.io, full, .{ .iterate = true });
    defer handle.close(b.graph.io);

    var it = handle.iterate();
    while (try it.next(b.graph.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ext)) continue;
        try files.append(b.allocator, b.fmt("{s}/{s}", .{ dir, entry.name }));
    }
}
