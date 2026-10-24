# Omnicode roadmap

Build a small Zig 0.17 coding agent inspired by [nanocode](https://github.com/1rgs/nanocode).
Minimize maintained code, not readability or correctness. No SDKs, framework,
database, background service, or speculative abstractions.

## Architecture

`CLI -> conversation loop -> provider router -> Messages API`

`model tool calls -> local tools / skill loader -> tool results -> loop`

Use the same Messages protocol for Anthropic and OpenRouter. Route explicitly
by provider and model, with deterministic defaults from environment variables.
Do not silently retry mutations or switch providers. Skills are local instructions,
not plugins: advertise names/descriptions and load a body only when requested.

## Increments

1. **Router and foundation:** replace template build noise, implement route
   selection, test defaults and invalid configuration. Commit and push.
2. **Tools and skills:** read/write/edit, glob/grep via ripgrep, bounded shell
   execution, local skill discovery and validated loading. Test real filesystem
   effects, failures, output limits, and timeouts. Commit and push.
3. **Agent and CLI:** native HTTP/JSON, sequential tool round trips, retained
   conversation, one-shot prompts and REPL, clear/model/skill commands, bounded
   turns and history. Build and test. Commit and push.
4. **Acceptance:** run the binary against a local mock Messages endpoint for both
   routes, tool errors, malformed/truncated responses, history, skills, and CLI
   failures. Document usage and exact limits; review diff and LOC. Commit and push.

Every increment must build and pass focused checks before committing. Never
include keys or private configuration. Live paid API calls are not needed for
automated verification.

## Scope boundaries

Trusted local use: tools operate with the user's permissions, without a sandbox.
Initial scope is POSIX, Zig 0.17.0, and ripgrep for glob/regex search. No streaming,
automatic model classification, MCP, persisted sessions, or full YAML parser.

## Primary references

- Zig 0.17.0 installed standard-library source: `std.process`, `std.Io`,
  `std.http.Client`, and `std.json` (implementation must follow this exact version).
- [Anthropic tool calls](https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls)
- [Anthropic stop reasons](https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons)
- [OpenRouter Messages endpoint](https://openrouter.ai/docs/api/api-reference/anthropic-messages/create-messages)

## Progress

- [x] Inspect template, reference implementation, installed Zig APIs and API docs.
- [x] Router and foundation (route tests and build pass).
- [ ] Tools and skills.
- [ ] Agent and CLI.
- [ ] Acceptance and documentation.
