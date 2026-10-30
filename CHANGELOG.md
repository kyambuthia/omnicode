# Changelog

User-visible changes are recorded here from the 0.2.0 baseline onward. Add
entries under `Unreleased` as changes land, then move them into a dated version
section for a release. Put incompatible changes under `Breaking changes`.

## Unreleased

## 0.3.0 - 2026-10-30

### Breaking changes

- Tool calls now reject unrecognized input fields instead of silently ignoring
  them. Invalid calls return the expected tool input schema for recovery.

### Added

- OpenAI Chat Completions support, including tool-call conversion, for OpenAI, Gemini, Mistral, Together, Fireworks, Cerebras, DeepInfra, and NVIDIA NIM.
- Six direct provider presets (Mistral, Together, Fireworks, Cerebras, DeepInfra, NVIDIA) and a configurable custom endpoint using either OpenAI Chat Completions or Anthropic Messages.
- `/model` and `/model list` discover models from the active provider's standard `/models` API when available; `API_MODELS_URL` overrides discovery for custom gateways.
- RunInfra provider support through its Anthropic-compatible Messages API, using `RUNINFRA_API_KEY` or `RUNINFRA_GATEWAY_KEY`.
- Contributor instructions and a change history for future releases.
- `--dry-run` previews the first proposed tool batch and stops before executing
  any tool calls.
- `/export [name]` writes a redacted Markdown transcript and checklist to a
  private file under `.omnicode/exports/`.
- `/model compare` lists eligible OpenRouter models in recent median throughput
  order with catalog input and output prices before selecting a model number.
- `--json` emits one structured result for a one-shot task, including final
  text, usage, and proposed tools in dry-run mode. Progress is sent to stderr.
- Model requests are paced to 60 starts per minute by default across turns and
  delegated work. `MAX_REQUESTS_PER_MINUTE` sets 1–600 or 0 to disable pacing.

## 0.2.0

The 0.2.0 tag is the baseline for this changelog. See the repository history
for changes made before and after that tag.
