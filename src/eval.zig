//! Evaluator. Parses the input and AST onto the request arena,
//! projects the AST into `Module`, then walks the rules.
//!
//! Every recursive helper bumps a depth counter capped at
//! `max_eval_depth`. Hitting the cap is reported as
//! `error.EvalTooDeep`; the export wrapper turns that into `-1` and
//! the proxy-wasm shim treats it as deny.
//!
//! `some` and `every` push a `Scope` frame on the C stack while
//! their body runs. Refs check the scope chain before falling back
//! to the input root, so no heap traffic is needed for bindings.

const std = @import("std");
const ast = @import("ast.zig");
const json = @import("json.zig");

/// Default rule name when the caller doesn't override it.
pub const default_target_rule: []const u8 = "allow";

/// Recursion cap. See `docs/ast.md` for context.
const max_eval_depth: u32 = 32;

/// Explicit error set; needed because the recursive helpers form a
/// cycle that the compiler can't infer through.
const HelperError = error{
    EvalTooDeep,
    PathNotObject,
    PathNotFound,
    RefYieldsComposite,
};

/// Scope frame for variables introduced by `some` / `every`.
const Scope = struct {
    parent: ?*const Scope = null,
    name: []const u8,
    bound: json.Value,
};

/// Run a single evaluation. `arena` must already be initialised; this
/// function neither inits nor resets it -- that is the caller's job.
pub fn evaluate(
    arena: *std.heap.ArenaAllocator,
    input_json: []const u8,
    ast_json: []const u8,
) !bool {
    const allocator = arena.allocator();

    const input_value = try json.parse(allocator, input_json);
    const ast_value = try json.parse(allocator, ast_json);
    const module = try ast.buildModule(allocator, ast_value);

    return evalModule(module, default_target_rule, input_value);
}

/// Walk every rule named `target`. A `default` rule's value becomes
/// the fallback; the first regular rule whose body holds wins.
fn evalModule(module: ast.Module, target: []const u8, input: json.Value) !bool {
    var fallback: bool = false;
    var have_fallback: bool = false;

    for (module.rules) |rule| {
        if (!std.mem.eql(u8, rule.name, target)) continue;

        if (rule.is_default) {
            if (rule.value) |vex| {
                // Mirror the truthiness rule used for regular rules
                // below: only `false` and `nil` are falsy; any other
                // value (including non-booleans) is truthy.
                const v = try resolveValue(vex, input, null, 0);
                fallback = switch (v) {
                    .boolean => |b| b,
                    .nil => false,
                    else => true,
                };
                have_fallback = true;
            }
            continue;
        }

        if (try evalBody(rule.body, input)) {
            const decision = if (rule.value) |vex|
                try resolveValue(vex, input, null, 0)
            else
                json.Value{ .boolean = true };
            return switch (decision) {
                .boolean => |b| b,
                else => true,
            };
        }
    }

    return if (have_fallback) fallback else false;
}

/// Bodies are an implicit AND of expressions.
fn evalBody(body: []const *const ast.Expr, input: json.Value) !bool {
    for (body) |expr| {
        if (!try evalExprBool(expr, input, null, 0)) return false;
    }
    return true;
}

fn evalExprBool(
    expr: *const ast.Expr,
    input: json.Value,
    scope: ?*const Scope,
    depth: u32,
) HelperError!bool {
    if (depth >= max_eval_depth) return error.EvalTooDeep;
    return switch (expr.*) {
        .value => |v| switch (v) {
            .boolean => |b| b,
            .nil => false,
            else => true,
        },
        .ref => |path| blk: {
            // Missing paths are undefined in Rego; we treat that as
            // `false` so incomplete input falls through to deny.
            const v = resolveRef(input, scope, path) catch break :blk false;
            break :blk switch (v) {
                .boolean => |b| b,
                .nil => false,
                else => true,
            };
        },
        .compare => |c| try evalCompare(c, input, scope, depth + 1),
        .not => |inner| !(try evalExprBool(inner, input, scope, depth + 1)),
        .some => |it| try evalSome(it, input, scope, depth + 1),
        .every => |it| try evalEvery(it, input, scope, depth + 1),
    };
}

fn evalCompare(
    c: ast.Expr.Compare,
    input: json.Value,
    scope: ?*const Scope,
    depth: u32,
) HelperError!bool {
    if (depth >= max_eval_depth) return error.EvalTooDeep;
    const lhs = try resolveValue(c.left, input, scope, depth + 1);
    const rhs = try resolveValue(c.right, input, scope, depth + 1);
    return switch (c.op) {
        .eq => json.valueEquals(lhs, rhs),
        .neq => !json.valueEquals(lhs, rhs),
        .lt, .lte, .gt, .gte => blk: {
            const ord = json.valueCompare(lhs, rhs) orelse break :blk false;
            break :blk switch (c.op) {
                .lt => ord == .lt,
                .lte => ord != .gt,
                .gt => ord == .gt,
                .gte => ord != .lt,
                else => unreachable,
            };
        },
    };
}

/// `some x in source: body`. True if the body holds for at least
/// one binding.
fn evalSome(
    it: ast.Expr.Iter,
    input: json.Value,
    scope: ?*const Scope,
    depth: u32,
) HelperError!bool {
    if (depth >= max_eval_depth) return error.EvalTooDeep;
    const items = try iterItems(it.source, input, scope, depth + 1) orelse return false;
    for (items) |item| {
        const child = Scope{ .parent = scope, .name = it.var_name, .bound = item };
        if (try evalExprBool(it.body, input, &child, depth + 1)) return true;
    }
    return false;
}

/// `every x in source: body`. Vacuously true on an empty source.
fn evalEvery(
    it: ast.Expr.Iter,
    input: json.Value,
    scope: ?*const Scope,
    depth: u32,
) HelperError!bool {
    if (depth >= max_eval_depth) return error.EvalTooDeep;
    const items = try iterItems(it.source, input, scope, depth + 1) orelse return true;
    for (items) |item| {
        const child = Scope{ .parent = scope, .name = it.var_name, .bound = item };
        if (!try evalExprBool(it.body, input, &child, depth + 1)) return false;
    }
    return true;
}

/// Pull iterable items out of `source`. Returns `null` for
/// non-iterable values; the caller decides the default.
fn iterItems(
    source: *const ast.Expr,
    input: json.Value,
    scope: ?*const Scope,
    depth: u32,
) HelperError!?[]const json.Value {
    const v = try resolveValue(source, input, scope, depth);
    return switch (v) {
        .array => |xs| xs,
        .set => |xs| xs,
        else => null,
    };
}

/// Resolve an expression to a `Value`. Boolean operators fold into
/// `Value.boolean` so they're usable in value position (rule values,
/// compare operands).
fn resolveValue(
    expr: *const ast.Expr,
    input: json.Value,
    scope: ?*const Scope,
    depth: u32,
) HelperError!json.Value {
    if (depth >= max_eval_depth) return error.EvalTooDeep;
    return switch (expr.*) {
        .value => |v| v,
        .ref => |path| try resolveRef(input, scope, path),
        .compare => |c| .{ .boolean = try evalCompare(c, input, scope, depth + 1) },
        .not => |inner| .{ .boolean = !(try evalExprBool(inner, input, scope, depth + 1)) },
        .some => |it| .{ .boolean = try evalSome(it, input, scope, depth + 1) },
        .every => |it| .{ .boolean = try evalEvery(it, input, scope, depth + 1) },
    };
}

/// Resolve a ref. The first segment is matched against the scope
/// chain; the rest walk the bound value. A leading `"input"` segment
/// skips the chain and goes straight to the input root.
fn resolveRef(
    input: json.Value,
    scope: ?*const Scope,
    path: []const []const u8,
) HelperError!json.Value {
    if (path.len == 0) return error.PathNotFound;

    if (std.mem.eql(u8, path[0], "input")) {
        return json.lookupPath(input, path);
    }

    var cursor = scope;
    while (cursor) |frame| : (cursor = frame.parent) {
        if (std.mem.eql(u8, frame.name, path[0])) {
            return walkValue(frame.bound, path[1..]);
        }
    }

    // No matching binding -- treat as a plain input ref.
    return json.lookupPath(input, path);
}

/// Walk `path` through `value`. Returns the leaf as-is; the only
/// failure modes are "non-object on the way down" and "key missing".
fn walkValue(value: json.Value, path: []const []const u8) HelperError!json.Value {
    var cur = value;
    for (path) |segment| {
        switch (cur) {
            .object => |members| {
                var found = false;
                for (members) |m| {
                    if (std.mem.eql(u8, m.key, segment)) {
                        cur = m.value;
                        found = true;
                        break;
                    }
                }
                if (!found) return error.PathNotFound;
            },
            else => return error.PathNotObject,
        }
    }
    return cur;
}

// Tests.

const testing = std.testing;

fn run(input: []const u8, ast_src: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    return evaluate(&arena, input, ast_src);
}

test "evaluate: literal true allows" {
    try testing.expect(try run("{}", "{\"type\":\"value\",\"value\":true}"));
}

test "evaluate: literal false denies" {
    try testing.expect(!(try run("{}", "{\"type\":\"value\",\"value\":false}")));
}

test "evaluate: ref equality" {
    const policy =
        "{\"type\":\"eq\"," ++
        "\"left\":{\"type\":\"ref\",\"path\":[\"input\",\"role\"]}," ++
        "\"right\":{\"type\":\"value\",\"value\":\"admin\"}}";
    try testing.expect(try run("{\"role\":\"admin\"}", policy));
    try testing.expect(!(try run("{\"role\":\"guest\"}", policy)));
}

test "evaluate: missing ref denies" {
    try testing.expect(!(try run("{}", "{\"type\":\"ref\",\"path\":[\"input\",\"missing\"]}")));
}

test "evaluate: default rule when no other rule matches" {
    const policy =
        "{\"type\":\"module\",\"rules\":[" ++
        "{\"type\":\"rule\",\"name\":\"allow\",\"default\":true," ++
        "\"value\":{\"type\":\"value\",\"value\":false}}," ++
        "{\"type\":\"rule\",\"name\":\"allow\",\"body\":[" ++
        "{\"type\":\"eq\"," ++
        "\"left\":{\"type\":\"ref\",\"path\":[\"input\",\"role\"]}," ++
        "\"right\":{\"type\":\"value\",\"value\":\"admin\"}}]}" ++
        "]}";
    try testing.expect(!(try run("{\"role\":\"guest\"}", policy)));
    try testing.expect(try run("{\"role\":\"admin\"}", policy));
}

test "evaluate: every+some over arrays" {
    const policy =
        "{\"type\":\"every\",\"var\":\"req\"," ++
        "\"source\":{\"type\":\"ref\",\"path\":[\"input\",\"required\"]}," ++
        "\"body\":{\"type\":\"some\",\"var\":\"have\"," ++
        "\"source\":{\"type\":\"ref\",\"path\":[\"input\",\"granted\"]}," ++
        "\"body\":{\"type\":\"eq\"," ++
        "\"left\":{\"type\":\"ref\",\"path\":[\"have\"]}," ++
        "\"right\":{\"type\":\"ref\",\"path\":[\"req\"]}}}}";
    try testing.expect(try run(
        "{\"required\":[\"r\",\"w\"],\"granted\":[\"r\",\"w\",\"x\"]}",
        policy,
    ));
    try testing.expect(!(try run(
        "{\"required\":[\"r\",\"d\"],\"granted\":[\"r\",\"w\"]}",
        policy,
    )));
}

test "evaluate: depth guard fires" {
    var policy: std.ArrayList(u8) = .empty;
    defer policy.deinit(testing.allocator);
    var i: u32 = 0;
    while (i < max_eval_depth + 4) : (i += 1) {
        try policy.appendSlice(testing.allocator, "{\"type\":\"not\",\"expr\":");
    }
    try policy.appendSlice(testing.allocator, "{\"type\":\"value\",\"value\":true}");
    i = 0;
    while (i < max_eval_depth + 4) : (i += 1) {
        try policy.append(testing.allocator, '}');
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.EvalTooDeep, evaluate(&arena, "{}", policy.items));
}
