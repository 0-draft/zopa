# Changelog

All notable changes are recorded here. Format follows
[Keep a Changelog][kac]; releases follow [Semantic Versioning][semver]
once the first stable tag ships.

[kac]: https://keepachangelog.com/en/1.1.0/
[semver]: https://semver.org/spec/v2.0.0.html

## Unreleased

## [0.1.0] - 2026-05-07

First tagged release. Public surface (export names, AST schema,
callback semantics) is still alpha and may change before 1.0.

### Added

- Initial implementation: `wasm32-freestanding` build, ~50 KB
  release binary.
- In-tree JSON parser with surrogate-pair handling and zero-copy
  string aliasing.
- Per-request arena allocator with `retain_capacity` reset.
- Policy AST: `value`, `ref`, `compare` (`eq`/`neq`/`lt`/`lte`/`gt`/`gte`),
  `not`, `set`, `some`, `every`, `Module`, `Rule`.
- proxy-wasm 0.2.1 lifecycle exports: `proxy_on_vm_start`,
  `proxy_on_configure`, `proxy_on_context_create`,
  `proxy_on_request_headers`, `proxy_on_request_body` (no-op
  pending body-aware policy work), `proxy_on_response_headers`
  (no-op), `proxy_on_done`.
- Length-prefixed `malloc`/`free` exports compatible with
  proxy-wasm host buffer ownership conventions.
- Integration tests in Node, wasmtime, and a real Envoy
  (`zig build test`, `test-wasmtime`, `test-envoy`).
- Automated releases on `v*` tags with SLSA v1.0 build provenance and
  cosign keyless signatures. Each release attaches `zopa-<tag>.wasm`,
  `.sha256`, `.intoto.jsonl`, and `.sigstore.json`.

### Fixed

- README badges (CI, OpenSSF Scorecard) now resolve. They were left
  pointing at `kanywst/zopa` after the repo moved to `0-draft/zopa`.

[0.1.0]: https://github.com/0-draft/zopa/releases/tag/v0.1.0
