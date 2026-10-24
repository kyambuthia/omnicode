#!/usr/bin/env python3
"""Exercise the built binary with a local Messages server; no real keys or API calls."""
import json
import os
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


class Integration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cwd = Path(self.tmp.name)
        self.requests = []
        self.reply = lambda _: text()
        outer = self

        class Handler(BaseHTTPRequestHandler):
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
            "API_URL": f"http://127.0.0.1:{self.server.server_port}/v1/messages",
        }

    def run_agent(self, *args, stdin=None):
        return subprocess.run([str(BINARY), *args], input=stdin, text=True,
                              capture_output=True, cwd=self.cwd, env=self.env, timeout=15)

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
                         {"read", "write", "edit", "glob", "grep", "bash", "skill"})
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

    def test_loop_is_bounded(self):
        self.reply = lambda _: tools(call("bash", {"cmd": "printf ok"}))
        result = self.run_agent("fix bug")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.requests), 32)
        self.assertIn("TurnLimit", result.stderr)

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
        self.reply = lambda _: text("x" * (1024 * 1024 + 100))
        result = self.run_agent(stdin="list files\nlist files\nlist files\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HistoryLimit", result.stdout)

    def test_binary_output_is_a_tool_error(self):
        self.reply = lambda _: tools(call("bash", {"cmd": "printf '\\377'"})) if len(self.requests) == 1 else text()
        result = self.run_agent("fix bug")
        self.assertEqual(result.returncode, 0, result.stderr)
        outcome = self.requests[-1][0]["messages"][-1]["content"][0]
        self.assertTrue(outcome["is_error"])
        self.assertIn("NonUtf8Output", outcome["content"])

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
