# Paid agent evaluations — 2026-10-25

These runs used the real Omnicode CLI and paid `deepseek-flash` through DeepSeek's
Anthropic-compatible endpoint. Projects are retained under
`~/Projects/omnicode-lab/`. Credentials were loaded by Omnicode, never copied into
fixtures or source control. Provider responses did not report dollar costs.

| Project/run | Tool calls | Failed tools | Independent outcome |
| --- | ---: | ---: | --- |
| Taskledger initial build | 121 | 40 | 17 tests pass; Unicode, monotonic IDs after deletion, malformed-store preservation checked separately |
| CSV Audit initial build | 32 | 2 | Found a missed malformed-quote case and default discovery running zero tests |
| CSV Audit follow-up repair | 26 | 2 | 28 tests pass; malformed quotes, BOMs, embedded newlines, duplicates checked separately |
| Taskledger JSON-list extension | 27 | 2 | 23 tests pass; filtered JSON, Unicode, and missing-store behavior checked separately |
| Counter repair evaluation 1 | 9 | 0 | Seeded failing tests repaired; independent Unicode/iterator/input-preservation checks pass |
| Counter repair evaluation 2 | 10 | 1 | Same independent checks pass; one shell syntax failure recovered |

Failed-tool counts include expected failures while reproducing bugs. These are
individual, different tasks, not a controlled model-quality comparison or a
success-rate estimate. The counter runs took 23.00 and 16.81 seconds respectively.

## Findings that changed Omnicode

- Taskledger attempted nested writes before creating their parent directory.
  `write` now creates missing parents after path/content validation. Read-only
  requests are rejected before directories can be created.
- Taskledger made 26 malformed calls that returned only `MissingField`.
  Argument errors now include the expected tool input schema without echoing
  supplied values. In the CSV follow-up, a malformed Bash-tool call received that
  schema and the next command successfully executed the test suite.
- Current DeepSeek documentation advertises `deepseek-flash` and
  `deepseek-v4-pro`; built-in defaults and menu presets now use those names.
- New `--read-only` model-tool enforcement supports code investigation without
  allowing mutation or delegation through unadvertised model tool calls.

## Repeatable repair evaluation

```sh
zig build
python3 tests/live_agent.py --allow-paid-api --binary ./zig-out/bin/omnicode
```

The script creates a fresh counter project, verifies that the seed fails, runs
Omnicode, and checks the result independently of the tests the agent can edit.
It retains `baseline.log`, `agent.log`, `reference.log`, and `result.json` in the
created project. API authorization is explicit; offline integration tests do not
invoke this script. A zero agent exit alone does not count as success: the
reference checks must also pass.

## Follow-up areas

- Measure the same repair cases across multiple runs before claiming an efficiency gain.
- Keep independent behavior checks: self-authored tests missed a CSV parsing bug.
- Shell capabilities are now advertised: the tool named `bash` executes POSIX
  `sh -c`; Bash-specific syntax requires an explicit Bash invocation.

## Recovery and execution follow-up

A paid read-only review flagged output-prefix error classification. Its suggested
file-read reproducer was invalid because reads add line numbers, but a successful
`printf 'error: example'` command reproduced the bug. Tool results now carry an
execution status independently of output text, for both parent and child agents.

Independent failure-summary tests also exposed split UTF-8 and partial secret
retention at raw byte cutoffs. Complete values are now redacted before shortening
on UTF-8 boundaries. Finally, a timeout reproduction showed a shell descendant
writing a file after the reported deadline. Interrupted commands now receive
process-group cleanup, with regressions for ordinary descendants and leaders
that ignore SIGTERM. These remain trusted local commands, not a sandbox.

Primary references: [DeepSeek Anthropic API](https://api-docs.deepseek.com/guides/anthropic_api/),
[Python 3.13 CSV strict parsing](https://docs.python.org/3.13/library/csv.html#csv.Dialect.strict).
