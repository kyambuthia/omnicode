# Changelog

User-visible changes are recorded here from the 0.2.0 baseline onward. Add
entries under `Unreleased` as changes land, then move them into a dated version
section for a release. Put incompatible changes under `Breaking changes`.

## Unreleased

### Breaking changes

- Tool calls now reject unrecognized input fields instead of silently ignoring
  them. Invalid calls return the expected tool input schema for recovery.

### Added

- Contributor instructions and a change history for future releases.
- `--dry-run` previews the first proposed tool batch and stops before executing
  any tool calls.
- `/export [name]` writes a redacted Markdown transcript and checklist to a
  private file under `.omnicode/exports/`.

## 0.2.0

The 0.2.0 tag is the baseline for this changelog. See the repository history
for changes made before and after that tag.
