//! Build-time tool that prepares one Metal kernel source for embedding.
//!
//! Replaces the `cat`/`sed` pipeline that llama.cpp's CMake uses when
//! `GGML_METAL_EMBED_LIBRARY` is on. The Metal driver compiles the shader
//! source at runtime, so nothing here invokes `xcrun metal`; the job is purely
//! to flatten a kernel and its headers into one self-contained MSL file, then
//! emit an assembly stub that pulls that file into the binary.
//!
//! Usage:
//!   metal_embed <kind> <out.metal> <out.s> <ggml-common.h> <ggml-metal-impl.h>
//!               <kernels/common.h> <kernels/dequantize.h> <kernels/quantize.h>
//!               <kernels/fa_common.metal> <kernels/fa_vec_common.metal>
//!               <kernels/{kind}.metal>

const std = @import("std");
const log = std.log.scoped(.llamacpp_metal_embed);

/// Logs at info and above. The `@src()` entry traces are debug, and the build
/// runs this tool once per kernel; at the Debug default they would fill the
/// build's output.
pub const std_options: std.Options = .{ .log_level = .info };

/// Header includes that are inlined rather than resolved by a compiler, and so
/// must be stripped from the flattened output.
const stripped_includes = [_][]const u8{
    "#include \"common.h\"",
    "#include \"dequantize.h\"",
    "#include \"quantize.h\"",
    "#include \"fa_common.metal\"",
    "#include \"fa_vec_common.metal\"",
};

/// Sentinel in `kernels/dequantize.h` marking where `ggml-common.h` belongs.
const common_sentinel = "__embed_ggml-common.h__";

/// Include directive marking where `ggml-metal-impl.h` belongs.
const impl_include = "#include \"ggml-metal-impl.h\"";

/// How many input files one kernel is flattened from: the fields of `Sources`.
const input_count = 8;

/// The texts one kernel is flattened from, in the order the command line
/// names them.
const Sources = struct {
    const Self = @This();
    ggml_common: []const u8,
    metal_impl: []const u8,
    kernels_common: []const u8,
    dequantize: []const u8,
    quantize: []const u8,
    fa_common: []const u8,
    fa_vec_common: []const u8,
    kernel: []const u8,
};

/// Flattens Metal kernels and writes the stubs that embed them.
pub const MetalEmbed = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    io: std.Io,

    /// Create an embedder.
    ///
    /// - `allocator`: Allocates every buffer the embedder reads or writes.
    /// - `io`: The I/O implementation files are read and written through.
    /// - Returns: The embedder.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        return .{ .allocator = allocator, .io = io };
    }

    /// Release the embedder; it owns nothing beyond its calls.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        _ = self;
    }

    /// Flatten one kernel into `out_metal` and write the assembly stub that
    /// `.incbin`s it into `out_asm`.
    ///
    /// - `kind`: The kernel's name, which names its symbols.
    /// - `out_metal`: Where the flattened MSL source is written.
    /// - `out_asm`: Where the assembly stub is written.
    /// - `paths`: The input files, in the order `Sources` lists them.
    /// - Returns: Nothing on success; read, write and allocation failures.
    pub fn embed(self: *const Self, kind: []const u8, out_metal: []const u8, out_asm: []const u8, paths: *const [input_count][]const u8) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const cwd = std.Io.Dir.cwd();
        const limit: std.Io.Limit = .limited(64 << 20);

        var texts: [input_count][]u8 = undefined;
        var n_read: usize = 0;
        defer for (texts[0..n_read]) |t| self.allocator.free(t);
        for (paths, 0..) |path, i| {
            texts[i] = try cwd.readFileAlloc(self.io, path, self.allocator, limit);
            n_read += 1;
        }
        const sources = Sources{
            .ggml_common = texts[0],
            .metal_impl = texts[1],
            .kernels_common = texts[2],
            .dequantize = texts[3],
            .quantize = texts[4],
            .fa_common = texts[5],
            .fa_vec_common = texts[6],
            .kernel = texts[7],
        };

        const flat = try self.flatten(&sources);
        defer self.allocator.free(flat);
        try cwd.writeFile(self.io, .{ .sub_path = out_metal, .data = flat });

        const stub = try self.incbinStub(kind, out_metal);
        defer self.allocator.free(stub);
        try cwd.writeFile(self.io, .{ .sub_path = out_asm, .data = stub });
    }

    /// The kernel with the headers it includes inlined, as one MSL source.
    ///
    /// Only the headers this kernel actually includes are prepended.
    /// Prepending all of them would compile, but every kernel would carry the
    /// full dequantize and quantize tables, and the driver recompiles this
    /// text on every load.
    ///
    /// - `sources`: The kernel and every header it may include.
    /// - Returns: The flattened source, owned by the caller.
    fn flatten(self: *const Self, sources: *const Sources) ![]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const gpa = self.allocator;
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(gpa);

        try joined.appendSlice(gpa, sources.kernels_common);
        try joined.append(gpa, '\n');
        if (std.mem.find(u8, sources.kernel, "#include \"dequantize.h\"") != null) {
            try joined.appendSlice(gpa, sources.dequantize);
            try joined.append(gpa, '\n');
        }
        if (std.mem.find(u8, sources.kernel, "#include \"quantize.h\"") != null) {
            try joined.appendSlice(gpa, sources.quantize);
            try joined.append(gpa, '\n');
        }
        // The flash-attention kernels share two bodies since v0.6.0, prepended
        // in the order ggml-metal/CMakeLists.txt:107-114 tests for them.
        if (std.mem.find(u8, sources.kernel, "#include \"fa_common.metal\"") != null) {
            try joined.appendSlice(gpa, sources.fa_common);
            try joined.append(gpa, '\n');
        }
        if (std.mem.find(u8, sources.kernel, "#include \"fa_vec_common.metal\"") != null) {
            try joined.appendSlice(gpa, sources.fa_vec_common);
            try joined.append(gpa, '\n');
        }
        try joined.appendSlice(gpa, sources.kernel);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        var lines = std.mem.splitScalar(u8, joined.items, '\n');
        while (lines.next()) |line| {
            // `#pragma once` is meaningless once the headers are concatenated,
            // and would make the driver reject the combined source.
            if (std.mem.find(u8, line, "#pragma once") != null) continue;

            if (containsAny(line, &stripped_includes)) continue;

            // The two inlined headers are substituted in place, so a reader of
            // the generated file sees them where the original expected them.
            if (std.mem.find(u8, line, common_sentinel) != null) {
                try out.appendSlice(gpa, sources.ggml_common);
                try out.append(gpa, '\n');
                continue;
            }
            if (std.mem.find(u8, line, impl_include) != null) {
                try out.appendSlice(gpa, sources.metal_impl);
                try out.append(gpa, '\n');
                continue;
            }

            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
        }
        return out.toOwnedSlice(gpa);
    }

    /// The assembly stub that `.incbin`s a flattened kernel between its
    /// `ggml_metallib_<kind>_{start,end}` symbols.
    ///
    /// `-` is not legal in a C identifier, so the symbol stem replaces it. The
    /// Mach-O section name is capped at 16 characters, so all kinds share one
    /// section and only the global symbols vary.
    ///
    /// - `kind`: The kernel's name.
    /// - `metal_path`: The flattened source the stub includes.
    /// - Returns: The stub's text, owned by the caller.
    fn incbinStub(self: *const Self, kind: []const u8, metal_path: []const u8) ![]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const gpa = self.allocator;
        const sym = try gpa.dupe(u8, kind);
        defer gpa.free(sym);
        std.mem.replaceScalar(u8, sym, '-', '_');

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.print(gpa,
            \\.section __DATA,__ggml_metallib
            \\.globl _ggml_metallib_{s}_start
            \\_ggml_metallib_{s}_start:
            \\.incbin "{s}"
            \\.globl _ggml_metallib_{s}_end
            \\_ggml_metallib_{s}_end:
            \\
        , .{ sym, sym, metal_path, sym, sym });
        return out.toOwnedSlice(gpa);
    }

    /// Whether `line` contains any of `needles`.
    ///
    /// - `line`: The text to search; borrowed for the call only.
    /// - `needles`: Substrings to look for.
    /// - Returns: True when at least one needle occurs in `line`.
    fn containsAny(line: []const u8, needles: []const []const u8) bool {
        for (needles) |needle| {
            if (std.mem.find(u8, line, needle) != null) return true;
        }
        return false;
    }
};

/// Flatten the kernel the command line names and write its `.metal` and `.s`.
///
/// - `init`: Process capabilities supplied by the runtime (allocator, I/O, args).
/// - Returns: Nothing on success; `error.BadUsage` on a wrong argument count,
///   and read, write and allocation failures otherwise.
pub fn main(init: std.process.Init) !void {
    log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // The program name, the kind, the two outputs, then the inputs.
    if (args.len != 4 + input_count) {
        log.err("usage: metal_embed <kind> <out.metal> <out.s> and {d} input files; got {d} arguments", .{ input_count, args.len - 1 });
        return error.BadUsage;
    }

    var embedder = MetalEmbed.init(init.gpa, init.io);
    defer embedder.deinit();
    try embedder.embed(args[1], args[2], args[3], args[4..][0..input_count]);
}
