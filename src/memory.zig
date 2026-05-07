//! Allocators for the host boundary and per-request scratch.
//!
//! Two allocators, two lifetimes:
//!
//! - `host_allocator` backs every buffer that crosses the boundary
//!   (host calls `malloc` / `free`). Lifetime is the host's call.
//! - `request_arena` is reset at the end of each `evaluate()`, so
//!   per-request scratch (parse trees, AST nodes, intermediate
//!   slices) never needs an explicit free.
//!
//! Don't mix the two. A pointer minted by one must be released by
//! the matching path. In particular, anything from the request arena
//! becomes dangling after `resetRequestArena()`; copy into the host
//! allocator first if it needs to outlive the call.
//!
//! Length-prefixed boundary buffers: proxy-wasm hosts call
//! `free(ptr)` without a length, so `hostMalloc` reserves
//! `@sizeOf(usize)` bytes in front of every block to record it.
//! The prefix is `usize`-aligned via `alignedAlloc`.

const std = @import("std");

/// Backs every buffer that crosses the host boundary. Lives for the
/// whole module.
pub const host_allocator: std.mem.Allocator = std.heap.wasm_allocator;

/// Per-request arena. Lazily created, reused across calls,
/// single-threaded (proxy-wasm runs one VM per thread).
var request_arena_state: ?std.heap.ArenaAllocator = null;

/// Returns the per-request arena. Pair with `resetRequestArena()`.
pub fn requestArena() *std.heap.ArenaAllocator {
    if (request_arena_state == null) {
        request_arena_state = std.heap.ArenaAllocator.init(host_allocator);
    }
    return &(request_arena_state.?);
}

/// Drop everything allocated since the last reset, keeping the
/// underlying pages. Steady-state evaluation calls this on every
/// request, so `memory.grow` only fires during warm-up.
pub fn resetRequestArena() void {
    if (request_arena_state) |*arena| {
        _ = arena.reset(.retain_capacity);
    }
}

// Length-prefixed alloc/free for the proxy-wasm boundary.

const len_prefix_bytes: usize = @sizeOf(usize);

/// Allocate `len` bytes that the host can later free by pointer
/// alone. Returns null on OOM or on `len + prefix` overflow.
pub fn hostMalloc(len: usize) ?[*]u8 {
    const total = std.math.add(usize, len, len_prefix_bytes) catch return null;
    const slice = host_allocator.alignedAlloc(u8, .of(usize), total) catch return null;
    const len_slot: *usize = @ptrCast(slice.ptr);
    len_slot.* = len;
    return slice.ptr + len_prefix_bytes;
}

/// Free a buffer returned by `hostMalloc`.
pub fn hostFree(ptr: [*]u8) void {
    const base = ptr - len_prefix_bytes;
    const base_aligned: [*]align(len_prefix_bytes) u8 = @ptrCast(@alignCast(base));
    const len_slot: *usize = @ptrCast(base_aligned);
    const len = len_slot.*;
    const total = len + len_prefix_bytes;
    host_allocator.free(base_aligned[0..total]);
}
