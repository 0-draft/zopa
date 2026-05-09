# Body-aware policies

Status: Proposed (draft PR, design doc only).
Tracking: ROADMAP.md → Near term.

## Motivation

Today zopa decides allow/deny purely from request headers. That covers
authn-style checks ("Authorization must match a SPIFFE pattern",
"method must be GET"), but it can't reason about the body.

Use cases that need body access:

- Reject requests where a JSON body field falls outside a numeric range
  (`input.body.amount > 10000` → deny).
- Block form posts that lack a CSRF nonce field.
- Refuse requests whose body matches a deny-listed substring (cheap WAF).

Currently `proxy_on_request_body` is a no-op (`src/proxy_wasm.zig`)
because by the time it fires, the request pseudo-headers (`:method`,
`:path`, `:authority`) have already been cleared from the header map.
A rule that references both `input.method` and `input.body.amount`
cannot be evaluated in either callback alone.

## Goals

1. In `proxy_on_request_headers`, snapshot `:method`, `:path`,
   `:authority`, and a configurable subset of request headers into
   per-context state.
1. Implement `proxy_on_request_body`:
   - Wait for `end_of_stream` (or buffer up to `max_body_bytes`).
   - Read the body via `proxy_get_buffer_bytes(BufferType.HttpRequestBody)`.
   - Build an `input` JSON containing snapshot + parsed body.
   - Run `evaluate` against the configured policy AST.
   - On deny, call `proxy_send_local_response(403)` and return Pause;
     on allow, return Continue.
1. Add an opt-in plugin config flag `require_body_eval: true` so hosts
   that don't need body inspection don't pay the buffering cost.

## Non-goals

- Streaming evaluation (tracked separately in
  `streaming-evaluation.md`). v1 buffers up to `max_body_bytes`.
- Mutating the body. zopa stays decision-only.
- Binary body parsers (protobuf, msgpack). v1 is JSON-only via
  `src/json.zig`. Other shapes get the raw byte slice as
  `input.body_raw`.

## Design sketch

### Per-context state

```zig
const RequestContext = struct {
    method: ?[]const u8 = null,
    path: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    headers: ?json.Value = null,
};
```

A small `AutoHashMap(u32, *RequestContext)` keyed by `context_id` lives
in `host_allocator`. Cleared on `proxy_on_done`.

### Input shape

```json
{
  "method": "POST",
  "path":   "/orders",
  "headers": { "...": "..." },
  "body":     { "amount": 250 },
  "body_raw": "{\"amount\":250}"
}
```

`body` is present iff the body parsed as JSON. `body_raw` is always
present once body eval ran.

### Buffer limit

Configurable via plugin config: `max_body_bytes` (default 64 KiB). When
exceeded, the policy sees `body: undefined` and `body_raw` truncated.
Mirrors Envoy's own `max_request_bytes` posture.

## API impact

- `proxy_on_request_body` returns `Action.Pause` until evaluation
  completes. Behavior change, but only when the host opts in via
  `require_body_eval: true`.
- New AST refs become valid: `input.body.<path>`, `input.body_raw`.

## Test plan

- Node integration test: drive `evaluate` with a synthetic input that
  includes `body`, verify `ref` resolves into the body subtree.
- Envoy integration test: extend `examples/envoy/run.sh` with a POST
  case that depends on a body field.
- wasmtime test: simulate `proxy_on_request_headers` then
  `proxy_on_request_body`, check the snapshot survives between
  callbacks.

## Open questions

- How to surface non-JSON bodies (`application/x-www-form-urlencoded`,
  binary protocols)? Either a small parser in `src/json.zig` or push
  the burden to the host through a richer input ABI.
- Right default for `max_body_bytes`? 64 KiB feels small for GraphQL,
  large for control-plane chatter.
- Should `require_body_eval` be inferred from the policy AST (does it
  reference `input.body`)? Static AST analysis would flip the flag
  ergonomically.
