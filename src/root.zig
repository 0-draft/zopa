//! Public library entry. Re-exports the modules another Zig project
//! would import via `@import("zopa")`.
//!
//! `proxy_wasm.zig` is intentionally not exported -- its `extern "env"`
//! declarations only resolve inside a wasm host, so it can't be linked
//! into a native build. The wasm artifact pulls it in directly from
//! `main.zig`.

pub const ast = @import("ast.zig");
pub const eval = @import("eval.zig");
pub const json = @import("json.zig");
pub const memory = @import("memory.zig");

pub const Value = json.Value;
pub const Module = ast.Module;
pub const Rule = ast.Rule;
pub const Expr = ast.Expr;

pub const evaluate = eval.evaluate;

test {
    // Discover and run tests in every re-exported module.
    const testing = @import("std").testing;
    testing.refAllDecls(@This());
    _ = ast;
    _ = eval;
    _ = json;
}
