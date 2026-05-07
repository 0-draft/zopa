# Changelog

All notable changes are recorded here. Format follows
[Keep a Changelog][kac]; releases follow [Semantic Versioning][semver]
once the first stable tag ships.

[kac]: https://keepachangelog.com/en/1.1.0/
[semver]: https://semver.org/spec/v2.0.0.html

## Unreleased

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
- Release pipeline: `v*` tag pushes trigger `.github/workflows/release.yml`,
  which builds `zopa-<tag>.wasm` (`--release=small`), generates a
  SHA-256 checksum, attests SLSA v1.0 build provenance via
  `slsa-github-generator`, signs the wasm with cosign keyless, and
  attaches all four artifacts (`.wasm`, `.sha256`, `.intoto.jsonl`,
  `.sigstore.json`) to the GitHub Release with auto-generated notes.
