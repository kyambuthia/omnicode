# Contributing to Omnicode

Omnicode is built with Zig 0.17.0. Install Zig, Python 3, and `rg` (ripgrep).
The runtime and offline integration suite currently use POSIX facilities.

## Build and verify

Run these commands from the repository root:

```sh
zig fmt --check build.zig build.zig.zon src
zig build test --summary all
zig build --summary all
python3 tests/integration.py -v
python3 tests/installer.py -v
```

The integration suite uses a local mock HTTP server and fake credentials. It
does not make paid API requests. The optional `tests/live_agent.py` evaluation
does make API requests and must be invoked explicitly with `--allow-paid-api`.

For a focused change, run the affected checks while developing, then run the
full offline set before opening a pull request. Include the exact commands and
results in the pull request description. See [README.md](README.md) for setup
and command behavior.

## Changes and commits

- Keep changes focused and preserve unrelated work in the checkout.
- Add regression coverage when changing behavior or fixing a bug. Use the Zig
  unit tests for isolated logic and `tests/integration.py` for CLI or protocol
  behavior.
- Document user-facing changes in the guide and add a note under
  `Unreleased` in [CHANGELOG.md](CHANGELOG.md). Mark compatibility breaks under
  `Breaking changes`.
- Use the existing `type(scope): summary` commit style, such as
  `fix(http): handle a malformed response` or `feat(cli): add an option`.
  Common types in this repository are `feat`, `fix`, `test`, `docs`, and `chore`.
- Do not include API keys, vault contents, local sessions, or generated build
  output in commits.

Pull requests should explain the behavior change, any compatibility impact,
and the verification performed.
