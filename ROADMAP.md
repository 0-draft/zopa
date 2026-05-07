# Roadmap

Plans are best-effort. Priorities shift with adoption signals; if
something here matters to you, open an issue.

## Near term

- **Body-aware policies.** Snapshot request headers in
  `proxy_on_request_headers`, surface them to `proxy_on_request_body`
  so policies can reference both `input.method` and `input.body`.
  Today the body callback is a no-op because pseudo-headers are
  already gone by the time it fires.
- **Response-side policies.** A separate target rule (`deny_response`,
  `allow_response`) plus an input shape that reflects response
  headers and status. Currently `proxy_on_response_headers` is a
  no-op.
- **Compiled-policy benchmark.** Numbers worth quoting against OPA
  and Cedar -- evaluation latency, memory floor, cold-start.
- **AST conformance harness.** Take the official OPA test suite,
  feed compiled ASTs through zopa, track coverage as a percentage.

## Medium term

- **Set/object refs.** Walk a `ref` into a composite and use it as
  the `source` of `some`/`every` even when stored under input.
- **Function calls.** A small set of builtins (`startswith`,
  `endswith`, `contains`, `count`). No general user-defined
  functions until there's a clear need.
- **Multiple policies.** Load more than one module per VM, address
  rules by `package.rule` rather than just rule name.
- **Distroless OCI image** with the `.wasm` and a wasmtime CLI for
  CI use.

## Longer term

- **proxy-wasm 0.3.x** when the spec stabilizes.
- **Streaming evaluation.** Decide on partial input without buffering
  the whole body.
- **CNCF Sandbox application** once there are at least three
  unaffiliated adopters using zopa in production.

## Out of scope

- Compiling Rego source. zopa expects pre-compiled AST. Use OPA's
  compiler.
- WASI support. zopa targets `wasm32-freestanding`; WASI would
  pull in syscalls we don't need.
- A query language separate from Rego. The AST is Rego-shaped on
  purpose.
