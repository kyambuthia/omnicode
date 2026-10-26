# Changelog

User-visible changes are recorded here from the 0.2.0 baseline onward. Add
entries under `Unreleased` as changes land, then move them into a dated version
section for a release. Put incompatible changes under `Breaking changes`.

## Unreleased

### Fixed

- Provider credential displays now hide the full value instead of showing key fragments.
- Short vault values and short provider-key overrides are now scrubbed from output.
- Replaced and removed vault values are securely cleared from active vault slots.
- Temporary vault copies are securely cleared after a mutation succeeds or fails.
- Imported and serialized vault buffers are securely cleared after use.
- Replaced and removed vault environment copies are securely cleared before release.
- REPL history slots are securely cleared when overwritten or replaced by redaction.
- New REPL history entries are scrubbed before they are retained.
- The current REPL input buffer is securely cleared after processing or cancellation.
- Custom endpoint summaries redact query strings that may contain credentials.
- The interactive model picker sanitizes catalog model IDs before displaying them in the terminal.
- Credential and vault values entered with `/setup`, `/providers`, or `/secrets`
  are masked while typing; recalled input history is scrubbed before display.
- Custom endpoint URLs entered with `/setup` or `/providers url` are masked while typing.
- Automatic model retries respect the configured request start limit.
- The REPL drops incomplete Escape sequences after 100 ms instead of waiting
  indefinitely.
- Voice input detects supported audio formats without regard to extension case.
- Voice input rejects unknown filename extensions instead of labeling arbitrary files as WAV.
- Voice input requires an OpenRouter key for OpenRouter endpoints; custom
  compatible endpoints can use their configured key.
- Voice recording clears its previous output before invoking a recorder, avoiding
  stale-clip reuse.
- Non-UTF-8 shell output is replaced with a bounded diagnostic before entering
  model history.

### Breaking changes

- Tool calls now reject unrecognized input fields instead of silently ignoring
  them. Invalid calls return the expected tool input schema for recovery.

### Added

- Contributor instructions and a change history for future releases.
- `--dry-run` previews the first proposed tool batch and stops before executing
  any tool calls.
- `/export [name]` writes a redacted Markdown transcript and checklist to a
  private file under `.omnicode/exports/`.
- `/model compare` lists eligible OpenRouter models in recent median throughput
  order with catalog input and output prices before selecting a model number.
- `--json` emits one structured result for a one-shot task, including final
  text, usage, and proposed tools in dry-run mode. Progress is sent to stderr.
- `--json` keeps offline commands such as `--setup` on their normal text interface.
- Model requests are paced to 60 starts per minute by default across turns and
  delegated work. `MAX_REQUESTS_PER_MINUTE` sets 1–600 or 0 to disable pacing.

## 0.2.0

The 0.2.0 tag is the baseline for this changelog. See the repository history
for changes made before and after that tag.
