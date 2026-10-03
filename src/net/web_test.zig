// SPDX-License-Identifier: BSD-3-Clause

//! The web from a script, against a server on this machine: an answer
//! awaited, a form posted, a file downloaded, a failure caught. And what
//! else a launcher gives a game: its command line, the files beside the
//! program, the news of its focus and its end.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const http = std.http;

const App = @import("../App.zig");
const flux = @import("fluxion_script");

/// A server answering by the path asked: `/hello`, `/echo` (the body back),
/// `/file` (bytes to save), anything else a 404.
const Server = struct {
    io: Io,
    listener: Io.net.Server,
    port: u16 = 0,
    future: Io.Future(void) = .{ .any_future = null, .result = {} },

    fn start(s: *Server, io: Io) !void {
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        s.* = .{ .io = io, .listener = try address.listen(io, .{ .reuse_address = true }) };
        s.port = s.listener.socket.address.getPort();
        s.future = try io.concurrent(serve, .{s});
    }

    fn stop(s: *Server) void {
        _ = s.future.cancel(s.io);
        s.listener.deinit(s.io);
    }

    fn url(s: *const Server, buffer: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}{s}", .{ s.port, path }) catch unreachable;
    }

    fn serve(s: *Server) void {
        while (true) {
            const stream = s.listener.accept(s.io) catch return;
            defer stream.close(s.io);
            var in_buffer: [4096]u8 = undefined;
            var out_buffer: [4096]u8 = undefined;
            var reader = stream.reader(s.io, &in_buffer);
            var writer = stream.writer(s.io, &out_buffer);
            var server = http.Server.init(&reader.interface, &writer.interface);
            while (true) {
                var request = server.receiveHead() catch {
                    if (reader.err) |err| if (err == error.Canceled) return;
                    break;
                };
                answer(&request) catch {
                    if (reader.err) |err| if (err == error.Canceled) return;
                    if (writer.err) |err| if (err == error.Canceled) return;
                    break;
                };
            }
        }
    }

    fn answer(request: *http.Server.Request) !void {
        const target = request.head.target;
        var body: [256]u8 = undefined;
        var body_len: usize = 0;
        if (request.head.method.requestHasBody()) {
            var buffer: [512]u8 = undefined;
            const reader = try request.readerExpectContinue(&buffer);
            body_len = try reader.readSliceShort(&body);
        }
        if (std.mem.eql(u8, target, "/hello")) {
            try request.respond("{\"name\": \"hi\"}", .{ .extra_headers = &.{.{ .name = "x-test", .value = "yes" }} });
        } else if (std.mem.eql(u8, target, "/echo")) {
            try request.respond(body[0..body_len], .{});
        } else if (std.mem.eql(u8, target, "/file")) {
            try request.respond("0123456789", .{});
        } else {
            try request.respond("no", .{ .status = .not_found });
        }
    }
};

const script_text =
    \\var status = 0;
    \\var text = "";
    \\var name = "";
    \\var marked = "";
    \\var why = "";
    \\var size = 0;
    \\var fronts = 0;
    \\var quit = false;
    \\fn go(url: string) {
    \\    const reply = await web.get(url) catch |err| {
    \\        why = err.name;
    \\        return;
    \\    };
    \\    status = reply.status;
    \\    text = reply.text;
    \\    marked = reply.header("X-Test") orelse "";
    \\    if (reply.ok) {
    \\        name = reply.json()["name"];
    \\    }
    \\}
    \\fn form(url: string) {
    \\    const reply = await web.postForm(url, {"b": "two words", "a": 1}) catch return;
    \\    text = reply.text;
    \\}
    \\fn grab(url: string, path: string) {
    \\    size = await web.download(url, path) catch |err| {
    \\        why = err.name;
    \\        return;
    \\    };
    \\}
    \\fn front(now: bool) {
    \\    fronts += 1;
    \\}
    \\fn ending() {
    \\    quit = true;
    \\}
    \\fn listen() {
    \\    app.focus_changed.connect(front);
    \\    app.quitting.connect(ending);
    \\}
;

const Fixture = struct {
    tmp: testing.TmpDir,
    server: Server = undefined,
    app: *App,
    module: *flux.object.Module,
    buffer: [128]u8 = undefined,

    fn init(f: *Fixture) !void {
        f.tmp = testing.tmpDir(.{});
        errdefer f.tmp.cleanup();
        var root: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = root[0..try f.tmp.dir.realPath(testing.io, &root)];
        try f.tmp.dir.createDirPath(testing.io, "user");
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "beside.txt", .data = "left by a launcher" });
        const user = try std.fs.path.join(testing.allocator, &.{ path, "user" });
        defer testing.allocator.free(user);
        f.app = try App.create(testing.allocator, .{
            .headless = true,
            .io = testing.io,
            .root = path,
            .user_root = user,
            .program_root = path,
            .arguments = &.{ "game", "--level", "3", "--quiet", "--name=Ann" },
        });
        errdefer f.app.destroy();
        f.app.project.settings = .{ .network = .{ .allow_plain_http = true } };
        try f.app.useScripts(.{});
        const handle = try f.app.addScript("web.flux", script_text);
        f.module = f.app.scripts.?.moduleOf(handle).?;
        try f.server.start(testing.io);
    }

    fn deinit(f: *Fixture) void {
        f.app.destroy();
        f.server.stop();
        f.tmp.cleanup();
    }

    fn call(f: *Fixture, name: []const u8, args: []const flux.Value) !void {
        _ = try f.app.scripts.?.vm.callName(f.module, name, args);
    }

    fn string(f: *Fixture, bytes: []const u8) !flux.Value {
        return f.app.scripts.?.vm.string(bytes);
    }

    fn get(f: *Fixture, name: []const u8) flux.Value {
        return f.app.scripts.?.vm.get(f.module, name).?;
    }

    fn text(f: *Fixture, name: []const u8) []const u8 {
        return f.get(name).as(flux.object.String).bytes();
    }

    /// Frames, until `name` is no longer what it was, for five seconds.
    fn until(f: *Fixture, name: []const u8) !void {
        const before = f.get(name);
        var frames: usize = 0;
        while (frames < 1000) : (frames += 1) {
            _ = try f.app.step();
            if (!f.get(name).identical(before)) return;
            try testing.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.TestTimedOut;
    }
};

test "a script awaits the web: an answer, its text, a header and its JSON; a form; a download; a failure caught" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    try f.call("go", &.{try f.string(f.server.url(&f.buffer, "/hello"))});
    try f.until("status");
    try testing.expectEqual(@as(i64, 200), f.get("status").asInt());
    try testing.expectEqualStrings("{\"name\": \"hi\"}", f.text("text"));
    try testing.expectEqualStrings("yes", f.text("marked"));
    try testing.expectEqualStrings("hi", f.text("name"));

    try f.call("go", &.{try f.string(f.server.url(&f.buffer, "/nothing"))});
    try f.until("status");
    try testing.expectEqual(@as(i64, 404), f.get("status").asInt());

    try f.call("form", &.{try f.string(f.server.url(&f.buffer, "/echo"))});
    try f.until("text");
    try testing.expectEqualStrings("a=1&b=two%20words", f.text("text"));

    try f.call("grab", &.{ try f.string(f.server.url(&f.buffer, "/file")), try f.string("user://downloads/ten.bin") });
    try f.until("size");
    try testing.expectEqual(@as(i64, 10), f.get("size").asInt());
    const saved = try f.app.readText(testing.allocator, "user://downloads/ten.bin");
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("0123456789", saved);

    // A download that is no success saves nothing, and fails.
    try f.call("grab", &.{ try f.string(f.server.url(&f.buffer, "/nothing")), try f.string("user://downloads/none.bin") });
    try f.until("why");
    try testing.expectEqualStrings("HttpStatus", f.text("why"));
    try testing.expect(!f.app.fileExists("user://downloads/none.bin"));

    // Plain http where the project does not allow it.
    f.app.web.client.?.options.allow_plain_http = false;
    try f.call("go", &.{try f.string(f.server.url(&f.buffer, "/hello"))});
    try f.until("why");
    try testing.expectEqualStrings("NotSecure", f.text("why"));
}

test "a page's word: what its address gives, by name" {
    const app = try App.create(testing.allocator, .{ .headless = true, .page = &.{ "level=3", "gjapi_username=Ann", "quiet=", "odd" } });
    defer app.destroy();
    try testing.expectEqualStrings("3", app.pageParameter("level").?);
    try testing.expectEqualStrings("Ann", app.pageParameter("gjapi_username").?);
    try testing.expectEqualStrings("", app.pageParameter("quiet").?);
    try testing.expect(app.pageParameter("odd") == null);
    try testing.expect(app.pageParameter("missing") == null);
}

test "a launcher's word: the command line, the files beside the program, the focus and the end" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    try testing.expectEqualStrings("3", f.app.commandArgument("level").?);
    try testing.expectEqualStrings("", f.app.commandArgument("quiet").?);
    try testing.expectEqualStrings("Ann", f.app.commandArgument("name").?);
    try testing.expect(f.app.commandArgument("missing") == null);
    try testing.expect(f.app.commandArgument("game") == null);
    try testing.expect(f.app.pageParameter("level") == null);

    const beside = try f.app.readText(testing.allocator, "program://beside.txt");
    defer testing.allocator.free(beside);
    try testing.expectEqualStrings("left by a launcher", beside);

    try f.call("listen", &.{});
    f.app.input.focused = true;
    _ = try f.app.step();
    f.app.input.focused = false;
    _ = try f.app.step();
    try testing.expectEqual(@as(i64, 1), f.get("fronts").asInt());
    try f.app.stop();
    try testing.expect(f.get("quit").asBool());
}
