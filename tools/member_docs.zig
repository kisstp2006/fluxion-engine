// SPDX-License-Identifier: BSD-3-Clause

//! What the engine's doc comments say of its types' members, for the
//! scripts' compiler to show: run by the build over the engine's sources,
//! it writes a Zig file whose `list(Doc)` is every documented field, method
//! and type, keyed `Type.member` - a type by its `reflect_name`, or its own
//! name - and sorted by key, as `flux.Vm.Options.docs` wants.
//!
//! `member_docs <out.zig> <source.zig>...`

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const Entry = struct { key: []const u8, text: []const u8 };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: member_docs <out.zig> <source.zig>...\n", .{});
        return 64;
    }
    var entries: std.ArrayList(Entry) = .empty;
    for (args[2..]) |path| {
        const source = try std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(16 << 20), .of(u8), 0);
        var tree = try Ast.parse(arena, source, .zig);
        const stem = std.fs.path.stem(path);
        const own = reflectName(tree, tree.rootDecls()) orelse if (hasFields(tree, tree.rootDecls())) stem else null;
        try container(arena, tree, own, tree.rootDecls(), &entries);
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.less);

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("// Written by tools/member_docs.zig from the engine's doc comments.\n\n");
    try w.writeAll("pub fn list(comptime Doc: type) []const Doc {\n    return &[_]Doc{\n");
    var last: []const u8 = "";
    for (entries.items) |e| {
        // The first of a key said twice - two types of one name - is kept.
        if (std.mem.eql(u8, e.key, last)) continue;
        last = e.key;
        try w.writeAll("        .{ .key = \"");
        try escaped(w, e.key);
        try w.writeAll("\", .text = \"");
        try escaped(w, e.text);
        try w.writeAll("\" },\n");
    }
    try w.writeAll("    };\n}\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = out.written() });
    return 0;
}

/// The members of a container whose script name is `owner`, and the
/// containers declared in it.
fn container(arena: Allocator, tree: Ast, owner: ?[]const u8, members: []const Ast.Node.Index, out: *std.ArrayList(Entry)) !void {
    for (members) |node| {
        if (tree.fullVarDecl(node)) |v| {
            const init_node = v.ast.init_node.unwrap() orelse continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const inner = tree.fullContainerDecl(&buffer, init_node) orelse continue;
            const declared = tree.tokenSlice(v.ast.mut_token + 1);
            const name = reflectName(tree, inner.ast.members) orelse declared;
            if (try docOf(arena, tree, tree.firstToken(node))) |text| try out.append(arena, .{ .key = name, .text = text });
            try container(arena, tree, name, inner.ast.members, out);
            continue;
        }
        const type_name = owner orelse continue;
        var one: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&one, node)) |f| {
            if (f.visib_token == null) continue;
            const name_token = f.name_token orelse continue;
            if (try docOf(arena, tree, tree.firstToken(node))) |text| {
                try out.append(arena, .{ .key = try std.fmt.allocPrint(arena, "{s}.{s}", .{ type_name, tree.tokenSlice(name_token) }), .text = text });
            }
            continue;
        }
        if (tree.fullContainerField(node)) |f| {
            if (try docOf(arena, tree, tree.firstToken(node))) |text| {
                try out.append(arena, .{ .key = try std.fmt.allocPrint(arena, "{s}.{s}", .{ type_name, tree.tokenSlice(f.ast.main_token) }), .text = text });
            }
        }
    }
}

/// The name a container's `reflect_name` gives it, without the file it is
/// in: what a script calls it.
fn reflectName(tree: Ast, members: []const Ast.Node.Index) ?[]const u8 {
    for (members) |node| {
        const v = tree.fullVarDecl(node) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(v.ast.mut_token + 1), "reflect_name")) continue;
        const init_node = v.ast.init_node.unwrap() orelse return null;
        if (tree.nodeTag(init_node) != .string_literal) return null;
        const quoted = tree.tokenSlice(tree.nodeMainToken(init_node));
        const text = quoted[1 .. quoted.len - 1];
        const dot = std.mem.lastIndexOfScalar(u8, text, '.') orelse return text;
        return text[dot + 1 ..];
    }
    return null;
}

fn hasFields(tree: Ast, members: []const Ast.Node.Index) bool {
    for (members) |node| if (tree.fullContainerField(node) != null) return true;
    return false;
}

/// The doc comment before the token `first`, its lines joined, or null.
fn docOf(arena: Allocator, tree: Ast, first: Ast.TokenIndex) !?[]const u8 {
    var start = first;
    while (start > 0 and tree.tokenTag(start - 1) == .doc_comment) start -= 1;
    if (start == first) return null;
    var text: std.ArrayList(u8) = .empty;
    var t = start;
    while (t < first) : (t += 1) {
        var line = tree.tokenSlice(t)["///".len..];
        if (line.len > 0 and line[0] == ' ') line = line[1..];
        if (t > start) try text.append(arena, '\n');
        try text.appendSlice(arena, std.mem.trimEnd(u8, line, " \r"));
    }
    return text.items;
}

fn escaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        '\r' => {},
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
}
