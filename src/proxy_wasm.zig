//! proxy-wasm 0.2.1 shim. Spec: https://github.com/proxy-wasm/spec
//!
//! Lifecycle: `proxy_on_vm_start`, `proxy_on_configure`,
//! `proxy_on_context_create`, `proxy_on_request_headers`,
//! `proxy_on_request_body`, `proxy_on_response_headers`,
//! `proxy_on_done`. Request headers fire the "allow" target rule;
//! response headers fire "allow_response" with `{"response":{...}}`.
//! Body callbacks are no-ops; see ROADMAP.md.
//!
//! Configuration: the policy AST JSON arrives via
//! `proxy_on_configure`. We copy it into `host_allocator` so it
//! outlives any single request.
//!
//! Memory: host-supplied buffers (header values, header pairs, body
//! bytes, configuration bytes) are allocated by the host calling our
//! `malloc`. We `hostFree` them once consumed.

const std = @import("std");
const memory = @import("memory.zig");
const eval = @import("eval.zig");

// ABI version negotiation: one empty export per supported version.

export fn proxy_abi_version_0_2_1() void {}

// Status codes from host functions (proxy-wasm 0.2.1).

const status_ok: i32 = 0;

// Buffer / map type identifiers.

const buffer_type_http_request_body: i32 = 0;
const buffer_type_plugin_configuration: i32 = 7;

const map_type_request_headers: i32 = 0;
const map_type_response_headers: i32 = 2;

// Action returned by stream callbacks.

const action_continue: i32 = 0;
const action_pause: i32 = 1;

/// Lifecycle callbacks return `1` for success in proxy-wasm.
const result_ok: i32 = 1;

// Host imports.

extern "env" fn proxy_log(
    level: i32,
    msg_data: [*]const u8,
    msg_size: usize,
) i32;

// Return-data pointers are nullable: per the proxy-wasm spec, hosts
// may signal "no data" with a null pointer + zero size for empty or
// missing values.
extern "env" fn proxy_get_buffer_bytes(
    buffer_type: i32,
    start: usize,
    max_size: usize,
    return_buffer_data: *?[*]u8,
    return_buffer_size: *usize,
) i32;

extern "env" fn proxy_get_header_map_pairs(
    map_type: i32,
    return_buffer_data: *?[*]u8,
    return_buffer_size: *usize,
) i32;

extern "env" fn proxy_get_header_map_value(
    map_type: i32,
    key_data: [*]const u8,
    key_size: usize,
    return_value_data: *?[*]u8,
    return_value_size: *usize,
) i32;

extern "env" fn proxy_send_local_response(
    response_code: i32,
    response_code_details_data: [*]const u8,
    response_code_details_size: usize,
    response_body_data: [*]const u8,
    response_body_size: usize,
    additional_headers_map_data: [*]const u8,
    additional_headers_size: usize,
    grpc_status: i32,
) i32;

// Hosts skip the pointer when the matching size is 0, but the type
// system still demands a non-null `[*]const u8`.
const empty_ptr: [*]const u8 = @ptrFromInt(1);

// Module-global state. proxy-wasm runs one VM per thread, so a
// plain global is safe.

var configured_policy: ?[]u8 = null;

// Lifecycle exports.

export fn proxy_on_vm_start(_: i32, _: i32) i32 {
    return result_ok;
}

export fn proxy_on_configure(_: i32, configuration_size: i32) i32 {
    if (configuration_size <= 0) return result_ok;

    var data: ?[*]u8 = null;
    var data_size: usize = 0;
    const status = proxy_get_buffer_bytes(
        buffer_type_plugin_configuration,
        0,
        @intCast(configuration_size),
        &data,
        &data_size,
    );
    if (status != status_ok) return 0;

    const ptr = data orelse return 0;
    defer if (data_size > 0) memory.hostFree(ptr);

    if (configured_policy) |old| memory.host_allocator.free(old);
    configured_policy = memory.host_allocator.dupe(u8, ptr[0..data_size]) catch {
        configured_policy = null;
        return 0;
    };
    return result_ok;
}

export fn proxy_on_context_create(_: i32, _: i32) void {}

/// Evaluate against request headers. Deny short-circuits with a
/// 403; allow lets the chain proceed.
///
/// We don't pause to wait for the body: hosts clear `:method` /
/// `:path` from the header map before `proxy_on_request_body` fires,
/// so body-aware policies need per-request state plumbing.
/// Tracked in ROADMAP.md.
export fn proxy_on_request_headers(_: i32, _: i32, _: i32) i32 {
    const policy = configured_policy orelse return action_continue;
    if (!evaluateAt(map_type_request_headers, null, policy)) {
        denyWithStatus(403);
    }
    return action_continue;
}

/// No-op for now. Keeps the symbol resolvable when the filter
/// declares body interest.
export fn proxy_on_request_body(_: i32, _: i32, _: i32) i32 {
    return action_continue;
}

/// Evaluate against response status + headers under the
/// `allow_response` target rule. Deny replaces the response with a
/// 503; allow lets the upstream response through unchanged.
///
/// Request-side policy targeting "allow" runs in
/// `proxy_on_request_headers`; the two phases use disjoint target
/// rules so a single bundled policy can carry both.
export fn proxy_on_response_headers(_: i32, _: i32, _: i32) i32 {
    const policy = configured_policy orelse return action_continue;
    if (!evaluateResponseAt(policy)) {
        denyWithStatus(503);
    }
    return action_continue;
}

const response_target_rule: []const u8 = "allow_response";

fn evaluateResponseAt(policy: []const u8) bool {
    const arena = memory.requestArena();
    defer memory.resetRequestArena();
    const allocator = arena.allocator();

    const input_bytes = buildResponseInput(allocator) catch return false;
    return eval.evaluateWithTarget(arena, input_bytes, policy, response_target_rule) catch false;
}

/// Build `{"response":{"status":<int>,"headers":{...}}}` from the
/// response header map. `:status` is fetched individually for the
/// same wamr-host reasons that drive the request-side path.
fn buildResponseInput(allocator: std.mem.Allocator) ![]u8 {
    const status_str = (try readSingleHeader(allocator, map_type_response_headers, ":status")) orelse "";
    const headers = readAllHeaders(allocator, map_type_response_headers) catch &[_]HeaderPair{};

    const status_num = std.fmt.parseInt(i32, status_str, 10) catch -1;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"response\":{\"status\":");
    if (status_num < 0) {
        try buf.appendSlice(allocator, "null");
    } else {
        var num_buf: [16]u8 = undefined;
        const slice = std.fmt.bufPrint(&num_buf, "{d}", .{status_num}) catch unreachable;
        try buf.appendSlice(allocator, slice);
    }

    try buf.appendSlice(allocator, ",\"headers\":{");
    var first = true;
    for (headers) |h| {
        if (h.key.len > 0 and h.key[0] == ':') continue;
        if (!first) try buf.append(allocator, ',');
        first = false;
        try appendJsonString(allocator, &buf, h.key);
        try buf.append(allocator, ':');
        try appendJsonString(allocator, &buf, h.value);
    }
    try buf.appendSlice(allocator, "}}}");

    return try allocator.dupe(u8, buf.items);
}

export fn proxy_on_done(_: i32) i32 {
    return result_ok;
}

// Helpers.

/// Build an input from a header map (optionally with a body) and run
/// `eval.evaluate`. Errors fold into deny -- never default to allow
/// on failure.
fn evaluateAt(map_type: i32, body: ?[]const u8, policy: []const u8) bool {
    const arena = memory.requestArena();
    defer memory.resetRequestArena();
    const allocator = arena.allocator();

    const input_bytes = buildHeadersInput(allocator, map_type, body) catch return false;
    return eval.evaluate(arena, input_bytes, policy) catch false;
}

// ---------------------------------------------------------------------------
// Helpers: input synthesis
// ---------------------------------------------------------------------------

const HeaderPair = struct { key: []const u8, value: []const u8 };

/// Build the input JSON: `method`, `path`, `headers`, optional
/// `body`. `:method` and `:path` are fetched individually because
/// Envoy with the wamr runtime omits pseudo-headers from
/// `proxy_get_header_map_pairs`.
fn buildHeadersInput(
    allocator: std.mem.Allocator,
    map_type: i32,
    body: ?[]const u8,
) ![]u8 {
    const method = (try readSingleHeader(allocator, map_type, ":method")) orelse "";
    const path = (try readSingleHeader(allocator, map_type, ":path")) orelse "";
    const headers = readAllHeaders(allocator, map_type) catch &[_]HeaderPair{};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"method\":");
    try appendJsonString(allocator, &buf, method);
    try buf.appendSlice(allocator, ",\"path\":");
    try appendJsonString(allocator, &buf, path);

    try buf.appendSlice(allocator, ",\"headers\":{");
    var first = true;
    for (headers) |h| {
        // Skip pseudo-headers; we already promoted those.
        if (h.key.len > 0 and h.key[0] == ':') continue;
        if (!first) try buf.append(allocator, ',');
        first = false;
        try appendJsonString(allocator, &buf, h.key);
        try buf.append(allocator, ':');
        try appendJsonString(allocator, &buf, h.value);
    }
    try buf.append(allocator, '}');

    if (body) |b| {
        try buf.appendSlice(allocator, ",\"body\":");
        try appendJsonString(allocator, &buf, b);
    }

    try buf.append(allocator, '}');
    return try allocator.dupe(u8, buf.items);
}

/// Read one header value. `null` for missing keys (distinct from
/// present-but-empty).
fn readSingleHeader(
    allocator: std.mem.Allocator,
    map_type: i32,
    key: []const u8,
) !?[]const u8 {
    var data: ?[*]u8 = null;
    var data_size: usize = 0;
    const status = proxy_get_header_map_value(
        map_type,
        key.ptr,
        key.len,
        &data,
        &data_size,
    );
    if (status != status_ok) return null;
    // Hosts may signal "missing" with null + 0; do not free in that case.
    if (data_size == 0) return null;
    const ptr = data orelse return null;
    defer memory.hostFree(ptr);
    return try allocator.dupe(u8, ptr[0..data_size]);
}

/// Decode the proxy-wasm header-map serialisation:
///
/// ```text
///   u32_le N
///   (u32_le key_size, u32_le value_size) * N
///   (key, NUL, value, NUL) * N
/// ```
fn readAllHeaders(allocator: std.mem.Allocator, map_type: i32) ![]HeaderPair {
    var data: ?[*]u8 = null;
    var data_size: usize = 0;
    const status = proxy_get_header_map_pairs(map_type, &data, &data_size);
    if (status != status_ok) return &[_]HeaderPair{};
    if (data_size == 0) return &[_]HeaderPair{};
    const ptr = data orelse return &[_]HeaderPair{};
    defer memory.hostFree(ptr);

    if (data_size < 4) return error.InvalidHeaderMap;
    const buf = ptr[0..data_size];

    const num = std.mem.readInt(u32, buf[0..4], .little);
    if (num == 0) return &[_]HeaderPair{};

    // Checked arithmetic: on wasm32 `usize` is 32 bits, so a
    // sufficiently large `num` (or per-entry size) read from the
    // host buffer can wrap and bypass the bounds check below.
    const sizes_off: usize = 4;
    const sizes_len = std.math.mul(usize, num, 8) catch return error.InvalidHeaderMap;
    const sizes_end = std.math.add(usize, sizes_off, sizes_len) catch return error.InvalidHeaderMap;
    if (buf.len < sizes_end) return error.InvalidHeaderMap;

    var headers = try allocator.alloc(HeaderPair, num);
    var p: usize = sizes_end;
    var i: usize = 0;
    while (i < num) : (i += 1) {
        const so = sizes_off + i * 8;
        const key_size = std.mem.readInt(u32, buf[so .. so + 4][0..4], .little);
        const value_size = std.mem.readInt(u32, buf[so + 4 .. so + 8][0..4], .little);

        // (key_size + 1) + (value_size + 1), guarded.
        const kv = std.math.add(usize, key_size, value_size) catch return error.InvalidHeaderMap;
        const need = std.math.add(usize, kv, 2) catch return error.InvalidHeaderMap;
        const end = std.math.add(usize, p, need) catch return error.InvalidHeaderMap;
        if (end > buf.len) return error.InvalidHeaderMap;

        const key = try allocator.dupe(u8, buf[p .. p + key_size]);
        p += @as(usize, key_size) + 1; // skip NUL terminator
        const value = try allocator.dupe(u8, buf[p .. p + value_size]);
        p += @as(usize, value_size) + 1;
        headers[i] = .{ .key = key, .value = value };
    }

    return headers;
}

fn appendJsonString(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    s: []const u8,
) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0c => try buf.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    // RFC 8259 requires every <0x20 control byte to
                    // be escaped. Fall back to \u00XX for the ones
                    // without a short form.
                    var hex_buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try buf.appendSlice(allocator, hex);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

fn denyWithStatus(status: i32) void {
    _ = proxy_send_local_response(
        status,
        empty_ptr,
        0,
        empty_ptr,
        0,
        empty_ptr,
        0,
        -1,
    );
}
