#!/usr/bin/env python3
"""Opt-in paid CLI evaluation; creates a repair project and verifies its behavior."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


REFERENCE = '''import counter
cases = [([], {}), (["A", " a ", "B"], {"a": 2, "b": 1}),
         (["", " ", "\\t"], {}), (["Straße", "STRASSE"], {"strasse": 2}),
         (["東京", "東京", "京都"], {"東京": 2, "京都": 1})]
for values, expected in cases:
    original = values.copy()
    actual = counter.tally(values)
    assert actual == expected, (values, expected, actual)
    assert values == original, "input mutated"
assert counter.tally(iter([" X ", "x"])) == {"x": 2}
print("reference checks passed")
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--allow-paid-api", action="store_true", required=True,
                        help="authorize real DeepSeek API calls through Omnicode")
    parser.add_argument("--binary", default=shutil.which("omnicode") or "omnicode")
    parser.add_argument("--model", default="deepseek-flash")
    parser.add_argument("--projects", type=Path,
                        default=Path.home() / "Projects/omnicode-lab/evals")
    parser.add_argument("--exercise-resume", action="store_true",
                        help="also extend the repaired project through a named session (two paid tasks)")
    parser.add_argument("--timeout", type=int, default=600, help="deadline per paid task in seconds")
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    binary = shutil.which(args.binary)
    if not binary:
        parser.error("Omnicode binary not found")
    binary = str(Path(binary).resolve())
    args.projects.mkdir(parents=True, exist_ok=True)
    project = Path(tempfile.mkdtemp(prefix="counter-repair-", dir=args.projects)).resolve()
    (project / "counter.py").write_text('def tally(values):\n    return {}\n')
    (project / "test_counter.py").write_text('''import unittest
from counter import tally

class CounterTests(unittest.TestCase):
    def test_counts(self):
        self.assertEqual(tally(["A", " a ", "B"]), {"a": 2, "b": 1})
    def test_blanks(self):
        self.assertEqual(tally(["", " "]), {})

if __name__ == "__main__":
    unittest.main()
''')
    (project / "OMNICODE.md").write_text('''# Counter repair project
Repair tally(values) in counter.py. It accepts an iterable of strings, trims
whitespace, casefolds Unicode, ignores empty values, and returns a count dict.
Preserve inputs. Use only Python's standard library. Work in this directory.
Inspect the existing implementation and tests, reproduce the failing tests,
implement the repair, add edge tests, and execute the tests again. Do not delegate.
Report exact verification commands and observed results.
''')
    baseline = subprocess.run(["python3", "-m", "unittest", "-v"], cwd=project,
                              capture_output=True, text=True, timeout=30)
    (project / "baseline.log").write_text(baseline.stdout + baseline.stderr)
    if baseline.returncode != 1:
        raise RuntimeError("invalid evaluation: seeded project should fail")
    env = dict(os.environ, PROVIDER="deepseek", MODEL=args.model, FAST_MODEL=args.model,
               API_URL="https://api.deepseek.com/anthropic/v1/messages",
               MAX_TURNS="12", MAX_TOKENS="8192")
    started = time.monotonic()
    session_args = ["--session", "repair"] if args.exercise_resume else []
    def invoke(prompt, filename):
        with (project / filename).open("w") as log:
            try:
                agent = subprocess.run([binary, *session_args, prompt], cwd=project, env=env,
                                       stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
                return agent.returncode, False
            except subprocess.TimeoutExpired:
                return None, True
    agent_exit, timed_out = invoke("Read OMNICODE.md and complete the repair. "
                                  "Reproduce the failure, fix the implementation, add edge "
                                  "tests, run all tests, and report the results.", "agent.log")
    reference = subprocess.run(["python3", "-c", REFERENCE], cwd=project,
                               capture_output=True, text=True, timeout=30)
    (project / "reference.log").write_text(reference.stdout + reference.stderr)
    resume = {}
    if args.exercise_resume and agent_exit == 0 and reference.returncode == 0:
        snapshot = project / ".omnicode/sessions/repair.json"
        before = json.loads(snapshot.read_text())["messages"]
        resumed_exit, resumed_timeout = invoke(
            "Extend the repaired project from our saved progress. Add tally_total(values) "
            "to counter.py, returning (counts, total), where counts uses the existing tally "
            "normalization rules and total is the number of nonblank normalized items. "
            "Accept one-pass iterators and preserve inputs. Add edge tests, run them, and "
            "report results. Keep the existing tally API. Do not delegate.", "resume.log")
        extra = REFERENCE + '''for values in [[], ["A", " a ", ""], ["Straße", "STRASSE", " "]]:
    original = values.copy()
    expected = counter.tally(values)
    assert counter.tally_total(iter(values)) == (expected, sum(expected.values()))
    assert values == original
print("resumed extension checks passed")
'''
        checked = subprocess.run(["python3", "-c", extra], cwd=project,
                                 capture_output=True, text=True, timeout=30)
        (project / "resume-reference.log").write_text(checked.stdout + checked.stderr)
        after = json.loads(snapshot.read_text())["messages"]
        prefix = after[:len(before)] == before
        checkpoint_valid = (bool(after) and after[-1]["role"] == "assistant" and
                            snapshot.stat().st_mode & 0o777 == 0o600)
        resume = {"resumed_agent_exit": resumed_exit, "resumed_timed_out": resumed_timeout,
                  "resumed_reference_exit": checked.returncode, "history_prefix_retained": prefix,
                  "checkpoint_valid": checkpoint_valid,
                  "resumed_passed": resumed_exit == 0 and checked.returncode == 0 and checkpoint_valid}
    log = (project / "agent.log").read_text(errors="replace")
    if (project / "resume.log").exists():
        log += (project / "resume.log").read_text(errors="replace")
    result = {"project": str(project), "model": args.model, "baseline_exit": baseline.returncode,
              "agent_exit": agent_exit, "timed_out": timed_out,
              "reference_exit": reference.returncode,
              "elapsed_seconds": round(time.monotonic() - started, 2),
              "tool_calls": log.count("• "), "failed_tools": log.count("✗ Failed"),
              "passed": agent_exit == 0 and reference.returncode == 0 and
                        (not args.exercise_resume or resume.get("resumed_passed", False)), **resume}
    (project / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2), flush=True)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
