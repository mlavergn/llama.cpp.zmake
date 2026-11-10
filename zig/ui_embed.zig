//! Build-time tool that embeds the web UI's built assets into `ui.h` and
//! `ui.cpp`, as upstream's `scripts/ui-assets.cmake` does in its
//! `emit_files` function.
//!
//! Upstream's CMake provisions the SvelteKit bundle (`npm ci` and
//! `npm run build`, or a download) and then writes every file of the
//! bundle into the two templates `tools/ui/ui.h.in` and `tools/ui/ui.cpp.in`
//! as C++ byte arrays. The Makefile here does the npm half (`make ui`); this
//! tool does the embedding, so `build.zig` needs no CMake.
//!
//! What it reproduces from `emit_files`:
//! - every file under the dist directory, `_gzip/` excluded, sorted by name;
//!   none at all when there is no `index.html`;
//! - `ui_validate_assets`'s check that the bundle has the files the UI
//!   needs at run time;
//! - with gzip on, each file gzip-compressed with a zero timestamp, served
//!   with `Content-Encoding: gzip`;
//! - per asset: its bytes, `sizeof`, an ETag that is the quoted SHA-256 of
//!   the embedded bytes, and a MIME type from `mime_from_ext`;
//! - `#cmakedefine LLAMA_UI_HAS_ASSETS 1`, `@N_ASSETS@`, `@ASSET_ARRAYS@`,
//!   `@ASSET_TABLE@` and `@USE_GZIP@` substituted as `configure_file(@ONLY)`
//!   does.
//!
//! The gzip bytes are this compressor's, not libarchive's, so the ETags of a
//! gzip build differ from a CMake build's. Nothing compares the two.
//!
//! Usage:
//!   ui_embed <dist-dir> <ui.h.in> <ui.cpp.in> <gzip: 0|1> <out ui.h> <out ui.cpp>

const std = @import("std");
const log = std.log.scoped(.llamacpp_ui_embed);

/// Logs at info and above, so the `@src()` entry traces, which are debug,
/// stay out of the build's output.
pub const std_options: std.Options = .{ .log_level = .info };

/// One `@NAME@` substitution.
const Var = struct {
    const Self = @This();
    name: []const u8,
    value: []const u8,
};

/// One file `ui_validate_assets` requires, and whether the bundle has it.
const RequiredAsset = struct {
    const Self = @This();
    label: []const u8,
    found: bool = false,
};

/// Embeds a built web UI bundle into upstream's `ui.h` and `ui.cpp` templates.
pub const UiEmbed = struct {
    const Self = @This();
    /// An arena: every allocation lives until the tool exits.
    allocator: std.mem.Allocator,
    io: std.Io,

    /// Create an embedder.
    ///
    /// - `allocator`: An arena every allocation is made from and never freed.
    /// - `io`: The I/O implementation files are read and written through.
    /// - Returns: The embedder.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        return .{ .allocator = allocator, .io = io };
    }

    /// Release the embedder; its arena belongs to the caller.
    pub fn deinit(self: *Self) void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        _ = self;
    }

    /// Read the bundle in `dist_path` and the two templates, and write the
    /// configured `ui.h` and `ui.cpp`.
    ///
    /// - `dist_path`: The SvelteKit `dist` directory.
    /// - `h_in_path`: `tools/ui/ui.h.in`.
    /// - `cpp_in_path`: `tools/ui/ui.cpp.in`.
    /// - `use_gzip_opt`: Whether assets are gzip-compressed, as `LLAMA_UI_GZIP`.
    /// - `h_out_path`: Where `ui.h` is written.
    /// - `cpp_out_path`: Where `ui.cpp` is written.
    /// - Returns: Nothing on success; `error.MissingAssets` when the bundle
    ///   lacks a required file, `error.EmptyAsset` for an empty file, and
    ///   read, write and allocation failures otherwise.
    pub fn embed(
        self: *const Self,
        dist_path: []const u8,
        h_in_path: []const u8,
        cpp_in_path: []const u8,
        use_gzip_opt: bool,
        h_out_path: []const u8,
        cpp_out_path: []const u8,
    ) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const arena = self.allocator;
        const io = self.io;
        const cwd = std.Io.Dir.cwd();
        const limit: std.Io.Limit = .limited(256 << 20);

        const h_in = try cwd.readFileAlloc(io, h_in_path, arena, limit);
        const cpp_in = try cwd.readFileAlloc(io, cpp_in_path, arena, limit);

        // file(GLOB_RECURSE ... RELATIVE), _gzip/ filtered out, list(SORT).
        var names: std.ArrayList([]const u8) = .empty;
        var dist = try cwd.openDir(io, dist_path, .{ .iterate = true });
        defer dist.close(io);
        const has_index = if (dist.access(io, "index.html", .{})) true else |_| false;
        if (has_index) {
            var walker = try dist.walk(arena);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind == .directory) continue;
                const rel = try arena.dupe(u8, entry.path);
                std.mem.replaceScalar(u8, rel, std.Io.Dir.path.sep, '/');
                if (std.mem.startsWith(u8, rel, "_gzip/")) continue;
                try names.append(arena, rel);
            }
            std.mem.sort([]const u8, names.items, {}, lessThan);
        }

        try validate(names.items);

        const use_gzip = use_gzip_opt and has_index;

        var arrays: std.Io.Writer.Allocating = .init(arena);
        var table: std.Io.Writer.Allocating = .init(arena);
        for (names.items, 0..) |name, idx| {
            const raw = try dist.readFileAlloc(io, name, arena, limit);
            const data = if (use_gzip) try self.gzip(raw) else raw;
            if (data.len == 0) {
                log.err("UI: empty file: {s}/{s}", .{ dist_path, name });
                return error.EmptyAsset;
            }

            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
            const etag = std.fmt.bytesToHex(digest, .lower);

            const w = &arrays.writer;
            try w.print("static const unsigned char asset_{d}[] = {{", .{idx});
            for (data) |byte| try w.print("0x{x:0>2},", .{byte});
            try w.writeAll("};\n");

            try table.writer.print(
                "    {{ \"{s}\", asset_{d}, sizeof(asset_{d}), \"\\\"{s}\\\"\", \"{s}\" }},\n",
                .{ name, idx, idx, &etag, mimeFromExt(name) },
            );
        }

        const n_assets = try arena.print("{d}", .{names.items.len});
        const vars = [_]Var{
            .{ .name = "N_ASSETS", .value = n_assets },
            .{ .name = "ASSET_ARRAYS", .value = arrays.written() },
            .{ .name = "ASSET_TABLE", .value = table.written() },
            .{ .name = "USE_GZIP", .value = if (use_gzip) "true" else "false" },
        };
        const has_assets = names.items.len > 0;

        try cwd.writeFile(io, .{ .sub_path = h_out_path, .data = try self.configure(h_in, &vars, has_assets) });
        try cwd.writeFile(io, .{ .sub_path = cpp_out_path, .data = try self.configure(cpp_in, &vars, has_assets) });
    }

    /// `configure_file(... @ONLY)` over `vars`, with `#cmakedefine
    /// LLAMA_UI_HAS_ASSETS 1` defined or undefined by `has_assets`.
    ///
    /// - `template`: The `.in` file's text.
    /// - `vars`: The `@NAME@` substitutions; an unknown `@NAME@` is left as is.
    /// - `has_assets`: Whether `LLAMA_UI_HAS_ASSETS` is defined.
    /// - Returns: The configured text, owned by the arena.
    fn configure(self: *const Self, template: []const u8, vars: []const Var, has_assets: bool) ![]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        const w = &out.writer;
        var lines = std.mem.splitScalar(u8, template, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try w.writeByte('\n');
            first = false;
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "#cmakedefine ")) {
                var words = std.mem.tokenizeAny(u8, trimmed["#cmakedefine ".len..], " \t");
                const name = words.next() orelse "";
                const rest = std.mem.trim(u8, words.rest(), " \t");
                if (std.mem.eql(u8, name, "LLAMA_UI_HAS_ASSETS") and has_assets) {
                    try w.print("#define {s}", .{name});
                    if (rest.len > 0) try w.print(" {s}", .{rest});
                } else {
                    try w.print("/* #undef {s} */", .{name});
                }
                continue;
            }
            var i: usize = 0;
            while (i < line.len) {
                if (line[i] == '@') {
                    if (std.mem.findScalarPos(u8, line, i + 1, '@')) |end| {
                        const key = line[i + 1 .. end];
                        if (lookup(vars, key)) |value| {
                            try w.writeAll(value);
                            i = end + 1;
                            continue;
                        }
                    }
                }
                try w.writeByte(line[i]);
                i += 1;
            }
        }
        return out.toOwnedSlice();
    }

    /// gzip with a zero timestamp, so identical inputs give identical bytes
    /// and stable ETags (upstream sets `SOURCE_DATE_EPOCH=0` for the same
    /// reason).
    ///
    /// - `raw`: The uncompressed file.
    /// - Returns: The gzip stream, owned by the arena.
    fn gzip(self: *const Self, raw: []const u8) ![]u8 {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const a = self.allocator;
        var out: std.Io.Writer.Allocating = try .initCapacity(a, raw.len / 2 + 64);
        const window = try a.alloc(u8, std.compress.flate.max_window_len);
        var c: std.compress.flate.Compress = try .init(&out.writer, window, .gzip, .default);
        try c.writer.writeAll(raw);
        try c.finish();
        return out.toOwnedSlice();
    }

    /// Byte order, as CMake's `list(SORT)` with its default `COMPARE STRING`.
    ///
    /// - `a`: The left-hand name.
    /// - `b`: The right-hand name.
    /// - Returns: Whether `a` sorts before `b`.
    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    /// The value `vars` substitutes for `@key@`.
    ///
    /// - `vars`: The substitutions.
    /// - `key`: The name between the `@`s.
    /// - Returns: The value, or null when `key` is not substituted.
    fn lookup(vars: []const Var, key: []const u8) ?[]const u8 {
        for (vars) |v| if (std.mem.eql(u8, v.name, key)) return v.value;
        return null;
    }

    /// `ui_validate_assets`: a non-empty bundle must hold every file the UI
    /// loads at run time. Each missing one is logged.
    ///
    /// - `names`: The bundle's relative paths.
    /// - Returns: Nothing when the bundle is empty or complete;
    ///   `error.MissingAssets` otherwise.
    fn validate(names: []const []const u8) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        if (names.len == 0) return;
        var need = [_]RequiredAsset{
            .{ .label = "index.html" },
            .{ .label = "manifest.webmanifest" },
            .{ .label = "sw.js" },
            .{ .label = "build.json" },
            .{ .label = "version.json" },
            .{ .label = "bundle[hash].js" },
            .{ .label = "bundle[hash].css" },
            .{ .label = "workbox[hash].js" },
        };
        for (names) |name| {
            const base = std.Io.Dir.path.basenamePosix(name);
            if (std.mem.eql(u8, base, "index.html")) need[0].found = true;
            if (std.mem.eql(u8, base, "manifest.webmanifest")) need[1].found = true;
            if (std.mem.eql(u8, base, "sw.js")) need[2].found = true;
            if (std.mem.eql(u8, base, "build.json")) need[3].found = true;
            if (std.mem.eql(u8, base, "version.json")) need[4].found = true;
            if (std.mem.startsWith(u8, base, "bundle") and std.mem.endsWith(u8, base, ".js")) need[5].found = true;
            if (std.mem.startsWith(u8, base, "bundle") and std.mem.endsWith(u8, base, ".css")) need[6].found = true;
            if (std.mem.startsWith(u8, base, "workbox") and std.mem.endsWith(u8, base, ".js")) need[7].found = true;
        }
        var missing = false;
        for (need) |n| if (!n.found) {
            log.err("UI: missing required asset: {s}", .{n.label});
            missing = true;
        };
        if (missing) return error.MissingAssets;
    }

    /// `mime_from_ext`: the MIME type for a file name's extension.
    ///
    /// - `name`: The asset's path.
    /// - Returns: The MIME type; `application/octet-stream` for an unknown
    ///   or missing extension.
    fn mimeFromExt(name: []const u8) []const u8 {
        const dot = std.mem.findScalarLast(u8, name, '.') orelse return "application/octet-stream";
        const ext = name[dot + 1 ..];
        const table = [_][2][]const u8{
            .{ "html", "text/html; charset=utf-8" },
            .{ "css", "text/css" },
            .{ "js", "application/javascript" },
            .{ "json", "application/json" },
            .{ "webmanifest", "application/manifest+json" },
            .{ "svg", "image/svg+xml" },
            .{ "png", "image/png" },
            .{ "jpg", "image/jpeg" },
            .{ "jpeg", "image/jpeg" },
            .{ "ico", "image/x-icon" },
            .{ "woff", "font/woff" },
            .{ "woff2", "font/woff2" },
        };
        for (table) |row| if (std.mem.eql(u8, ext, row[0])) return row[1];
        return "application/octet-stream";
    }
};

/// Embed the bundle the command line names into `ui.h` and `ui.cpp`.
///
/// - `init`: Process capabilities supplied by the runtime (allocator, I/O, args).
/// - Returns: Nothing on success; `error.BadUsage` on a wrong argument count,
///   and whatever `UiEmbed.embed` returns otherwise.
pub fn main(init: std.process.Init) !void {
    log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 7) {
        log.err("usage: ui_embed <dist-dir> <ui.h.in> <ui.cpp.in> <gzip: 0|1> <out ui.h> <out ui.cpp>", .{});
        return error.BadUsage;
    }

    var embedder = UiEmbed.init(arena, init.io);
    defer embedder.deinit();
    try embedder.embed(args[1], args[2], args[3], std.mem.eql(u8, args[4], "1"), args[5], args[6]);
}
