# Response-side policies

Status: Proposed (draft PR, design doc only).
Tracking: ROADMAP.md → Near term.

## Motivation

Today zopa only evaluates against the request side. `proxy_on_response_headers`
is implemented as a no-op (`src/proxy_wasm.zig`). That means rules like
"never let an upstream `5xx` reach the client", "block responses that
leak `Server: <internal-build>`", or "redact responses for unauthenticated
users" cannot be enforced.

Use cases:

- Cap `5xx` bleed during incidents (return a generic `503` instead).
- Strip / mask response headers that leak infra details.
- Force `Cache-Control: no-store` on routes the policy marks as
  sensitive.
- Enforce that responses to unauthenticated requests don't carry a
  `Set-Cookie`.

## Goals

1. Add a separate target rule: `allow_response` (or `deny_response`).
   Convention to be locked in §Open questions.
1. Implement `proxy_on_response_headers`:
   - Build an input shape reflecting response status and headers.
   - Evaluate the AST against the response target rule.
   - On deny, replace the response (status + body + selected headers).
   - On allow, fall through.
1. Reuse the existing AST machinery. No new node types are needed for
   v1; only a new target rule and a new input shape.

## Non-goals

- Response body inspection. Same pattern as request-body, but tracked
  with `body-aware-policies.md`. v1 only sees status + headers.
- Mutating the response in place. v1 either lets it through or
  replaces it entirely (status + body + headers from the rule's
  `value`).
- Per-route policy targeting. The same policy applies everywhere the
  filter is configured.

## Design sketch

### Per-context state

Borrow the snapshot from `body-aware-policies.md`: a per-context store
that already holds request `:method` and `:path` so the response rule
can reason about request → response pairs.

```zig
const ResponseContext = struct {
    request: *RequestContext,  // shared with request-side eval
    status: u32 = 0,
    headers: ?json.Value = null,
};
```

### Input shape

```json
{
  "request": {
    "method":  "GET",
    "path":    "/admin/users",
    "headers": { "...": "..." }
  },
  "response": {
    "status":  500,
    "headers": { "server": "nginx/1.27", "...": "..." }
  }
}
```

### Replacement contract

When the response rule denies, zopa calls `proxy_send_local_response`
with parameters drawn from the rule's `value`:

```json
{
  "type": "value",
  "value": {
    "status":  503,
    "body":    "service temporarily unavailable",
    "headers": { "retry-after": "30" }
  }
}
```

A bare boolean `false` keeps current behavior (replace with a static
`503` and an empty body).

## API impact

- New target rule name `allow_response` joins the existing `allow`.
- Existing `allow` policies continue to work unchanged.
- New AST refs become valid: `input.request.*`, `input.response.*`.

## Test plan

- Node integration test: drive `evaluate` directly with a synthetic
  response-shaped input.
- Envoy integration test: extend `examples/envoy/run.sh` to assert a
  rewritten `503` when the upstream returns `500`.
- wasmtime test: walk through `proxy_on_request_headers` →
  `proxy_on_response_headers` and verify the request snapshot is still
  reachable from the response rule.

## Open questions

- Naming: `allow_response` (additive) vs `deny_response` (subtractive)?
  Picking the wrong default biases policies; revisit before
  implementation.
- Should the request snapshot be auto-cleared after the response phase,
  or kept until `proxy_on_done`? Memory vs late-binding tradeoff.
- How should the `value` shape diverge from a plain boolean? If we
  ever want partial mutation (just a header swap, not a full
  replacement) the schema needs a `mode` discriminator.
