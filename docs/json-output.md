# JSON output for one-shot tasks

Use `--json` with a task prompt when another program needs a structured result:

```sh
omnicode --json "Summarize the current project"
```

The command writes one JSON object followed by a newline to stdout. Progress,
tool previews, and diagnostics go to stderr. A successful result has this shape:

```json
{
  "ok": true,
  "text": "Final assistant response",
  "usage": { "requests": 1, "input": 0, "output": 0, "read": 0, "write": 0, "missing": 1, "unknown_cost": 1, "estimated": 0, "compactions": 0, "usd": 0 },
  "dry_run": false,
  "proposed_tools": []
}
```

`usage` reflects responses returned during this one-shot task. Missing usage
and unknown cost are counted explicitly; `usd: 0` with `unknown_cost > 0` is
not a free request. With `--dry-run`, `proposed_tools` contains the first
proposed batch as objects with `name` and `input`; those tools are not run.
Registered secrets are redacted in `text` and `proposed_tools`.

If the task fails, the process exits nonzero and stdout contains a JSON object
such as `{"ok":false,"error":"ApiRateLimited"}`. `--json` requires a prompt;
the REPL and offline setup commands use their normal text interface. `--help`
and `--version` also retain their normal text output.
