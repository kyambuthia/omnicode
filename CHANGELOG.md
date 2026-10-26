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
- JSON-decoded vault values are securely cleared after copying into the live vault.
- Parsed session, voice, and compact-response values, validation copies, and save/export buffers are securely cleared after use through an iterative traversal.
- Temporary checklist formatting buffers are securely cleared after successful and failed updates.
- Retired checklist contents are securely cleared on update, redaction, load, and conversation reset.
- Replaced `/details` output is securely cleared before the next result is retained.
- Voice recorder command and captured-output copies are securely cleared after use.
- Serialized model request bodies, including replaced compact-retry bodies, are securely cleared after use.
- Temporary redacted terminal-display copies are securely cleared after rendering.
- Raw retained-detail snapshots are securely cleared after credential-driven redaction.
- JSON credential redaction securely clears replaced source strings.
- Partially built redaction output is securely cleared after allocation or formatting errors.
- Partially serialized vault data is securely cleared after write errors.
- Partially serialized `/setup` config data is securely cleared after write errors.
- Partially formatted session exports are securely cleared after formatting errors.
- Partially formatted read and skill listings are securely cleared after formatting errors.
- Fallback-summary redaction and writer buffers are securely cleared after use.
- JSON result formatting securely clears replaced raw assistant-text copies.
- Partial JSON result-formatting buffers are securely cleared after errors.
- Prompt serialization clears its raw source and parsed JSON tree after encoding.
- Proposed-tool JSON clears each raw input serialization after parsing.
- Dry-run previews clear source, parsed, and encoded tool-input copies after display.
- Voice prompt and preview copies are securely cleared after the turn.
- History-redaction snapshots and serialization buffers use a cleared scratch arena.
- Replaced and removed vault environment copies are securely cleared before release.
- Startup vault injection clears any replaced environment values before swapping them.
- Replaced and removed sensitive `/setup` environment values are securely cleared before release.
- Active route credential and endpoint references refresh after `/setup` and `/secrets` changes.
- Allocated `Bearer` header copies are cleared after model and voice requests.
- In-memory audio, base64, request bodies, and raw transcripts are cleared after transcription; transcripts are scrubbed before display or prompt use.
- HTTP response staging bytes are securely cleared after parsing or transport failure.
- Serialized `/setup` config buffers are securely cleared after writes.
- Parsed `/setup` values and temporary environment copies are securely cleared after use.
- Captured shell output buffers are securely cleared after scrubbed results are prepared.
- Subprocess capture buffers are securely cleared on timeout, output-limit, and allocation errors.
- Read-tool source and redacted intermediate buffers are securely cleared after formatting.
- File-edit source and replacement buffers are securely cleared after completion or failure.
- Project instructions and skill descriptions are scrubbed before entering model context.
- Loaded skill bodies are scrubbed before results are retained, and raw buffers are cleared.
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
