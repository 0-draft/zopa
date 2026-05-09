//! Builtin function implementations for the `call` AST node.
//!
//! Each builtin takes a slice of pre-resolved `Value`s and returns a
//! `Value`. Type mismatches resolve to `Value.nil`, which the
//! evaluator treats as falsy / undefined -- matching Rego's
//! deny-friendly posture.
//!
//! v1 builtins are pure (no allocation). When the first
//! allocating builtin (e.g. `lower` / `upper`) lands, the signature
//! grows an arena allocator parameter.

const std = @import("std");
const json = @import("json.zig");

pub const Impl = *const fn (args: []const json.Value) json.Value;

const Builtin = struct {
    name: []const u8,
    arity: u32,
    impl: Impl,
};

const table = [_]Builtin{
    .{ .name = "startswith", .arity = 2, .impl = startswith },
    .{ .name = "endswith", .arity = 2, .impl = endswith },
    .{ .name = "contains", .arity = 2, .impl = contains },
    .{ .name = "count", .arity = 1, .impl = count },
};

/// Look up a builtin by name. Returns `null` if no entry matches.
pub fn lookup(name: []const u8) ?*const Builtin {
    for (&table) |*b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

/// Dispatch a resolved call. Arity is checked here; type checks live
/// inside each impl and degrade to `nil` when they fail.
pub fn dispatch(
    b: *const Builtin,
    args: []const json.Value,
) json.Value {
    if (args.len != b.arity) return .nil;
    return b.impl(args);
}

fn startswith(args: []const json.Value) json.Value {
    if (args[0] != .string or args[1] != .string) return .nil;
    return .{ .boolean = std.mem.startsWith(u8, args[0].string, args[1].string) };
}

fn endswith(args: []const json.Value) json.Value {
    if (args[0] != .string or args[1] != .string) return .nil;
    return .{ .boolean = std.mem.endsWith(u8, args[0].string, args[1].string) };
}

fn contains(args: []const json.Value) json.Value {
    if (args[0] != .string or args[1] != .string) return .nil;
    return .{ .boolean = std.mem.indexOf(u8, args[0].string, args[1].string) != null };
}

fn count(args: []const json.Value) json.Value {
    return switch (args[0]) {
        .array => |xs| .{ .number = @floatFromInt(xs.len) },
        .set => |xs| .{ .number = @floatFromInt(xs.len) },
        .object => |xs| .{ .number = @floatFromInt(xs.len) },
        .string => |s| .{ .number = @floatFromInt(s.len) },
        else => .nil,
    };
}

const testing = std.testing;

test "startswith: positive and negative" {
    const args_yes = [_]json.Value{
        .{ .string = "/admin/users" },
        .{ .string = "/admin/" },
    };
    const args_no = [_]json.Value{
        .{ .string = "/users" },
        .{ .string = "/admin/" },
    };
    try testing.expect(startswith(&args_yes).boolean);
    try testing.expect(!startswith(&args_no).boolean);
}

test "endswith / contains" {
    const ends_yes = [_]json.Value{ .{ .string = "api.internal" }, .{ .string = ".internal" } };
    const ends_no = [_]json.Value{ .{ .string = "api.external" }, .{ .string = ".internal" } };
    const con_yes = [_]json.Value{ .{ .string = "Mozilla/5.0 Bot" }, .{ .string = "Bot" } };
    const con_no = [_]json.Value{ .{ .string = "curl/8.0" }, .{ .string = "Bot" } };
    try testing.expect(endswith(&ends_yes).boolean);
    try testing.expect(!endswith(&ends_no).boolean);
    try testing.expect(contains(&con_yes).boolean);
    try testing.expect(!contains(&con_no).boolean);
}

test "count: array / set / object / string" {
    const arr = [_]json.Value{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } };
    const set = [_]json.Value{ .{ .string = "a" }, .{ .string = "b" } };
    const members = [_]json.Value.Member{
        .{ .key = "k1", .value = .{ .number = 1 } },
    };

    const arr_args = [_]json.Value{.{ .array = &arr }};
    const set_args = [_]json.Value{.{ .set = &set }};
    const obj_args = [_]json.Value{.{ .object = &members }};
    const str_args = [_]json.Value{.{ .string = "abcd" }};

    try testing.expectEqual(@as(f64, 3), count(&arr_args).number);
    try testing.expectEqual(@as(f64, 2), count(&set_args).number);
    try testing.expectEqual(@as(f64, 1), count(&obj_args).number);
    try testing.expectEqual(@as(f64, 4), count(&str_args).number);
}

test "type mismatch resolves to nil" {
    const bad = [_]json.Value{ .{ .number = 42 }, .{ .string = "/" } };
    try testing.expect(startswith(&bad) == .nil);
}

test "lookup + arity: unknown returns null, wrong arity yields nil" {
    try testing.expect(lookup("nope") == null);

    const b = lookup("startswith").?;
    const wrong = [_]json.Value{.{ .string = "x" }};
    try testing.expect(dispatch(b, &wrong) == .nil);
}
