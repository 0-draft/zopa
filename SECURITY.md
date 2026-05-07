# Security Policy

## Supported versions

zopa is pre-1.0. Only the latest tag receives security fixes.

## Reporting a vulnerability

Do not open a public GitHub issue.

Use [GitHub's private vulnerability reporting][advisory] on this repository.
A maintainer will acknowledge within 72 hours and coordinate a fix.

If private reporting is unavailable, email the maintainers listed in
[MAINTAINERS.md](MAINTAINERS.md) with `[zopa security]` in the subject.

[advisory]: https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability

## Scope

In scope:

- Memory safety issues in the wasm module (out-of-bounds reads/writes,
  use-after-free, leaks across the request arena).
- Logic bugs that cause `evaluate()` to return `allow` when the policy
  forbids the request.
- proxy-wasm ABI misuse that crashes the host or escapes the wasm
  sandbox.
- Parser bugs that cause unbounded recursion, stack overflow, or
  memory blowup on adversarial input.

Out of scope:

- Denial of service from oversized policies or inputs that fit within
  configured limits. zopa enforces a recursion cap; configure your
  proxy to bound request size.
- Issues in dependencies of the test harness (Node, wasmtime, Envoy).
  Report those upstream.

## Disclosure

Fixes are released as soon as a patch is verified. A GitHub Security
Advisory is published with the fix release.
