// SPDX-License-Identifier: BSD-3-Clause

//! What a script reaches as `web`: pages and web APIs, asked without the
//! game waiting. Each call gives a task its answer ends: `await` it for the
//! answer, or keep it and `await` it later. A request that could not be
//! made or answered - no network, too long - is an error caught where it is
//! awaited; an answer with a status that is not a success is an answer,
//! with its `status`.
//!
//! ```
//! const reply = await web.get("https://api.example.com/scores?game=1") catch |err| {
//!     print("no scores:", err);
//!     return;
//! };
//! if (reply.ok) {
//!     const scores = reply.json();
//! }
//! const level = web.download("https://example.com/level2.bin", "user://levels/2.bin");
//! // each frame: bar.value = web.progress(level);
//! const bytes = await level catch 0;
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

const flux = @import("fluxion_script");
const net = @import("fluxion_net");
const App = @import("../App.zig");
const attr = @import("../reflect/attr.zig");

const Scripts = @import("script.zig").Scripts;
const FileAccess = @import("file_access.zig").FileAccess;

/// How a request asks: what `web.request` takes.
pub const Method = enum {
    get,
    post,
    put,
    patch,
    delete,
    head,
    options,

    fn http(m: Method) std.http.Method {
        return switch (m) {
            .get => .GET,
            .post => .POST,
            .put => .PUT,
            .patch => .PATCH,
            .delete => .DELETE,
            .head => .HEAD,
            .options => .OPTIONS,
        };
    }
};

const answer: flux.Pending = .of(WebResponse, true);
const bytes: flux.Pending = .{ .gives = .{ .builtin = .int }, .fails = true };

pub const WebAccess = struct {
    app: *App,

    pub const reflect_name = "Web";
    pub const reflect_opaque = true;
    pub const reflect_methods = .{
        .get = .{ attr.Params{ .names = &.{ "vm", "url", "timeout" } }, attr.defaults(.{30.0}), answer },
        .post = .{ attr.Params{ .names = &.{ "vm", "url", "body", "content_type", "timeout" } }, attr.defaults(.{ "application/json", 30.0 }), answer },
        .postForm = .{ attr.Params{ .names = &.{ "vm", "url", "values", "timeout" } }, attr.defaults(.{30.0}), answer },
        .request = .{ attr.Params{ .names = &.{ "vm", "method", "url", "headers", "body", "timeout" } }, attr.defaults(.{ "", 30.0 }), answer },
        .download = .{ attr.Params{ .names = &.{ "vm", "url", "path", "timeout" } }, attr.defaults(.{0.0}), bytes },
        .progress = .{ attr.Params{ .names = &.{ "vm", "task" } }, flux.Takes.builtin("task", .task) },
        .received = .{ attr.Params{ .names = &.{ "vm", "task" } }, flux.Takes.builtin("task", .task) },
        .cancel = .{ attr.Params{ .names = &.{ "vm", "task" } }, flux.Takes.builtin("task", .task) },
    };

    /// Ask for the page at `url`, giving up after `timeout` seconds.
    pub fn get(self: *WebAccess, vm: *flux.Vm, url: []const u8, timeout: f64) flux.Vm.Error!flux.Value {
        return ask(self, vm, .{ .url = url, .timeout_ms = milliseconds(timeout) }, false);
    }

    /// Send `body` to `url`, as `content_type` says it is: JSON, unless it
    /// says otherwise.
    pub fn post(self: *WebAccess, vm: *flux.Vm, url: []const u8, body: []const u8, content_type: []const u8, timeout: f64) flux.Vm.Error!flux.Value {
        return ask(self, vm, .{ .method = .POST, .url = url, .body = body, .content_type = content_type, .timeout_ms = milliseconds(timeout) }, false);
    }

    /// Send a map to `url` as a form fills one in - `a=1&b=two%20words`, its
    /// keys in order: what an API that takes big values by POST wants.
    pub fn postForm(self: *WebAccess, vm: *flux.Vm, url: []const u8, values: flux.Value, timeout: f64) flux.Vm.Error!flux.Value {
        const body = try formOf(vm, values);
        defer vm.gpa.free(body);
        return ask(self, vm, .{ .method = .POST, .url = url, .body = body, .content_type = "application/x-www-form-urlencoded", .timeout_ms = milliseconds(timeout) }, false);
    }

    /// Ask any way: the method, the headers as a map of text - `{"Authorization":
    /// "Bearer ..."}`, or `{}` for none - and a body.
    pub fn request(self: *WebAccess, vm: *flux.Vm, method: Method, url: []const u8, headers: flux.Value, body: []const u8, timeout: f64) flux.Vm.Error!flux.Value {
        var arena: std.heap.ArenaAllocator = .init(vm.gpa);
        defer arena.deinit();
        const given = try headersOf(vm, arena.allocator(), headers);
        return ask(self, vm, .{ .method = method.http(), .url = url, .headers = given, .body = body, .timeout_ms = milliseconds(timeout) }, false);
    }

    /// Save what is at `url` into the player's file at `path`: a task that
    /// ends with how many bytes it was. The file is whole or not there; an
    /// answer that is no success saves nothing, and fails with
    /// `HttpStatus`. No time limit unless `timeout` gives one.
    pub fn download(self: *WebAccess, vm: *flux.Vm, url: []const u8, path: []const u8, timeout: f64) flux.Vm.Error!flux.Value {
        FileAccess.writable(path) catch return failed(vm, "NotAllowed", "a download is saved under user://");
        const target = self.app.project.osPath(vm.gpa, path) catch |err| return failed(vm, @errorName(err), null);
        defer vm.gpa.free(target);
        return ask(self, vm, .{ .url = url, .save_to = target, .timeout_ms = milliseconds(timeout) }, true);
    }

    /// How far a request's answer has come, from 0 to 1: 1 once it is in,
    /// and -1 while its length is not known.
    pub fn progress(self: *WebAccess, vm: *flux.Vm, task: flux.Value) f64 {
        const waiting = waitingFor(vm, task) orelse return 1;
        const now = self.app.webProgress(waiting.id) orelse return 1;
        const total = now.total orelse return -1;
        if (total == 0) return 1;
        return @min(1.0, @as(f64, @floatFromInt(now.received)) / @as(f64, @floatFromInt(total)));
    }

    /// How many bytes of a request's answer have come.
    pub fn received(self: *WebAccess, vm: *flux.Vm, task: flux.Value) i64 {
        const waiting = waitingFor(vm, task) orelse return 0;
        const now = self.app.webProgress(waiting.id) orelse return 0;
        return @intCast(@min(now.received, std.math.maxInt(i64)));
    }

    /// Stop a request: what awaits it is given `error.Cancelled`.
    pub fn cancel(self: *WebAccess, vm: *flux.Vm, task: flux.Value) void {
        const waiting = waitingFor(vm, task) orelse return;
        self.app.cancelWebRequest(waiting.id);
    }
};

/// A request a script made, and the task its answer ends.
pub const Waiting = struct {
    id: net.Id,
    task: flux.Value,
    download: bool,
};

fn ask(self: *WebAccess, vm: *flux.Vm, given: net.Request, download: bool) flux.Vm.Error!flux.Value {
    const scripts: *Scripts = @ptrCast(@alignCast(vm.host.?));
    const id = self.app.webSend(given) catch |err| return failed(vm, @errorName(err), "the request was not sent");
    const task = try vm.newHostTask();
    try vm.pushRoot(task);
    defer vm.popRoot();
    try scripts.web_waiting.ensureUnusedCapacity(vm.gpa, 1);
    try vm.hold(task);
    scripts.web_waiting.appendAssumeCapacity(.{ .id = id, .task = task, .download = download });
    return task;
}

/// A task ended already with an error: a request that could not be made.
fn failed(vm: *flux.Vm, name: []const u8, why: ?[]const u8) flux.Vm.Error!flux.Value {
    const task = try vm.newHostTask();
    try vm.pushRoot(task);
    defer vm.popRoot();
    try vm.failTask(task, name, why);
    return task;
}

fn waitingFor(vm: *flux.Vm, task: flux.Value) ?Waiting {
    const scripts: *Scripts = @ptrCast(@alignCast(vm.host.?));
    for (scripts.web_waiting.items) |w| if (w.task.identical(task)) return w;
    return null;
}

fn milliseconds(seconds: f64) u32 {
    if (!(seconds > 0)) return 0;
    return @intFromFloat(@min(seconds * 1000, std.math.maxInt(u32)));
}

/// A map's keys and values as text, `a=1&b=two%20words`, the keys in order.
fn formOf(vm: *flux.Vm, values: flux.Value) flux.Vm.Error![]u8 {
    if (values.tag != .map) return vm.fail("a form is a map of its values, not {s}", .{@import("script.zig").typeName(values)});
    const url = vm.native_modules.get("url").?;
    const query = vm.get(url, "query").?;
    const text = try vm.call(query, &.{values});
    return vm.gpa.dupe(u8, text.as(flux.object.String).bytes());
}

fn headersOf(vm: *flux.Vm, a: Allocator, headers: flux.Value) flux.Vm.Error![]const net.Header {
    if (headers.tag == .null) return &.{};
    if (headers.tag != .map) return vm.fail("headers are a map of text, not {s}", .{@import("script.zig").typeName(headers)});
    var out: std.ArrayList(net.Header) = .empty;
    var it = headers.as(flux.object.Map).table.iterator();
    while (it.next()) |entry| {
        if (entry.key.tag != .string or entry.value.tag != .string) return vm.fail("a header's name and value are text", .{});
        const name = entry.key.as(flux.object.String).bytes();
        const value = entry.value.as(flux.object.String).bytes();
        if (name.len == 0 or std.mem.indexOfAny(u8, name, ":\r\n") != null or std.mem.indexOfAny(u8, value, "\r\n") != null) {
            return vm.fail("\"{s}\" is not a header a request can carry", .{name});
        }
        try out.append(a, .{ .name = try a.dupe(u8, name), .value = try a.dupe(u8, value) });
    }
    return out.items;
}

/// An answer, ended into the task that waited for it: a `Response`, the
/// bytes a download was, or the error it failed with.
pub fn finish(scripts: *Scripts, waiting: Waiting, done: *net.Done) flux.Vm.Error!void {
    const vm = scripts.vm;
    const response = done.result catch |err| {
        defer done.deinit();
        return vm.failTask(waiting.task, @errorName(err), done.reason);
    };
    if (waiting.download) {
        defer done.deinit();
        if (response.status < 200 or response.status >= 300) {
            var why: [64]u8 = undefined;
            return vm.failTask(waiting.task, "HttpStatus", std.fmt.bufPrint(&why, "the server answered {d}", .{response.status}) catch null);
        }
        return vm.finishTask(waiting.task, .int(@intCast(@min(response.size, std.math.maxInt(i64)))));
    }
    const ref = vm.gpa.create(WebResponse) catch |err| {
        done.deinit();
        return err;
    };
    ref.* = .{ .held = response };
    const made = vm.adoptHandle(ref) catch |err| {
        ref.held.deinit();
        vm.gpa.destroy(ref);
        return err;
    };
    try vm.pushRoot(made);
    defer vm.popRoot();
    try vm.finishTask(waiting.task, made);
}

/// An answer to a script's request: its `status` - 200, or 404 for a page
/// not there, which is an answer too - `ok` for a success, its `text`, and
/// `json()` and `header(name)`.
pub const WebResponse = struct {
    held: net.Response,

    pub const reflect_name = "Response";
    pub const reflect_opaque = true;
    pub const reflect_drop = release;
    pub const reflect_methods = .{
        .json = .{attr.Params{ .names = &.{"vm"} }},
        .header = .{attr.Params{ .names = &.{"name"} }},
    };

    /// The members a script reads as fields: see `script_host.zig`.
    pub const fields = [_]struct { name: []const u8, type: flux.Vm.BuiltinType, doc: []const u8 }{
        .{ .name = "status", .type = .int, .doc = "The answer's HTTP status: 200 for a success, 404 for a page not there." },
        .{ .name = "ok", .type = .bool, .doc = "Whether the status is a success: from 200 to 299." },
        .{ .name = "text", .type = .string, .doc = "The answer's body, as text." },
    };

    fn release(self: *WebResponse, gpa: Allocator) void {
        _ = gpa;
        self.held.deinit();
    }

    /// A field of the answer's, by name: see `fields`.
    pub fn member(self: *const WebResponse, vm: *flux.Vm, name: []const u8) flux.Vm.Error!?flux.Value {
        if (std.mem.eql(u8, name, "status")) return .int(self.held.status);
        if (std.mem.eql(u8, name, "ok")) return .boolean(self.held.status >= 200 and self.held.status < 300);
        if (std.mem.eql(u8, name, "text")) return try vm.string(self.held.body);
        return null;
    }

    /// The body read as JSON: maps, lists, strings, numbers, bools and null,
    /// or an error saying where the text is wrong.
    pub fn json(self: *WebResponse, vm: *flux.Vm) flux.Vm.Error!flux.Value {
        const module = vm.native_modules.get("json").?;
        const parse = vm.get(module, "parse").?;
        const text = try vm.string(self.held.body);
        try vm.pushRoot(text);
        defer vm.popRoot();
        return vm.call(parse, &.{text});
    }

    /// The value of the header of the name, whatever its case; null for one
    /// the answer did not have.
    pub fn header(self: *WebResponse, name: []const u8) ?[]const u8 {
        return self.held.header(name);
    }
};
