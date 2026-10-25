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
| Journalbox initial build | 36 | 2 | 14 tests pass; separate oversized SQLite ID probe exposed an HTTP 500 |
| Journalbox boundary repair | 49 | 1 | 17 tests pass; independent raw HTTP probes return 404 for oversized IDs and 413 for a 5,000-digit Content-Length, with empty server stderr |
| Intervalkit first named session | 12 | 0 | 15 tests pass; 300 independent randomized merge checks pass |
| Intervalkit resumed extension | 16 | 1 | 29 tests pass; 500 independent randomized gap checks pass; complete 18-message prefix retained in the final 42-message checkpoint |
| Intervalkit JSON CLI extension | 42 | 6 | 44 tests pass; 80 independent randomized CLI checks, nine invalid-input classes, and the exact 1 MiB input boundary pass |

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

## Longer project continuity

Journalbox was built and repaired through paid CLI tasks, with the initial build
and boundary repair committed in the project as `fc4c6a8` and `422a34f`. Its
initial build took 215 seconds; the boundary repair took 186 seconds. A completed task with passing self-authored tests does not imply bug-free
output: independent behavior probes still found the oversized-ID bug. One verification command also used a pipeline that
masked the test runner's exit status; shell guidance now asks the model to run
verification commands directly.

Named one-shot sessions (`--session NAME`) now retain complete tool rounds and
checklists across invocations. Offline integration tests interrupt a task with
an API error after a successful write, then verify that a new invocation sees
the saved history and completed effect. Additional checks cover private file
permissions, secret redaction, malformed archive preservation, and compaction
when a saved history is full. This is retained context, not transactional replay.

Intervalkit exercised the installed ReleaseSafe binary with two paid invocations
of `--session milestone`. They took 23.0 and 37.2 seconds, and committed the
project as `3e4a8b1` and `a4c0b6e`. The checkpoint retained its checklist and mode
`0600`; session files stayed ignored by Git. Independent checks compared covered
and missing integer sets, ordering, adjacency, generators, input preservation,
and invalid endpoint handling. The second task also repaired default unittest
discovery, which had found zero tests despite the explicit test-directory command
passing. The built-in workflow now asks for observed test discovery and results.

A separate paid read-only review of the session feature ended inconclusively:
its compaction summary reached the output limit. This exposed a recovery gap,
not a supported defect in the reviewed feature. Compaction now retries a
truncated summary once with an 8,192-token budget, discards partial summaries,
and preserves history if both attempts fail. Offline tests cover successful
retry and exhausted retry without history replacement.

A paid `/resume milestone` → `/compact` → `/save compacted` pass on the updated
binary successfully reduced Intervalkit's 42-message history to four messages,
retaining its original goal and checklist with mode `0600`. This particular
summary completed on the first attempt; bounded retry behavior is covered by
the local API fixtures rather than inferred from this successful paid call.

The third Intervalkit invocation resumed the same named session and committed a
JSON CLI as `4822d12`. It completed in 141.1 seconds through two automatic
compactions; both summaries completed without retry. The final valid checkpoint
contained 20 messages. Independent subprocess probes covered malformed JSON,
invalid UTF-8, bool endpoints, NaN/Infinity, excessive nesting, oversized integer
literals, non-array input, oversized input, and the accepted exact byte limit.

Two shell calls used the unadvertised `command` field instead of `cmd`; this
was confirmed by inspecting input field names in the live checkpoint. Runtime
execution now accepts `command` as a compatibility alias while continuing to
advertise `cmd` as canonical. A shared resolver rejects conflicting values and
invalid types, and drives execution, the command preview, and retained summaries.
Offline regressions verify that conflicting, mistyped, and NUL-containing inputs
do not execute, while both supported spellings preserve execution status.

## Repeatable paid continuation evaluation

```sh
python3 tests/live_agent.py --allow-paid-api --exercise-resume
```

The first run against the installed ReleaseSafe binary created
`evals/counter-repair-qimz5h4e` and passed in 28.47 seconds with 16 tool calls and
one failed tool (the expected failing baseline test command). Both paid tasks
exited zero; independent repair and extension references passed. The named
checkpoint retained the full earlier message prefix, ended with an assistant
response, and had mode `0600`. The evaluator retains separate agent/reference
logs for both tasks and reports these outcomes in `result.json`. This is one
successful run, not a model reliability estimate.

## Linux interruption recovery

An independent SIGINT probe reproduced a command descendant writing after the
CLI had exited. Timeouts already cancelled command groups, but the OS signal
bypassed the structured cancellation path. The Linux entry point now records
SIGINT/SIGTERM with a lock-free atomic, observes it outside the handler, cancels
active work, and waits for cleanup before returning status 130/143. Parent and
child tool loops and REPL recovery paths propagate `Canceled` instead of
converting it into a failed tool followed by another model request.

Offline regressions cover both signals during command execution, an interrupted
child agent, raw terminal restoration, idle piped input, and an in-flight API
request with no follow-up request. A pending-signal check also handles work
finishing before the watcher tick; the input-close race passed 12 repeated
focused runs. The code compiled for both native Linux and aarch64 Linux.

The handler performs no logging, allocation, or process cleanup. Reference:
[Linux signal safety](https://man7.org/linux/man-pages/man7/signal-safety.7.html),
plus the pinned Zig 0.17 `std.posix.sigaction`, `std.atomic.Value`, and
`std.Io.Select` source contracts.

A paid read-only review then highlighted the remaining handler-lifetime window
after the first completion check. The final signal check now runs after both
structured cleanup and restoration of the prior handlers, including ordinary
error paths. Its proposed timing-only reproduction was not treated as proof: a
zero exit can also belong to a process that finished before signal delivery.

After installation of the interruption fixes, all five focused signal tests
also passed against `~/.local/bin/omnicode`. A second paid continuation evaluation
created `evals/counter-repair-48bo3sgi` and passed in 34.01 seconds with 18 tool
calls and zero reported tool errors. Both independent reference stages passed,
the full earlier history prefix was retained, and the checkpoint remained
private and complete. Tool-error counts are execution-status observations, not
a substitute for those independent references.

## Read-only investigation of long lines

A paid read-only task in `catalog-scan` inspected a 77,077-byte single-line JSON
file using a byte window around offset 69,000. It returned the exact Unicode
marker and count in 4.7 seconds with four tool calls and no failed tools. The
final JSON response matched a separate reference, and the tracked project files
remained unchanged. The named local checkpoint was explicitly requested by the
CLI caller.

`read` now offers `byte_offset`/`byte_limit` alongside its existing line mode.
It redacts the complete file before slicing, aligns UTF-8 boundaries, reports
actual ranges and the next offset, and keeps results below 64 KiB. Unit and
integration regressions cover long lines, UTF-8 progress, secret fragments at
window edges, mixed-mode rejection, invalid bounds/encoding, and file/output
limits. UTF-8 boundaries follow [RFC 3629](https://www.rfc-editor.org/rfc/rfc3629).

The boundary tests exposed Zig 0.17's exclusive `readFileAlloc` limit: a file
whose size equals the supplied limit is rejected. An exact 1 MiB source file
could be written but not read; an exact 2 MiB session could be saved but not
loaded. The latter failure was reproduced by a serialized round-trip unit test
before the loader fix. Readers now reserve one probe byte, making the documented
limits inclusive. Exact-limit session/config/vault fixtures pass; one byte over
is still rejected without replacing prior live state or a saved config/vault.
