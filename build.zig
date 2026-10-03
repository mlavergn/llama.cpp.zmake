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

/// Version reported by `ggml_version` and `llama_build_info`, matching what
/// CMake derives from git.
const version = "0.3.0";
const commit = "c1d0e7a00";
const build_number = 10621;

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
            else => null,
        };
    }

    /// Whether the Metal backend and the Accelerate framework are available.
    ///
    /// The two travel together: both come from the Apple SDK, and CMake
    /// defaults `GGML_METAL` and the Accelerate lookup off the same `APPLE`
    /// check (`ggml/CMakeLists.txt:96`, `ggml-cpu/CMakeLists.txt:60`).
    fn isApple(self: Platform) bool {
        return self != .linux;
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
// ARC stays off: the Metal sources use manual reference counting and bridge
// freely between void* and Objective-C object pointers.
const objc_std = [_][]const u8{"-std=c11"} ++ quiet;

// -----------------------------------------------------------------------------
// Apple's libc++ instead of Zig's
//
// **Zig 0.16.0 cannot build its own libc++ against the 27.x SDKs**, macOS and
// iOS alike. It compiles `libcxx/src/random.cpp` with a hardcoded
// `-std=c++23`, which turns clang's `modules` feature on; the SDK's `<math.h>`
// then declines to define `INFINITY` (C23 moved it to `<float.h>`), and
// libc++'s own `__random/clamp_to_integral.h:47` uses it without including
// that. The symptom is `error: sub-compilation of libcxx failed` on the first
// link. The full diagnosis, with a reproducer, is in the sibling llamazig
// repository's `testcase/`, which hit it first.
//
// No flag, environment variable, or libc file reaches that `-std`, so on the
// Apple platforms this build links **Apple's** libc++ instead -- the SDK's
// headers and its `.tbd`s together, a matched pair. It is also the C++ runtime
// the CMake reference build links, so this moves the build closer to it, not
// further away. Linux is unaffected and keeps Zig's libc++.
//
// Two details that are easy to get wrong, both measured in llamazig:
//
// - The headers go in with `-I`, not `-isystem`. `-isystem` puts them after
//   clang's own include paths, and `<cstdio>` then fails with "tried including
//   <stdio.h> but didn't find libc++'s <stdio.h> header".
// - `link_libcpp = false` also switches the C++ header search off, which is
//   why the include path is added by hand rather than merely dropped.
//
// **Revert when the toolchain is fixed** -- llamazig's `make -C testcase
// cxx20` passing is the signal. Drop `appleCxxStd` and `linkAppleLibcxx`, and
// set `link_libcpp = true` unconditionally in `baseModule`.

/// The C++ standard flags, plus Apple's libc++ headers on Apple platforms.
///
/// Parameters:
/// - `b`: the build graph, for the allocator.
/// - `sdk`: the Apple SDK root; null on Linux, where Zig's libc++ is used.
///
/// Return: a flag list owned by the build graph.
fn appleCxxStd(b: *std.Build, sdk: ?[]const u8) ![]const []const u8 {
    const path = sdk orelse return &cxx_std;
    return join(b, &cxx_std, &.{
        "-nostdinc++",
        b.fmt("-I{s}/usr/include/c++/v1", .{path}),
    });
}

/// Links Apple's libc++ into an executable, standing in for `link_libcpp`.
///
/// Only executables need it: a static archive never links. `libc++abi` is
/// named as well because the `__cxa_*` guard, exception and personality
/// symbols live there, and `libc++.tbd` does not re-export them.
///
/// Parameters:
/// - `b`: the build graph, for the allocator.
/// - `mod`: the executable's root module.
/// - `sdk`: the Apple SDK root; null on Linux, where this is a no-op.
///
/// Return: nothing.
fn linkAppleLibcxx(b: *std.Build, mod: *std.Build.Module, sdk: ?[]const u8) void {
    const path = sdk orelse return;
    mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/usr/lib/libc++.tbd", .{path}) });
    mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/usr/lib/libc++abi.tbd", .{path}) });
}

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
    "-DGGML_VERSION=\"" ++ version ++ "\"",
    "-DGGML_COMMIT=\"" ++ commit ++ "\"",
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
/// on everywhere except Windows and the mobile/WASM targets, where spawning a
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

/// Scoped to the `llama` target only, as CMake does with
/// `target_compile_definitions(llama PRIVATE ...)`. They must not be global:
/// `build-info.cpp` declares variables with these exact names, and a macro of
/// the same name breaks it.
const llama_defines = [_][]const u8{
    "-DLLAMA_VERSION=\"" ++ version ++ "\"",
    "-DLLAMA_COMMIT=\"" ++ commit ++ "\"",
};

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
    "ggml/src/ggml-cpu/arch/arm/quants.c",
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
    "ggml/src/ggml-cpu/arch/arm/repack.cpp",
};

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
    "src/llama-memory-hybrid-iswa.cpp", "src/llama-memory-recurrent.cpp",
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
    optimize: std.builtin.OptimizeMode,
    platform: Platform,

    /// Apple SDK path. Null on Linux.
    sdk: ?[]const u8,

    /// A generated `zig libc` file pointing at the SDK's headers. Null on
    /// Linux, where Zig ships glibc and needs no help.
    ///
    /// Both Apple platforms need one, because both are named by an explicit
    /// `-Dtarget`. Zig only sets up the SDK include chain for a *native*
    /// target; name any triple and it treats the build as cross-compilation,
    /// after which its clang finds no `stdio.h` and its libc++ build dies on
    /// `mbstate_t`. Passing `-idirafter` on our own sources is not enough --
    /// Zig builds libc++ itself, and that internal build sees none of our
    /// flags. A libc file is the one knob that reaches it.
    libc_file: ?std.Build.LazyPath,

    /// The bare C++ flags, without the platform's defines: `cxx_std` plus,
    /// on Apple platforms, the path to the SDK's libc++ headers. For the
    /// vendored libraries CMake compiles without ggml's defines.
    cxx_std: []const []const u8,

    /// Compiler flags per language, with the platform's defines already
    /// folded in.
    c: []const []const u8,
    cxx: []const []const u8,
    objc: []const []const u8,
};

/// Declares the build graph.
///
/// Parameters:
/// - `b`: the build graph the steps are registered on.
///
/// Return: nothing on success; propagates target, SDK resolution, and
/// directory-read failures.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform = Platform.detect(target.result) orelse {
        std.log.err(
            "no configuration for OS '{s}'; this build knows macos, ios, and linux",
            .{@tagName(target.result.os.tag)},
        );
        return error.UnsupportedTarget;
    };
    // The only ggml arch sources listed are `arch/arm`. Anything else would
    // link a libggml with no quant kernels rather than fail outright, so it is
    // caught here instead.
    if (target.result.cpu.arch != .aarch64) {
        std.log.err(
            "no configuration for arch '{s}'; the ggml source list is arm64 only",
            .{@tagName(target.result.cpu.arch)},
        );
        return error.UnsupportedTarget;
    }

    const sdk = if (platform.isApple()) try resolveAppleSdk(b, target.result) else null;

    var defs: std.ArrayList([]const u8) = .empty;
    try defs.appendSlice(b.allocator, &base_defines);
    if (platform.isApple()) try defs.appendSlice(b.allocator, &apple_defines);
    if (platform != .ios) try defs.appendSlice(b.allocator, &subprocess_defines);
    if (platform == .linux) try defs.appendSlice(b.allocator, &linux_defines);

    const cxx = try appleCxxStd(b, sdk);
    const cfg = Config{
        .target = target,
        .optimize = optimize,
        .platform = platform,
        .sdk = sdk,
        .libc_file = if (sdk) |s| writeAppleLibcFile(b, s) else null,
        .cxx_std = cxx,
        .c = try join(b, &c_std, defs.items),
        .cxx = try join(b, cxx, defs.items),
        .objc = try join(b, &objc_std, defs.items),
    };

    const ggml = addGgml(b, cfg);
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
    if (b.args) |args| run.addArgs(args);
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
/// The remaining keys are required by the file format and empty by design:
/// Darwin needs no crt files (libSystem provides the entry stubs), and the
/// MSVC and gcc keys are for other platforms entirely.
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
        \\crt_dir=
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ sdk, sdk }));
}

/// Applies the settings every C/C++ target in this build shares.
fn baseModule(b: *std.Build, cfg: Config) *std.Build.Module {
    const mod = b.createModule(.{
        .target = cfg.target,
        .optimize = cfg.optimize,
        .link_libc = true,
        // Apple platforms link the SDK's libc++ instead; see `appleCxxStd`.
        .link_libcpp = cfg.sdk == null,
        // These sources are not UBSan-clean -- they rely on pointer arithmetic
        // that is technically undefined but universally works -- and Zig turns
        // the C sanitizers on in Debug. CMake never enabled them.
        .sanitize_c = .off,
    });
    if (cfg.sdk) |sdk| {
        mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        // Only iOS needs the library path spelled out; for macOS Zig already
        // searches the SDK, and this is the same directory it would find.
        mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
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
/// one, and Apple's libc++. See `addLibrary` and `linkAppleLibcxx`.
fn addExecutable(b: *std.Build, cfg: Config, name: []const u8, mod: *std.Build.Module) *std.Build.Step.Compile {
    linkAppleLibcxx(b, mod, cfg.sdk);
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

/// Builds ggml with its CPU backend -- and, on Apple platforms, its Metal
/// backend -- as one static archive.
///
/// CMake splits the backends so they can be loaded dynamically. With static
/// linking and `GGML_BACKEND_DL` off that split carries no meaning:
/// `ggml-backend-reg.cpp` calls each backend's registration function directly
/// under an `#ifdef`, so one archive links identically.
fn addGgml(b: *std.Build, cfg: Config) *std.Build.Step.Compile {
    const mod = baseModule(b, cfg);

    mod.addIncludePath(srcPath(b, "ggml/include"));
    mod.addIncludePath(srcPath(b, "ggml/src"));
    mod.addIncludePath(srcPath(b, "ggml/src/ggml-cpu"));

    mod.addCSourceFiles(.{ .root = b.path(src_root), .files = &ggml_c_sources, .flags = cfg.c });
    mod.addCSourceFiles(.{ .root = b.path(src_root), .files = &ggml_cxx_sources, .flags = cfg.cxx });

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

    return addLibrary(b, cfg, "ggml", mod);
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
            .optimize = .Debug,
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

    var files: std.ArrayList([]const u8) = .empty;
    try files.appendSlice(b.allocator, &llama_sources);
    try appendGlob(b, &files, "src/models", ".cpp");

    mod.addCSourceFiles(.{
        .root = b.path(src_root),
        .files = files.items,
        .flags = try join(b, cfg.cxx, &llama_defines),
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
            .flags = &c_std,
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
        break :blk addLibrary(b, cfg, "cpp-httplib", mod);
    };

    // llama-common-base: just the generated build-info.cpp. CMake produces it
    // with configure_file from build-info.cpp.in; this writes it directly.
    const build_info = b.addWriteFiles().add("build-info.cpp", b.fmt(
        \\#include "build-info.h"
        \\
        \\#include <cstdio>
        \\#include <string>
        \\
        \\int LLAMA_BUILD_NUMBER = {d};
        \\char const * LLAMA_COMMIT = "{s}";
        \\char const * LLAMA_COMPILER = "Zig {s} clang";
        \\char const * LLAMA_BUILD_TARGET = "{s}";
        \\
        \\int llama_build_number(void) {{ return LLAMA_BUILD_NUMBER; }}
        \\const char * llama_commit(void) {{ return LLAMA_COMMIT; }}
        \\const char * llama_compiler(void) {{ return LLAMA_COMPILER; }}
        \\const char * llama_build_target(void) {{ return LLAMA_BUILD_TARGET; }}
        \\
        \\const char * llama_build_info(void) {{
        \\    static std::string s = "b" + std::to_string(LLAMA_BUILD_NUMBER) + "-" + LLAMA_COMMIT;
        \\    return s.c_str();
        \\}}
        \\
        \\void llama_print_build_info(const char * llama_version) {{
        \\    fprintf(stderr, "version: %s (build %d, commit %s)\n", llama_version, llama_build_number(), llama_commit());
        \\    fprintf(stderr, "built with %s for %s\n", LLAMA_COMPILER, LLAMA_BUILD_TARGET);
        \\}}
        \\
    , .{
        build_number,
        commit,
        builtin.zig_version_string,
        // The resolved target is only known at configure time, so the triple
        // is formatted rather than concatenated at comptime.
        b.fmt("{s}-{s}", .{
            @tagName(cfg.target.result.cpu.arch),
            @tagName(cfg.target.result.os.tag),
        }),
    }));

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
    var handle = try b.build_root.handle.openDir(b.graph.io, full, .{ .iterate = true });
    defer handle.close(b.graph.io);

    var it = handle.iterate();
    while (try it.next(b.graph.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ext)) continue;
        try files.append(b.allocator, b.fmt("{s}/{s}", .{ dir, entry.name }));
    }
}
