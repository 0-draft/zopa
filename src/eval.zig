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
const builtins = @import("builtins.zig");
const json = @import("json.zig");

/// Default rule name when the caller doesn't override it.
pub const default_target_rule: []const u8 = "allow";

/// Recursion cap. See `docs/ast.md` for context.
const max_eval_depth: u32 = 32;

/// Stack-allocated buffer for builtin args. Larger calls fall back to
/// `nil` (deny in body position). Bump if a future builtin needs more.
const max_builtin_args: usize = 8;

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
///
/// Targets the default package ("") and the default rule ("allow").
/// Use `evaluateWithTarget` to pick a non-default rule (e.g.
/// "allow_response" or "allow_body"), or `evaluateAddressed` to
/// dispatch into a specific `package.rule` pair within a
/// `{"type":"modules", ...}` bundle.
pub fn evaluate(
    arena: *std.heap.ArenaAllocator,
    input_json: []const u8,
    ast_json: []const u8,
) !bool {
    return evaluateAddressed(arena, input_json, ast_json, "", default_target_rule);
}

/// Run a single evaluation against `target_rule` in the default
/// package (""). Used by the proxy-wasm shim to route phase-specific
/// callbacks: `allow_response` for the response phase and
/// `allow_body` for the body phase, while the request-headers phase
/// stays on `allow`.
pub fn evaluateWithTarget(
    arena: *std.heap.ArenaAllocator,
    input_json: []const u8,
    ast_json: []const u8,
    target_rule: []const u8,
) !bool {
    return evaluateAddressed(arena, input_json, ast_json, "", target_rule);
}

/// Run a single evaluation against `target_package.target_rule`. The
/// AST source can be either a single module or a `Modules` bundle;
/// the legacy single-module form is treated as `package = ""`.
pub fn evaluateAddressed(
    arena: *std.heap.ArenaAllocator,
    input_json: []const u8,
    ast_json: []const u8,
    target_package: []const u8,
    target_rule: []const u8,
) !bool {
    const allocator = arena.allocator();

    const input_value = try json.parse(allocator, input_json);
    const ast_value = try json.parse(allocator, ast_json);
    const bundle = try ast.buildModulesBundle(allocator, ast_value);

    return evalBundle(bundle, target_package, target_rule, input_value);
}

/// OR-combine evalModule across every module whose package matches.
/// Empty match set returns `false` (deny by default).
fn evalBundle(
    bundle: ast.Modules,
    target_package: []const u8,
    target_rule: []const u8,
    input: json.Value,
) !bool {
    for (bundle.modules) |module| {
        if (!std.mem.eql(u8, module.package, target_package)) continue;
        if (try evalModule(module, target_rule, input)) return true;
    }
    return false;
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
        .call => |c| switch (try evalCall(c, input, scope, depth + 1)) {
            .boolean => |b| b,
            .nil => false,
            else => true,
        },
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

/// Iterator handle returned by `iterItems`. Avoids allocating a
/// projected `Value` slice for object iteration; the consumer reads
/// elements through `len()` and `at()`.
const ItemIter = union(enum) {
    none,
    flat: []const json.Value,
    object_keys: []const json.Value.Member,
    object_values: []const json.Value.Member,

    fn len(self: ItemIter) usize {
        return switch (self) {
            .none => 0,
            .flat => |xs| xs.len,
            .object_keys, .object_values => |members| members.len,
        };
    }

    fn at(self: ItemIter, i: usize) json.Value {
        return switch (self) {
            .none => unreachable,
            .flat => |xs| xs[i],
            .object_keys => |members| .{ .string = members[i].key },
            .object_values => |members| members[i].value,
        };
    }
};

/// `some x in source: body`. True if the body holds for at least
/// one binding. A non-iterable source yields `false`.
fn evalSome(
    it: ast.Expr.Iter,
    input: json.Value,
    scope: ?*const Scope,
    depth: u32,
) HelperError!bool {
    if (depth >= max_eval_depth) return error.EvalTooDeep;
    const items = try iterItems(it.source, it.kind, input, scope, depth + 1);
    if (items == .none) return false;
    var i: usize = 0;
    while (i < items.len()) : (i += 1) {
        const child = Scope{ .parent = scope, .name = it.var_name, .bound = items.at(i) };
        if (try evalExprBool(it.body, input, &child, depth + 1)) return true;
    }
    return false;
}

/// `every x in source: body`. Vacuously true on an empty or
/// non-iterable source.
fn evalEvery(
    it: ast.Expr.Iter,
    input: json.Value,
    scope: ?*const Scope,
    depth: u32,
) HelperError!bool {
    if (depth >= max_eval_depth) return error.EvalTooDeep;
    const items = try iterItems(it.source, it.kind, input, scope, depth + 1);
    if (items == .none) return true;
    var i: usize = 0;
    while (i < items.len()) : (i += 1) {
        const child = Scope{ .parent = scope, .name = it.var_name, .bound = items.at(i) };
        if (!try evalExprBool(it.body, input, &child, depth + 1)) return false;
    }
    return true;
}

/// Resolve `source` to an iterable view. Returns `.none` for
/// non-iterable values; the caller decides the default.
fn iterItems(
    source: *const ast.Expr,
    kind: ast.Expr.IterKind,
    input: json.Value,
    scope: ?*const Scope,
    depth: u32,
) HelperError!ItemIter {
    const v = try resolveValue(source, input, scope, depth);
    return switch (v) {
        .array => |xs| .{ .flat = xs },
        .set => |xs| .{ .flat = xs },
        .object => |members| switch (kind) {
            .keys => .{ .object_keys = members },
            .values => .{ .object_values = members },
        },
        else => .none,
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
        // Missing paths in Rego are *undefined*. We surface that as
        // `Value.nil` so callers (compare, call, iterators) see a
        // type-mismatched value rather than an error -- a missing
        // ref inside `eq` should produce false, not -1. EvalTooDeep
        // and RefYieldsComposite still propagate.
        .ref => |path| resolveRef(input, scope, path) catch |err| switch (err) {
            error.PathNotFound, error.PathNotObject => json.Value.nil,
            else => return err,
        },
        .compare => |c| .{ .boolean = try evalCompare(c, input, scope, depth + 1) },
        .not => |inner| .{ .boolean = !(try evalExprBool(inner, input, scope, depth + 1)) },
        .some => |it| .{ .boolean = try evalSome(it, input, scope, depth + 1) },
        .every => |it| .{ .boolean = try evalEvery(it, input, scope, depth + 1) },
        .call => |c| try evalCall(c, input, scope, depth + 1),
    };
}

fn evalCall(
    c: ast.Expr.Call,
    input: json.Value,
    scope: ?*const Scope,
    depth: u32,
) HelperError!json.Value {
    if (depth >= max_eval_depth) return error.EvalTooDeep;
    if (c.args.len > max_builtin_args) return .nil;
    const b = builtins.lookup(c.name) orelse return .nil;
    var resolved: [max_builtin_args]json.Value = undefined;
    for (c.args, 0..) |arg, i| {
        resolved[i] = try resolveValue(arg, input, scope, depth + 1);
    }
    return builtins.dispatch(b, resolved[0..c.args.len]);
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

test "evaluate: missing ref inside compare denies (Rego undefined semantics)" {
    // `input.user.role == "admin"` against `{}` -- the ref resolves
    // to undefined; comparing undefined with a string is false, which
    // means deny in body position. zopa used to surface this as -1
    // (error) which diverged from Rego.
    const policy =
        "{\"type\":\"compare\",\"op\":\"eq\"," ++
        "\"left\":{\"type\":\"ref\",\"path\":[\"input\",\"user\",\"role\"]}," ++
        "\"right\":{\"type\":\"value\",\"value\":\"admin\"}}";
    try testing.expect(!(try run("{}", policy)));
    // Sanity: present + matching -> allow, present + mismatch -> deny.
    try testing.expect(try run("{\"user\":{\"role\":\"admin\"}}", policy));
    try testing.expect(!(try run("{\"user\":{\"role\":\"guest\"}}", policy)));
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

test "evaluate: call startswith on input.path" {
    const policy =
        "{\"type\":\"call\",\"name\":\"startswith\",\"args\":[" ++
        "{\"type\":\"ref\",\"path\":[\"input\",\"path\"]}," ++
        "{\"type\":\"value\",\"value\":\"/admin/\"}]}";
    try testing.expect(try run("{\"path\":\"/admin/users\"}", policy));
    try testing.expect(!(try run("{\"path\":\"/users\"}", policy)));
}

test "evaluate: call count compared with gt" {
    const policy =
        "{\"type\":\"gt\"," ++
        "\"left\":{\"type\":\"call\",\"name\":\"count\",\"args\":[" ++
        "{\"type\":\"ref\",\"path\":[\"input\",\"perms\"]}]}," ++
        "\"right\":{\"type\":\"value\",\"value\":2}}";
    try testing.expect(try run("{\"perms\":[\"r\",\"w\",\"x\"]}", policy));
    try testing.expect(!(try run("{\"perms\":[\"r\"]}", policy)));
}

test "evaluate: unknown builtin denies" {
    const policy =
        "{\"type\":\"call\",\"name\":\"made_up_fn\",\"args\":[" ++
        "{\"type\":\"value\",\"value\":1}]}";
    try testing.expect(!(try run("{}", policy)));
}

test "evaluate: every over object keys" {
    const policy =
        "{\"type\":\"every\",\"var\":\"k\",\"kind\":\"keys\"," ++
        "\"source\":{\"type\":\"ref\",\"path\":[\"input\",\"attrs\"]}," ++
        "\"body\":{\"type\":\"neq\"," ++
        "\"left\":{\"type\":\"ref\",\"path\":[\"k\"]}," ++
        "\"right\":{\"type\":\"value\",\"value\":\"internal\"}}}";
    try testing.expect(try run(
        "{\"attrs\":{\"team\":\"sre\",\"region\":\"us-east\"}}",
        policy,
    ));
    try testing.expect(!(try run(
        "{\"attrs\":{\"team\":\"sre\",\"internal\":\"yes\"}}",
        policy,
    )));
}

test "evaluate: some over object values" {
    const policy =
        "{\"type\":\"some\",\"var\":\"v\",\"kind\":\"values\"," ++
        "\"source\":{\"type\":\"ref\",\"path\":[\"input\",\"flags\"]}," ++
        "\"body\":{\"type\":\"eq\"," ++
        "\"left\":{\"type\":\"ref\",\"path\":[\"v\"]}," ++
        "\"right\":{\"type\":\"value\",\"value\":true}}}";
    try testing.expect(try run(
        "{\"flags\":{\"a\":false,\"b\":true,\"c\":false}}",
        policy,
    ));
    try testing.expect(!(try run(
        "{\"flags\":{\"a\":false,\"b\":false}}",
        policy,
    )));
}

test "evaluate: every over object defaults to keys" {
    const policy =
        "{\"type\":\"every\",\"var\":\"k\"," ++
        "\"source\":{\"type\":\"ref\",\"path\":[\"input\",\"m\"]}," ++
        "\"body\":{\"type\":\"neq\"," ++
        "\"left\":{\"type\":\"ref\",\"path\":[\"k\"]}," ++
        "\"right\":{\"type\":\"value\",\"value\":\"banned\"}}}";
    try testing.expect(try run("{\"m\":{\"x\":1,\"y\":2}}", policy));
    try testing.expect(!(try run("{\"m\":{\"x\":1,\"banned\":2}}", policy)));
}

fn runAddressed(input: []const u8, ast_src: []const u8, pkg: []const u8, rule: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    return evaluateAddressed(&arena, input, ast_src, pkg, rule);
}

test "modules bundle: address authz.allow vs audit.allow" {
    const policy =
        "{\"type\":\"modules\",\"modules\":[" ++
        "{\"type\":\"module\",\"package\":\"authz\",\"rules\":[" ++
        "{\"type\":\"rule\",\"name\":\"allow\",\"body\":[" ++
        "{\"type\":\"eq\"," ++
        "\"left\":{\"type\":\"ref\",\"path\":[\"input\",\"role\"]}," ++
        "\"right\":{\"type\":\"value\",\"value\":\"admin\"}}]}]}," ++
        "{\"type\":\"module\",\"package\":\"audit\",\"rules\":[" ++
        "{\"type\":\"rule\",\"name\":\"allow\",\"body\":[" ++
        "{\"type\":\"value\",\"value\":true}]}]}" ++
        "]}";

    // authz.allow fires only on admin.
    try testing.expect(try runAddressed("{\"role\":\"admin\"}", policy, "authz", "allow"));
    try testing.expect(!(try runAddressed("{\"role\":\"guest\"}", policy, "authz", "allow")));

    // audit.allow always fires regardless of role.
    try testing.expect(try runAddressed("{\"role\":\"guest\"}", policy, "audit", "allow"));
}

test "modules bundle: missing package -> deny" {
    const policy =
        "{\"type\":\"modules\",\"modules\":[" ++
        "{\"type\":\"module\",\"package\":\"authz\",\"rules\":[" ++
        "{\"type\":\"rule\",\"name\":\"allow\",\"body\":[" ++
        "{\"type\":\"value\",\"value\":true}]}]}" ++
        "]}";
    try testing.expect(!(try runAddressed("{}", policy, "missing", "allow")));
}

test "modules bundle: bare module wraps as package='' (backwards compat)" {
    const policy =
        "{\"type\":\"module\",\"rules\":[" ++
        "{\"type\":\"rule\",\"name\":\"allow\",\"body\":[" ++
        "{\"type\":\"value\",\"value\":true}]}]}";
    try testing.expect(try runAddressed("{}", policy, "", "allow"));
    // Same module via the default `evaluate` entry must still allow.
    try testing.expect(try run("{}", policy));
}

test "modules bundle: OR across two modules in same package" {
    const policy =
        "{\"type\":\"modules\",\"modules\":[" ++
        "{\"type\":\"module\",\"package\":\"authz\",\"rules\":[" ++
        "{\"type\":\"rule\",\"name\":\"allow\",\"body\":[" ++
        "{\"type\":\"eq\"," ++
        "\"left\":{\"type\":\"ref\",\"path\":[\"input\",\"role\"]}," ++
        "\"right\":{\"type\":\"value\",\"value\":\"admin\"}}]}]}," ++
        "{\"type\":\"module\",\"package\":\"authz\",\"rules\":[" ++
        "{\"type\":\"rule\",\"name\":\"allow\",\"body\":[" ++
        "{\"type\":\"eq\"," ++
        "\"left\":{\"type\":\"ref\",\"path\":[\"input\",\"role\"]}," ++
        "\"right\":{\"type\":\"value\",\"value\":\"editor\"}}]}]}" ++
        "]}";
    try testing.expect(try runAddressed("{\"role\":\"admin\"}", policy, "authz", "allow"));
    try testing.expect(try runAddressed("{\"role\":\"editor\"}", policy, "authz", "allow"));
    try testing.expect(!(try runAddressed("{\"role\":\"guest\"}", policy, "authz", "allow")));
}

fn runWithTarget(input: []const u8, ast_src: []const u8, target: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    return evaluateWithTarget(&arena, input, ast_src, target);
}

test "evaluateWithTarget: allow_response fires on 5xx" {
    const policy =
        "{\"type\":\"module\",\"rules\":[" ++
        "{\"type\":\"rule\",\"name\":\"allow_response\",\"default\":true," ++
        "\"value\":{\"type\":\"value\",\"value\":true}}," ++
        "{\"type\":\"rule\",\"name\":\"allow_response\",\"body\":[" ++
        "{\"type\":\"gte\"," ++
        "\"left\":{\"type\":\"ref\",\"path\":[\"input\",\"response\",\"status\"]}," ++
        "\"right\":{\"type\":\"value\",\"value\":500}}]," ++
        "\"value\":{\"type\":\"value\",\"value\":false}}" ++
        "]}";

    // 5xx responses fail the allow_response rule -> deny -> 503 replacement.
    try testing.expect(!(try runWithTarget(
        "{\"response\":{\"status\":500,\"headers\":{}}}",
        policy,
        "allow_response",
    )));

    // Non-5xx responses go through default (allow).
    try testing.expect(try runWithTarget(
        "{\"response\":{\"status\":200,\"headers\":{}}}",
        policy,
        "allow_response",
    ));
}

test "evaluateWithTarget: missing target rule -> deny" {
    const policy =
        "{\"type\":\"module\",\"rules\":[" ++
        "{\"type\":\"rule\",\"name\":\"allow\",\"body\":[" ++
        "{\"type\":\"value\",\"value\":true}]}]}";
    // Policy only has `allow`; `allow_response` doesn't exist.
    try testing.expect(!(try runWithTarget("{}", policy, "allow_response")));
}

test "evaluateWithTarget: allow target preserves default behaviour" {
    const policy = "{\"type\":\"value\",\"value\":true}";
    try testing.expect(try runWithTarget("{}", policy, "allow"));
}

test "evaluateWithTarget: allow_body fires on amount > limit" {
    const policy =
        "{\"type\":\"module\",\"rules\":[" ++
        "{\"type\":\"rule\",\"name\":\"allow_body\",\"default\":true," ++
        "\"value\":{\"type\":\"value\",\"value\":true}}," ++
        "{\"type\":\"rule\",\"name\":\"allow_body\",\"body\":[" ++
        "{\"type\":\"gt\"," ++
        "\"left\":{\"type\":\"ref\",\"path\":[\"input\",\"body\",\"amount\"]}," ++
        "\"right\":{\"type\":\"value\",\"value\":1000}}]," ++
        "\"value\":{\"type\":\"value\",\"value\":false}}" ++
        "]}";

    // Body amount over limit -> rule fires returning false -> deny.
    try testing.expect(!(try runWithTarget(
        "{\"body\":{\"amount\":5000},\"body_raw\":\"...\"}",
        policy,
        "allow_body",
    )));

    // Body amount under limit -> default rule wins -> allow.
    try testing.expect(try runWithTarget(
        "{\"body\":{\"amount\":50},\"body_raw\":\"...\"}",
        policy,
        "allow_body",
    ));
}

test "evaluateWithTarget: body_raw fallback when body parse fails" {
    // Policy targets body_raw directly so a non-JSON body is still
    // policy-checkable.
    const policy =
        "{\"type\":\"module\",\"rules\":[" ++
        "{\"type\":\"rule\",\"name\":\"allow_body\",\"body\":[" ++
        "{\"type\":\"eq\"," ++
        "\"left\":{\"type\":\"ref\",\"path\":[\"input\",\"body_raw\"]}," ++
        "\"right\":{\"type\":\"value\",\"value\":\"BLOCKED\"}}]," ++
        "\"value\":{\"type\":\"value\",\"value\":false}}," ++
        "{\"type\":\"rule\",\"name\":\"allow_body\",\"default\":true," ++
        "\"value\":{\"type\":\"value\",\"value\":true}}" ++
        "]}";
    try testing.expect(!(try runWithTarget(
        "{\"body\":null,\"body_raw\":\"BLOCKED\"}",
        policy,
        "allow_body",
    )));
    try testing.expect(try runWithTarget(
        "{\"body\":null,\"body_raw\":\"ok\"}",
        policy,
        "allow_body",
    ));
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
