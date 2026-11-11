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
//! implementation that the CLI links against, and `llama-server` over it
//! (`zig build server`). The SvelteKit web UI is embedded under `-Dui=<dist>`
//! (`make ui` builds it with npm; `zig/ui_embed.zig` embeds it); without it,
//! `zig/ui-stub` supplies an empty table. Not built: the other ~90 CMake
//! binaries (tests, benchmarks, the other tools).
//!
//! `zig build xcframework -Dblas` builds one slice of the libraries upstream's
//! `build-xcframework.sh` packs into `llama.xcframework` -- ggml with the BLAS
//! backend, libllama, mtmd and vendor-hash -- for the Apple `-Dtarget` given.
//! The Makefile's `xcframework` target runs it per slice and does the rest.
//!
//! # Configuration
//!
//! Selected by `-Dtarget` and distinguished by `Platform`. Everything else
//! matches the `-D` flags CMake was being driven with: static libraries, BLAS
//! off unless `-Dblas`, OpenMP off, no curl.
//!
//!   macOS  Metal on, shader library embedded, Accelerate on, subprocess on
//!   iOS    the same, minus subprocess -- CMake turns it off on mobile
//!   Linux  CPU backend only, no Metal, no Accelerate, `_GNU_SOURCE` on
//!
//! The Makefile drives all three; it owns the deployment targets and the one
//! `-Dcpu` pin, none of which this file needs to know about.
//!
//! tvOS and visionOS configure as iOS does, but keep subprocess on, as CMake
//! does; they and the Apple simulators, and macOS on x86_64, exist for the
//! xcframework slices.
//!
//! `-Dvulkan` adds ggml's Vulkan backend on any of them. It needs three things
//! from outside the Zig toolchain, as CMake's build does: `glslc` to compile
//! the shaders (`-Dglslc`, else the one on PATH), the Vulkan and SPIR-V
//! headers (`-Dvulkan-include`, default `/usr/include` on Linux), and
//! `libvulkan` to link (`-Dvulkan-lib` for a directory Zig does not search).
//! Which shader extensions that `glslc` accepts decides which C++ compiles, so
//! the same `glslc` and headers must build both sides of any comparison.
//!
//! `-Dcuda` adds ggml's CUDA backend, on Linux for the host's own
//! architecture. Its `.cu` files are compiled by the toolkit's `nvcc` with
//! nvcc's default host compiler (g++), exactly as CMake's `enable_language(CUDA)`
//! compiles them; everything else stays on Zig's clang. `-Dcuda-path` names the
//! toolkit (default `$CUDA_PATH`, else `/usr/local/cuda`), `-Dcuda-arch` the
//! GPU architectures in CMake's `CMAKE_CUDA_ARCHITECTURES` spelling.
//!
//! # Steps
//!
//!   zig build            everything below
//!   zig build cli        llama-cli
//!   zig build lib        ggml + libllama only
//!   zig build server     llama-server; -Dui=.ui/dist embeds the web UI
//!   zig build xcframework one xcframework slice's libraries; needs -Dblas
//!   zig build run -- ... build and run llama-cli

const std = @import("std");
const log = std.log.scoped(.llamacpp_build);
const builtin = @import("builtin");

/// The name of the llama.cpp sources in `build.zig.zon`.
///
/// The build system sits outside the sources rather than inside them: this
/// directory is its own repository, and the sources are a package Zig fetches
/// from upstream's release tarball, pinned by content hash. Upstream ships no
/// `build.zig`, so the package contributes files only; every path into it goes
/// through `Config.src`. Nothing in it is modified, so re-pinning is a new URL
/// and hash in `build.zig.zon` with nothing here to reconcile.
const src_dep = "llama_cpp";

/// What CMake configures `ggml-version.h`, `llama-version.h` and
/// `build-info.cpp` with at the pinned release tag.
///
/// `version` is `LLAMA_VERSION` with `LLAMA_BUILD_IS_DEV` off, as for a
/// release tag (CMakeLists.txt:6-21); `ggml_version` is ggml's own
/// (ggml/CMakeLists.txt:6-31), which is not llama.cpp's. `commit` is
/// `git rev-parse --short HEAD` and `build_number` the build tag's number
/// (`git describe --tags --match 'b*'`), as cmake/build-info.cmake derives
/// them.
const version = "0.9.0";
const ggml_version = "0.29.0";
const commit = "cd959bae9";
const build_number = 12110;

/// The platforms this build knows how to configure.
///
/// CMake branches on `APPLE`, `CMAKE_SYSTEM_NAME`, and the `GGML_*` options
/// its caller passes. Those branches collapse to this enum, because the option
/// set is fixed: which backends exist, which sources compile, and which
/// feature-test macros are defined all follow from the target OS.
const Platform = enum {
    const Self = @This();
    macos,
    ios,
    tvos,
    visionos,
    linux,
    windows,

    /// Map a resolved target onto a configuration this build supports.
    ///
    /// - `target`: The target `-Dtarget` resolved to.
    /// - Returns: The platform, or null if this build has no configuration for
    ///   that OS; the caller reports it.
    fn detect(target: std.Target) ?Self {
        return switch (target.os.tag) {
            .macos => .macos,
            .ios => .ios,
            .tvos => .tvos,
            .visionos => .visionos,
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
    /// `APPLE` is true for tvOS and visionOS too, and upstream's
    /// `build-xcframework.sh` builds Metal for both.
    ///
    /// - Returns: True on macOS, iOS, tvOS and visionOS.
    fn isApple(self: *const Self) bool {
        return switch (self.*) {
            .macos, .ios, .tvos, .visionos => true,
            .linux, .windows => false,
        };
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
/// subprocess is not sandbox-friendly (`CMakeLists.txt:104-110`). "Mobile"
/// there is `CMAKE_SYSTEM_NAME` iOS and Android only: tvOS and visionOS keep
/// it, and so do they here. Nothing in ggml, libllama or mtmd reads it.
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
    "ggml/src/ggml-cpu/hbm.cpp",
    "ggml/src/ggml-cpu/traits.cpp",
    "ggml/src/ggml-cpu/binary-ops.cpp",
    "ggml/src/ggml-cpu/unary-ops.cpp",
    "ggml/src/ggml-cpu/vec.cpp",
    "ggml/src/ggml-cpu/ops.cpp",
    // amx compiles to nothing on ARM but CMake lists it unconditionally.
    "ggml/src/ggml-cpu/amx/amx.cpp",
    "ggml/src/ggml-cpu/amx/mmq.cpp",
    "ggml/src/ggml-cpu/tiled/tiled.cpp",
    "ggml/src/ggml-cpu/tiled/tiled-kernel.cpp",
    "ggml/src/ggml-cpu/llamafile/sgemm.cpp",
};

/// The CPU backend's per-architecture sources, one pair per
/// `GGML_SYSTEM_ARCH` (ggml/src/ggml-cpu/CMakeLists.txt:79, 240). On x86
/// CMake adds `arch/x86/cpu-feats.cpp` only for `GGML_BACKEND_DL`, which is
/// off here, and the `GGML_AVX*` definitions it pairs with the `-m` flags are
/// read by that file alone; the kernels test the compiler's own `__AVX2__`
/// and friends, which `-Dcpu` sets.
const ArchSources = struct {
    const Self = @This();
    c: []const []const u8,
    cxx: []const []const u8,

    /// The arch sources for `arch`.
    ///
    /// - `arch`: The target's CPU architecture.
    /// - Returns: Its sources, or null for one this build has no list for.
    fn forArch(arch: std.Target.Cpu.Arch) ?Self {
        return switch (arch) {
            .aarch64 => ggml_arm_sources,
            .x86_64 => ggml_x86_sources,
            else => null,
        };
    }
};

const ggml_arm_sources: ArchSources = .{
    .c = &.{"ggml/src/ggml-cpu/arch/arm/quants.c"},
    .cxx = &.{"ggml/src/ggml-cpu/arch/arm/repack.cpp"},
};

const ggml_x86_sources: ArchSources = .{
    .c = &.{"ggml/src/ggml-cpu/arch/x86/quants.c"},
    .cxx = &.{"ggml/src/ggml-cpu/arch/x86/repack.cpp"},
};

/// ggml's BLAS backend with Accelerate as its vendor, the one upstream's
/// Apple builds default to (`ggml/CMakeLists.txt:96-98`). `GGML_USE_BLAS`
/// is ggml_add_backend's PUBLIC definition (`ggml/src/CMakeLists.txt:435`),
/// so it joins the global defines; `GGML_BLAS_USE_ACCELERATE` is
/// `add_compile_definitions` in `ggml-blas/CMakeLists.txt:19-22`, a
/// directory-scoped one, so it reaches this file alone. The two LAPACK
/// macros beside it are already among `apple_defines`.
const blas_sources = [_][]const u8{"ggml/src/ggml-blas/ggml-blas.cpp"};
const blas_defines = [_][]const u8{"-DGGML_BLAS_USE_ACCELERATE"};

/// The Metal backend's C++ layer. Apple platforms only.
const metal_cxx_sources = [_][]const u8{
    "ggml/src/ggml-metal/ggml-metal.cpp",
    "ggml/src/ggml-metal/ggml-metal-device.cpp",
    "ggml/src/ggml-metal/ggml-metal-common.cpp",
    "ggml/src/ggml-metal/ggml-metal-fusion.cpp",
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
    "fa_aux",          "fa_f16",      "fa_f32",      "fa_q4_0",
    "fa_q4_1",         "fa_q5_0",     "fa_q5_1",     "fa_q8_0",
    "fa_tensor",       "fa_vec_f16",  "fa_vec_f32",  "fa_vec_q4_0",
    "fa_vec_q4_1",     "fa_vec_q5_0", "fa_vec_q5_1", "fa_vec_q8_0",
    "mul_mv",          "mul_mv_mma",  "mul_mm",      "quantize",
    "softmax",         "norm",        "unary",       "binbcast",
    "reduce",          "tri",         "ssm",         "wkv",
    "gated_delta_net", "solve_tri",   "rope",        "conv",
    "upscale",         "argsort",     "pool",        "misc",
};

const llama_sources = [_][]const u8{
    "src/llama.cpp",                   "src/llama-adapter.cpp",
    "src/llama-arch.cpp",              "src/llama-batch.cpp",
    "src/llama-chat.cpp",              "src/llama-context.cpp",
    "src/llama-cparams.cpp",           "src/llama-grammar.cpp",
    "src/llama-graph.cpp",             "src/llama-hparams.cpp",
    "src/llama-impl.cpp",              "src/llama-io.cpp",
    "src/llama-kv-cache.cpp",          "src/llama-kv-cache-iswa.cpp",
    "src/llama-kv-cache-dsa.cpp",      "src/llama-kv-cache-dsa-iswa.cpp",
    "src/llama-kv-cache-msa.cpp",      "src/llama-kv-cache-dsv4.cpp",
    "src/llama-memory.cpp",            "src/llama-moe-cache.cpp",
    "src/llama-memory-hybrid.cpp",     "src/llama-memory-hybrid-iswa.cpp",
    "src/llama-memory-hybrid-idx.cpp", "src/llama-memory-recurrent.cpp",
    "src/llama-mmap.cpp",              "src/llama-model-loader.cpp",
    "src/llama-model-saver.cpp",       "src/llama-model.cpp",
    "src/llama-quant.cpp",             "src/llama-sampler.cpp",
    "src/llama-vocab.cpp",             "src/unicode-data.cpp",
    "src/unicode.cpp",
};

const common_sources = [_][]const u8{
    "common/arg.cpp",                      "common/chat-auto-parser-generator.cpp",
    "common/chat-auto-parser-helpers.cpp", "common/chat-diff-analyzer.cpp",
    "common/chat-peg-parser.cpp",          "common/chat.cpp",
    "common/common.cpp",                   "common/console.cpp",
    "common/debug.cpp",                    "common/download.cpp",
    "common/fit.cpp",                      "common/file-lock.cpp",
    "common/hf-cache.cpp",                 "common/imatrix-loader.cpp",
    "common/json-schema-to-grammar.cpp",   "common/json-schema.cpp",
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
    // common/parsers/sources.cmake's LLAMA_CHAT_PARSERS_SOURCES
    "common/parsers/parsers.cpp",          "common/parsers/cohere2moe.cpp",
    "common/parsers/deepseek.cpp",         "common/parsers/functionary-v3-2.cpp",
    "common/parsers/gemma4.cpp",           "common/parsers/gigachat-v3.cpp",
    "common/parsers/gpt-oss.cpp",          "common/parsers/harmony-xml.cpp",
    "common/parsers/k2-horizon.cpp",       "common/parsers/kimi-k2.cpp",
    "common/parsers/kimi-k3.cpp",          "common/parsers/ling3.cpp",
    "common/parsers/lfm2.cpp",             "common/parsers/llm-jp-harmony.cpp",
    "common/parsers/minicpm5.cpp",         "common/parsers/minimax-m3.cpp",
    "common/parsers/ministral3.cpp",       "common/parsers/muse-glimmer.cpp",
    "common/parsers/muse-spark.cpp",       "common/parsers/qwen3-coder.cpp",
    "common/parsers/translate-gemma.cpp",
};

/// `MTMD_VIDEO`, private to mtmd (`tools/mtmd/CMakeLists.txt:100`).
const mtmd_video_defines = [_][]const u8{"-DMTMD_VIDEO"};

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
    "tools/server/server-chat.cpp",     "tools/server/server-task.cpp",
    "tools/server/server-queue.cpp",    "tools/server/server-common.cpp",
    "tools/server/server-context.cpp",  "tools/server/server-realtime.cpp",
    "tools/server/server-stream.cpp",   "tools/server/server-tools.cpp",
    "tools/server/server-mcp.cpp",      "tools/server/server-schema.cpp",
    "tools/server/server-decision.cpp",
};

const server_impl_sources = [_][]const u8{
    "tools/server/server.cpp",
    "tools/server/server-connect.cpp",
    "tools/server/server-http.cpp",
    "tools/server/server-models.cpp",
    "tools/server/server-models-sched.cpp",
};

const cli_impl_sources = [_][]const u8{
    "tools/cli/cli.cpp",
    "tools/cli/cli-client.cpp",
    "tools/cli/cli-context.cpp",
};

// -----------------------------------------------------------------------------

/// The shader extensions `ggml/src/ggml-vulkan/CMakeLists.txt:80-121` asks
/// `glslc` about, in its order. Each one `glslc` accepts defines its macro for
/// the shader generator and for `ggml-vulkan.cpp`, and both compile
/// differently for it.
const VulkanFeature = struct {
    const Self = @This();
    /// The extension named in `glslc`'s refusal.
    extension: []const u8,
    /// The test shader under `vulkan-shaders/feature-tests/`.
    test_shader: []const u8,
    /// The macro defined when `glslc` accepts it.
    define: []const u8,
};

/// The extensions `configureVulkan` asks `glslc` about.
const vulkan_features = [_]VulkanFeature{
    .{ .extension = "GL_KHR_cooperative_matrix", .test_shader = "coopmat.comp", .define = "GGML_VULKAN_COOPMAT_GLSLC_SUPPORT" },
    .{ .extension = "GL_NV_cooperative_matrix2", .test_shader = "coopmat2.comp", .define = "GGML_VULKAN_COOPMAT2_GLSLC_SUPPORT" },
    .{ .extension = "GL_NV_cooperative_matrix_decode_vector", .test_shader = "coopmat2_decode_vector.comp", .define = "GGML_VULKAN_COOPMAT2_DECODE_VECTOR_GLSLC_SUPPORT" },
    .{ .extension = "GL_EXT_integer_dot_product", .test_shader = "integer_dot.comp", .define = "GGML_VULKAN_INTEGER_DOT_GLSLC_SUPPORT" },
    .{ .extension = "GL_EXT_bfloat16", .test_shader = "bfloat16.comp", .define = "GGML_VULKAN_BFLOAT16_GLSLC_SUPPORT" },
    .{ .extension = "GL_EXT_float_e2m1", .test_shader = "float_e2m1.comp", .define = "GGML_VULKAN_FLOAT_E2M1_GLSLC_SUPPORT" },
    .{ .extension = "GL_EXT_float_e4m3", .test_shader = "float_e4m3.comp", .define = "GGML_VULKAN_FLOAT_E4M3_GLSLC_SUPPORT" },
};

/// The Vulkan shader sources and their generator, relative to the sources.
const vulkan_shaders_dir = "ggml/src/ggml-vulkan/vulkan-shaders";

/// What `-Dvulkan` resolved to at configure time.
const Vulkan = struct {
    const Self = @This();
    /// The `glslc` every shader is compiled with.
    glslc: []const u8,
    /// Directories holding `vulkan/` and `spirv/`, searched after libc's.
    include_dirs: []const []const u8,
    /// Extra directories to find `libvulkan` in.
    lib_dirs: []const []const u8,
    /// `-D` flags for the shader extensions `glslc` accepts.
    features: []const []const u8,
};

/// The CUDA backend's sources, relative to the sources.
const cuda_dir = "ggml/src/ggml-cuda";

/// The FlashAttention K/V types `ggml_cuda_fattn_vec_instances` knows
/// (`ggml/cmake/common.cmake:61`), in its order.
const cuda_fa_types = [_][]const u8{ "q4_0", "q4_1", "q5_0", "q5_1", "q8_0", "bf16", "f16" };

/// `GGML_CUDA_FA_QUANTS`'s default (`ggml/CMakeLists.txt:208`), with the
/// commas CMake's define joins it with.
const cuda_fa_quants_default = "q4_0-q4_0,q8_0-q8_0,f16-f16,bf16-bf16";

/// What `-Dcuda` resolved to at configure time.
const Cuda = struct {
    const Self = @This();
    /// The `nvcc` every `.cu` file is compiled with.
    nvcc: []const u8,
    /// The toolkit's libraries: cudart, cublas, cublasLt and culibos.
    lib_dir: []const u8,
    /// The toolkit's driver stubs, which hold the `libcuda.so` linked against.
    stubs_dir: []const u8,
    /// The host compiler's `libstdc++.so`, which the `.cu` objects' host code
    /// calls into.
    libstdcxx: []const u8,
    /// The host compiler's `libgcc.a`, for the outline atomics
    /// (`__aarch64_cas4_sync` and kin) g++ emits on arm64 by default, which
    /// Zig's compiler_rt does not provide in their `_sync` form.
    libgcc: []const u8,
    /// Every `nvcc` flag but the include paths and the file's own arguments:
    /// the defines, then `CUDA_FLAGS`, in CMake's order.
    flags: []const []const u8,
    /// The `.cu` files under `fattn-vec-instance-*` that the selected
    /// FlashAttention K/V combinations compile.
    fa_vec_sources: []const []const u8,
};

/// The generated `ui.h` and `ui.cpp`.
const UiHeaders = struct {
    const Self = @This();
    /// The directory holding `ui.h`, for the include path.
    dir: std.Build.LazyPath,
    /// The generated `ui.cpp`, compiled into `llama-ui`.
    cpp: std.Build.LazyPath,
};

/// What `addCli` builds: the CLI, and the server over the same libraries.
const Executables = struct {
    const Self = @This();
    /// `llama-cli`.
    cli: *std.Build.Step.Compile,
    /// `llama-server`.
    server: *std.Build.Step.Compile,
};

/// Everything the target-specific decisions were resolved into, computed once
/// by `init`, and the methods that declare every target from them.
const Config = struct {
    const Self = @This();
    /// The build graph every target is declared on.
    b: *std.Build,
    /// What `-Dtarget` and `-Dcpu` resolved to.
    target: std.Build.ResolvedTarget,
    /// What `--release` / `-Doptimize` resolved to.
    optimize: std.lang.Optimize,
    /// The configuration `target`'s OS selects.
    platform: Platform,

    /// The llama.cpp sources (`src_dep`). `path` gives the lazy paths the
    /// graph compiles; `builder.root` is the same directory, for the globs
    /// that list it at configure time.
    src: *std.Build.Dependency,

    /// Apple SDK path. Null on Linux and Windows.
    sdk: ?[]const u8 = null,

    /// Whether ggml gains its BLAS backend over Accelerate (`-Dblas`).
    blas: bool = false,

    /// Whether mtmd is compiled with `MTMD_VIDEO` (`-Dmtmd-video`): video
    /// input, decoded by an `ffmpeg` subprocess. CMake's `MTMD_VIDEO` is on
    /// by default and forced off without `LLAMA_SUBPROCESS`
    /// (`tools/mtmd/CMakeLists.txt:5-11`), so it is off on iOS whatever the
    /// option says.
    mtmd_video: bool = false,

    /// A generated `zig libc` file pointing at the SDK's headers. Null on
    /// Linux and Windows, where Zig ships glibc and MinGW and needs no help.
    ///
    /// Every Apple platform needs one, because each is named by an explicit
    /// `-Dtarget`. Zig only sets up the SDK include chain for a *native*
    /// target; name any triple and it treats the build as cross-compilation,
    /// after which its clang finds no `stdio.h` and its libc++ build dies on
    /// `mbstate_t`. Passing `-idirafter` on our own sources is not enough --
    /// Zig builds libc++ itself, and that internal build sees none of our
    /// flags. A libc file is the one knob that reaches it.
    libc_file: ?std.Build.LazyPath = null,

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
    vulkan: ?Vulkan = null,

    /// The CUDA backend's configuration; null without `-Dcuda`.
    cuda: ?Cuda = null,

    /// The built web UI to embed (`-Dui`, a SvelteKit `dist` directory,
    /// relative to the build root or absolute); null for `zig/ui-stub`'s
    /// empty table.
    ui: ?[]const u8 = null,

    /// Whether the embedded UI is gzip-compressed (`-Dui-gzip`, upstream's
    /// `LLAMA_UI_GZIP`, default on).
    ui_gzip: bool = true,

    /// Resolve the target, the platform and every option into a
    /// configuration.
    ///
    /// - `b`: The build graph, whose options are read and which every target
    ///   is later declared on.
    /// - Returns: The configuration; `error.UnsupportedTarget` for an OS or
    ///   architecture this build has no configuration for, and SDK
    ///   resolution and `-Dvulkan` probe failures.
    pub fn init(b: *std.Build) !Self {
        // Zig 0.17 recognises the M5 as `apple_m5`, with i8mm and SME, where
        // 0.16 fell back to the macOS baseline (`apple_m1`). The native default
        // would therefore compile `__ARM_FEATURE_MATMUL_INT8` kernels into
        // ggml-cpu -- 158 i8mm instructions, measured -- and stop matching a
        // build that names its triple. The default stays at the baseline;
        // `-Dcpu=native` opts in.
        const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
        const optimize = b.standardOptimizeOption(.{});
        const platform = Platform.detect(target.result) orelse {
            log.err(
                "no configuration for OS '{s}'; this build knows macos, ios, tvos, visionos, linux, and windows",
                .{@tagName(target.result.os.tag)},
            );
            return error.UnsupportedTarget;
        };
        // ggml's arch sources are listed for arm64 and x86_64 only. Anything
        // else would link a libggml with no quant kernels rather than fail
        // outright, so it is caught here instead. On Apple platforms x86_64 is
        // macOS and the simulators -- the xcframework's universal slices --
        // since no Apple device runs it.
        const apple_x86_ok = platform == .macos or target.result.abi == .simulator;
        if (ArchSources.forArch(target.result.cpu.arch) == null or
            (target.result.cpu.arch == .x86_64 and platform.isApple() and !apple_x86_ok))
        {
            log.err(
                "no configuration for arch '{s}' on '{s}'; ggml's arch sources are arm64, and x86_64 on Linux, Windows, macOS and the Apple simulators",
                .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) },
            );
            return error.UnsupportedTarget;
        }

        const src = b.dependency(src_dep, .{});
        const sdk = if (platform.isApple()) try resolveAppleSdk(b, target.result) else null;
        const vulkan = try configureVulkan(b, platform, src);
        const cuda = try configureCuda(b, platform, target.result, optimize);
        const blas = b.option(bool, "blas", "Build ggml's BLAS backend over Accelerate, as upstream's Apple builds do by default (Apple targets only)") orelse false;
        if (blas and !platform.isApple()) {
            log.err("-Dblas: only the Accelerate vendor is configured, which is Apple's", .{});
            return error.UnsupportedTarget;
        }

        var defs: std.ArrayList([]const u8) = .empty;
        try defs.appendSlice(b.allocator, &base_defines);
        if (platform.isApple()) try defs.appendSlice(b.allocator, &apple_defines);
        const subprocess = platform != .ios;
        if (subprocess) try defs.appendSlice(b.allocator, &subprocess_defines);
        if (platform == .linux) try defs.appendSlice(b.allocator, &linux_defines);
        if (platform == .windows) try defs.appendSlice(b.allocator, &windows_defines);
        // Only `ggml-backend-reg.cpp` reads it, to register the backend.
        if (vulkan != null) try defs.append(b.allocator, "-DGGML_USE_VULKAN");
        // PUBLIC on ggml (ggml/src/CMakeLists.txt:436); likewise read only by
        // `ggml-backend-reg.cpp`.
        if (cuda != null) try defs.append(b.allocator, "-DGGML_USE_CUDA");
        if (blas) try defs.append(b.allocator, "-DGGML_USE_BLAS");

        // Declared on every platform, so passing it is never an error, then
        // forced off without subprocess support, as CMake forces it
        // (`MTMD_VIDEO AND NOT LLAMA_SUBPROCESS`, tools/mtmd/CMakeLists.txt:8).
        const mtmd_video_opt = b.option(bool, "mtmd-video", "Compile mtmd's video input (MTMD_VIDEO; needs ffmpeg at run time), as CMake does by default; always off on iOS") orelse true;
        const mtmd_video = mtmd_video_opt and subprocess;

        const lang_c: []const []const u8 = if (platform == .windows) &gnu_c_std else &c_std;
        const lang_cxx: []const []const u8 = if (platform == .windows) &gnu_cxx_std else &cxx_std;

        return .{
            .b = b,
            .target = target,
            .optimize = optimize,
            .platform = platform,
            .src = src,
            .sdk = sdk,
            .blas = blas,
            .mtmd_video = mtmd_video,
            .libc_file = if (sdk) |s| writeAppleLibcFile(b, s) else null,
            .c_std = lang_c,
            .cxx_std = lang_cxx,
            .c = try join(b, lang_c, defs.items),
            .cxx = try join(b, lang_cxx, defs.items),
            .objc = try join(b, &objc_std, defs.items),
            .vulkan = vulkan,
            .cuda = cuda,
            .ui =b.option([]const u8, "ui", "Embed the web UI built in this directory (a SvelteKit dist; `make ui` writes .ui/dist). Default: no UI"),
            .ui_gzip = b.option(bool, "ui-gzip", "gzip-compress the embedded web UI, as upstream's LLAMA_UI_GZIP (default true)") orelse true,
        };
    }

    /// Build ggml with its CPU backend -- and, on Apple platforms, its Metal
    /// backend, with `-Dblas` its BLAS backend, with `-Dvulkan` its Vulkan
    /// one, and with `-Dcuda` its CUDA one -- as one static archive.
    ///
    /// CMake splits the backends so they can be loaded dynamically. With static
    /// linking and `GGML_BACKEND_DL` off that split carries no meaning:
    /// `ggml-backend-reg.cpp` calls each backend's registration function directly
    /// under an `#ifdef`, so one archive links identically.
    ///
    /// - Returns: The archive; propagates directory-read failures.
    pub fn addGgml(self: *const Self) !*std.Build.Step.Compile {
        const b = self.b;
        const mod = self.baseModule();

        mod.addIncludePath(self.src.path("ggml/include"));
        mod.addIncludePath(self.src.path("ggml/src"));
        mod.addIncludePath(self.src.path("ggml/src/ggml-cpu"));
        // ggml/src/CMakeLists.txt:216, configure_file(ggml-version.h.in).
        mod.addConfigHeader(b.addConfigHeader(.{
            .style = .{ .cmake = self.src.path("ggml/src/ggml-version.h.in") },
            .include_path = "ggml-version.h",
        }, .{ .GGML_VERSION = ggml_version, .GGML_BUILD_COMMIT = commit }));

        mod.addCSourceFiles(.{ .root = self.src.path(""), .files = &ggml_c_sources, .flags = self.c });
        mod.addCSourceFiles(.{ .root = self.src.path(""), .files = &ggml_cxx_sources, .flags = self.cxx });
        const arch = ArchSources.forArch(self.target.result.cpu.arch).?;
        mod.addCSourceFiles(.{ .root = self.src.path(""), .files = arch.c, .flags = self.c });
        mod.addCSourceFiles(.{ .root = self.src.path(""), .files = arch.cxx, .flags = self.cxx });

        if (self.platform.isApple()) {
            mod.addIncludePath(self.src.path("ggml/src/ggml-metal"));
            mod.addCSourceFiles(.{ .root = self.src.path(""), .files = &metal_cxx_sources, .flags = self.cxx });
            mod.addCSourceFiles(.{ .root = self.src.path(""), .files = &metal_objc_sources, .flags = self.objc });

            // One host tool for every kernel, run once per kernel.
            const tool = b.addExecutable(.{
                .name = "metal_embed",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("zig/metal_embed.zig"),
                    .target = b.graph.host,
                    .optimize = .debug,
                }),
            });
            for (metal_kernels) |kind| mod.addAssemblyFile(self.embedMetalKernel(tool, kind));

            mod.linkFramework("Foundation", .{});
            mod.linkFramework("Metal", .{});
            mod.linkFramework("MetalKit", .{});
            mod.linkFramework("Accelerate", .{});
        }

        if (self.blas) {
            mod.addCSourceFiles(.{ .root = self.src.path(""), .files = &blas_sources, .flags = try join(b, self.cxx, &blas_defines) });
        }

        if (self.vulkan) |vk| try self.addVulkan(vk, mod);
        if (self.cuda) |cu| try self.addCuda(cu, mod);

        return self.addLibrary("ggml", mod);
    }

    /// Build libllama, including every architecture under `src/models/`.
    ///
    /// The architectures are read from the directory rather than listed, as
    /// CMake's `file(GLOB)` does, so adding one needs no build change.
    ///
    /// - `ggml`: The ggml archive libllama links.
    /// - Returns: The archive; propagates directory-read failures.
    pub fn addLlama(self: *const Self, ggml: *std.Build.Step.Compile) !*std.Build.Step.Compile {
        const b = self.b;
        const mod = self.baseModule();
        self.addCommonIncludes(mod);
        // Private to this target; see addCommonIncludes.
        mod.addIncludePath(self.src.path("src"));
        // src/CMakeLists.txt:66, configure_file(llama-version.h.in).
        mod.addConfigHeader(b.addConfigHeader(.{
            .style = .{ .cmake = self.src.path("src/llama-version.h.in") },
            .include_path = "llama-version.h",
        }, .{ .LLAMA_VERSION = version, .LLAMA_BUILD_COMMIT = commit }));

        var files: std.ArrayList([]const u8) = .empty;
        try files.appendSlice(b.allocator, &llama_sources);
        try self.appendGlob(&files, "src/models", ".cpp");

        mod.addCSourceFiles(.{
            .root = self.src.path(""),
            .files = files.items,
            .flags = self.cxx,
        });
        mod.linkLibrary(ggml);

        return self.addLibrary("llama", mod);
    }

    /// Build vendor::hash (`vendor/hash/CMakeLists.txt`), which mtmd links.
    ///
    /// - Returns: The archive.
    pub fn addVendorHash(self: *const Self) *std.Build.Step.Compile {
        const mod = self.baseModule();
        mod.addIncludePath(self.src.path("vendor"));
        mod.addIncludePath(self.src.path("vendor/hash"));
        mod.addCSourceFiles(.{
            .root = self.src.path(""),
            .files = &[_][]const u8{"vendor/hash/hash.cpp"},
            .flags = self.cxx_std,
        });
        // sha1.c is C++ despite the extension. CMake sets LANGUAGE CXX on it
        // (vendor/hash/CMakeLists.txt:32) because the file wraps itself in a
        // namespace to avoid clashing with boringssl's symbols.
        mod.addCSourceFiles(.{
            .root = self.src.path(""),
            .files = &[_][]const u8{"vendor/hash/sha1/sha1.c"},
            .flags = self.cxx_std,
            .language = .cpp,
        });
        mod.addCSourceFiles(.{
            .root = self.src.path(""),
            .files = &[_][]const u8{
                "vendor/hash/xxhash/xxhash.c",
                "vendor/hash/sha256/sha256.c",
            },
            .flags = self.c_std,
        });

        return self.addLibrary("vendor-hash", mod);
    }

    /// Build mtmd, multimodal support. The CLI links it through server-context;
    /// the xcframework carries it as upstream's does (`LLAMA_BUILD_MTMD=ON`).
    ///
    /// `MTMD_VIDEO` is a private definition (`tools/mtmd/CMakeLists.txt:100`),
    /// read by `mtmd-helper.cpp`, whose video path includes the header-only
    /// `vendor/sheredom/subprocess.h` from the `vendor` include path; see
    /// `mtmd_video` for when it is on. `build-xcframework.sh` turns it off for
    /// every slice but macOS, and so does the Makefile's `xcframework`.
    ///
    /// - `ggml`: The ggml archive.
    /// - `llama`: The libllama archive.
    /// - `hash`: The vendor-hash archive.
    /// - Returns: The archive; propagates directory-read failures.
    pub fn addMtmd(
        self: *const Self,
        ggml: *std.Build.Step.Compile,
        llama: *std.Build.Step.Compile,
        hash: *std.Build.Step.Compile,
    ) !*std.Build.Step.Compile {
        const b = self.b;
        const mod = self.baseModule();
        self.addCommonIncludes(mod);
        mod.addIncludePath(self.src.path("tools/mtmd"));
        mod.addIncludePath(self.src.path("vendor/hash"));

        var files: std.ArrayList([]const u8) = .empty;
        try files.appendSlice(b.allocator, &mtmd_sources);
        try self.appendGlob(&files, "tools/mtmd/models", ".cpp");

        const flags = if (self.mtmd_video) try join(b, self.cxx, &mtmd_video_defines) else self.cxx;
        mod.addCSourceFiles(.{ .root = self.src.path(""), .files = files.items, .flags = flags });
        mod.linkLibrary(llama);
        mod.linkLibrary(ggml);
        mod.linkLibrary(hash);

        return self.addLibrary("mtmd", mod);
    }

    /// Build `llama-cli` and everything it links, and `llama-server` over the
    /// same libraries.
    ///
    /// The dependency chain, from CMake: llama-cli -> llama-cli-impl ->
    /// llama-server-impl -> {server-context, llama-ui, cpp-httplib} ->
    /// {llama-common, mtmd} -> {llama, ggml, vendor}. The CLI pulls in the whole
    /// server because `cli-context.cpp` drives it in-process.
    ///
    /// - `ggml`: The ggml archive.
    /// - `llama`: The libllama archive.
    /// - `mtmd`: The mtmd archive.
    /// - Returns: Both executables; propagates UI-embedding failures.
    pub fn addCli(
        self: *const Self,
        ggml: *std.Build.Step.Compile,
        llama: *std.Build.Step.Compile,
        mtmd: *std.Build.Step.Compile,
    ) !Executables {
        const b = self.b;
        // cpp-httplib, needed by the server and by common's downloader.
        const httplib = blk: {
            const mod = self.baseModule();
            mod.addIncludePath(self.src.path("vendor"));
            mod.addIncludePath(self.src.path("vendor/cpp-httplib"));
            mod.addCSourceFiles(.{
                .root = self.src.path(""),
                .files = &[_][]const u8{"vendor/cpp-httplib/httplib.cpp"},
                .flags = try join(b, self.cxx_std, &httplib_defines),
            });
            // vendor/cpp-httplib/CMakeLists.txt:23, `WIN32 AND NOT MSVC`.
            if (self.platform == .windows) mod.linkSystemLibrary("ws2_32", .{});
            break :blk self.addLibrary("cpp-httplib", mod);
        };

        // llama-common-base: just build-info.cpp, configured from upstream's
        // build-info.cpp.in as common/CMakeLists.txt does. The resolved target is
        // only known at configure time, so the triple is formatted.
        const build_info = b.addConfigHeader(.{
            .style = .{ .cmake = self.src.path("common/build-info.cpp.in") },
            .include_path = "build-info.cpp",
        }, .{
            .LLAMA_BUILD_NUMBER = build_number,
            .LLAMA_BUILD_COMMIT = commit,
            .BUILD_COMPILER = b.fmt("Zig {s} clang", .{builtin.zig_version_string}),
            .BUILD_TARGET = b.fmt("{s}-{s}", .{
                @tagName(self.target.result.cpu.arch),
                @tagName(self.target.result.os.tag),
            }),
        }).getOutputFile();

        const common_base = blk: {
            const mod = self.baseModule();
            self.addCommonIncludes(mod);
            mod.addCSourceFile(.{ .file = build_info, .flags = self.cxx });
            break :blk self.addLibrary("llama-common-base", mod);
        };

        const common = blk: {
            const mod = self.baseModule();
            self.addCommonIncludes(mod);
            mod.addIncludePath(self.src.path("tools/mtmd"));
            mod.addCSourceFiles(.{ .root = self.src.path(""), .files = &common_sources, .flags = self.cxx });
            mod.linkLibrary(common_base);
            mod.linkLibrary(httplib);
            mod.linkLibrary(llama);
            mod.linkLibrary(ggml);
            break :blk self.addLibrary("llama-common", mod);
        };

        // The web UI: upstream's bundle embedded under -Dui, else the stub.
        const ui_headers = if (self.ui) |dist| try self.embedUi(dist) else null;
        const ui_include = if (ui_headers) |h| h.dir else b.path("zig/ui-stub");
        const ui = blk: {
            const mod = self.baseModule();
            mod.addIncludePath(ui_include);
            if (ui_headers) |h| {
                // tools/ui/CMakeLists.txt:63, add_library(llama-ui ui.cpp) with cxx_std_17.
                mod.addCSourceFile(.{ .file = h.cpp, .flags = self.cxx_std });
            } else {
                mod.addCSourceFiles(.{
                    .files = &[_][]const u8{"zig/ui-stub/ui.cpp"},
                    .flags = self.cxx_std,
                });
            }
            break :blk self.addLibrary("llama-ui", mod);
        };

        const server_context = blk: {
            const mod = self.baseModule();
            self.addCommonIncludes(mod);
            mod.addIncludePath(self.src.path("tools/mtmd"));
            mod.addIncludePath(self.src.path("tools/server"));
            mod.addCSourceFiles(.{ .root = self.src.path(""), .files = &server_context_sources, .flags = self.cxx });
            mod.linkLibrary(common);
            mod.linkLibrary(mtmd);
            break :blk self.addLibrary("server-context", mod);
        };

        const server_impl = blk: {
            const mod = self.baseModule();
            self.addCommonIncludes(mod);
            mod.addIncludePath(self.src.path("tools/mtmd"));
            mod.addIncludePath(self.src.path("tools/server"));
            mod.addIncludePath(ui_include);
            mod.addCSourceFiles(.{ .root = self.src.path(""), .files = &server_impl_sources, .flags = self.cxx });
            mod.linkLibrary(server_context);
            mod.linkLibrary(ui);
            mod.linkLibrary(httplib);
            break :blk self.addLibrary("llama-server-impl", mod);
        };

        const cli_impl = blk: {
            const mod = self.baseModule();
            self.addCommonIncludes(mod);
            mod.addIncludePath(self.src.path("tools/cli"));
            mod.addIncludePath(self.src.path("tools/server"));
            mod.addIncludePath(self.src.path("tools/mtmd"));
            mod.addCSourceFiles(.{ .root = self.src.path(""), .files = &cli_impl_sources, .flags = self.cxx });
            mod.linkLibrary(server_impl);
            break :blk self.addLibrary("llama-cli-impl", mod);
        };

        const mod = self.baseModule();
        self.addCommonIncludes(mod);
        mod.addIncludePath(self.src.path("tools/cli"));
        mod.addCSourceFiles(.{
            .root = self.src.path(""),
            .files = &[_][]const u8{"tools/cli/main.cpp"},
            .flags = self.cxx,
        });
        mod.linkLibrary(cli_impl);
        self.linkVulkan(mod);
        self.linkCuda(mod);

        // tools/server/CMakeLists.txt:71, llama-server: main.cpp over llama-server-impl.
        const server = blk: {
            const smod = self.baseModule();
            self.addCommonIncludes(smod);
            smod.addIncludePath(self.src.path("tools/server"));
            smod.addCSourceFiles(.{
                .root = self.src.path(""),
                .files = &[_][]const u8{"tools/server/main.cpp"},
                .flags = self.cxx,
            });
            smod.linkLibrary(server_impl);
            self.linkVulkan(smod);
            self.linkCuda(smod);
            break :blk self.addExecutable("llama-server", smod);
        };

        return .{ .cli = self.addExecutable("llama-cli", mod), .server = server };
    }

    /// A module with the settings every C/C++ target in this build shares.
    ///
    /// - Returns: The module.
    fn baseModule(self: *const Self) *std.Build.Module {
        const b = self.b;
        const mod = b.createModule(.{
            .target = self.target,
            .optimize = self.optimize,
            .link_libc = true,
            .link_libcpp = true,
            // These sources are not UBSan-clean -- they rely on pointer arithmetic
            // that is technically undefined but universally works -- and Zig turns
            // the C sanitizers on in Debug. CMake never enabled them.
            .sanitize_c = .off,
        });
        if (self.sdk) |sdk| {
            mod.addFrameworkPath(b.graph.cwdRelativePath(b.fmt("{s}/System/Library/Frameworks", .{sdk})));
            // Only iOS needs the library path spelled out; for macOS Zig already
            // searches the SDK, and this is the same directory it would find.
            mod.addLibraryPath(b.graph.cwdRelativePath(b.fmt("{s}/usr/lib", .{sdk})));
        }
        return mod;
    }

    /// Wrap `b.addLibrary`, attaching the libc file when the platform needs one.
    ///
    /// `libc_file` lives on the compile step rather than the module, so it cannot
    /// be set in `baseModule` and has to be applied at every construction site.
    ///
    /// - `name`: The library's name.
    /// - `mod`: Its root module.
    /// - Returns: The static library.
    fn addLibrary(self: *const Self, name: []const u8, mod: *std.Build.Module) *std.Build.Step.Compile {
        const b = self.b;
        const lib = b.addLibrary(.{ .name = name, .root_module = mod, .linkage = .static });
        lib.setLibCFile(self.libc_file);
        return lib;
    }

    /// Wrap `b.addExecutable`, attaching the libc file when the platform needs
    /// one. See `addLibrary`.
    ///
    /// - `name`: The executable's name.
    /// - `mod`: Its root module.
    /// - Returns: The executable.
    fn addExecutable(self: *const Self, name: []const u8, mod: *std.Build.Module) *std.Build.Step.Compile {
        const b = self.b;
        const exe = b.addExecutable(.{ .name = name, .root_module = mod });
        exe.setLibCFile(self.libc_file);
        return exe;
    }

    /// Add the include paths shared by everything above ggml.
    ///
    /// - `mod`: The module that gains them.
    fn addCommonIncludes(self: *const Self, mod: *std.Build.Module) void {
        mod.addIncludePath(self.src.path(""));
        mod.addIncludePath(self.src.path("include"));
        // Note `src` is deliberately absent. It holds a second unicode.h, and
        // adding it here shadows common/unicode.h, which common/jinja needs.
        // CMake keeps it PRIVATE to the llama target for the same reason.
        mod.addIncludePath(self.src.path("common"));
        mod.addIncludePath(self.src.path("ggml/include"));
        mod.addIncludePath(self.src.path("ggml/src"));
        // Covers both <nlohmann/json.hpp> and <cpp-httplib/httplib.h>.
        mod.addIncludePath(self.src.path("vendor"));
    }

    /// Add ggml's Vulkan backend to `mod`: the shader generator, the SPIR-V it
    /// embeds, and `ggml-vulkan.cpp`. `addCli` links `libvulkan`.
    ///
    /// Replaces CMake's `ExternalProject` and custom commands
    /// (`ggml-vulkan/CMakeLists.txt:162-259`) with the same two passes of the
    /// same tool. `vulkan-shaders-gen` is upstream's generator, built for the host
    /// with the extension macros: run once with no source it writes
    /// `ggml-vulkan-shaders.hpp`, declaring every variant; run once per `.comp`
    /// with `--glslc` it compiles that file's variants and writes a `.cpp`
    /// holding their SPIR-V. Each run is a separate, cached step, so the 155
    /// shader files compile in parallel and only a changed one recompiles.
    ///
    /// Every `.comp` and `.glsl` is an input of every run: a shader's includes
    /// are resolved by `glslc`, which Zig cannot see.
    ///
    /// - `vk`: What `configureVulkan` resolved.
    /// - `mod`: ggml's module, which gains the backend's sources.
    /// - Returns: Nothing; propagates directory-read failures.
    fn addVulkan(self: *const Self, vk: Vulkan, mod: *std.Build.Module) !void {
        const b = self.b;
        const gen_mod = b.createModule(.{
            .target = b.graph.host,
            .optimize = .fast,
            .link_libc = true,
            .link_libcpp = true,
            .sanitize_c = .off,
        });
        gen_mod.addCSourceFile(.{
            .file = self.src.path(vulkan_shaders_dir ++ "/vulkan-shaders-gen.cpp"),
            .flags = try join(b, &cxx_std, vk.features),
        });
        const gen = b.addExecutable(.{ .name = "vulkan-shaders-gen", .root_module = gen_mod });

        var comp: std.ArrayList([]const u8) = .empty;
        try self.appendGlob(&comp, vulkan_shaders_dir, ".comp");
        var glsl: std.ArrayList([]const u8) = .empty;
        try self.appendGlob(&glsl, vulkan_shaders_dir, ".glsl");

        // Pass 1: the header, which names every variant.
        const hdr_run = b.addRunArtifact(gen);
        hdr_run.addArg("--output-dir");
        _ = hdr_run.addOutputDirectoryArg2("spv", .{});
        hdr_run.addArg("--target-hpp");
        const header = hdr_run.addOutputFileArg2("ggml-vulkan-shaders.hpp", .{});
        mod.addIncludePath(header.dirname());

        // `-idirafter`, not `-I`: the header directory is usually `/usr/include`,
        // which must not shadow the libc headers Zig supplies.
        var vk_flags: std.ArrayList([]const u8) = .empty;
        try vk_flags.appendSlice(b.allocator, self.cxx);
        try vk_flags.appendSlice(b.allocator, vk.features);
        for (vk.include_dirs) |dir| try vk_flags.appendSlice(b.allocator, &.{ "-idirafter", dir });
        // `CXX_VISIBILITY_PRESET hidden` and `VISIBILITY_INLINES_HIDDEN ON`
        // (ggml-vulkan/CMakeLists.txt:74-76, since v0.5.0), so a dlclosed duplicate
        // copy cannot interpose the backend's symbols.
        try vk_flags.appendSlice(b.allocator, &.{ "-fvisibility=hidden", "-fvisibility-inlines-hidden" });

        // Pass 2: one run per shader file, each writing that file's SPIR-V.
        for (comp.items) |file| {
            const run = b.addRunArtifact(gen);
            run.addArgs(&.{ "--glslc", vk.glslc });
            run.addArg("--source");
            run.addFileArg(self.src.path(file));
            run.addArg("--output-dir");
            _ = run.addOutputDirectoryArg2("spv", .{});
            // Only its basename is used, for the generated `#include`.
            run.addArgs(&.{ "--target-hpp", "ggml-vulkan-shaders.hpp" });
            run.addArg("--target-cpp");
            const cpp = run.addOutputFileArg2(b.fmt("{s}.cpp", .{std.Io.Dir.path.basename(file)}), .{});
            for (comp.items) |f| run.addFileInput(self.src.path(f));
            for (glsl.items) |f| run.addFileInput(self.src.path(f));
            mod.addCSourceFile(.{ .file = cpp, .flags = self.cxx });
        }

        mod.addCSourceFiles(.{
            .root = self.src.path(""),
            .files = &.{
                "ggml/src/ggml-vulkan/ggml-vulkan.cpp",
                "ggml/src/ggml-vulkan/ggml-vulkan-buffers.cpp",
                "ggml/src/ggml-vulkan/ggml-vulkan-comm.cpp",
                "ggml/src/ggml-vulkan/ggml-vulkan-debug.cpp",
            },
            .flags = vk_flags.items,
        });
        // `libvulkan` is linked by the executable, in `addCli`, not here: Zig
        // resolves a system library even for a static archive, which links
        // nothing, and a machine that only builds the archive -- for a harness
        // that links it itself -- need not have the loader installed.
    }

    /// Flatten one Metal kernel and return the assembly stub that embeds it.
    ///
    /// Replaces the `cat`/`sed` pipeline CMake runs under
    /// `GGML_METAL_EMBED_LIBRARY`. The stub `.incbin`s the flattened shader
    /// *source* into a `__DATA,__ggml_metallib` section; the Metal driver compiles
    /// it at load time, so no `xcrun metal` step is involved. That is also why
    /// this works unchanged for iOS: nothing here is host-specific.
    ///
    /// Never switch to the non-embedded path: that one does need `xcrun metal`,
    /// which the Zig toolchain cannot replace.
    ///
    /// - `tool`: `zig/metal_embed.zig`, built for the host.
    /// - `kind`: The kernel, one of `metal_kernels`.
    /// - Returns: The generated assembly stub.
    fn embedMetalKernel(self: *const Self, tool: *std.Build.Step.Compile, kind: []const u8) std.Build.LazyPath {
        const b = self.b;
        const run = b.addRunArtifact(tool);
        run.addArg(kind);
        _ = run.addOutputFileArg2(b.fmt("ggml-metal-embed-{s}.metal", .{kind}), .{});
        const out_asm = run.addOutputFileArg2(b.fmt("ggml-metal-embed-{s}.s", .{kind}), .{});

        run.addFileArg(self.src.path("ggml/src/ggml-common.h"));
        run.addFileArg(self.src.path("ggml/src/ggml-metal/ggml-metal-impl.h"));
        run.addFileArg(self.src.path("ggml/src/ggml-metal/kernels/common.h"));
        run.addFileArg(self.src.path("ggml/src/ggml-metal/kernels/dequantize.h"));
        run.addFileArg(self.src.path("ggml/src/ggml-metal/kernels/quantize.h"));
        run.addFileArg(self.src.path("ggml/src/ggml-metal/kernels/fa_common.metal"));
        run.addFileArg(self.src.path("ggml/src/ggml-metal/kernels/fa_vec_common.metal"));
        run.addFileArg(self.src.path(b.fmt("ggml/src/ggml-metal/kernels/{s}.metal", .{kind})));

        return out_asm;
    }

    /// Link `libvulkan` into an executable when the Vulkan backend is on.
    ///
    /// - `mod`: The executable's root module.
    fn linkVulkan(self: *const Self, mod: *std.Build.Module) void {
        const b = self.b;
        if (self.vulkan) |vk| {
            for (vk.lib_dirs) |dir| mod.addLibraryPath(b.graph.cwdRelativePath(dir));
            mod.linkSystemLibrary("vulkan", .{});
        }
    }

    /// Add ggml's CUDA backend to `mod`: every `.cu` file CMake lists,
    /// compiled by `nvcc` into an object the archive carries.
    ///
    /// Replaces `enable_language(CUDA)` and `ggml-cuda/CMakeLists.txt:114-128`.
    /// Each file is a cached `nvcc` run of its own, with the command line
    /// CMake's Makefiles give it (`-forward-unknown-to-host-compiler`,
    /// defines, includes, `CUDA_FLAGS`, `-MD`, `-x cu -c`). nvcc's depfile is
    /// handed to Zig, so a changed header recompiles exactly the files that
    /// include it. No device-link step is needed: CMake leaves
    /// `CUDA_SEPARABLE_COMPILATION` off, so each object is self-contained.
    ///
    /// nvcc's host compiler is left at its default, g++, as CMake leaves it.
    /// Zig's own clang cannot stand in: CUDA 13.0's `crt/math_functions.hpp`
    /// redeclares the `isnan`/`isinf` overloads Zig's libc++ 22 already
    /// provides, and every file that includes `ggml-impl.h` fails on the
    /// ambiguity. The objects' host code therefore links against libstdc++
    /// (`linkCuda`), which `libcudart.so` loads in any case; it shares no C++
    /// types with the rest of ggml, which reaches the backend only through its
    /// C API.
    ///
    /// - `cu`: What `configureCuda` resolved.
    /// - `mod`: ggml's module, which gains the objects.
    /// - Returns: Nothing; propagates directory-read failures.
    fn addCuda(self: *const Self, cu: Cuda, mod: *std.Build.Module) !void {
        const b = self.b;
        var files: std.ArrayList([]const u8) = .empty;
        try self.appendGlobPrefixed(&files, cuda_dir, "", ".cu");
        const inst = cuda_dir ++ "/template-instances";
        for ([_][]const u8{ "fattn-tile", "fattn-mma", "mmq", "mmf" }) |prefix| {
            try self.appendGlobPrefixed(&files, inst, prefix, ".cu");
        }
        try files.appendSlice(b.allocator, cu.fa_vec_sources);

        for (files.items) |file| {
            const run = b.addSystemCommand(&.{ cu.nvcc, "-forward-unknown-to-host-compiler" });
            run.addArgs(cu.flags);
            // `includes_CUDA.rsp`: `ggml-cuda/..` and `../include` from
            // ggml_add_backend_library (ggml/src/CMakeLists.txt:400) and ggml's
            // PUBLIC include; the toolkit's own include nvcc adds by itself.
            //
            // Every path is absolute, as CMake's are: nvcc bakes the source's
            // and its headers' paths into `__FILE__` strings, and a relative
            // one leaves the objects differing from CMake's in nothing else.
            // They are also spelled as CMake spells them, unnormalized: a header
            // found through `ggml-cuda/..` is named `.../ggml-cuda/../ggml-cuda/x.cuh`.
            run.addDirectoryArg2(self.src.path(cuda_dir), .{ .prefix = "-I", .suffix = "/..", .make_absolute = true });
            run.addDirectoryArg2(self.src.path("ggml/src"), .{ .prefix = "-I", .suffix = "/../include", .make_absolute = true });
            run.addArgs(&.{ "-MD", "-MF" });
            _ = run.addDepFileOutputArg2("dep.d", .{});
            run.addArgs(&.{ "-x", "cu", "-c" });
            run.addFileArg2(self.src.path(file), .{ .make_absolute = true });
            run.addArg("-o");
            const base = std.Io.Dir.path.basename(file);
            const obj = run.addOutputFileArg2(b.fmt("{s}.o", .{base[0 .. base.len - ".cu".len]}), .{});
            mod.addObjectFile(obj);
        }
        // The toolkit's libraries are linked by the executables, in `addCli`,
        // not here, for the reason `addVulkan` gives for `libvulkan`.
    }

    /// Link the CUDA runtime, cuBLAS and the driver into an executable when
    /// the CUDA backend is on.
    ///
    /// The libraries are CMake's link line for `llama-cli` with `GGML_STATIC`
    /// off, its default (`ggml-cuda/CMakeLists.txt:175-182`): the shared
    /// `cudart`, `cublas` and `cublasLt`, the static `culibos` that
    /// `CUDA::cublas` carries, and the driver stub, with an rpath to the
    /// toolkit as CMake's build tree gets. The stub directory is searched last,
    /// so only `libcuda.so` -- which nothing but the driver provides -- comes
    /// from it; at run time its soname finds the driver's real one.
    ///
    /// `libstdc++.so` is linked by path because `linkSystemLibrary("stdc++")`
    /// is rewritten into Zig's libc++ (`std/zig/target.zig`, `isLibCppLibName`).
    ///
    /// - `mod`: The executable's root module.
    fn linkCuda(self: *const Self, mod: *std.Build.Module) void {
        const b = self.b;
        const cu = self.cuda orelse return;
        const lib = b.graph.cwdRelativePath(cu.lib_dir);
        mod.addLibraryPath(lib);
        mod.addRPath(lib);
        mod.addLibraryPath(b.graph.cwdRelativePath(cu.stubs_dir));
        for ([_][]const u8{ "cudart", "cublas", "cublasLt", "culibos", "cuda" }) |name| {
            mod.linkSystemLibrary(name, .{ .use_pkg_config = .no });
        }
        mod.addObjectFile(b.graph.cwdRelativePath(cu.libstdcxx));
        // Last, so it only fills what compiler_rt leaves undefined; g++ adds it
        // to CMake's link the same way.
        mod.addObjectFile(b.graph.cwdRelativePath(cu.libgcc));
    }

    /// Embed a built web UI, as `scripts/ui-assets.cmake`'s `emit_files` does.
    ///
    /// Upstream's CMake first provisions the SvelteKit bundle -- `npm ci` and
    /// `npm run build` under `LLAMA_BUILD_UI`, or a download under
    /// `LLAMA_USE_PREBUILT_UI` -- then writes every file of it into
    /// `tools/ui/ui.h.in` and `ui.cpp.in` as byte arrays. The npm half is the
    /// Makefile's `ui` target here; `zig/ui_embed.zig` does the rest.
    ///
    /// - `dist_path`: The bundle's directory, relative to the build root or
    ///   absolute.
    /// - Returns: The generated header directory and source; propagates
    ///   directory-read failures.
    fn embedUi(self: *const Self, dist_path: []const u8) !UiHeaders {
        const b = self.b;
        const dist: std.Build.LazyPath = if (std.Io.Dir.path.isAbsolute(dist_path))
            b.graph.cwdRelativePath(dist_path)
        else
            b.path(dist_path);
        const tool = b.addExecutable(.{
            .name = "ui_embed",
            .root_module = b.createModule(.{
                .root_source_file = b.path("zig/ui_embed.zig"),
                .target = b.graph.host,
                // gzip and the hex dump of ~10 MB are slow in Debug.
                .optimize = .fast,
            }),
        });
        const run = b.addRunArtifact(tool);
        run.addDirectoryArg2(dist, .{});
        run.addFileArg(self.src.path("tools/ui/ui.h.in"));
        run.addFileArg(self.src.path("tools/ui/ui.cpp.in"));
        run.addArg(if (self.ui_gzip) "1" else "0");
        const h = run.addOutputFileArg2("ui.h", .{});
        const cpp = run.addOutputFileArg2("ui.cpp", .{});

        // A directory argument is not hashed by its contents: name every file,
        // so a rebuilt bundle re-runs the tool. And reconfigure when any
        // directory's listing changes (see appendGlob) -- every one, not just the
        // top: each `npm run build` renames the hashed bundles under
        // `_app/immutable/`, and a graph reused over the old listing fails on a
        // file that no longer exists.
        b.dependOnDirectoryContents(dist);
        var handle = try b.root.openDir(b.graph.io, dist_path, .{ .iterate = true });
        defer handle.close(b.graph.io);
        var walker = try handle.walk(b.allocator);
        defer walker.deinit();
        while (try walker.next(b.graph.io)) |entry| {
            const rel = b.graph.dupeString(entry.path);
            if (entry.kind == .directory) {
                b.dependOnDirectoryContents(dist.path(b, rel));
                continue;
            }
            run.addFileInput(dist.path(b, rel));
        }

        return .{ .dir = h.dirname(), .cpp = cpp };
    }

    /// Append every file in `dir` with the given extension, as CMake's
    /// `file(GLOB)` does.
    ///
    /// - `files`: The list source-relative paths are appended to.
    /// - `dir`: The directory to read, relative to the sources.
    /// - `ext`: The extension to match, including the dot.
    /// - Returns: Nothing; propagates directory-read and allocation failures.
    fn appendGlob(self: *const Self, files: *std.ArrayList([]const u8), dir: []const u8, ext: []const u8) !void {
        return self.appendGlobPrefixed(files, dir, "", ext);
    }

    /// Append every file in `dir` whose name starts with `prefix` and ends with
    /// `ext`, as a CMake `file(GLOB "<dir>/<prefix>*<ext>")` does.
    ///
    /// - `files`: The list source-relative paths are appended to.
    /// - `dir`: The directory to read, relative to the sources.
    /// - `prefix`: The name's required start; empty matches every name.
    /// - `ext`: The extension to match, including the dot.
    /// - Returns: Nothing; propagates directory-read and allocation failures.
    fn appendGlobPrefixed(
        self: *const Self,
        files: *std.ArrayList([]const u8),
        dir: []const u8,
        prefix: []const u8,
        ext: []const u8,
    ) !void {
        const b = self.b;
        // `dir` is relative to the sources, and so are the paths appended, since
        // the source lists are resolved against `self.src`.
        //
        // Zig 0.17 reuses a configured build graph until one of its declared
        // inputs changes, and a directory listing is not one by default. A pinned
        // package cannot change without its hash, but its unpacked copy under
        // `zig-pkg/` is an ordinary directory, and an edit to it must reconfigure.
        b.dependOnDirectoryContents(self.src.path(dir));
        var handle = try self.src.builder.root.openDir(b.graph.io, dir, .{ .iterate = true });
        defer handle.close(b.graph.io);

        var it = handle.iterate();
        while (try it.next(b.graph.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
            if (!std.mem.endsWith(u8, entry.name, ext)) continue;
            try files.append(b.allocator, b.fmt("{s}/{s}", .{ dir, entry.name }));
        }
    }

    /// Concatenate two flag lists into one the build graph can hold onto.
    ///
    /// - `b`: The build graph, whose allocator owns the result.
    /// - `a`: The leading flags.
    /// - `c`: The trailing flags.
    /// - Returns: The joined list.
    fn join(b: *std.Build, a: []const []const u8, c: []const []const u8) ![]const []const u8 {
        const out = try b.allocator.alloc([]const u8, a.len + c.len);
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len..], c);
        return out;
    }

    /// Locate the Apple SDK matching the target, for the header, framework, and
    /// library search paths.
    ///
    /// - `b`: The build graph, for its allocator and I/O.
    /// - `target`: The resolved target; selects the SDK by OS and ABI.
    /// - Returns: The SDK path; `error.AppleSdkNotFound` when none is installed.
    fn resolveAppleSdk(b: *std.Build, target: std.Target) ![]const u8 {
        return std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target) orelse
            error.AppleSdkNotFound;
    }

    /// Write a `zig libc` file describing an Apple SDK.
    ///
    /// Pointing both include directories at the SDK fixes the compile and, because
    /// Zig feeds the same file to its internal libc++ build, the link as well. See
    /// `libc_file` for why a named triple needs this and a native one does not.
    ///
    /// Zig 0.17 requires two keys it did not before: `darwin_sdk_dir`, the SDK
    /// root, and a non-empty `crt_dir`. Both take the values Zig's own native
    /// detection writes (`LibCInstallation.findNative`), so a named triple sees the
    /// same libc a native build does. The remaining keys are required by the file
    /// format and empty by design: the MSVC and cc keys are for other platforms
    /// entirely.
    ///
    /// - `b`: The build graph, for its allocator and generated-file step.
    /// - `sdk`: The SDK root.
    /// - Returns: A lazy path to the generated file, valid for the whole build.
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

    /// Read the `-Dvulkan` options and ask `glslc` which shader extensions it
    /// accepts, at configure time, as `ggml-vulkan/CMakeLists.txt:34-57` does.
    ///
    /// CMake's test is the one reproduced: an extension is supported unless
    /// `glslc`'s diagnostics contain `extension not supported: <name>` -- any
    /// other failure still counts as support. Locating `glslc` poisons Zig's
    /// configuration cache, so every build re-asks, and a `glslc` that changes
    /// between builds cannot leave stale answers.
    ///
    /// - `b`: The build graph, for its options, allocator and process spawning.
    /// - `platform`: Decides the default header directory.
    /// - `src`: The llama.cpp sources, for the feature-test shaders.
    /// - Returns: Null without `-Dvulkan`; otherwise the configuration, or an
    ///   error when `glslc` or the headers cannot be found or a probe cannot run.
    fn configureVulkan(b: *std.Build, platform: Platform, src: *std.Build.Dependency) !?Vulkan {
        const enabled = b.option(bool, "vulkan", "Build ggml's Vulkan backend (needs glslc, the Vulkan and SPIR-V headers, and libvulkan)") orelse false;
        const glslc_opt = b.option([]const u8, "glslc", "The glslc to compile the Vulkan shaders with (default: glslc on PATH)");
        const include_opt = b.option([]const []const u8, "vulkan-include", "Directories holding vulkan/ and spirv/, searched after libc's headers (default on Linux: /usr/include)");
        const lib_opt = b.option([]const []const u8, "vulkan-lib", "Extra directories to find libvulkan in");
        if (!enabled) return null;

        const glslc = glslc_opt orelse b.findProgram(.{ .names = &.{"glslc"} }) orelse {
            log.err("-Dvulkan needs glslc: put it on PATH or pass -Dglslc=<path>", .{});
            return error.GlslcNotFound;
        };
        const include_dirs: []const []const u8 = include_opt orelse if (platform == .linux)
            &.{"/usr/include"}
        else {
            log.err("-Dvulkan on {s} needs -Dvulkan-include=<dir holding vulkan/ and spirv/>", .{@tagName(platform)});
            return error.VulkanHeadersNotFound;
        };

        // The probes below count any output but a refusal as support, so a
        // `glslc` that cannot run at all would pass every one of them: make sure
        // it runs first.
        switch (b.runFallible(&.{ glslc, "--version" }, .{ .stderr_behavior = .ignore })) {
            .success => {},
            else => {
                log.err("-Dvulkan: {s} does not run", .{glslc});
                return error.GlslcNotFound;
            },
        }

        var features: std.ArrayList([]const u8) = .empty;
        for (vulkan_features) |f| {
            const rel = b.fmt("{s}/feature-tests/{s}", .{ vulkan_shaders_dir, f.test_shader });
            b.dependOnFileContents(src.path(rel));
            const test_shader = try src.builder.root.joinString(b.allocator, rel);
            // glslc's diagnostics go to stderr and it exits non-zero on the
            // refusal, so the shell folds both into a successful stdout.
            const out = switch (b.runFallible(&.{
                "sh",                                                                                       "-c",
                "\"$0\" -o - -fshader-stage=compute --target-env=vulkan1.3 \"$1\" 2>&1 >/dev/null; exit 0", glslc,
                test_shader,
            }, .{ .stderr_behavior = .ignore })) {
                .success => |stdout| stdout,
                else => {
                    log.err("could not run {s} on {s}", .{ glslc, test_shader });
                    return error.GlslcProbeFailed;
                },
            };
            const refusal = b.fmt("extension not supported: {s}", .{f.extension});
            if (std.mem.find(u8, out, refusal) == null) {
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

    /// Read the `-Dcuda` options and resolve them into `nvcc`'s command line
    /// and the toolkit's link inputs, as `ggml-cuda/CMakeLists.txt` and
    /// `ggml_cuda_fattn_vec_instances` (`ggml/cmake/common.cmake:60`) do.
    ///
    /// The defines are the ones CMake's `flags.make` gives the target, in its
    /// order: the 49 FlashAttention K/V switches and their summary,
    /// `GGML_CUDA_USE_GRAPHS` (on, because llama.cpp's top-level
    /// `CMakeLists.txt:171` changes ggml's default), and ggml's directory-wide
    /// `GGML_SCHED_MAX_COPIES`, `_GNU_SOURCE` and `_XOPEN_SOURCE=600`. That
    /// last one this build otherwise leaves out (see `linux_defines`); it is
    /// kept here because these objects come from CMake's own compilers, so
    /// nothing short of CMake's exact command line lets them match its objects
    /// byte for byte. `GGML_ALL_WARNINGS`'s `-Xcompiler` warnings are dropped;
    /// they change diagnostics only.
    ///
    /// - `b`: The build graph, for its options, allocator and process spawning.
    /// - `platform`: Must be Linux.
    /// - `target`: Must be the host's own OS and architecture: nvcc's host
    ///   compiler and the toolkit are the host's.
    /// - `optimize`: Picks CMake's per-configuration `CMAKE_CUDA_FLAGS_*`.
    /// - Returns: Null without `-Dcuda`; otherwise the configuration, or an
    ///   error for an unsupported target, a missing toolkit or host compiler,
    ///   or a malformed `-Dcuda-arch` or `-Dcuda-fa-quants`.
    fn configureCuda(b: *std.Build, platform: Platform, target: std.Target, optimize: std.lang.Optimize) !?Cuda {
        const enabled = b.option(bool, "cuda", "Build ggml's CUDA backend (Linux, host architecture; needs the CUDA toolkit and g++)") orelse false;
        const path_opt = b.option([]const u8, "cuda-path", "The CUDA toolkit (default: $CUDA_PATH, else /usr/local/cuda)");
        const arch_opt = b.option([]const []const u8, "cuda-arch", "GPU architectures in CMAKE_CUDA_ARCHITECTURES spelling, e.g. 121a-real (default: CMake's non-native list for the toolkit)");
        const fa_opt = b.option([]const u8, "cuda-fa-quants", "FlashAttention vector-kernel K-V types, as GGML_CUDA_FA_QUANTS: comma-separated <K>-<V>, or all (default: " ++ cuda_fa_quants_default ++ ")");
        if (!enabled) return null;

        const host = b.graph.host.result;
        if (platform != .linux or target.cpu.arch != host.cpu.arch or target.os.tag != host.os.tag) {
            log.err("-Dcuda builds for the host only, and only on Linux: nvcc's host compiler and the toolkit's libraries are the host's", .{});
            return error.UnsupportedTarget;
        }

        const env_path = b.graph.environ_map.get("CUDA_PATH");
        const cuda_path = path_opt orelse env_path orelse "/usr/local/cuda";
        const nvcc = b.pathJoin(&.{ cuda_path, "bin", "nvcc" });
        const version_out = switch (b.runFallible(&.{ nvcc, "--version" }, .{ .stderr_behavior = .ignore })) {
            .success => |stdout| stdout,
            else => {
                log.err("-Dcuda: {s} does not run; pass -Dcuda-path=<toolkit>", .{nvcc});
                return error.NvccNotFound;
            },
        };
        const toolkit = parseNvccVersion(version_out) orelse {
            log.err("-Dcuda: no 'release X.Y' in {s} --version", .{nvcc});
            return error.NvccNotFound;
        };
        const at_least = struct {
            fn f(v: [2]u32, major: u32, minor: u32) bool {
                return v[0] > major or (v[0] == major and v[1] >= minor);
            }
        }.f;

        // nvcc's default host compiler, whose runtime the objects need.
        const libstdcxx = try hostCompilerFile(b, "-print-file-name=libstdc++.so");
        const libgcc = try hostCompilerFile(b, "-print-libgcc-file-name");

        // ggml-cuda/CMakeLists.txt:43-68, the GGML_NATIVE=OFF defaults.
        var archs: std.ArrayList([]const u8) = .empty;
        if (arch_opt) |list| {
            try archs.appendSlice(b.allocator, list);
        } else {
            if (!at_least(toolkit, 13, 0)) try archs.appendSlice(b.allocator, &.{ "50-virtual", "61-virtual", "70-virtual" });
            try archs.appendSlice(b.allocator, &.{ "75-virtual", "80-virtual", "86-real" });
            if (at_least(toolkit, 11, 8)) try archs.appendSlice(b.allocator, &.{ "89-real", "90-virtual" });
            if (at_least(toolkit, 12, 8)) try archs.append(b.allocator, "120a-real");
            if (at_least(toolkit, 12, 9)) try archs.append(b.allocator, "121a-real");
        }

        var flags: std.ArrayList([]const u8) = .empty;
        const fa = try cudaFaQuants(b, fa_opt orelse cuda_fa_quants_default);
        try flags.appendSlice(b.allocator, fa.defines);
        try flags.appendSlice(b.allocator, &.{
            "-DGGML_CUDA_USE_GRAPHS",
            "-DGGML_SCHED_MAX_COPIES=4",
            "-D_GNU_SOURCE",
            "-D_XOPEN_SOURCE=600",
        });
        // CMAKE_CUDA_FLAGS_<CONFIG>, then CUDA_STANDARD from cxx_std_17
        // (ggml/src/CMakeLists.txt:619).
        try flags.appendSlice(b.allocator, if (optimize == .debug) &.{"-g"} else &.{ "-O3", "-DNDEBUG" });
        try flags.append(b.allocator, "-std=c++17");
        for (archs.items) |arch| try flags.append(b.allocator, try cudaGencode(b, arch));
        // ggml-cuda/CMakeLists.txt:196-262.
        try flags.appendSlice(b.allocator, &.{ "-use_fast_math", "-extended-lambda" });
        if (at_least(toolkit, 12, 8)) try flags.append(b.allocator, "-compress-mode=size");
        try flags.appendSlice(b.allocator, &.{ "-Xcompiler", "-Wno-pedantic" });

        return .{
            .nvcc = nvcc,
            .lib_dir = b.pathJoin(&.{ cuda_path, "lib64" }),
            .stubs_dir = b.pathJoin(&.{ cuda_path, "lib64", "stubs" }),
            .libstdcxx = libstdcxx,
            .libgcc = libgcc,
            .flags = flags.items,
            .fa_vec_sources = fa.sources,
        };
    }

    /// Ask g++, nvcc's default host compiler, where one of its runtime files is.
    ///
    /// - `b`: The build graph, for process spawning.
    /// - `query`: The `-print-...` flag naming the file.
    /// - Returns: The file's path; `error.HostCompilerNotFound` when g++ does
    ///   not run.
    fn hostCompilerFile(b: *std.Build, query: []const u8) ![]const u8 {
        return switch (b.runFallible(&.{ "g++", query }, .{ .stderr_behavior = .ignore })) {
            .success => |stdout| std.mem.trim(u8, stdout, " \r\n"),
            else => {
                log.err("-Dcuda: g++, nvcc's host compiler, does not run", .{});
                return error.HostCompilerNotFound;
            },
        };
    }

    /// Find the toolkit's version in `nvcc --version`'s output.
    ///
    /// - `out`: The output, whose last lines read `... release 13.0, V13.0.88`.
    /// - Returns: The major and minor version; null when none is found.
    fn parseNvccVersion(out: []const u8) ?[2]u32 {
        const key = "release ";
        const at = std.mem.find(u8, out, key) orelse return null;
        const rest = out[at + key.len ..];
        const end = std.mem.findAny(u8, rest, ", \n") orelse rest.len;
        var it = std.mem.splitScalar(u8, rest[0..end], '.');
        const major = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const minor = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        return .{ major, minor };
    }

    /// Translate one `CMAKE_CUDA_ARCHITECTURES` entry into the `nvcc` flag
    /// CMake generates for it, after CMake's own rewrite of a plain Blackwell
    /// `12X` into the architecture-specific `12Xa`
    /// (`ggml-cuda/CMakeLists.txt:92-104`), which its FP4 tensor-core
    /// instructions need.
    ///
    /// - `b`: The build graph, whose allocator owns the result.
    /// - `spec`: `<arch>`, `<arch>-real` or `<arch>-virtual`, e.g. `121a-real`.
    /// - Returns: `--generate-code=arch=compute_<a>,code=[...]`; an error for
    ///   an entry that is not of that form.
    fn cudaGencode(b: *std.Build, spec: []const u8) ![]const u8 {
        const dash = std.mem.findScalar(u8, spec, '-');
        var arch = spec[0 .. dash orelse spec.len];
        const kind = if (dash) |d| spec[d + 1 ..] else "";
        if (arch.len == 0 or !std.ascii.isDigit(arch[0])) {
            log.err("-Dcuda-arch: '{s}' is not <arch>[-real|-virtual]", .{spec});
            return error.InvalidCudaArch;
        }
        if (arch.len == 3 and std.mem.startsWith(u8, arch, "12") and std.ascii.isDigit(arch[2])) {
            arch = b.fmt("{s}a", .{arch});
        }
        const code = if (std.mem.eql(u8, kind, "real"))
            b.fmt("sm_{s}", .{arch})
        else if (std.mem.eql(u8, kind, "virtual"))
            b.fmt("compute_{s}", .{arch})
        else if (kind.len == 0)
            b.fmt("compute_{s},sm_{s}", .{ arch, arch })
        else {
            log.err("-Dcuda-arch: '{s}' is not <arch>[-real|-virtual]", .{spec});
            return error.InvalidCudaArch;
        };
        return b.fmt("--generate-code=arch=compute_{s},code=[{s}]", .{ arch, code });
    }

    /// What `cudaFaQuants` resolves `GGML_CUDA_FA_QUANTS` to.
    const CudaFa = struct {
        const Self = @This();
        /// `GGML_CUDA_FA_<K>_<V>=0|1` for every pair, then `GGML_CUDA_FA_QUANTS`.
        defines: []const []const u8,
        /// The vector-kernel instance per selected pair.
        sources: []const []const u8,
    };

    /// Resolve `GGML_CUDA_FA_QUANTS` as `ggml_cuda_fattn_vec_instances` does:
    /// `f16-f16` always, plus each listed pair, or every pair for `all`.
    ///
    /// CMake orders its 49 switches by the define's name when it writes
    /// `flags.make`, so they are sorted here too.
    ///
    /// - `b`: The build graph, whose allocator owns the result.
    /// - `spec`: Comma-separated `<K>-<V>` pairs, or `all`.
    /// - Returns: The defines and sources; an error for an unknown type or a
    ///   malformed pair.
    fn cudaFaQuants(b: *std.Build, spec: []const u8) !CudaFa {
        const quants = try std.ascii.allocLowerString(b.allocator, std.mem.trim(u8, spec, " "));
        if (quants.len == 0) {
            log.err("-Dcuda-fa-quants must not be empty", .{});
            return error.InvalidCudaFaQuants;
        }
        const all = std.mem.eql(u8, quants, "all");

        var selected: std.ArrayList([]const u8) = .empty;
        if (all) {
            for (cuda_fa_types) |v| for (cuda_fa_types) |k| try selected.append(b.allocator, b.fmt("{s}-{s}", .{ k, v }));
        } else {
            try selected.append(b.allocator, "f16-f16");
            var it = std.mem.splitScalar(u8, quants, ',');
            while (it.next()) |raw| {
                const pair = std.mem.trim(u8, raw, " ");
                const dash = std.mem.findScalar(u8, pair, '-') orelse {
                    log.err("-Dcuda-fa-quants: \"{s}\" is not \"all\" or a <type_K>-<type_V> combination", .{pair});
                    return error.InvalidCudaFaQuants;
                };
                for ([_][]const u8{ pair[0..dash], pair[dash + 1 ..] }) |t| {
                    for (cuda_fa_types) |known| {
                        if (std.mem.eql(u8, t, known)) break;
                    } else {
                        log.err("-Dcuda-fa-quants: unknown type \"{s}\" in \"{s}\"", .{ t, pair });
                        return error.InvalidCudaFaQuants;
                    }
                }
                for (selected.items) |s| {
                    if (std.mem.eql(u8, s, pair)) break;
                } else try selected.append(b.allocator, pair);
            }
        }

        var defines: std.ArrayList([]const u8) = .empty;
        for (cuda_fa_types) |v| for (cuda_fa_types) |k| {
            const pair = b.fmt("{s}-{s}", .{ k, v });
            const on = for (selected.items) |s| {
                if (std.mem.eql(u8, s, pair)) break true;
            } else false;
            const name = try std.ascii.allocUpperString(b.allocator, b.fmt("GGML_CUDA_FA_{s}_{s}", .{ k, v }));
            try defines.append(b.allocator, b.fmt("-D{s}={d}", .{ name, @intFromBool(on) }));
        };
        std.mem.sort([]const u8, defines.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        try defines.append(b.allocator, b.fmt("-DGGML_CUDA_FA_QUANTS=\"{s}\"", .{quants}));

        var sources: std.ArrayList([]const u8) = .empty;
        for (selected.items) |pair| {
            try sources.append(b.allocator, b.fmt("{s}/template-instances/fattn-vec-instance-{s}.cu", .{ cuda_dir, pair }));
        }
        return .{ .defines = defines.items, .sources = sources.items };
    }
};

/// Declare the build graph.
///
/// - `b`: The build graph the steps are registered on.
/// - Returns: Nothing on success; propagates target, SDK resolution, and
///   directory-read failures.
pub fn build(b: *std.Build) !void {
    const cfg = try Config.init(b);

    const ggml = try cfg.addGgml();
    const llama = try cfg.addLlama(ggml);

    const lib_step = b.step("lib", "Build ggml and libllama only");
    lib_step.dependOn(&b.addInstallArtifact(ggml, .{}).step);
    lib_step.dependOn(&b.addInstallArtifact(llama, .{}).step);

    const hash = cfg.addVendorHash();
    const mtmd = try cfg.addMtmd(ggml, llama, hash);

    // One slice of upstream's llama.xcframework: what `combine_static_libraries`
    // (build-xcframework.sh) force-loads into the framework's binary, less
    // ggml's internal split (see addGgml). The Makefile's `xcframework` target
    // links and bundles it, and builds its C++ runtime probe against the libc
    // file installed beside the libraries -- the one they were compiled with.
    const xcf_step = b.step("xcframework", "Build one llama.xcframework slice's libraries (ggml with BLAS, llama, mtmd, vendor-hash) for an Apple -Dtarget; needs -Dblas");
    if (!cfg.platform.isApple()) {
        xcf_step.dependOn(&b.addFail("xcframework: the target is not an Apple platform").step);
    } else if (!cfg.blas) {
        xcf_step.dependOn(&b.addFail("xcframework: upstream's Apple framework has the BLAS backend; pass -Dblas").step);
    } else {
        for ([_]*std.Build.Step.Compile{ ggml, llama, mtmd, hash }) |lib| {
            xcf_step.dependOn(&b.addInstallArtifact(lib, .{}).step);
        }
        xcf_step.dependOn(&b.addInstallFile(cfg.libc_file.?, "apple-libc.txt").step);
    }

    const exes = try cfg.addCli(ggml, llama, mtmd);
    const cli = exes.cli;
    b.installArtifact(cli);

    const cli_step = b.step("cli", "Build llama-cli");
    cli_step.dependOn(&b.addInstallArtifact(cli, .{}).step);

    // Not part of the default step: llama-cli is this build's deliverable.
    const server_step = b.step("server", "Build llama-server (with the web UI under -Dui)");
    server_step.dependOn(&b.addInstallArtifact(exes.server, .{}).step);

    const run = b.addRunArtifact(cli);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    const run_step = b.step("run", "Run llama-cli");
    run_step.dependOn(&run.step);
}
