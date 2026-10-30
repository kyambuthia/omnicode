# Omnicode

A small terminal coding agent in Zig, inspired by
[nanocode](https://github.com/1rgs/nanocode). It can inspect files, edit code,
run commands, load project skills, and select a model by task complexity.
No Zig package dependencies; native HTTP, TLS, and JSON use the standard library.

## Quick install (Linux x86_64 & aarch64)

The installer requires `curl`, `tar`, `awk`, and standard Linux coreutils
(including `sha256sum`, `install`, `mktemp`, and `mv` with `-T`). It verifies the
archive against the release’s `SHA256SUMS` and stops if verification is unavailable
or fails. Updates stage the binary in a private directory on the installation
filesystem, check `--version`, and rename it into place. Failures before replacement
preserve the existing binary; destination links are replaced without modifying
their targets, and a directory at the binary path is rejected.

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
| `PROVIDER` | `abliteration`, `openrouter`, `runinfra`, `anthropic`, `deepseek`, `xai`, `openai`, `gemini`, `groq`, `mistral`, `together`, `fireworks`, `cerebras`, `deepinfra`, `nvidia`, or `custom`; hosted providers are auto-detected from configured API keys. `--free` forces `openrouter` |
| `MODEL` | Strong model. Default: provider default or catalog-selected (OpenRouter) |
| `FAST_MODEL` | Fast model. Default: provider default or catalog-selected (OpenRouter) |
| `VOICE_MODEL` | Audio transcription model for `/voice`. Default: cheapest audio-capable model in the OpenRouter catalog (fallback `google/gemini-2.0-flash-lite-001`) |
| `ANTHROPIC_API_KEY` | Key for direct Anthropic requests |
| `OPENROUTER_API_KEY` | Key for OpenRouter requests and `/voice` audio transcription |
| `RUNINFRA_API_KEY` (`RUNINFRA_GATEWAY_KEY` also accepted) | RunInfra key for its Anthropic-compatible Messages API |
| `DEEPSEEK_API_KEY`, `XAI_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `GROQ_API_KEY`, `MISTRAL_API_KEY`, `TOGETHER_API_KEY`, `FIREWORKS_API_KEY`, `CEREBRAS_API_KEY`, `DEEPINFRA_API_KEY`, `NVIDIA_API_KEY` | Keys for direct provider APIs (manageable via `/providers` or `/setup`) |
| `CUSTOM_API_KEY` | Key for a custom OpenAI-compatible or Anthropic Messages endpoint |
| `OMNICODE_CONFIG` | Optional path to the persistent config file (default: `$XDG_CONFIG_HOME/omnicode/config.env` or `~/.config/omnicode/config.env`) |
| `API_URL` | Optional complete chat endpoint URL; used with the selected provider or custom endpoint |
| `API_MODELS_URL` | Optional provider model-list endpoint; otherwise Omnicode derives `/models` from the selected chat endpoint |
| `API_PROTOCOL` | Optional wire format override: `openai` (Chat Completions) or `anthropic` (Messages) |
| `API_AUTH` | Optional auth header override: `bearer` or `x-api-key` |
| `MODELS_URL` | Optional OpenRouter model catalog URL (public metadata; the API key is never sent to it) |
| `OMNICODE_STATUS` | Status line mode: `pinned` (default), `inline`, `title`, or `off` |

RunInfra uses `https://api.runinfra.ai/v1/messages`, with `deepseek-v4-1-flash-1017`
for fast turns and `glm-5-3` for strong turns. If a RunInfra key is already
exported by your login shell, run `omnicode --providers runinfra` once to select
it. This persists the provider selection while leaving the key in the environment.
You can change the models with `FAST_MODEL` and `MODEL` or `/model`.

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
fallback. Model requests retry HTTP 500 and 503 at most twice, waiting one then
two seconds; a valid `Retry-After` delta of up to 30 seconds increases the wait.
HTTP-date, malformed, duplicate, or longer `Retry-After` values stop automatic
retry. The two-minute deadline covers all attempts and backoff together. Other
HTTP errors, transport failures, and invalid responses are not retried. Failed
HTTP attempts are printed without response bodies; usage totals count returned
model responses and do not estimate charges for failed attempts. For a custom
endpoint, HTTPS is required except for HTTP to literal IPv4 loopback addresses
(`127.0.0.0/8`) or IPv6 loopback (`[::1]`). This applies to `API_URL`,
`MODELS_URL`, and `VOICE_URL`. Use `127.0.0.1` instead of `localhost` for local
testing; DNS hostnames are not accepted for plaintext HTTP. Endpoint URLs must
not contain embedded credentials, fragments, or whitespace.

Omnicode includes 15 hosted provider presets and supports custom endpoints that
implement OpenAI Chat Completions or Anthropic Messages. OpenAI, Gemini, and the
new presets use Chat Completions; Anthropic-compatible providers continue using Messages. The
adapter translates tool calls and results so the same local tool loop works
across both formats. Configure a custom endpoint with:

```text
/providers custom <api-key>
/providers url https://llm.example/v1/chat/completions
/providers protocol openai
/providers auth bearer
/providers models-url https://llm.example/v1/models
/setup set MODEL provider/model-id
/setup set FAST_MODEL provider/fast-model-id
```

REPL commands:

| Command | Effect |
|---|---|
| `/providers` or `/providers list` | Show numbered list of all supported providers, active status (`*`), API key status, default models, and endpoints |
| `/providers <N\|provider>` | Switch active provider by number or name (preserves conversation) |
| `/providers <provider> <key>` | Save API key for `<provider>` (`0o600`) and activate it immediately |
| `/providers url <url\|default>` | Set or reset the complete `API_URL` endpoint |
| `/providers models-url <url\|default>` | Set or reset the provider model-list endpoint used by `/model` |
| `/providers protocol <openai\|anthropic>` | Select Chat Completions or Messages wire format |
| `/providers auth <bearer\|x-api-key>` | Select the custom API authentication header |
| `/providers custom <key>` | Save a key and select a custom API; configure endpoint, protocol, and model with the commands above |
| `/providers unset <provider>` | Remove saved API key for `<provider>` |
| `/setup` | Show configured provider API keys (masked), active settings, and config file path |
| `/setup <provider> <key>` | Save an API key for a listed provider (`0o600`) and activate it |
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
| `/model` or `/model list` | Show current routing mode and a numbered model list; direct providers are queried for models when their API exposes `/models` |
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

Config, vault, and session saves use private (`0600`) temporary files and atomic
replacement. Saving repairs loose permissions on an existing destination and
replaces a destination symlink rather than modifying its target. Parent directory
symlinks are still resolved normally; use a trusted configuration directory.

Secret commands stage changes before saving: a failed save or invalid import
leaves the live vault and subprocess environment unchanged.

Startup stops on unreadable configuration/vault files or invalid vault entries,
so requests cannot proceed with a partially loaded secret scrubber. Missing files
are allowed. Vault loads and imports apply only after the whole file parses;
comments, blank lines, `export` entries, and empty-value skips are supported.
`--help` and `--version` remain available even when persisted files need repair.

Configuration saves also use a v2 header and JSON-encoded values. Legacy
configuration files remain readable and are upgraded on the next successful save;
quoted legacy values retain their meaning during unrelated updates. Configuration
files must not be sourced as shell scripts. Malformed assignments, unsupported
format versions, and invalid values stop loading before any saved settings are
applied. Existing process environment variables still take precedence. Saves
prepare environment allocations first and reject files exceeding the 64 KiB load
limit, preserving the previous file and live setting on failure.

New vault saves use a versioned header and JSON-encoded values to preserve quotes,
backslashes, significant spaces, and control bytes across restarts. Older vaults
and ordinary `.env` imports remain readable; saving upgrades them to v2. The
vault remains unencrypted and must not be sourced as a shell script. Vault and
import files are capped at 256 KiB, enough for all 64 supported secrets at the
512-byte value limit even after JSON escaping.

Conversation and system strings are scrubbed again before model requests, and
session message and todo strings are scrubbed on save and resume. This covers history
created before a value was registered as a secret, including JSON-escaped values.
Before `/secrets`, `/setup`, or `/providers` can change credentials, retained
conversation messages, checklist text, input history, and tool details are redacted
with the current values. Removing or replacing a credential therefore preserves
redaction in that retained state. Input entries whose redacted form exceeds the
history slot capacity are discarded.
Assistant text and tool previews redact registered values before terminal rendering;
`/details` retention redacts before truncation. Tool execution keeps the original
arguments.
Command output and skill descriptions are scrubbed before truncation, so a
preview boundary cannot expose a fragment of a registered value.
Subagent reports are also scrubbed before truncation and retain their head and
tail. Review output retains the overall verdict within its 64 KiB limit. A critic
passes only with an exact final `VERDICT: PASS` line; turn-limit reports and
reports containing `VERDICT: FAIL` are treated as failures.

File tools, voice input, secret imports, and private state writes reject NUL bytes
in paths. The tool named `bash` executes commands with POSIX `sh -c`. Invoke `bash -c`
explicitly when using Bash arrays, `PIPESTATUS`, or other Bash-specific syntax.
Command tools (`bash`, `glob`, `grep`)
reject NUL bytes in subprocess arguments before executing. Malformed arguments
return tool errors instead of truncating a command/path or crashing the session.
File contents remain length-delimited and may contain NUL bytes.

File edits require a unique exact match, including overlapping occurrences. For
example, `aa` in `aaa` is ambiguous and leaves the file unchanged. With `all=true`,
edits replace non-overlapping matches from left to right (`aaa` becomes `xa` when
replacing `aa` with `x`).

Checklist replacements apply only after all items validate and fit the 4 KiB
limit. A rejected replacement preserves the previous checklist.

Resuming validates message shapes, tool-call/result pairing, and the 4 KiB todo
limit before replacing live state. Malformed or unsupported sessions leave the
current conversation and checklist intact. Sessions support the text, thinking,
and client-tool messages generated by Omnicode; incomplete tool exchanges are
rejected on resume.

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
paste. History retains complete, valid UTF-8 entries up to 1 KiB; longer entries
are submitted normally but omitted from arrow-key history. Pasted newlines remain in one prompt until Enter is pressed. Input is capped
at 16 KiB; overflow discards the prompt on submission. Terminal settings are
restored on return, errors, and EOF, before model or tool work. Pipes, dumb
terminals, and `NO_COLOR` use canonical input. Arbitrary cursor movement and a
full-screen editor are not implemented; wide-character and wrapped-line backspace
display is limited. Codex and fx references are recorded in [ROADMAP.md](ROADMAP.md).

Use `omnicode --read-only "inspect this project"` to restrict model tools to
`read`, `glob`, `grep`, and `skill`. The restriction is checked at execution, so
unadvertised mutation, shell, checklist, and delegation calls are rejected. It
persists across conversation clearing, compaction, and session loading. This flag
controls model tools; commands you explicitly enter, such as `/save`, `/init`,
`/setup`, and `/review`, keep their normal behavior. It is not a filesystem sandbox:
read tools can access files available to your user, and model requests still send
project context to the configured provider.

DeepSeek's built-in fast/strong routes use `deepseek-flash` and
`deepseek-v4-pro`, matching its [documented Anthropic-compatible models](https://api-docs.deepseek.com/guides/anthropic_api/).
Explicit `MODEL`, `FAST_MODEL`, and `/model` choices take precedence.

For a long one-shot task, opt into named checkpoints:

```sh
omnicode --session build "Implement the next milestone and run its tests"
omnicode --session build "Continue from the saved progress"
```

`--session NAME` resumes `.omnicode/sessions/NAME.json` when it exists and creates
it when missing. It requires a task prompt; interactive sessions retain `/save`
and `/resume`. Checkpoints are written before main task requests (after any
needed compaction), after complete tool rounds, and after the final response.
They include the checklist, use atomic private writes, and redact registered
secrets. Invalid existing sessions fail
before a model request and are preserved. `--read-only` can be combined with
`--session`: model tools remain restricted while the explicitly requested local
checkpoint is written.

Context compaction retries a truncated summary once, increasing its output budget
from 4,096 to 8,192 tokens. It discards incomplete summaries and preserves the
previous history if the retry also fails. Both requests count toward usage.

Each checkpoint has the normal 2 MiB/128-message session limits. A failed write
stops the task and preserves the preceding checkpoint. A crash during a tool
batch can leave effects beyond the last checkpoint, so inspect completed tool
effects before retrying an interrupted mutation. Checkpoints provide retained
context, not exactly-once tool execution.

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
| `read` | Numbered lines (`offset`, default `limit=200`), or UTF-8 byte windows (`byte_offset`, default `byte_limit=4096`, max 61440); max 1 MiB file |
| `write` | Create or overwrite a file; create missing parent directories after validating input |
| `edit` | Exact nonempty string replacement; reject repeated matches unless `all=true` |
| `glob` | `rg --files --glob`; respects ripgrep glob and ignore rules |
| `grep` | Ripgrep regex search with line numbers; up to 50 matches per file |
| `bash` | Execute `cmd` through `sh -c` (`command` is a compatibility alias; conflicting values are rejected); optional `timeout_ms` from 1 to 300,000 (default 30,000); returns stdout then stderr and reports nonzero exit |
| `skill` | Load an advertised project's skill body by name |
| `todo` | Read or replace the session checklist (`items: [{task, done}]`); survives compaction and `/save` |
| `task` | Delegate a sub-task to a depth-1 child agent (`mode: explore\|edit`, `tier: fast\|strong`); returns only its final report |
| `review` | Run adversarial multi-agent code review (Correctness/Security critic + Anti-Slop/Simplicity critic) on current workspace changes; returns findings and `OVERALL VERDICT: PASS\|FAIL` |

For editable parent tasks, a final response with pending checklist steps triggers
one completion review per user request. The model is asked to reconcile only
observed work, retaining blocked steps. If items remain pending, the CLI reports
that state and finishes without repeating the review. This uses the normal turn
and compaction budgets; read-only tasks do not trigger additional review calls.

For single-line generated files, use `read` with `byte_offset` and `byte_limit`
instead of line `offset`/`limit`. Do not mix the two modes. Byte offsets refer to
the complete redacted UTF-8 view; the tool redacts before slicing, rounds the
start down and end up to whole characters (up to three extra bytes), and reports
the actual byte range and the next offset or EOF. Invalid UTF-8 and offsets
beyond the view are rejected. Byte windows remain below the 64 KiB output cap.

File reads and writes, skill loading, and project-instruction loading reject
non-regular entries before opening them, including pipes, devices, sockets, and
directories. Writes can create new files, and symlinks to regular files remain
supported. Forced initialization checks both instruction targets before writing.
Saved state, secret-import, and audio-file inputs also require regular files;
unreadable timezone data retains the UTC fallback. These metadata prechecks do
not protect against concurrent path replacement.

On Linux, SIGINT and SIGTERM cancel active work and clean up its command process
group before exiting with status 130 or 143. Interactive raw terminal settings
are restored during cancellation.

Tools execute sequentially with your user's filesystem and process permissions.
There is **no sandbox or approval prompt**. Run in a checkout you trust; inspect
changes with Git. Symlinks are followed normally. Files and selected tool output
are sent to your configured model provider.

File reads/writes/edits are limited to 1 MiB; formatted reads and skill bodies
to 64 KiB. Command output retains up to 64 KiB total, with collection capped
at 256 KiB per stream. Commands have a 30-second default deadline (`bash` can
request up to five minutes with `timeout_ms`), covering both output collection
and process waiting. Commands run in their own process group; timeout or output
overflow cleanup sends SIGKILL to that group and reaps the leader, including when
SIGTERM is ignored. Descendants that deliberately move to another process group
can escape this cleanup. Successfully completed commands retain their normal
behavior, including explicitly detached background jobs. HTTP requests have a 120-second deadline and a 2 MiB response
limit. Redirects are disabled. Requests are limited to 2 MiB serialized history,
128 messages and 64 content blocks per response. The parent agent allows 32 model
calls per compaction batch by default, with at most three automatic compactions
per user request. These budgets stop runaway tool loops. Set `MAX_TURNS` to an
integer from 1 to 256 to change the batch limit; `/setup set MAX_TURNS 64` persists
it and applies to the next request. `/setup unset MAX_TURNS` restores the default.
Child model-call and compaction budgets remain separate.

`MAX_TOOL_CALLS` limits attempted model tool calls across an entire user request,
including failed calls, delegation/review calls, and child-agent tools. The
default is 256; accepted values are 1–4096. For a small investigation, run
`MAX_TOOL_CALLS=5 omnicode --read-only 'inspect this change'`, or persist a value
with `/setup set MAX_TOOL_CALLS 512`. The budget resets for each new user request
and also applies to `/review`. Completion totals include child tools.

If an invalid saved `MAX_TURNS` or `MAX_TOOL_CALLS` blocks startup, repair that
key with `omnicode --setup set MAX_TOOL_CALLS 256` or remove it with
`omnicode --setup unset MAX_TOOL_CALLS` (substitute `MAX_TURNS` as needed).
Replacement values are validated before saving. Other invalid settings and
malformed config files still need separate correction.

When a batch exceeds the remaining budget, earlier calls in that batch may have
completed; later calls receive `ToolLimit` results without executing. The agent
records the complete batch and checkpoints named tasks before stopping, without
another model request. Inspect the completed effects before continuing. Exact
budget use can still finish normally; pending checklists do not trigger an
extra completion review when no tool budget remains.

`TurnLimit` means the model-call budget was exhausted, rather than that the
conversation is full. In the REPL, completed work is retained in a summary when
available. Inspect completed tool effects, then enter `continue` to resume from
that state. Tool actions are not rolled back; avoid restarting the original task
blindly when earlier commands may already have changed files.

Outgoing headers are validated before connecting. Invalid field names and unsafe
control bytes in values (including credentials supplied through the environment)
return `InvalidHttpHeader` without printing the value. This prevents header
injection and avoids runtime assertions in the HTTP client.

HTTP failures distinguish authentication (401), access denial (403), rate limits
(429), and server errors (5xx), with recovery hints in the REPL. Diagnostics show
the status code without printing response bodies. Invalid JSON responses return
`InvalidJsonResponse`; HTTP failures are not automatically retried.

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

Initialization preserves existing instruction and verification-skill entries
unless `force` is explicit, including oversized files, unreadable files, and
symlinks. New files are published only after their complete contents are written,
and creation refuses to replace an entry that appears concurrently. Skill
directories are prepared before publishing `OMNICODE.md`; the two files are
updated separately, so a later failure can still leave partial initialization.
Inspect the files before using `force` after a failure.

## Verification

```sh
zig fmt --check build.zig build.zig.zon src
zig build test --summary all
zig build --summary all
python3 tests/integration.py -v
python3 tests/installer.py -v
```

For an opt-in paid DeepSeek repair evaluation, run:

```sh
python3 tests/live_agent.py --allow-paid-api --binary ./zig-out/bin/omnicode
```

This creates a fresh project under `~/Projects/omnicode-lab/evals`, reproduces a
seeded failure, asks Omnicode to repair it through the real API, then runs
independent reference checks for Unicode normalization, blank values, iterators,
and preservation of inputs. Each project retains the agent transcript, baseline
and reference logs, and a `result.json` with exit codes, elapsed time, and tool
counts. It uses the CLI's configured DeepSeek credential and makes paid calls;
it is separate from the offline test suite. `--model`, `--projects`, and
`--timeout` customize the run (the timeout applies to each paid task).
Add `--exercise-resume` to run two paid tasks through `--session repair`: repair
the seed, then extend it with an iterator-safe total-count API. This retains
`resume.log` and `resume-reference.log`, checks the extension independently, and
reports checkpoint permissions/completion and whether the earlier message prefix
was retained. Compaction can replace that prefix with a summary.

The Python standard-library integration suite runs the actual binary in temporary
workspaces against a loopback mock Messages server, with fake keys and no paid
API calls. It covers both routes/authentication, every tool, skill discovery and
loading, history, model overrides, error recovery, malformed/truncated responses,
HTTP failures, loop limits and size limits. Pseudo-terminal tests cover styling,
waiting indicators, `NO_COLOR`, compact/full previews, and control sanitization.
Unit tests cover routing, real file
edits, skill-name validation, process timeouts and output overflow.

CI runs these checks for main-branch pushes and pull requests. Tagged releases
reuse the same verification workflow from the tagged commit; release builds and
publishing wait for it to succeed. Verification uses read-only repository access,
and release write access is scoped to the release job. Installer tests use local
release fixtures and require no downloads.

See [ROADMAP.md](ROADMAP.md) for the implementation sequence and primary references.
