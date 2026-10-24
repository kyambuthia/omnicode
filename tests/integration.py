#!/usr/bin/env python3
"""Exercise the built binary with a local Messages server; no real keys or API calls."""
import json
import fcntl
import os
import struct
import pty
import select
import termios
import time
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BINARY = Path(__file__).resolve().parents[1] / "zig-out/bin/omnicode"


def text(message="done"):
    return {"stop_reason": "end_turn", "content": [{"type": "text", "text": message}]}


def call(name, args, id="tool-1"):
    return {"type": "tool_use", "id": id, "name": name, "input": args}


def tools(*calls):
    return {"stop_reason": "tool_use", "content": list(calls)}


def model(id, prompt="0.000001", completion="0.000002", **pricing):
    return {"id": id, "pricing": dict(prompt=prompt, completion=completion, **pricing),
            "context_length": 65536, "supported_parameters": ["tools"],
            "architecture": {"output_modalities": ["text"]}}


class Integration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cwd = Path(self.tmp.name)
        self.requests = []
        self.catalog_requests = []
        self.catalog_status = 200
        self.catalog = {"data": [model("strong-test-model"), model("fast-test-model"), model("pinned-model"),
                                 model("openai/gpt-4.1-mini", "0.0000004", "0.0000016"),
                                 model("unpriced-custom", overrides=[{"prompt": "0.1"}])]}
        self.reply = lambda _: text()
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                outer.catalog_requests.append((self.path, dict(self.headers)))
                data = json.dumps(outer.catalog).encode()
                self.send_response(outer.catalog_status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                outer.requests.append((body, {k.lower(): v for k, v in self.headers.items()}))
                result = outer.reply(body)
                status, result = result if isinstance(result, tuple) else (200, result)
                data = result if isinstance(result, bytes) else json.dumps(result).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *_):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(self.server.shutdown)
        self.env = {
            "PATH": os.environ.get("PATH", os.defpath),
            "HOME": self.tmp.name,
            "PROVIDER": "anthropic",
            "ANTHROPIC_API_KEY": "fake-anthropic",
            "OPENROUTER_API_KEY": "fake-openrouter",
            "MODEL": "strong-test-model",
            "FAST_MODEL": "fast-test-model",
            "MODELS_URL": f"http://127.0.0.1:{self.server.server_port}/models",
            "API_URL": f"http://127.0.0.1:{self.server.server_port}/v1/messages",
        }

    def run_agent(self, *args, stdin=None):
        return subprocess.run([str(BINARY), *args], input=stdin, text=True,
                              capture_output=True, cwd=self.cwd, env=self.env, timeout=15)

    def run_pty(self, stdin, cols=0):
        """Run with stdout on a pseudo-terminal (stdin piped); return decoded output."""
        master, slave = pty.openpty()
        if cols:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, cols, 0, 0))
        try:
            proc = subprocess.Popen([str(BINARY)], stdin=subprocess.PIPE, stdout=slave, stderr=slave,
                                    cwd=self.cwd, env=self.env)
            os.close(slave)
            slave = None
            try:
                proc.communicate(stdin, timeout=15)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
            chunks = []
            while True:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if not chunk: break
                chunks.append(chunk)
            self.assertEqual(proc.returncode, 0, b"".join(chunks).decode(errors="replace"))
            return b"".join(chunks).decode()
        finally:
            os.close(master)
            if slave is not None: os.close(slave)

    def skill(self):
        path = self.cwd / ".omnicode/skills/check/SKILL.md"
        path.parent.mkdir(parents=True)
        path.write_text("---\nname: check\ndescription: Check the project\n---\nRun checks carefully.\n")

    def test_routes_and_auth_headers(self):
        for provider, prompt, expected in [("anthropic", "list files", "fast-test-model"),
                                            ("openrouter", "FIX the bug", "strong-test-model")]:
            with self.subTest(provider=provider):
                self.env["PROVIDER"] = provider
                result = self.run_agent(prompt)
                self.assertEqual(result.returncode, 0, result.stderr)
                body, headers = self.requests[-1]
                self.assertEqual(body["model"], expected)
                self.assertEqual(headers["anthropic-version"], "2023-06-01")
                if provider == "anthropic":
                    self.assertEqual(headers["x-api-key"], "fake-anthropic")
                    self.assertNotIn("authorization", headers)
                else:
                    self.assertEqual(headers["authorization"], "Bearer fake-openrouter")
                    self.assertNotIn("x-api-key", headers)

    def test_reasoning_blocks_are_preserved_across_tool_continuations(self):
        thinking = {"type": "thinking", "thinking": "private model analysis", "signature": "opaque-signature"}
        redacted = {"type": "redacted_thinking", "data": "opaque-data"}
        self.reply = lambda _: tools(thinking, redacted, call("bash", {"cmd": "printf ok"})) if len(self.requests) == 1 else text()
        result = self.run_agent("fix code")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("private model analysis", result.stdout)
        content = self.requests[-1][0]["messages"][-2]["content"]
        self.assertEqual(content[:2], [thinking, redacted])
        self.requests.clear()
        self.reply = lambda _: tools(call("write", {"path": "should-not-exist", "content": "oops"}), {"type": "thinking"})
        result = self.run_agent("fix code")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.cwd / "should-not-exist").exists())

    def test_live_cost_selection_and_refresh(self):
        self.env["PROVIDER"] = "openrouter"
        self.env.pop("MODEL")
        self.env.pop("FAST_MODEL")
        self.catalog = {"data": [model("z-ai/glm-test", "0.0000002", "0.00000015"),
                                  model("deepseek/test", "0.00000001", "0.0000003")]}
        result = self.run_agent("--cost-max", "lookup")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests[-1][0]["model"], "deepseek/test")
        self.assertIn("catalog $0.0100 in / $0.3000 out", result.stdout)
        result = self.run_agent("fix code")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests[-1][0]["model"], "z-ai/glm-test")
        self.catalog["data"][0]["pricing"]["completion"] = "0.00003"
        self.run_agent("fix code")
        self.assertEqual(self.requests[-1][0]["model"], "deepseek/test")
        self.assertEqual(len(self.catalog_requests), 3)
        self.assertTrue(all("Authorization" not in headers for _, headers in self.catalog_requests))
        self.assertEqual(self.requests[-1][0]["provider"]["sort"], "price")
        self.assertNotIn("max_price", self.requests[-1][0]["provider"])

    def test_free_mode_guards_every_continuation(self):
        self.env.pop("MODEL")
        self.env.pop("FAST_MODEL")
        self.catalog["data"].extend([model("paid-fee:free", "0", "0", request="0.01"),
                                     model("available/tool:free", "0", "0")])
        self.reply = lambda _: tools(call("bash", {"cmd": "printf free"})) if len(self.requests) == 1 else text()
        result = self.run_agent("--verbose", "--free", "fix code")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 2)
        for body, _ in self.requests:
            self.assertEqual(body["model"], "available/tool:free")
            self.assertEqual(body["provider"]["max_price"], {"prompt": 0, "completion": 0, "request": 0, "image": 0})
            self.assertTrue(body["provider"]["require_parameters"])
            self.assertNotIn("models", body)
            self.assertNotIn("fallbacks", body)
        self.assertEqual(len(self.catalog_requests), 1)
        self.assertIn("--free", result.stdout)

    def test_free_mode_survives_repl_model_switches(self):
        self.env.pop("MODEL")
        self.env.pop("FAST_MODEL")
        self.catalog = {"data": [model("available/tool:free", "0", "0")]}
        result = self.run_agent("--free", stdin="/model anthropic claude-haiku-4-5\nhello\n/model auto\nhello\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("provider switch rejected", result.stdout)
        self.assertEqual(len(self.requests), 2)
        self.assertTrue(all(body["provider"]["max_price"]["prompt"] == 0 for body, _ in self.requests))

    def test_policy_flags_preserve_offline_commands_and_literal_prompt(self):
        self.catalog_status = 503
        for flags in (("--free", "--help"), ("--cost-max", "--skills")):
            self.assertEqual(self.run_agent(*flags).returncode, 0)
        self.assertEqual(self.catalog_requests, [])
        result = self.run_agent("--", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests[0][0]["messages"][0]["content"], "--help")

    def test_free_mode_fails_closed_for_paid_overrides_and_catalog_errors(self):
        for mode in ("paid override", "no free models", "catalog unavailable", "invalid catalog"):
            with self.subTest(mode=mode):
                self.env.pop("MODEL", None)
                self.env.pop("FAST_MODEL", None)
                self.catalog_status = 200
                self.catalog = {"data": [model("available/tool:free", "0", "0")]}
                if mode == "paid override":
                    self.catalog["data"].append(model("paid/model"))
                    self.env["FAST_MODEL"] = "paid/model"
                if mode == "no free models": self.catalog = {"data": [model("paid/model")]}
                if mode == "catalog unavailable": self.catalog_status = 503
                if mode == "invalid catalog": self.catalog = {"data": {}}
                result = self.run_agent("--free", "hello")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.requests, [])
        result = self.run_agent("--free", "--cost-max", "hello")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ConflictingOptions", result.stderr)

    def test_all_tools_and_skill_round_trip(self):
        self.skill()
        (self.cwd / "input.txt").write_text("alpha\nbeta\n")
        calls = [call("skill", {"name": "check"}, "s"),
                 call("glob", {"pat": "*.txt"}, "g"),
                 call("grep", {"pat": "beta"}, "p"),
                 call("read", {"path": "input.txt", "offset": 1, "limit": 1}, "r"),
                 call("write", {"path": "output.txt", "content": "before"}, "w"),
                 call("edit", {"path": "output.txt", "old": "before", "new": "after"}, "e"),
                 call("bash", {"cmd": "printf shell-ok"}, "b"),
                 call("read", {"path": "missing"}, "missing"),
                 call("does-not-exist", {}, "unknown"),
                 call("bash", {"cmd": "printf failure >&2; exit 7"}, "failure")]
        self.reply = lambda _: tools(*calls) if len(self.requests) == 1 else text("finished")
        result = self.run_agent("fix the example using tools")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 2)
        first, second = [r[0] for r in self.requests]
        self.assertIn("check: Check the project", first["system"])
        self.assertNotIn("Run checks carefully", first["system"])
        self.assertEqual({t["name"] for t in first["tools"]},
                         {"read", "write", "edit", "glob", "grep", "bash", "skill", "todo", "task"})
        self.assertEqual(first["model"], second["model"])
        messages = second["messages"]
        self.assertEqual([m["role"] for m in messages], ["user", "assistant", "user"])
        results = {r["tool_use_id"]: r for r in messages[-1]["content"]}
        self.assertIn("Run checks carefully", results["s"]["content"])
        self.assertIn("input.txt", results["g"]["content"])
        self.assertIn("input.txt:2:beta", results["p"]["content"])
        self.assertTrue(results["r"]["content"].startswith("2| beta\n"))
        self.assertEqual(results["b"]["content"], "shell-ok")
        self.assertTrue(results["missing"]["is_error"])
        self.assertTrue(results["unknown"]["is_error"])
        self.assertTrue(results["failure"]["is_error"])
        self.assertIn("failure", results["failure"]["content"])
        self.assertEqual((self.cwd / "output.txt").read_text(), "after")
        self.assertIn("finished", result.stdout)

    def test_subagent_task_isolation_explore_restrictions_and_limits(self):
        (self.cwd / "secret.txt").write_text("hidden-intermediate-data\n")
        def reply(body):
            n = len(self.requests)
            if n == 1:
                return dict(tools(call("task", {"prompt": "inspect secret.txt", "mode": "explore"}, "t1")),
                            usage={"input_tokens": 50, "output_tokens": 10, "cost": 0.001})
            if n == 2:
                # Subagent turn 1: read file, attempt forbidden write, attempt nested task.
                return dict(tools(call("read", {"path": "secret.txt"}, "c1"),
                                  call("write", {"path": "nope.txt", "content": "x"}, "c2"),
                                  call("task", {"prompt": "nested"}, "c3")),
                            usage={"input_tokens": 30, "output_tokens": 5, "cost": 0.0005})
            if n == 3:
                return dict(text("subagent final report: found 1 line"),
                            usage={"input_tokens": 40, "output_tokens": 8, "cost": 0.0005})
            return dict(text("parent finished"),
                        usage={"input_tokens": 60, "output_tokens": 12, "cost": 0.001})
        self.reply = reply
        result = self.run_agent(stdin="fix bug with subagent\n/details\n/usage\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.cwd / "nope.txt").exists())
        # Subagent explore mode uses fast-test-model while parent uses strong-test-model.
        self.assertEqual([r[0]["model"] for r in self.requests],
                         ["strong-test-model", "fast-test-model", "fast-test-model", "strong-test-model"])
        # Subagent explore schema excludes write/edit/bash/task.
        self.assertEqual({t["name"] for t in self.requests[1][0]["tools"]},
                         {"read", "glob", "grep", "skill"})
        # Subagent saw ReadOnlySubagent and NestedSubagent errors.
        child_results = {r["tool_use_id"]: r for r in self.requests[2][0]["messages"][-1]["content"]}
        self.assertIn("ReadOnlySubagent", child_results["c2"]["content"])
        self.assertIn("NestedSubagent", child_results["c3"]["content"])
        # Parent history never receives intermediate secret.txt content; only the final report.
        parent_final = json.dumps(self.requests[3][0]["messages"])
        self.assertNotIn("hidden-intermediate-data", parent_final)
        self.assertIn("subagent final report: found 1 line", parent_final)
        # UI indents child tools, /details holds the child report, and usage rolls up.
        self.assertIn("  • read  secret.txt", result.stdout)
        self.assertIn("Subagent usage · 70 in · 13 out", result.stdout)
        self.assertIn("Turn usage · 180 in · 35 out", result.stdout)
        self.assertIn("$0.00300000 reported", result.stdout)
        # Edit-mode subagent and partial report when child hits its turn limit.
        self.requests.clear()
        def limit_reply(body):
            if "tools" not in body:
                return text("child compaction summary")
            if "subagent" in body["system"]:
                return {"stop_reason": "tool_use", "content": [
                    {"type": "text", "text": "working on child step"},
                    call("write", {"path": "child-edit.txt", "content": "edited"}, "cw"),
                ]}
            if len(self.requests) == 1:
                return tools(call("task", {"prompt": "edit file", "mode": "edit", "tier": "strong"}, "t2"))
            return text("parent handled partial report")
        self.reply = limit_reply
        result = self.run_agent("fix with edit subagent")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.cwd / "child-edit.txt").read_text(), "edited")
        self.assertIn("partial report", self.requests[-1][0]["messages"][-1]["content"][0]["content"])

    def test_repl_history_skill_clear_and_model_override(self):
        self.skill()
        result = self.run_agent(stdin="/skills\n/skill check\nlist files\nfix bug\n/model openrouter pinned-model\nlist files\n/model auto\nlist files\n/c\nlist files\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        bodies = [r[0] for r in self.requests]
        self.assertEqual([b["model"] for b in bodies],
                         ["fast-test-model", "strong-test-model", "pinned-model", "fast-test-model", "fast-test-model"])
        self.assertIn("Run checks carefully", bodies[0]["messages"][0]["content"])
        self.assertEqual(len(bodies[1]["messages"]), 4)
        self.assertEqual(len(bodies[-1]["messages"]), 1)
        self.assertEqual(self.requests[2][1]["authorization"], "Bearer fake-openrouter")
        self.assertEqual(self.requests[3][1]["x-api-key"], "fake-anthropic")
        self.assertIn("check: Check the project", result.stdout)

    def test_invalid_responses_do_not_execute_tools(self):
        write = call("write", {"path": "unexpected", "content": "bad"})
        for response in [b"not-json", [], {},
                         {"stop_reason": "max_tokens", "content": [write]},
                         {"stop_reason": "end_turn", "content": [write]},
                         tools(write, write),
                         tools(write, {"type": "tool_use", "name": "write"})]:
            with self.subTest(response=response):
                self.reply = lambda _, r=response: r
                result = self.run_agent("fix bug")
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.cwd / "unexpected").exists())

    def test_api_failure_is_not_retried_or_leaked(self):
        self.reply = lambda _: (429, {"error": "fake-anthropic reflected secret"})
        result = self.run_agent("list files")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.requests), 1)
        self.assertIn("429", result.stderr)
        self.assertNotIn("fake-anthropic", result.stderr + result.stdout)

    def test_failed_repl_turn_resets_history(self):
        self.reply = lambda _: (500, {}) if len(self.requests) == 1 else text()
        result = self.run_agent(stdin="fix bug\nlist files\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests[-1][0]["messages"]), 1)
        self.assertIn("conversation cleared", result.stdout)
        # When tool calls completed before a turn failure, retain a summary instead of wiping history.
        self.requests.clear()
        def partial(_):
            if len(self.requests) == 1:
                return tools(call("write", {"path": "kept.txt", "content": "ok"}))
            if len(self.requests) == 2:
                return (500, {})
            return text("resumed")
        self.reply = partial
        result = self.run_agent(stdin="fix bug\ncontinue\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("completed work retained in summary", result.stdout)
        self.assertIn("<summary>", self.requests[-1][0]["messages"][0]["content"])
        self.assertIn("- tool write: kept.txt", self.requests[-1][0]["messages"][0]["content"])

    def test_loop_is_bounded(self):
        self.reply = lambda body: text("summary of progress") if "tools" not in body else tools(call("bash", {"cmd": "printf ok"}))
        result = self.run_agent("fix bug")
        self.assertNotEqual(result.returncode, 0)
        # 4 windows of 32 tool turns + 3 compactions = 131 requests before TurnLimit.
        self.assertEqual(len(self.requests), 32 * 4 + 3)
        self.assertIn("TurnLimit", result.stderr)
        self.assertIn("3 compaction(s)", result.stdout)

    def test_compaction_commands_and_tool_pair_preservation(self):
        def reply(body):
            if "tools" not in body:
                return text("summary: inspected project and ran checks")
            if len(self.requests) == 1:
                return tools(call("todo", {"items": [{"task": "verify checks", "done": False}]}))
            if len(self.requests) in (2, 4):
                return tools(call("bash", {"cmd": "printf step"}))
            return text("step complete")
        self.reply = reply
        result = self.run_agent(stdin="first step\nsecond step\n/todo\n/context\n/compact focus on checks\n/context\nthird step\n/usage\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1. [ ] verify checks", result.stdout)
        self.assertIn("Context · 10/128 messages", result.stdout)
        self.assertIn("Context compacted.", result.stdout)
        self.assertIn("Context · 1/128 messages", result.stdout)
        self.assertIn("1 compaction(s)", result.stdout)
        summary_req = [r[0] for r in self.requests if "tools" not in r[0]][0]
        self.assertEqual(summary_req["model"], "fast-test-model")
        self.assertIn("Focus especially on: focus on checks", summary_req["messages"][-1]["content"])
        final_msgs = self.requests[-1][0]["messages"]
        self.assertIn("first step", final_msgs[0]["content"])
        self.assertIn("<summary>\nsummary: inspected project and ran checks\n</summary>", final_msgs[0]["content"])
        self.assertIn("<todo>\n1. [ ] verify checks\n</todo>", final_msgs[0]["content"])

    def test_redirects_are_not_followed(self):
        # A redirect must not replay a request carrying credentials.
        self.reply = lambda _: (307, {})
        result = self.run_agent("list files")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.requests), 1)
        self.assertIn("307", result.stderr)

    def test_response_and_history_size_limits(self):
        self.reply = lambda _: text("x" * (2 * 1024 * 1024))
        result = self.run_agent("list files")
        self.assertNotEqual(result.returncode, 0)
        # Oversized history triggers automatic compaction first; if single prompt still exceeds 2 MiB, HistoryLimit fires.
        self.requests.clear()
        self.reply = lambda body: text("compact summary") if "tools" not in body else text("x" * (800 * 1024))
        result = self.run_agent(stdin="step 1\nstep 2\nstep 3\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Context compacted.", result.stdout)
        self.reply = lambda _: text("x" * (2047 * 1024))
        result = self.run_agent(stdin="step 1\nstep 2\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HistoryLimit", result.stdout)

    def test_binary_output_is_a_tool_error(self):
        self.reply = lambda _: tools(call("bash", {"cmd": "printf '\\377'"})) if len(self.requests) == 1 else text()
        result = self.run_agent("fix bug")
        self.assertEqual(result.returncode, 0, result.stderr)
        outcome = self.requests[-1][0]["messages"][-1]["content"][0]
        self.assertTrue(outcome["is_error"])
        self.assertIn("NonUtf8Output", outcome["content"])

    def test_tool_transcript_previews_and_verbose_mode(self):
        def reply(body):
            if isinstance(body["messages"][-1]["content"], str):
                return tools(call("bash", {"cmd": "printf 'first\\n2\\n3\\n4\\n5\\n6\\n7\\nlast\\n'"}))
            return text("finished")
        self.reply = reply
        compact = self.run_agent("list files")
        self.assertEqual(compact.returncode, 0, compact.stderr)
        self.assertIn("• bash  printf", compact.stdout)
        self.assertIn("✓ Done", compact.stdout)
        self.assertIn("3 lines hidden", compact.stdout)
        self.assertIn("last", compact.stdout)
        self.assertIn("1 tool call", compact.stdout)
        self.assertNotIn("\x1b", compact.stdout)
        verbose = self.run_agent("--verbose", "list files")
        self.assertEqual(verbose.returncode, 0, verbose.stderr)
        self.assertNotIn("lines hidden", verbose.stdout)
        self.assertIn("    5\n", verbose.stdout)
        repl = self.run_agent(stdin="/help\n/model\n/verbose on\nlist files\n/verbose off\n/q\n")
        self.assertEqual(repl.returncode, 0, repl.stderr)
        self.assertIn("Full tool output enabled", repl.stdout)
        self.assertNotIn("lines hidden", repl.stdout)
        self.assertIn("fast-test-model", repl.stdout)

    def test_retained_details_replace_and_sanitize(self):
        self.reply = lambda _: tools(call("bash", {"cmd": "printf 'first\\n2\\n3\\n4\\n5\\n6\\nlast\\033[2J'"})) if len(self.requests) == 1 else text()
        result = self.run_agent(stdin="/details\nlist files\n/details\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No retained tool output", result.stdout)
        self.assertIn("Last tool result", result.stdout)
        self.assertIn("    4\n", result.stdout)
        self.assertNotIn("\x1b", result.stdout)

    def test_edit_preview_and_visible_failure(self):
        (self.cwd / "a.txt").write_text("before")
        self.reply = lambda _: tools(call("edit", {"path": "a.txt", "old": "before", "new": "after"}, "edit"),
                                    call("read", {"path": "missing"}, "read")) if len(self.requests) == 1 else text()
        result = self.run_agent("fix file")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("• edit  a.txt", result.stdout)
        self.assertIn("    - before", result.stdout)
        self.assertIn("    + after", result.stdout)
        self.assertIn("✗ Failed", result.stdout)
        self.assertEqual((self.cwd / "a.txt").read_text(), "after")

    def test_model_and_tool_controls_are_neutralized(self):
        self.reply = lambda _: tools(call("bash", {"cmd": "printf '\\033[2Junsafe'"})) if len(self.requests) == 1 else text("hello\x1b[31m world\rhidden")
        result = self.run_agent("list files")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("\x1b", result.stdout)
        self.assertNotIn("\r", result.stdout)
        self.assertIn("unsafe", result.stdout)
        # Display sanitization must not change the data returned to the model.
        self.assertIn("\x1b[2Junsafe", self.requests[-1][0]["messages"][-1]["content"][0]["content"])

    def test_terminal_style_and_no_color(self):
        def reply(_):
            time.sleep(0.25)
            return text("terminal response")
        self.reply = reply
        for no_color in (False, True):
            with self.subTest(no_color=no_color):
                self.env.update(TERM="xterm-256color", COLUMNS="48")
                if no_color: self.env["NO_COLOR"] = "1"
                else: self.env.pop("NO_COLOR", None)
                master, slave = pty.openpty()
                try:
                    proc = subprocess.Popen([str(BINARY)], stdin=subprocess.PIPE, stdout=slave, stderr=slave,
                                            cwd=self.cwd, env=self.env)
                    os.close(slave)
                    slave = None
                    try:
                        proc.communicate(b"list files\n/q\n", timeout=15)
                    finally:
                        if proc.poll() is None:
                            proc.kill()
                            proc.wait()
                    chunks = []
                    while True:
                        try:
                            chunk = os.read(master, 4096)
                        except OSError:
                            break
                        if not chunk: break
                        chunks.append(chunk)
                    output = b"".join(chunks).decode()
                finally:
                    os.close(master)
                    if slave is not None: os.close(slave)
                self.assertEqual(proc.returncode, 0, output)
                self.assertIn("terminal response", output)
                self.assertIn("Thinking...", output)
                self.assertNotIn("\x1b[?1049h", output)
                if no_color: self.assertNotIn("\x1b", output)
                else:
                    self.assertIn("\x1b[1m", output)
                    self.assertIn("\x1b[2m", output)
                    self.assertNotIn("\x1b[1;36m", output)
                    self.assertIn("\x1b[2K", output)

    def test_turn_and_session_usage_survive_conversation_reset(self):
        def reply(_):
            first = len(self.requests) == 1
            result = tools(call("bash", {"cmd": "printf ok"})) if first else text()
            result["usage"] = {"input_tokens": 100 if first else 200,
                               "output_tokens": 10 if first else 20,
                               "cost": 0.001 if first else 0.002}
            return result
        self.reply = reply
        result = self.run_agent(stdin="list files\n/usage\n/c\n/usage\n/model openrouter custom\n/usage\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Turn usage · 300 in · 30 out", result.stdout)
        self.assertEqual(result.stdout.count("Session usage · 300 in · 30 out"), 3)
        self.assertEqual(result.stdout.count("$0.00300000 reported"), 4)
        self.assertEqual(len(self.requests), 2)

    def test_usage_estimates_unknown_prices_and_failed_response(self):
        self.env["PROVIDER"] = "openrouter"
        self.reply = lambda _: dict(text(), usage={"input_tokens": 1000, "output_tokens": 100})
        self.env["FAST_MODEL"] = "openai/gpt-4.1-mini"
        result = self.run_agent("hello")
        self.assertIn("$0.00056000 estimated", result.stdout)
        self.env["FAST_MODEL"] = "unpriced-custom"
        result = self.run_agent("hello")
        self.assertIn("cost unavailable for 1 response", result.stdout)
        self.assertNotIn("$0.00000000", result.stdout)
        self.reply = lambda _: {"stop_reason": "max_tokens", "usage": {"input_tokens": 7, "output_tokens": 8, "cost": 0.004}}
        result = self.run_agent("hello")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Turn usage · 7 in · 8 out", result.stdout)
        self.assertIn("$0.00400000 reported", result.stdout)

    def test_raw_input_paste_cancel_eof_and_terminal_restore(self):
        self.env.update(TERM="xterm-256color")
        self.env.pop("NO_COLOR", None)
        for finish in (b"/q\r", b"\x04"):
            with self.subTest(finish=finish):
                master, slave = pty.openpty()
                original = termios.tcgetattr(slave)
                restored_during_request = []
                def reply(_):
                    restored_during_request.append(termios.tcgetattr(slave) == original)
                    return text("paste accepted")
                self.reply = reply
                proc = subprocess.Popen([str(BINARY)], stdin=slave, stdout=slave, stderr=slave,
                                        cwd=self.cwd, env=self.env)
                output = bytearray()
                def until(marker):
                    deadline = time.monotonic() + 15
                    while marker not in output:
                        self.assertLess(time.monotonic(), deadline, output.decode(errors="replace"))
                        if select.select([master], [], [], 0.1)[0]:
                            output.extend(os.read(master, 4096))
                try:
                    until(b"\x1b[?2004h")
                    self.assertFalse(termios.tcgetattr(slave)[3] & termios.ICANON)
                    output.clear()
                    os.write(master, b"discard me\x1b\x03")
                    until(b"\x1b[?2004h")
                    self.assertIn(b"^C", output)
                    output.clear()
                    if finish == b"/q\r":
                        payload = b"\x1b[200~" + b"x" * (16 * 1024 + 1) + b"\x1b[201~\r"
                        def write_overflow():
                            view = memoryview(payload)
                            while view:
                                view = view[os.write(master, view):]
                        writer = threading.Thread(target=write_overflow, daemon=True)
                        writer.start()
                        until(b"InputTooLong")
                        until(b"\x1b[?2004h")
                        writer.join(timeout=2)
                        self.assertFalse(writer.is_alive())
                        self.assertEqual(self.requests, [])
                        output.clear()
                    os.write(master, b"\x1b[200~explain first\r\nsecond\x1b[201~")
                    time.sleep(0.1)
                    self.assertEqual(len(self.requests), 0)
                    os.write(master, b"\r")
                    until(b"paste accepted")
                    until(b"\x1b[?2004h")
                    os.write(master, finish)
                    proc.wait(timeout=10)
                    self.assertEqual(proc.returncode, 0)
                    self.assertEqual(termios.tcgetattr(slave), original)
                    self.assertTrue(all(restored_during_request))
                    self.assertEqual(self.requests[-1][0]["messages"][0]["content"], "explain first\nsecond")
                    self.requests.clear()
                finally:
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait()
                    os.close(slave)
                    os.close(master)

    def test_status_line_model_directory_time_and_modes(self):
        self.env.update(TERM="xterm-256color", TZ="UTC")
        self.env.pop("NO_COLOR", None)
        (self.cwd / "nested").mkdir()
        self.cwd = self.cwd / "nested"
        output = self.run_pty(b"list files\n/model anthropic pinned-model\n/status title\n/status off\n/status bogus\n/q\n", cols=100)
        lines = [l for l in output.replace("\r", "").split("\n") if " · " in l and "anthropic" in l and "~" in l]
        self.assertGreaterEqual(len(lines), 2, output)
        self.assertRegex(lines[0], r"anthropic · auto · ~/nested · \d\d:\d\d")
        self.assertIn("auto → fast-test-model", lines[1])
        self.assertIn("anthropic · pinned-model · ~/nested", output)
        self.assertIn("\x1b]0;omnicode · anthropic · pinned-model", output)
        self.assertIn("\x1b[22;0t", output)
        self.assertIn("\x1b[23;0t", output)
        self.assertIn("usage: /status inline|title|off (current: off)", output)
        # Width comes from the terminal, not COLUMNS; the line never exceeds it.
        self.env["COLUMNS"] = "160"
        output = self.run_pty(b"/q\n", cols=50)
        status = [l for l in output.replace("\r", "").split("\n") if "anthropic · auto · " in l][0]
        self.assertLessEqual(len(status.replace("\x1b[2m", "").replace("\x1b[0m", "")), 49)
        # Plain output and OMNICODE_STATUS=off never print it; invalid modes are rejected.
        result = self.run_agent(stdin="/q\n")
        self.assertNotIn("anthropic · auto · ~", result.stdout)
        self.env["OMNICODE_STATUS"] = "off"
        self.assertNotIn("anthropic · auto · ~", self.run_pty(b"/q\n"))
        self.env["OMNICODE_STATUS"] = "pinned-typo"
        self.assertIn("InvalidStatusMode", self.run_agent(stdin="/q\n").stderr)

    def test_offline_commands_and_missing_key(self):
        self.skill()
        self.env.pop("ANTHROPIC_API_KEY")
        for args in [("--help",), ("--skills",)]:
            self.assertEqual(self.run_agent(*args).returncode, 0)
        result = self.run_agent("list files")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MissingApiKey", result.stderr)
        self.assertEqual(self.requests, [])


if __name__ == "__main__":
    unittest.main()
