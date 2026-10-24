# Omnicode

A small terminal coding agent in Zig, inspired by
[nanocode](https://github.com/1rgs/nanocode). It can inspect files, edit code,
run commands, load project skills, and select a model by task complexity.
No Zig package dependencies; native HTTP, TLS, and JSON use the standard library.

## Quick install (Linux x86_64 & aarch64)

The installer requires `curl`, `tar`, and `sha256sum`. It verifies the archive
against the release’s `SHA256SUMS` and stops if verification is unavailable or fails.

Install the prebuilt static Linux binary to `~/.local/bin/omnicode` (requires [ripgrep](https://github.com/BurntSushi/ripgrep) `rg` for `glob`/`grep` search):

```sh
curl -fsSL https://raw.githubusercontent.com/kyambuthia/omnicode/main/install.sh | sh
omnicode --setup openrouter 'your-key'
omnicode
```

## Build from source

Requires **Zig 0.17.0**, a POSIX system with `sh`, and
[ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) for glob/regex search.

```sh
zig build
export ANTHROPIC_API_KEY='your-key'
./zig-out/bin/omnicode
./zig-out/bin/omnicode 'explain src/main.zig'
./zig-out/bin/omnicode 'fix the failing tests'
```

For OpenRouter:

```sh
export PROVIDER=openrouter
export OPENROUTER_API_KEY='your-key'
./zig-out/bin/omnicode
```

Use `zig build run -- 'your task'` during development. `--help`, `--version`, `--skills`, `--init`, `--providers`, `--setup`, and `--secrets`
work without a key or network connection. Do not put API keys in tracked files.

```text
omnicode [--free|--cost-max] [--verbose] [--] [prompt ...]
omnicode --skills | --init [force] | --providers [...] | --setup [...] | --secrets [...] | --version | --help
```

| Option | Effect |
|---|---|
| `--cost-max` | Default. Pick the cheapest suitable model from the live OpenRouter catalog |
| `--free` | Only zero-price OpenRouter tool models; forces OpenRouter and rejects paid overrides |
| `--verbose` | Full tool output instead of compact previews |
| `--init [force]` | Bootstrap `OMNICODE.md` and `.omnicode/skills/verify/SKILL.md` for the current repository |
| `--providers [...]` | List, switch, or configure LLM providers, API keys, and custom `API_URL` endpoints |
| `--setup [...]` | View or configure provider API keys and settings in `~/.config/omnicode/config.env` (`0o600`) |
| `--secrets [...]` | Manage zero-leak secrets (passwords, logins, tokens) in `~/.config/omnicode/secrets.env` (`0o600`) |
| `--` | Treat every following argument literally as prompt text (e.g. `-- --help me`) |

`--free` and `--cost-max` together is an error (`ConflictingOptions`); other
unknown `--` options are rejected (`UnknownOption`).

## Minimal automatic router

Each user prompt selects **fast** or **strong** once; all tool calls and API
continuations in that turn stay on that model. Subsequent user prompts are
classified independently. The selected provider and model are printed.

The classifier is deliberately a small heuristic, not another model call:
use strong for prompts longer than 240 bytes or containing a development verb
such as `implement`, `fix`, `debug`, `refactor`, `test`, `review`, or `design`.
Matching is case-insensitive by word. Other short prompts use fast. The exact
word list is in `src/router.zig`. It does not understand semantics or languages
beyond those keywords; override the model for ambiguous work.

| Variable | Meaning / default |
|---|---|
| `PROVIDER` | `abliteration`, `openrouter`, `anthropic`, `deepseek`, `xai`, `openai`, `gemini`, or `groq`; otherwise auto-detected from configured API keys. `--free` forces `openrouter` |
| `MODEL` | Strong model. Default: provider default or catalog-selected (OpenRouter) |
| `FAST_MODEL` | Fast model. Default: provider default or catalog-selected (OpenRouter) |
| `VOICE_MODEL` | Audio transcription model for `/voice`. Default: cheapest audio-capable model in the OpenRouter catalog (fallback `google/gemini-2.0-flash-lite-001`) |
| `ANTHROPIC_API_KEY` | Key for direct Anthropic requests |
| `OPENROUTER_API_KEY` | Key for OpenRouter requests and `/voice` audio transcription |
| `DEEPSEEK_API_KEY`, `XAI_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `GROQ_API_KEY` | Keys for additional providers (manageable via `/setup`) |
| `OMNICODE_CONFIG` | Optional path to the persistent config file (default: `$XDG_CONFIG_HOME/omnicode/config.env` or `~/.config/omnicode/config.env`) |
| `API_URL` | Optional **complete Messages endpoint URL**, primarily for local testing |
| `MODELS_URL` | Optional OpenRouter model catalog URL (public metadata; the API key is never sent to it) |
| `OMNICODE_STATUS` | Status line mode: `pinned` (default), `inline`, `title`, or `off` |

### Live catalog selection (OpenRouter)

With OpenRouter, each user turn first refreshes the public model catalog
(`/api/v1/models?supported_parameters=tools&sort=agentic-high-to-low`, 15 s
timeout, 8 MiB limit). Candidates must:

- advertise `tools` support and `text` output,
- have a context length of at least 32,768 tokens and allow at least 8,192 completion tokens,
- have parseable, finite, non-negative prices,
- be a concrete model: `openrouter/*` routers, `~` aliases and `:variant` IDs are
  excluded, except `:free`.

The score is `request + 1000 × (input + output × w)` USD, where `w` is 3 for
development (strong) turns and 1 for lookups. In `--cost-max` mode only the first
16 (strong) or 32 (fast) eligible models in the catalog's agentic ranking are
considered, so the cheapest model is chosen among reasonably capable ones. `--free`
searches the whole catalog for models whose every listed price is zero, and the
request adds a zero `max_price` provider constraint.

`MODEL`/`FAST_MODEL` (or `/model openrouter ID`) pin a specific catalog ID; it
must still pass the checks above, and in `--free` mode a paid ID fails with
`PaidModelInFreeMode`. The chosen model and its catalog rates are printed per turn.
Direct Anthropic does not use the catalog: Haiku 4.5 serves both tiers unless overridden.

Model IDs must match the selected provider and support tools. An explicit
provider takes precedence over key-based selection. There is no silent provider
fallback or automatic retry. For a custom endpoint, its authentication still
follows `PROVIDER`; use HTTPS except for trusted loopback testing.

REPL commands:

| Command | Effect |
|---|---|
| `/providers` or `/providers list` | Show numbered list of all supported providers, active status (`*`), API key status, default models, and endpoints |
| `/providers <N\|provider>` | Switch active provider by number or name (preserves conversation) |
| `/providers <provider> <key>` | Save API key for `<provider>` (`0o600`) and activate it immediately |
| `/providers url <url\|default>` | Set or reset custom `API_URL` endpoint |
| `/providers unset <provider>` | Remove saved API key for `<provider>` |
| `/setup` | Show configured provider API keys (masked), active settings, and config file path |
| `/setup <provider> <key>` | Save an API key for `abliteration`, `openrouter`, `anthropic`, `deepseek`, `xai`, `openai`, `gemini`, or `groq` (`0o600`) and activate it |
| `/setup set <KEY> <VALUE>` | Persist a setting (`PROVIDER`, `MODEL`, `FAST_MODEL`, `VOICE_MODEL`, etc.) and apply it immediately |
| `/setup unset <provider\|KEY>` | Remove a saved API key or setting |
| `/secrets` | List stored secret names and character lengths (values are never shown) |
| `/secrets set <NAME> <VALUE>` | Store a secret (`0o600`): injected as `$NAME` in `bash`, advertised by name only, and scrubbed (`[REDACTED:NAME]`) from all tool outputs and prompts |
| `/secrets unset <NAME>` | Remove a secret from the vault |
| `/secrets load <file.env>` | Import secrets from a `.env` file into the vault and redaction scrubber |
| `/voice [seconds\|file.wav]` | Record microphone audio (default 5s) or read an audio file, transcribe via cheap OpenRouter audio models, and run the spoken prompt |
| `/voice model [MODEL]` | View or pin `VOICE_MODEL` for voice transcription |
| `/init [force]` | Generate `OMNICODE.md` and `.omnicode/skills/verify/SKILL.md`, then reload system instructions |
| `/review [focus]` | Run the two-critic adversarial code review (Correctness/Security + Anti-Slop/Simplicity) on workspace changes |
| `/model` or `/model list` | Show current routing mode and a numbered list (`[1]`, `[2]`, …) of available models across the OpenRouter catalog and configured providers |
| `/model <N>` | Switch directly to model `#N` from the `/model` list (preserves conversation) |
| `/model <MODEL>` | Pin `<MODEL>` on the current or inferred provider (preserves conversation) |
| `/model <PROVIDER> <MODEL>` | Switch to `<PROVIDER>` and pin `<MODEL>` (preserves conversation) |
| `/model fast [MODEL]` or `/model strong [MODEL]` | Pin the fast or strong tier model (or update `FAST_MODEL`/`MODEL`) |
| `/model auto` | Restore automatic fast/strong task routing (preserves conversation) |
| `/skills` | List local skills |
| `/skill NAME` | Add that skill's instructions to the conversation |
| `/help` | Show commands and configuration |
| `/verbose on` or `/verbose off` | Switch future tool output between full and compact previews |
| `/status inline\|pinned\|title\|off` | Show the status line pinned to the bottom row (default), above the prompt, in the terminal title, or not at all |
| `/usage` | Show session token/cost totals, retained across clears and model changes |
| `/context` | Show conversation message, byte, and token budget |
| `/compact [focus]` | Summarize older exchanges on the fast route, keeping the original goal and recent tool pairs |
| `/todo` | Show the current session checklist |
| `/save [NAME]` | Save session history and checklist to `.omnicode/sessions/<NAME>.json` (default: `latest`) |
| `/resume [NAME]` | Load a saved session from `.omnicode/sessions/<NAME>.json` (default: `latest`) |
| `/details` | Recover the last tool result, up to 64 KiB; next tool call replaces it |
| `/c` | Clear conversation and free session allocations |
| `/q`, `/exit`, or `exit` | Quit |

## Terminal interface

The terminal keeps a scrollable transcript, with model responses separated from
tool activity. Tool entries show the file, search pattern, skill, or command,
followed by success/failure and elapsed time. Successful edits preview the exact
old/new replacement with `-` and `+`; these are replacement snippets, not a full
file diff. Writes report bytes written.

```text
• edit  src/example.zig
  ✓ Done · 1ms
    - return 1;
    + return 2;

• bash  zig build test
  ✓ Done · 142ms
    All tests passed.
```

Compact output retains the first three and last two lines, with an explicit
hidden-line count. Long preview lines end in `...`. Use `--verbose` before a
one-shot prompt, or `/verbose on` in the REPL, to show full output for subsequent
tool calls (within the tool's existing collection limits). `/details` shows the
last tool result without preview truncation, retaining at most 64 KiB on a UTF-8
boundary. It is replaced by the next tool result, including failures.

Interactive terminals show a waiting indicator with elapsed seconds during
model requests and tools. Color and animation are disabled when output is
redirected, `TERM=dumb`, or `NO_COLOR` is set. Preview width is the terminal's
reported width, else `COLUMNS`, else 80, clamped to 40–160. Terminal control characters from model text,
file contents, commands, and tool output are neutralized for display; the original
tool results still go to the model. UTF-8 characters are never cut mid-sequence.

### Status line

Interactive terminals pin a dim status line to the bottom terminal row by default
(using a `DECSTBM` scroll region for rows `1..rows-1`, restored on exit):

```text
 openrouter · auto (cost-max) → z-ai/glm-4.6 · ~/Projects/omnicode · 10:25
```

It shows the provider; the pinned model, or the routing policy plus the model
selected for the previous turn; the working directory (`$HOME` as `~`); the active
message count once a conversation has started; and local time. Local time comes from
`$TZ` or `/etc/localtime` (TZif); when no zone can be loaded the time is labeled
`UTC`. Narrow terminals elide the directory first, then the model, then drop the
context count and time. Width is read from the terminal on every prompt, falling back
to `COLUMNS`. `/status inline` prints the status line directly above each prompt,
`/status title` puts the status in the terminal title (restored via the xterm title
stack), `/status off` hides it, and `OMNICODE_STATUS=pinned|inline|title|off` sets
the startup mode. Plain output never prints it.

The interface keeps normal terminal scrolling and copy/paste. Styled terminal
responses emphasize Markdown headings and dim backtick fence markers; fenced
code stays literal. Plain output preserves Markdown source.

When both input and output are interactive, a small raw-mode composer supports
append, backspace, Up/Down arrow history navigation across the last 32 single-line
commands, Ctrl-C to discard input, Ctrl-D on empty input to quit, and bracketed
paste. Pasted newlines remain in one prompt until Enter is pressed. Input is capped
at 16 KiB; overflow discards the prompt on submission. Terminal settings are
restored on return, errors, and EOF, before model or tool work. Pipes, dumb
terminals, and `NO_COLOR` use canonical input. Arbitrary cursor movement and a
full-screen editor are not implemented; wide-character and wrapped-line backspace
display is limited. Codex and fx references are recorded in [ROADMAP.md](ROADMAP.md).

## Token and cost usage

Each turn reports input/output tokens, cache reads/writes, and cost across every
returned API response, including tool continuations and rejected truncated replies.
`/usage` shows totals for the current process; `/c` and model changes preserve them.
Input and cache counts are shown separately as reported by the Messages endpoint.

Provider `usage.cost` takes precedence and is labeled `reported`. Otherwise, the
rates fetched from the OpenRouter catalog for the selected model produce a labeled
`estimated` amount (input, output, cache read, 5-minute/1-hour cache write, and
per-request fee). Unknown prices or missing usage are explicitly unavailable; a
partial known cost is labeled a subtotal. Requests that fail before a parseable
response cannot contribute usage. Totals are in memory and are not an
account-wide billing ledger.

There is no static price table. Direct Anthropic requests have no catalog rates,
so their cost is unavailable unless the endpoint reports it. Estimates are also
withheld when the catalog marks a model's rates as variable (`overrides`), or
when a non-`anthropic/` OpenRouter model reports cache tokens, since upstream
cache counters may not share Anthropic's billing semantics. Estimates exclude
taxes, fees and negotiated discounts.

References: [OpenRouter usage accounting](https://openrouter.ai/docs/cookbook/administration/usage-accounting),
[Messages schema](https://openrouter.ai/docs/api/api-reference/anthropic-messages/create-a-message),
[model pricing catalog](https://openrouter.ai/api/v1/models), and
[Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing).
The general OpenRouter usage guide includes a cost field; its Messages schema
example omits it, so the implementation supports both shapes.

## Skills

Create `.omnicode/skills/<name>/SKILL.md` in the directory where you run the agent:

```markdown
---
name: verify
description: Run the project's verification steps
---
Before finishing a code change, run `zig build test` and `zig build`.
Report failures and the exact commands used.
```

Metadata keys must start in column one. Descriptions are a single line, optionally quoted;
this is intentionally a small convention rather than a full YAML parser.
The directory name is the skill's identity (`name:` is informational).
Names allow ASCII letters, digits, underscores and hyphens, at most 64 characters.

Only names and descriptions enter the initial system prompt. The model can
request a body using the `skill` tool, or you can load one with `/skill verify`.
Supporting files remain accessible through ordinary file tools. Skill discovery
refreshes when a conversation is initialized or cleared; `/skills` lists current
files immediately. Keep skills local and trusted.

## Tools and limits

| Tool | Behavior |
|---|---|
| `read` | Numbered lines; zero-based `offset`, default `limit=200`; marks truncation |
| `write` | Create or overwrite a file; parent directory must already exist |
| `edit` | Exact nonempty string replacement; reject repeated matches unless `all=true` |
| `glob` | `rg --files --glob`; respects ripgrep glob and ignore rules |
| `grep` | Ripgrep regex search with line numbers; up to 50 matches per file |
| `bash` | Execute through `sh -c`; returns stdout then stderr and reports nonzero exit |
| `skill` | Load an advertised project's skill body by name |
| `todo` | Read or replace the session checklist (`items: [{task, done}]`); survives compaction and `/save` |
| `task` | Delegate a sub-task to a depth-1 child agent (`mode: explore\|edit`, `tier: fast\|strong`); returns only its final report |
| `review` | Run adversarial multi-agent code review (Correctness/Security critic + Anti-Slop/Simplicity critic) on current workspace changes; returns findings and `OVERALL VERDICT: PASS\|FAIL` |

Tools execute sequentially with your user's filesystem and process permissions.
There is **no sandbox or approval prompt**. Run in a checkout you trust; inspect
changes with Git. Symlinks are followed normally. Files and selected tool output
are sent to your configured model provider.

File reads/writes/edits are limited to 1 MiB; formatted reads and skill bodies
to 64 KiB; command output to 64 KiB per stream. Commands have a 30-second deadline
covering both output collection and process waiting; the direct child is killed
on timeout or output overflow. This is not process-tree isolation: descendants
may outlive it. HTTP requests have a 120-second deadline and a 2 MiB response
limit. Redirects are disabled. Requests are limited to 2 MiB serialized history,
128 messages, 64 content blocks per response, and 32 model calls per user turn.

Errors become tool results when execution can continue. Invalid or truncated
model responses are rejected before executing any tools in that response.
Non-UTF-8 tool output is returned as a tool error. When a turn fails after
completing one or more tool calls or responses, a summary of completed work is
retained in history so the next turn can continue; if nothing completed before
the failure, history is cleared.

Before hitting the 32-call turn window, the 96-message threshold, 75% of the 2 MiB
serialized request budget, or 75% of the model's `context_length` token budget,
the agent automatically compacts older history via a summary request on the fast
route (up to 3 compactions per turn), keeping the original goal, any `/todo`
checklist, and recent tool pairs intact. `/save` and `/resume` persist sessions
under `.omnicode/sessions/`. Tool schemas attach an ephemeral `cache_control`
breakpoint for prompt caching.

## Verification

```sh
zig fmt --check build.zig build.zig.zon src
zig build test --summary all
zig build --summary all
python3 tests/integration.py -v
```

The Python standard-library integration suite runs the actual binary in temporary
workspaces against a loopback mock Messages server, with fake keys and no paid
API calls. It covers both routes/authentication, every tool, skill discovery and
loading, history, model overrides, error recovery, malformed/truncated responses,
HTTP failures, loop limits and size limits. Pseudo-terminal tests cover styling,
waiting indicators, `NO_COLOR`, compact/full previews, and control sanitization.
Unit tests cover routing, real file
edits, skill-name validation, process timeouts and output overflow.

See [ROADMAP.md](ROADMAP.md) for the implementation sequence and primary references.
