# Contributing

Thanks for considering a contribution. zopa is small enough that
nothing here should surprise you.

## Before you start

- Open an issue first if the change is non-trivial. It's faster than
  rewriting a PR after maintainer feedback.
- For typo fixes, comment polish, or one-line bug fixes, just open
  the PR.

## Local setup

You need Zig 0.16.0, Node 22+, and Python 3.12+.

```bash
zig build           # builds zig-out/bin/zopa.wasm
zig build test      # runs the Node integration suite
```

For the optional wasmtime suite:

```bash
python3 -m venv .venv-test
.venv-test/bin/pip install -r test/requirements.txt
zig build test-wasmtime
```

For the optional Envoy end-to-end check (requires `brew install envoy`
or equivalent, with the `wamr` runtime built in):

```bash
zig build test-envoy
```

`zig build test-all` runs every suite that's available on the host.

## Code style

- `zig fmt src test build.zig build.zig.zon` before committing.
- Public functions get a one-line doc comment that says *why* the
  function exists, not *what* it does. Don't restate the signature.
- Comments explain non-obvious memory ownership, lifetime, or
  invariants. If a comment doesn't add information beyond the code,
  remove it.

## Commit messages

Conventional Commits style: `feat(scope): summary`,
`fix(scope): summary`, `chore: summary`, `docs: summary`. Keep the
subject under 72 characters. Body wraps at 80.

One commit per logical change. Don't mix refactors with behavior
changes.

## DCO

Sign every commit with `git commit -s`. The Developer Certificate of
Origin appends a `Signed-off-by:` trailer. CI rejects commits without
it.

## Pull requests

- Rebase onto `main` before opening the PR.
- Include test coverage for behavior changes. The integration suites
  in `test/` are the right place for most additions.
- Update `CHANGELOG.md` under the *Unreleased* section.

## License

Contributions are accepted under [Apache 2.0](LICENSE).
