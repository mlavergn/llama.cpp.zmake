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
const flate = std.compress.flate;

/// Entry point: reads the bundle and the templates, writes `ui.h` and `ui.cpp`.
///
/// Parameters:
/// - `init`: process capabilities supplied by the runtime (allocator, IO, args).
///
/// Return: nothing on success; `error.BadUsage` on a wrong argument count,
/// `error.MissingAssets` when the bundle lacks a required file,
/// `error.EmptyAsset` for an empty file, and read, write and allocation
/// failures otherwise.
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 7) return error.BadUsage;

    const dist_path = args[1];
    const use_gzip_opt = std.mem.eql(u8, args[4], "1");
    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(256 << 20);

    const h_in = try cwd.readFileAlloc(io, args[2], arena, limit);
    const cpp_in = try cwd.readFileAlloc(io, args[3], arena, limit);

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
            std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
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
        const data = if (use_gzip) try gzip(arena, raw) else raw;
        if (data.len == 0) {
            std.log.err("UI: empty file: {s}/{s}", .{ dist_path, name });
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

    const n_assets = try std.fmt.allocPrint(arena, "{d}", .{names.items.len});
    const vars = [_]Var{
        .{ .name = "N_ASSETS", .value = n_assets },
        .{ .name = "ASSET_ARRAYS", .value = arrays.written() },
        .{ .name = "ASSET_TABLE", .value = table.written() },
        .{ .name = "USE_GZIP", .value = if (use_gzip) "true" else "false" },
    };
    const has_assets = names.items.len > 0;

    try cwd.writeFile(io, .{ .sub_path = args[5], .data = try configure(arena, h_in, &vars, has_assets) });
    try cwd.writeFile(io, .{ .sub_path = args[6], .data = try configure(arena, cpp_in, &vars, has_assets) });
}

/// Byte order, as CMake's `list(SORT)` with its default `COMPARE STRING`.
fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// One `@NAME@` substitution.
const Var = struct { name: []const u8, value: []const u8 };

/// `configure_file(... @ONLY)` over `vars`, with `#cmakedefine
/// LLAMA_UI_HAS_ASSETS 1` defined or undefined by `has_assets`.
///
/// Parameters:
/// - `a`: allocates the result.
/// - `template`: the `.in` file's text.
/// - `vars`: the `@NAME@` substitutions; an unknown `@NAME@` is left as is.
/// - `has_assets`: whether `LLAMA_UI_HAS_ASSETS` is defined.
///
/// Return: the configured text, owned by `a`.
fn configure(a: std.mem.Allocator, template: []const u8, vars: []const Var, has_assets: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
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
                if (std.mem.indexOfScalarPos(u8, line, i + 1, '@')) |end| {
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

fn lookup(vars: []const Var, key: []const u8) ?[]const u8 {
    for (vars) |v| if (std.mem.eql(u8, v.name, key)) return v.value;
    return null;
}

/// `ui_validate_assets`: a non-empty bundle must hold every file the UI
/// loads at run time.
///
/// Parameters:
/// - `names`: the bundle's relative paths.
///
/// Return: `error.MissingAssets` naming what is absent on stderr.
fn validate(names: []const []const u8) !void {
    if (names.len == 0) return;
    const Need = struct { label: []const u8, found: bool = false };
    var need = [_]Need{
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
        const base = std.fs.path.basenamePosix(name);
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
        std.log.err("UI: missing required asset: {s}", .{n.label});
        missing = true;
    };
    if (missing) return error.MissingAssets;
}

/// gzip with a zero timestamp, so identical inputs give identical bytes and
/// stable ETags (upstream sets `SOURCE_DATE_EPOCH=0` for the same reason).
///
/// Parameters:
/// - `a`: allocates the result.
/// - `raw`: the uncompressed file.
///
/// Return: the gzip stream, owned by `a`.
fn gzip(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(a, raw.len / 2 + 64);
    const window = try a.alloc(u8, flate.max_window_len);
    var c: flate.Compress = try .init(&out.writer, window, .gzip, .default);
    try c.writer.writeAll(raw);
    try c.finish();
    return out.toOwnedSlice();
}

/// `mime_from_ext`: the MIME type for a file name's extension.
fn mimeFromExt(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "application/octet-stream";
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
