// SPDX-License-Identifier: BSD-3-Clause

//! A call made by name, with values for its arguments, on whatever
//! fluxion-reflect describes: what a console does with a line it has read,
//! and what a signal's connection does to the method it names.

const std = @import("std");

const reflect = @import("fluxion_reflect");

/// Call a method of `receiver`'s type by name. An error the call returns is
/// returned from here; otherwise what it gives back is written into
/// `result`, when there is one, converted as numbers are.
pub fn call(receiver: reflect.Value, name: []const u8, args: []const reflect.Value, result: ?reflect.Value) anyerror!void {
    const method = receiver.type.method(name) orelse return error.NoSuchMethod;
    const returns = method.type.info.function.return_type;
    if (returns.kind != .error_union) return receiver.call(name, args, result);

    // Taken whole - error or value - so that an error comes back as one,
    // rather than going into `result` or nowhere.
    var held: [128]u8 align(16) = undefined;
    if (returns.size > held.len or returns.alignment > 16) return error.Unsupported;
    const returned: reflect.Value = .init(returns, &held);
    try receiver.call(name, args, returned);
    const code = returns.info.error_union.ops.code(&held);
    if (code != 0) return @errorFromInt(@as(std.meta.Int(.unsigned, @bitSizeOf(anyerror)), @intCast(code)));
    if (result) |into| try into.convertFrom(returned.unwrap().?);
}
