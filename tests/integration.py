#!/usr/bin/env python3
"""Exercise the built binary with a local Messages server; no real keys or API calls."""
import json
import fcntl
import os
import re
import struct
import pty
import select
import signal
import shutil
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
    def test_invalid_sessions_preserve_live_history_and_checklist(self):
        sessions = self.cwd / ".omnicode/sessions"
        sessions.mkdir(parents=True)
        def reply(_):
            if len(self.requests) == 1:
                return tools(call("todo", {"items": [{"task": "keep progress", "done": True}]}))
            return text("original answer")
        self.reply = reply
        invalid = [
            {"messages": [{"role": "user", "content": 42}]},
            {"messages": [{"role": "assistant", "content": []}]},
            {"messages": [{"role": "assistant", "content": [{"type": "text", "text": False}]}]},
            {"messages": [{"role": "assistant", "content": [call("read", [], "bad-input")]}]},
            {"messages": [{"role": "user", "content": [{"type": "tool_result", "tool_use_id": "x", "is_error": "false"}]}]},
            {"messages": [{"role": "user", "content": [{"type": "text", "text": "first"},
                          {"type": "tool_result", "tool_use_id": "x", "content": "late"}]}]},
            {"messages": [{"role": "assistant", "content": [call("read", {"path": "x"}, "pending")]}]},
            {"messages": [{"role": "user", "content": [{"type": "tool_result", "tool_use_id": "orphan", "content": "ok"}]}]},
            {"messages": [{"role": "assistant", "content": [call("read", {"path": "x"}, "expected")]},
                          {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "wrong", "content": "ok"}]}]},
            {"messages": [], "todo": 42},
            {"messages": [], "todo": "x" * 4097},
        ]
        commands = ["original goal", "/save original"]
        for index, snapshot in enumerate(invalid):
            (sessions / f"bad{index}.json").write_text(json.dumps(snapshot))
            commands.extend([f"/resume bad{index}", f"/save after{index}"])
        result = self.run_agent(stdin="\n".join(commands + ["/q", ""]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("InvalidSession"), len(invalid))
        original = json.loads((sessions / "original.json").read_text())
        for index in range(len(invalid)):
            self.assertEqual(json.loads((sessions / f"after{index}.json").read_text()), original)
        self.assertEqual(len(self.requests), 2)

    def test_unsafe_endpoints_are_rejected_before_network_or_persistence(self):
        unsafe = f"http://localhost:{self.server.server_port}/v1/messages"
        self.env["API_URL"] = unsafe
        result = self.run_agent("list files")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("InsecureEndpoint", result.stderr)
        self.assertEqual(self.requests, [])
        self.env["API_URL"] = f"http://127.0.0.1:{self.server.server_port}/v1/messages"
        self.env["PROVIDER"] = "openrouter"
        self.env["MODELS_URL"] = unsafe
        result = self.run_agent("list files")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("InsecureEndpoint", result.stderr)
        self.assertEqual(self.catalog_requests, [])
        self.assertEqual(self.requests, [])
        self.env["PROVIDER"] = "anthropic"
        self.env["VOICE_URL"] = unsafe
        self.env["VOICE_MODEL"] = "fixture-voice"
        (self.cwd / "clip.wav").write_bytes(b"RIFFfixtureWAVE")
        result = self.run_agent(stdin="/voice clip.wav\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("InsecureEndpoint", result.stdout)
        self.assertIn("literal loopback", result.stdout)
        self.assertEqual(self.requests, [])
        config = self.cwd / ".config/omnicode/config.env"
        for args in (("--providers", "url", unsafe),
                     ("--setup", "set", "VOICE_URL", unsafe),
                     ("--setup", "set", "MODELS_URL", unsafe)):
            result = self.run_agent(*args)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("InsecureEndpoint", result.stderr)
            self.assertFalse(config.exists())

    def test_shell_timeout_and_failed_checklist_recovery(self):
        def reply(_):
            if len(self.requests) == 1:
                return tools(call("todo", {"items": [{"task": "preserve this", "done": True}]}))
            if len(self.requests) == 2:
                return tools(call("todo", {"items": [{"task": "overwrite", "done": False},
                                                      {"task": "", "done": False}]}))
            if len(self.requests) == 3:
                return tools(call("bash", {"cmd": "touch forbidden", "timeout_ms": 300001}, "invalid"),
                             call("bash", {"cmd": "exec sleep 1", "timeout_ms": 10}, "timeout"),
                             call("bash", {"cmd": "printf recovered", "timeout_ms": 300000}, "ok"))
            return text("finished")
        self.reply = reply
        result = self.run_agent(stdin="verify work\n/todo\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1. [x] preserve this", result.stdout)
        self.assertFalse((self.cwd / "forbidden").exists())
        results = {block["tool_use_id"]: block["content"]
                   for block in self.requests[-1][0]["messages"][-1]["content"]}
        self.assertIn("InvalidTimeout", results["invalid"])
        self.assertIn("10ms deadline", results["timeout"])
        self.assertNotIn("30s deadline", results["timeout"])
        self.assertIn("integer from 1 to 300000", results["invalid"])
        self.assertEqual(results["ok"], "recovered")
        bash = next(tool for tool in self.requests[0][0]["tools"] if tool["name"] == "bash")
        self.assertEqual(bash["input_schema"]["properties"]["timeout_ms"]["maximum"], 300000)

    def test_terminal_redacts_provider_text_and_tool_previews(self):
        secret = "vault-secret-demo-998"
        (self.cwd / "edit-me").write_text(secret)
        def reply(_):
            if len(self.requests) == 1:
                return {"stop_reason": "max_tokens", "content": [
                    {"type": "text", "text": "partial " + secret}]}
            if len(self.requests) == 2:
                return tools(
                    call("bash", {"cmd": f"printf %s '{secret}' > marker"}, "literal"),
                    call("edit", {"path": "edit-me", "old": secret, "new": "updated " + secret}, "edit"),
                )
            return text("final " + secret + " fake-anthropic")
        self.reply = reply
        result = self.run_agent(stdin=f"/secrets set TOKEN {secret}\ncheck it\n/details\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[REDACTED:TOKEN]", result.stdout)
        self.assertIn("[REDACTED:ANTHROPIC_API_KEY]", result.stdout)
        self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertNotIn("fake-anthropic", result.stdout + result.stderr)
        self.assertEqual((self.cwd / "marker").read_text(), secret)
        self.assertEqual((self.cwd / "edit-me").read_text(), "updated " + secret)
        for body, _ in self.requests:
            self.assertNotIn(secret, json.dumps(body))

    def test_config_round_trip_preserves_quotes_and_migrates_legacy_values(self):
        config = self.cwd / ".config/omnicode/config.env"
        config.parent.mkdir(parents=True)
        config.write_text('MODEL="legacy model"\nFAST_MODEL=\'legacy fast\'\n')
        self.env.pop("MODEL", None)
        self.env.pop("FAST_MODEL", None)
        result = self.run_agent("--setup", "set", "VOICE_MODEL", "fixture-voice")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.reply = lambda _: text("done")
        result = self.run_agent("inspect project")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.requests[-1][0]["model"], ("legacy model", "legacy fast"))
        exact = '"quoted-model"'
        for key in ("MODEL", "FAST_MODEL"):
            result = self.run_agent("--setup", "set", key, exact)
            self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_agent("inspect project")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests[-1][0]["model"], exact)
        self.assertIn("# Omnicode configuration v2", config.read_text())

    def test_malformed_config_prevents_requests_and_is_not_overwritten(self):
        config = self.cwd / ".config/omnicode/config.env"
        config.parent.mkdir(parents=True)
        for data in ('MODEL=valid-first-line\nmalformed line\n',
                     '# Omnicode configuration v99\nMODEL=value\n',
                     '# Omnicode configuration v2 (JSON values; managed by /setup)\nMODEL=invalid-json\n'):
            with self.subTest(data=data):
                config.write_text(data)
                result = self.run_agent("inspect project")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("InvalidConfigFile", result.stderr)
                self.assertEqual(self.requests, [])
                result = self.run_agent("--setup", "set", "MODEL", "new-model")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(config.read_text(), data)
                result = self.run_agent("--help")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_retired_secret_redacts_checklist_and_retained_details(self):
        secret = "retired-checklist-private-token"
        def reply(body):
            if len(self.requests) == 1:
                return tools(
                    call("todo", {"items": [{"task": secret, "done": False}]}, "todo-1"),
                    call("bash", {"cmd": f"printf 'DETAIL_START {secret} DETAIL_END'"}, "bash-1"),
                )
            return text("done")
        self.reply = reply
        result = self.run_agent(stdin=(
            f"inspect project\n/secrets set TOKEN {secret}\n"
            "/secrets unset TOKEN\n/save retained\n/details\n/q\n"
        ))
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = json.loads((self.cwd / ".omnicode/sessions/retained.json").read_text())
        self.assertIn("[REDACTED:TOKEN]", snapshot["todo"])
        self.assertNotIn(secret, json.dumps(snapshot))
        retained = result.stdout.rsplit("DETAIL_START ", 1)[-1]
        self.assertIn("[REDACTED:TOKEN] DETAIL_END", retained)
        self.assertNotIn(secret, retained)

    def test_rotated_provider_keys_stay_redacted_in_history(self):
        secret = "fake-anthropic"
        self.reply = lambda _: text("remember " + secret)
        for command in ("/setup anthropic replacement-provider-key", "/providers anthropic another-provider-key"):
            with self.subTest(command=command):
                self.requests.clear()
                result = self.run_agent(stdin=(
                    f"remember {secret}\n{command}\n/save rotated\ncontinue\n/q\n"
                ))
                self.assertEqual(result.returncode, 0, result.stderr)
                snapshot = (self.cwd / ".omnicode/sessions/rotated.json").read_text()
                self.assertNotIn(secret, snapshot)
                self.assertIn("[REDACTED:ANTHROPIC_API_KEY]", snapshot)
                self.assertEqual(len(self.requests), 2)
                self.assertNotIn(secret, json.dumps(self.requests[-1][0]))

    def test_retired_secrets_stay_redacted_in_history(self):
        secret = "retired-token-private-value"
        self.reply = lambda _: text("remember " + secret)
        for command in ("/secrets unset TOKEN", "/secrets set TOKEN replacement-private-token"):
            with self.subTest(command=command):
                self.requests.clear()
                result = self.run_agent(stdin=(
                    f"remember {secret}\n/secrets set TOKEN {secret}\n"
                    f"{command}\n/save retired\ncontinue\n/q\n"
                ))
                self.assertEqual(result.returncode, 0, result.stderr)
                snapshot = json.loads((self.cwd / ".omnicode/sessions/retired.json").read_text())
                self.assertNotIn(secret, json.dumps(snapshot))
                self.assertIn("[REDACTED:TOKEN]", json.dumps(snapshot))
                self.assertEqual(len(self.requests), 2)
                self.assertNotIn(secret, json.dumps(self.requests[-1][0]))
                self.assertIn("[REDACTED:TOKEN]", json.dumps(self.requests[-1][0]))

    def test_new_secrets_scrub_existing_history_and_saved_sessions(self):
        secret = 'private"token\\value'
        sessions = self.cwd / ".omnicode/sessions"
        sessions.mkdir(parents=True)
        legacy = {"messages": [{"role": "user", "content": "old " + secret},
                               {"role": "assistant", "content": [
                                   {"type": "text", "text": "nested " + secret}]}],
                  "todo": "check " + secret}
        (sessions / "legacy.json").write_text(json.dumps(legacy))
        self.reply = lambda _: text("remember " + secret)
        result = self.run_agent(stdin=(
            f"remember {secret}\n"
            f"/secrets set TOKEN {secret}\n"
            "/save before\n/resume legacy\n/save after\ncontinue\n/exit\n"
        ))
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("before", "after"):
            snapshot = json.loads((sessions / f"{name}.json").read_text())
            self.assertNotIn(json.dumps(secret)[1:-1], json.dumps(snapshot))
            self.assertIn("[REDACTED:TOKEN]", json.dumps(snapshot))
        self.assertEqual(len(self.requests), 2)
        outbound = self.requests[-1][0]
        self.assertIn("[REDACTED:TOKEN]", json.dumps(outbound))
        self.assertNotIn(json.dumps(secret)[1:-1], json.dumps(outbound))
        self.assertEqual(json.loads((sessions / "legacy.json").read_text()), legacy)

    def test_child_report_redaction_precedes_truncation(self):
        secret = "private-report-token-997"
        report = "x" * (64 * 1024 - 8) + secret + "x" * 1000 + "\nfinal report footer"
        def reply(body):
            if len(self.requests) == 1:
                return tools(call("task", {"prompt": "inspect files", "mode": "explore"}, "child"))
            if len(self.requests) == 2:
                return text(report)
            return text("parent completed")
        self.reply = reply
        result = self.run_agent(stdin=f"/secrets set TOKEN {secret}\ninspect project\n/details\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        content = self.requests[-1][0]["messages"][-1]["content"][0]["content"]
        self.assertLessEqual(len(content.encode()), 64 * 1024)
        self.assertIn("report truncated", content)
        self.assertTrue(content.endswith("final report footer"))
        self.assertNotIn(secret[:8], content)
        self.assertNotIn(secret[:8], result.stdout + result.stderr)

    def test_review_requires_exact_final_pass_verdict(self):
        for report in ("VERDICT: PASS\nReview is still unfinished",
                       "x" * 40000 + "\nVERDICT: FAIL\n" + "x" * 40000 + "\nVERDICT: PASS"):
            with self.subTest(length=len(report)):
                self.reply = lambda body: text(report) if "Correctness & Security Critic" in body["system"] else text("No findings.\nVERDICT: PASS")
                result = self.run_agent(stdin="/review\n/details\n/q\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("OVERALL VERDICT: FAIL", result.stdout)
                self.assertNotIn("OVERALL VERDICT: PASS", result.stdout)

    def test_redaction_precedes_command_and_skill_truncation(self):
        head_secret = "HDsecretTokenPrivate998"
        tail_secret = "TLsecretTokenPrivate998"
        skill_secret = "VLTskillTokenPrivate998"
        limit = 64 * 1024
        output = bytearray(b"x" * (limit + 4096))
        head = limit * 2 // 3
        marker = b"\n...[truncated middle; narrow command or filter output]...\n"
        tail = len(output) - (limit - head - len(marker))
        output[head - 8:head - 8 + len(head_secret)] = head_secret.encode()
        output[tail - 8:tail - 8 + len(tail_secret)] = tail_secret.encode()
        (self.cwd / "output").write_bytes(output)
        skill = self.cwd / ".omnicode/skills/check/SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text("description: " + "x" * 232 + skill_secret + "\n")
        self.reply = lambda _: tools(call("bash", {"cmd": "cat output"})) if len(self.requests) == 1 else text("done")
        result = self.run_agent(stdin=(
            f"/secrets set HEAD {head_secret}\n/secrets set TAIL {tail_secret}\n"
            f"/secrets set SKILL {skill_secret}\ncheck output\n/details\n/q\n"
        ))
        self.assertEqual(result.returncode, 0, result.stderr)
        outbound = json.dumps([body for body, _ in self.requests])
        for fragment in (head_secret[:8], tail_secret[8:], skill_secret[:8]):
            self.assertNotIn(fragment, outbound)
            self.assertNotIn(fragment, result.stdout + result.stderr)
        tool_output = self.requests[-1][0]["messages"][-1]["content"][0]["content"]
        self.assertLessEqual(len(tool_output.encode()), limit)
        self.assertIn("truncated middle", tool_output)

    def test_vault_values_survive_import_and_process_restart(self):
        values = {"QUOTED": '"literal-quotes"', "SINGLE": "'single-quotes'",
                  "SPACED": "  significant spaces  ", "BACKSLASH": r"C:\tokens\private",
                  "UNICODE": "private-café"}
        legacy = self.cwd / "legacy.env"
        legacy.write_text("# legacy dotenv input\n" + "".join(f"{name}='{value}'\n" for name, value in values.items()))
        result = self.run_agent("--secrets", "load", "legacy.env")
        self.assertEqual(result.returncode, 0, result.stderr)
        vault = self.cwd / ".config/omnicode/secrets.env"
        lines = vault.read_text().splitlines()
        self.assertIn("vault v2", lines[0])
        stored = {name: json.loads(encoded) for name, encoded in
                  (line.split("=", 1) for line in lines[1:])}
        self.assertEqual(stored, values)
        (self.cwd / "observe.py").write_text(
            "import json, os\nfrom pathlib import Path\n" +
            "names = " + repr(list(values)) + "\n" +
            "Path('observed.json').write_text(json.dumps({name: os.environ[name] for name in names}))\n"
        )
        self.reply = lambda _: tools(call("bash", {"cmd": "python3 observe.py"})) if len(self.requests) == 1 else text("verified")
        result = self.run_agent("verify stored values")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.cwd / "observed.json").read_text()), values)
        for value in values.values():
            self.assertNotIn(value, result.stdout + result.stderr)
        self.assertEqual(vault.stat().st_mode & 0o777, 0o600)

    def test_startup_storage_errors_block_requests_but_allow_help(self):
        vault = self.cwd / "startup-vault.env"
        self.env["OMNICODE_SECRETS"] = str(vault)
        vault.write_text("FIRST=private-first-value\nLONG=" + "x" * 513 + "\n")
        for content, expected in ((vault.read_text(), "InvalidSecretValue"),
                                  ("FIRST=private-first-value\nmalformed\n", "InvalidSecretFile")):
            vault.write_text(content)
            result = self.run_agent("list files")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected, result.stderr)
            self.assertNotIn("private-first-value", result.stdout + result.stderr)
            self.assertEqual(self.requests, [])
            for flag in ("--help", "--version"):
                result = self.run_agent(flag)
                self.assertEqual(result.returncode, 0, result.stderr)
        vault.unlink()
        # Directories cannot be read as config files; startup must report the failure.
        self.env["OMNICODE_CONFIG"] = str(self.cwd)
        result = self.run_agent("list files")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.requests, [])
        self.assertEqual(self.run_agent("--help").returncode, 0)
        # Absent persisted files are supported, with ordinary environment configuration.
        self.env["OMNICODE_CONFIG"] = str(self.cwd / "absent-config.env")
        result = self.run_agent("list files")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 1)

    def test_private_state_replaces_permissive_files_and_links(self):
        for kind, relative, args, stdin in (
            ("config", ".config/omnicode/config.env", ("--setup", "openai", "fixture-key-private"), None),
            ("vault", ".config/omnicode/secrets.env", ("--secrets", "set", "TOKEN", "fixture-token-private"), None),
            ("session", ".omnicode/sessions/private.json", (), "/save private\n/q\n"),
        ):
            destination = self.cwd / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            for mode in ("permissive", "symlink", "hardlink"):
                with self.subTest(kind=kind, mode=mode):
                    destination.unlink(missing_ok=True)
                    target = self.cwd / f"{kind}-{mode}-target"
                    target.write_text("# original contents\n")
                    if mode == "symlink":
                        destination.symlink_to(target)
                    elif mode == "hardlink":
                        os.link(target, destination)
                    else:
                        destination.write_text("# original contents\n")
                    destination.chmod(0o644)
                    result = self.run_agent(*args, stdin=stdin)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(destination.is_symlink())
                    self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(target.read_text(), "# original contents\n")
                    self.assertNotEqual(destination.read_text(), "# original contents\n")

    @classmethod
    def setUpClass(cls):
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                outer = self.server.active_test
                outer.catalog_requests.append((self.path, dict(self.headers)))
                data = json.dumps(outer.catalog).encode()
                self.send_response(outer.catalog_status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass  # The CLI may cancel an in-flight request.

            def do_POST(self):
                outer = self.server.active_test
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                outer.request_times.append(time.monotonic())
                outer.requests.append((body, {k.lower(): v for k, v in self.headers.items()}))
                result = outer.reply(body)
                status, result = result if isinstance(result, tuple) else (200, result)
                data = result if isinstance(result, bytes) else json.dumps(result).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                for name, value in outer.response_headers:
                    self.send_header(name, value)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass  # The CLI may cancel an in-flight request.

            def log_message(self, *_):
                pass

        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join()
        cls.server.server_close()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cwd = Path(self.tmp.name)
        self.requests = []
        self.request_times = []
        self.catalog_requests = []
        self.catalog_status = 200
        self.catalog = {"data": [model("strong-test-model"), model("fast-test-model"), model("pinned-model"),
                                 model("openai/gpt-4.1-mini", "0.0000004", "0.0000016"),
                                 model("unpriced-custom", overrides=[{"prompt": "0.1"}])]}
        self.reply = lambda _: text()
        self.response_headers = []
        self.server.active_test = self

        self.env = {
            "PATH": os.environ.get("PATH", os.defpath),
            "HOME": self.tmp.name,
            "PROVIDER": "anthropic",
            "ANTHROPIC_API_KEY": "fake-anthropic",
            "OPENROUTER_API_KEY": "fake-openrouter",
            "MAX_REQUESTS_PER_MINUTE": "0",
            "MODEL": "strong-test-model",
            "FAST_MODEL": "fast-test-model",
            "MODELS_URL": f"http://127.0.0.1:{self.server.server_port}/models",
            "API_URL": f"http://127.0.0.1:{self.server.server_port}/v1/messages",
        }

    def test_oversized_piped_input_recovers_at_next_line(self):
        result = self.run_agent(stdin="x" * 16385 + "\n/help\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("InputTooLong", result.stdout)
        self.assertIn("omnicode [--free", result.stdout)
        self.assertEqual(self.requests, [])

    def test_tmux_output_pane_tracks_terminal_width(self):
        tmux = shutil.which("tmux")
        if tmux is None:
            self.skipTest("tmux is not installed")

        socket = f"omnicode-test-{os.getpid()}-{id(self)}"
        session = "resize-test"
        tmux_env = dict(self.env)
        tmux_env.update({
            "TERM": "xterm-256color",
            "TMUX_TMPDIR": str(self.cwd),
            "OMNICODE_TEST_SOCKET": socket,
        })
        wrapper_dir = self.cwd / "tmux-bin"
        wrapper_dir.mkdir()
        wrapper = wrapper_dir / "tmux"
        wrapper.write_text('#!/bin/sh\nexec "$OMNICODE_REAL_TMUX" -L "$OMNICODE_TEST_SOCKET" "$@"\n')
        wrapper.chmod(0o755)
        tmux_env["OMNICODE_REAL_TMUX"] = tmux
        tmux_env["PATH"] = os.pathsep.join((str(wrapper_dir), self.env["PATH"]))

        def tmux_run(*args, check=True):
            return subprocess.run(
                [tmux, "-L", socket, *args], env=tmux_env, capture_output=True,
                text=True, check=check, timeout=5,
            )

        tmux_run("-f", "/dev/null", "new-session", "-d", "-x", "120", "-y", "40", "-s", session)
        self.addCleanup(lambda: tmux_run("kill-server", check=False))
        pane = tmux_run("display-message", "-p", "-t", f"{session}:0.0", "#{pane_id}").stdout.strip()
        tmux_env["TMUX_PANE"] = pane

        def reply(_):
            call_index = len(self.requests)
            if call_index in (1, 3, 5):
                marker = {1: "LIVE_MARKER", 3: "FALLBACK_MARKER", 5: "REOPENED_MARKER"}[call_index]
                if call_index == 1:
                    cmd = f"printf '{marker}_%s\\n' \"$$\"; sleep 0.1"
                else:
                    prefix = marker.split("_")[0]
                    cmd = f"printf '{prefix}'; printf '_MARKER_%s\\n' \"$$\"; sleep 0.1"
                return tools(call("bash", {"cmd": cmd}, f"bash-{call_index}"))
            return text({2: "initial complete", 4: "fallback complete", 6: "reopened complete"}[call_index])

        self.reply = reply
        master, slave = pty.openpty()

        def set_terminal_width(cols):
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, cols, 0, 0))

        set_terminal_width(120)
        process = subprocess.Popen(
            [str(BINARY)], stdin=subprocess.PIPE, stdout=slave, stderr=slave,
            cwd=self.cwd, env=tmux_env,
        )
        os.close(slave)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        output = bytearray()

        def read_until(needle, timeout=10):
            deadline = time.monotonic() + timeout
            while needle not in output:
                if process.poll() is not None:
                    self.fail(f"Omnicode exited before {needle!r}: {output.decode(errors='replace')}")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self.fail(f"Timed out waiting for {needle!r}: {output.decode(errors='replace')}")
                ready, _, _ = select.select([master], [], [], min(0.05, remaining))
                if ready:
                    try:
                        output.extend(os.read(master, 4096))
                    except OSError:
                        self.fail(f"Terminal closed before {needle!r}: {output.decode(errors='replace')}")

        def read_until_regex(pattern, timeout=10):
            deadline = time.monotonic() + timeout
            matcher = re.compile(pattern)
            while matcher.search(output) is None:
                if process.poll() is not None:
                    self.fail(f"Omnicode exited before {pattern!r}: {output.decode(errors='replace')}")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self.fail(f"Timed out waiting for {pattern!r}: {output.decode(errors='replace')}")
                ready, _, _ = select.select([master], [], [], min(0.05, remaining))
                if ready:
                    try:
                        output.extend(os.read(master, 4096))
                    except OSError:
                        self.fail(f"Terminal closed before {pattern!r}: {output.decode(errors='replace')}")

        def send(line):
            process.stdin.write((line + "\n").encode())
            process.stdin.flush()

        def capture_pane():
            pane_ids = tmux_run("list-panes", "-t", session, "-F", "#{pane_id}").stdout.splitlines()
            output_pane = next(pane_id for pane_id in pane_ids if pane_id != pane)
            return tmux_run("capture-pane", "-p", "-S", "-", "-t", output_pane).stdout

        def wait_for_request_count(count):
            deadline = time.monotonic() + 10
            while len(self.requests) < count and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertGreaterEqual(len(self.requests), count, f"only {len(self.requests)} model requests arrived")

        try:
            send("run initial command")
            read_until(b"initial complete")
            wait_for_request_count(2)
            pane_output = capture_pane()
            self.assertIn("Ctrl+O latest", pane_output)
            self.assertIn("/out list", pane_output)
            self.assertIn("/out #<id> full", pane_output)
            self.assertRegex(pane_output, r"LIVE_MARKER_[0-9]+")
            self.assertRegex(output, rb"LIVE_MARKER_[0-9]+")
            self.assertIn(b"Ctrl+O full", output)
            self.assertEqual(len(tmux_run("list-panes", "-t", session, "-F", "#{pane_id}").stdout.splitlines()), 2)
            self.assertEqual(tmux_run("display-message", "-p", "-t", pane, "#{pane_active}").stdout.strip(), "1")

            send("/tmux off")
            read_until(b"tmux Bash pane closed; Bash results stay in the feed.")
            self.assertEqual(len(tmux_run("list-panes", "-t", session, "-F", "#{pane_id}").stdout.splitlines()), 1)
            set_terminal_width(80)
            tmux_run("resize-window", "-t", f"{session}:0", "-x", "80", "-y", "40")
            output.clear()
            send("/usage")
            read_until(b"Session usage")
            self.assertEqual(len(tmux_run("list-panes", "-t", session, "-F", "#{pane_id}").stdout.splitlines()), 1)
            set_terminal_width(120)
            tmux_run("resize-window", "-t", f"{session}:0", "-x", "120", "-y", "40")
            output.clear()
            send("/usage")
            read_until(b"Session usage")
            self.assertEqual(len(tmux_run("list-panes", "-t", session, "-F", "#{pane_id}").stdout.splitlines()), 1)
            send("/tmux on")
            read_until(b"tmux Bash pane opened. Ctrl+O replays the latest output in the feed.")
            self.assertEqual(len(tmux_run("list-panes", "-t", session, "-F", "#{pane_id}").stdout.splitlines()), 2)

            set_terminal_width(80)
            tmux_run("resize-window", "-t", f"{session}:0", "-x", "80", "-y", "40")
            send("/usage")
            read_until(b"Terminal narrowed below 100 columns; Bash output now stays in the feed.")
            self.assertEqual(len(tmux_run("list-panes", "-t", session, "-F", "#{pane_id}").stdout.splitlines()), 1)

            send("run narrow command")
            read_until_regex(rb"FALLBACK_MARKER_[0-9]+")
            wait_for_request_count(4)
            self.assertEqual(len(tmux_run("list-panes", "-t", session, "-F", "#{pane_id}").stdout.splitlines()), 1)

            set_terminal_width(120)
            tmux_run("resize-window", "-t", f"{session}:0", "-x", "120", "-y", "40")
            send("/usage")
            read_until(b"Terminal widened; Bash output is back in the tmux side pane.")
            self.assertEqual(len(tmux_run("list-panes", "-t", session, "-F", "#{pane_id}").stdout.splitlines()), 2)
            self.assertEqual(tmux_run("display-message", "-p", "-t", pane, "#{pane_active}").stdout.strip(), "1")

            send("run reopened command")
            read_until(b"reopened complete")
            wait_for_request_count(6)
            self.assertRegex(capture_pane(), r"REOPENED_MARKER_[0-9]+")
            self.assertRegex(output, rb"REOPENED_MARKER_[0-9]+")
            send("/q")
            process.stdin.close()
            process.wait(timeout=10)
            self.assertEqual(process.returncode, 0, output.decode(errors="replace"))
            self.assertEqual(len(tmux_run("list-panes", "-t", session, "-F", "#{pane_id}").stdout.splitlines()), 1)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)

    def test_ctrl_o_replays_latest_tool_output_and_restores_prompt_draft(self):
        self.env.update(TERM="xterm-256color", COLUMNS="80")
        self.env.pop("NO_COLOR", None)
        (self.cwd / "shortcut.txt").write_text("shortcut-tool-output\n")

        def reply(_):
            if len(self.requests) == 1:
                return tools(call("bash", {"cmd": "printf 'shortcut-bash-output\\n'"}, "bash"),
                             call("read", {"path": "shortcut.txt"}, "read"))
            return text("finished response")

        self.reply = reply
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        original = termios.tcgetattr(slave)
        process = subprocess.Popen([str(BINARY)], stdin=slave, stdout=slave, stderr=slave,
                                   cwd=self.cwd, env=self.env)
        output = bytearray()

        def read_until(marker, start=0, timeout=10):
            deadline = time.monotonic() + timeout
            while marker not in output[start:]:
                if process.poll() is not None:
                    self.fail(f"Omnicode exited before {marker!r}: {output.decode(errors='replace')}")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self.fail(f"Timed out waiting for {marker!r}: {output.decode(errors='replace')}")
                ready, _, _ = select.select([master], [], [], min(0.05, remaining))
                if ready:
                    try:
                        output.extend(os.read(master, 4096))
                    except OSError:
                        self.fail(f"Terminal closed before {marker!r}: {output.decode(errors='replace')}")

        def wait_for_prompt_after(marker):
            start = output.rfind(marker) + len(marker)
            if b"\x1b[?2004h" not in output[start:]:
                read_until(b"\x1b[?2004h", start)

        try:
            read_until(b"\x1b[?2004h")
            self.assertFalse(termios.tcgetattr(slave)[3] & termios.ICANON)
            os.write(master, b"run a command\r")
            read_until(b"finished response")
            wait_for_prompt_after(b"finished response")

            output.clear()
            os.write(master, b"draft")
            read_until(b"draft")
            output.clear()
            os.write(master, b"\x0f")
            read_until(b"shortcut-tool-output")
            result_start = output.index(b"shortcut-tool-output")
            read_until(b"draft", result_start)
            self.assertIn(b"TOOL #2", output)
            self.assertIn(b"read", output)

            os.write(master, b"\x03")
            read_until(b"^C")
            wait_for_prompt_after(b"^C")
            os.write(master, b"/setup openrouter very-secret-marker")
            read_until(b"***********")
            output.clear()
            os.write(master, b"\x0f")
            read_until(b"shortcut-tool-output")
            read_until(b"***********", output.index(b"shortcut-tool-output"))
            self.assertNotIn(b"very-secret-marker", output)
            self.assertIn(b"***********", output)

            os.write(master, b"\x03")
            read_until(b"^C")
            wait_for_prompt_after(b"^C")
            os.write(master, b"/q\r")
            process.wait(timeout=10)
            self.assertEqual(process.returncode, 0, output.decode(errors="replace"))
            self.assertEqual(termios.tcgetattr(slave), original)
            self.assertEqual(len(self.requests), 2)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)

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

    def test_json_one_shot_output_covers_success_preview_and_errors(self):
        secret = "fixture-json-secret"
        setup = self.run_agent("--secrets", "set", "TOKEN", secret)
        self.assertEqual(setup.returncode, 0, setup.stderr)
        self.reply = lambda _: text("answer " + secret)
        result = self.run_agent("--json", "summarize")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["text"], "answer [REDACTED:TOKEN]")
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["usage"]["requests"], 1)
        self.assertEqual(payload["proposed_tools"], [])
        self.assertNotIn(secret, result.stdout)
        self.assertIn("MODEL", result.stderr)

        self.reply = lambda _: tools(call("write", {"path": "blocked.txt", "content": secret}))
        preview = self.run_agent("--json", "--dry-run", "create a file")
        self.assertEqual(preview.returncode, 0, preview.stderr)
        planned = json.loads(preview.stdout)
        self.assertTrue(planned["dry_run"])
        self.assertEqual(planned["proposed_tools"], [{"name": "write", "input": {"path": "blocked.txt", "content": "[REDACTED:TOKEN]"}}])
        self.assertFalse((self.cwd / "blocked.txt").exists())

        self.reply = lambda _: (429, b"private upstream body")
        failed = self.run_agent("--json", "summarize")
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(json.loads(failed.stdout), {"ok": False, "error": "ApiRateLimited"})
        self.assertNotIn("private upstream body", failed.stdout + failed.stderr)
        missing = self.run_agent("--json")
        self.assertNotEqual(missing.returncode, 0)
        self.assertEqual(json.loads(missing.stdout), {"ok": False, "error": "JsonRequiresPrompt"})
        malformed = self.run_agent("--json", "--bogus", "summarize")
        self.assertNotEqual(malformed.returncode, 0)
        self.assertEqual(json.loads(malformed.stdout), {"ok": False, "error": "UnknownOption"})
        config = self.cwd / ".config/omnicode/config.env"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text("malformed line\n")
        startup = self.run_agent("--json", "summarize")
        self.assertNotEqual(startup.returncode, 0)
        self.assertEqual(json.loads(startup.stdout), {"ok": False, "error": "InvalidConfigFile"})

    def test_dry_run_previews_every_tool_without_side_effects_and_saves_valid_session(self):
        secret = 'quote"slash\\tail'
        setup = self.run_agent("--secrets", "set", "TOKEN", secret)
        self.assertEqual(setup.returncode, 0, setup.stderr)
        self.reply = lambda _: tools(
            call("write", {"path": "created.txt", "content": secret}, "write"),
            call("bash", {"cmd": "touch forbidden"}, "shell"),
        )
        result = self.run_agent("--dry-run", "--session", "preview", "make changes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Dry run: previewed 2 tool call(s); none executed.", result.stdout)
        self.assertIn('"path":"created.txt"', result.stdout)
        self.assertIn("touch forbidden", result.stdout)
        self.assertIn("[REDACTED:TOKEN]", result.stdout)
        self.assertNotIn(secret, result.stdout)
        self.assertNotIn(json.dumps(secret)[1:-1], result.stdout)
        self.assertFalse((self.cwd / "created.txt").exists())
        self.assertFalse((self.cwd / "forbidden").exists())
        self.assertEqual(len(self.requests), 1)
        snapshot = json.loads((self.cwd / ".omnicode/sessions/preview.json").read_text())
        self.assertEqual(snapshot["messages"][-1]["content"], "Dry run: previewed 2 tool call(s); none executed.")
        self.assertNotIn(secret, json.dumps(snapshot))
        resumed = self.run_agent("--dry-run", "--session", "preview", "continue")
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        self.assertEqual(len(self.requests), 2)

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
                         {"read", "write", "edit", "glob", "grep", "bash", "skill", "todo", "task", "review"})
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

    def test_read_only_byte_windows_inspect_long_single_line_files(self):
        (self.cwd / "long.json").write_text("x" * 70000 + "TARGET_VALUE" + "x" * 2000)
        def reply(body):
            if len(self.requests) == 1:
                read = next(t for t in body["tools"] if t["name"] == "read")
                self.assertEqual(read["input_schema"]["properties"]["byte_limit"]["maximum"], 61440)
                return tools(call("read", {"path": "long.json"}))
            if len(self.requests) == 2:
                self.assertIn("byte_offset", body["messages"][-1]["content"][0]["content"])
                return tools(call("read", {"path": "long.json", "byte_offset": 70000, "byte_limit": 12}))
            window = body["messages"][-1]["content"][0]
            self.assertFalse(window["is_error"])
            self.assertIn("TARGET_VALUE", window["content"])
            self.assertIn("next byte_offset=70012", window["content"])
            return text("inspected target")
        self.reply = reply
        result = self.run_agent("--read-only", "inspect the long line")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 3)

    def test_export_writes_private_redacted_markdown_with_tools_and_checklist(self):
        secret = "fixture-export-secret"
        setup = self.run_agent("--secrets", "set", "TOKEN", secret)
        self.assertEqual(setup.returncode, 0, setup.stderr)
        (self.cwd / "source.txt").write_text("fixture source\n")
        self.reply = lambda _: tools(
            call("read", {"path": "source.txt"}, "read-id"),
            call("todo", {"items": [{"task": "inspect source", "done": True}]}, "todo-id"),
        ) if len(self.requests) == 1 else text("summary " + secret)
        result = self.run_agent(stdin=f"inspect {secret}\n/export report\n/export ../bad\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Exported session to .omnicode/exports/report.md", result.stdout)
        self.assertIn("InvalidSessionName", result.stdout)
        exported = self.cwd / ".omnicode/exports/report.md"
        self.assertEqual(exported.stat().st_mode & 0o777, 0o600)
        markdown = exported.read_text()
        self.assertIn("# Omnicode session: report", markdown)
        self.assertIn("### Tool call: read", markdown)
        self.assertIn('    {"path":"source.txt"}', markdown)
        self.assertIn("### Tool result: read-id", markdown)
        self.assertIn("fixture source", markdown)
        self.assertIn("## Checklist", markdown)
        self.assertIn("1. [x] inspect source", markdown)
        self.assertIn("[REDACTED:TOKEN]", markdown)
        self.assertNotIn(secret, markdown)
        self.assertFalse((self.cwd / "bad.md").exists())

    def test_one_shot_session_checkpoints_completed_rounds_and_resumes(self):
        snapshot = self.cwd / ".omnicode/sessions/build.json"
        def reply(body):
            if len(self.requests) == 1:
                initial = json.loads(snapshot.read_text())
                self.assertEqual(initial["messages"][0]["content"], "build project")
                return tools(call("write", {"path": "kept.txt", "content": "completed"}, "kept"))
            saved = json.loads(snapshot.read_text())
            self.assertEqual(saved["messages"][-1]["content"][0]["tool_use_id"], "kept")
            return (500, {})
        self.reply = reply
        result = self.run_agent("--session", "build", "build project")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.cwd / "kept.txt").read_text(), "completed")
        self.assertEqual(snapshot.stat().st_mode & 0o777, 0o600)
        saved = json.loads(snapshot.read_text())
        self.assertEqual(len(saved["messages"]), 3)
        self.reply = lambda body: text("continued successfully")
        result = self.run_agent("--session", "build", "continue")
        self.assertEqual(result.returncode, 0, result.stderr)
        messages = self.requests[-1][0]["messages"]
        self.assertEqual(messages[:-1], saved["messages"])
        self.assertEqual(messages[-1]["content"], "continue")
        self.assertEqual(json.loads(snapshot.read_text())["messages"][-1]["content"][0]["text"], "continued successfully")

    def test_one_shot_full_session_compacts_before_checkpoint(self):
        snapshot = self.cwd / ".omnicode/sessions/full.json"
        snapshot.parent.mkdir(parents=True)
        messages = [{"role": "user" if i % 2 == 0 else "assistant", "content": "original goal" if i == 0 else "earlier exchange"} for i in range(128)]
        snapshot.write_text(json.dumps({"messages": messages, "todo": ""}))
        self.reply = lambda body: text("summary of earlier work") if "tools" not in body else text("continued")
        result = self.run_agent("--session", "full", "continue")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 2)
        saved = json.loads(snapshot.read_text())
        self.assertLessEqual(len(saved["messages"]), 128)
        self.assertIn("original goal", saved["messages"][0]["content"])
        self.assertIn("summary of earlier work", saved["messages"][0]["content"])

    def test_one_shot_session_rejects_invalid_input_without_overwriting(self):
        for args in [("--session",), ("--session", "../escape", "task"),
                     ("--session", "name"), ("--session", "name", "--init"),
                     ("--session", "one", "--session", "two", "task")]:
            with self.subTest(args=args):
                result = self.run_agent(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.requests, [])
                self.assertFalse((self.cwd / ".omnicode").exists())
        snapshot = self.cwd / ".omnicode/sessions/bad.json"
        snapshot.parent.mkdir(parents=True)
        original = b'{"messages":42,"todo":"keep"}'
        snapshot.write_bytes(original)
        result = self.run_agent("--session", "bad", "continue")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("InvalidSession", result.stderr)
        self.assertEqual(snapshot.read_bytes(), original)
        self.assertEqual(self.requests, [])

    def test_one_shot_checkpoint_redacts_registered_secrets(self):
        secret = "fixture-session-password"
        setup = self.run_agent("--secrets", "set", "TOKEN", secret)
        self.assertEqual(setup.returncode, 0, setup.stderr)
        self.reply = lambda body: text("remember " + secret)
        result = self.run_agent("--read-only", "--session", "private", "inspect " + secret)
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = (self.cwd / ".omnicode/sessions/private.json").read_text()
        self.assertNotIn(secret, snapshot)
        self.assertIn("[REDACTED:TOKEN]", snapshot)

    def test_os_interrupt_cleans_up_active_command_descendants(self):
        command = 'python3 -c \'import time; from pathlib import Path; Path("started").touch(); time.sleep(0.6); Path("late-write").touch()\' & wait'
        self.reply = lambda body: tools(call("bash", {"cmd": command}))
        for sig in [signal.SIGINT, signal.SIGTERM]:
            with self.subTest(signal=sig):
                (self.cwd / "started").unlink(missing_ok=True)
                initial_requests = len(self.requests)
                proc = subprocess.Popen([str(BINARY), "run a command"], cwd=self.cwd, env=self.env,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 5
                    while not (self.cwd / "started").exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue((self.cwd / "started").exists())
                    proc.send_signal(sig)
                    proc.communicate(timeout=3)
                    self.assertEqual(proc.returncode, 128 + sig)
                    self.assertEqual(len(self.requests), initial_requests + 1)
                    time.sleep(0.7)
                    self.assertFalse((self.cwd / "late-write").exists())
                finally:
                    if proc.poll() is None:
                        proc.kill()
                        proc.communicate(timeout=3)

    def test_interrupting_subagent_cancels_its_command_without_followup_requests(self):
        command = 'python3 -c \'import time; from pathlib import Path; Path("started").touch(); time.sleep(0.6); Path("late-write").touch()\''
        self.reply = lambda body: tools(call("task", {"prompt": "run the command", "mode": "edit"})) if len(self.requests) == 1 else tools(call("bash", {"cmd": command}))
        proc = subprocess.Popen([str(BINARY), "delegate a command"], cwd=self.cwd, env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not (self.cwd / "started").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.cwd / "started").exists())
            proc.send_signal(signal.SIGINT)
            proc.communicate(timeout=3)
            self.assertEqual(proc.returncode, 130)
            self.assertEqual(len(self.requests), 2)
            time.sleep(0.7)
            self.assertFalse((self.cwd / "late-write").exists())
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate(timeout=3)

    def test_sigterm_restores_raw_terminal_settings(self):
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        proc = subprocess.Popen([str(BINARY)], cwd=self.cwd, env=self.env,
                                stdin=slave, stdout=slave, stderr=slave)
        try:
            deadline = time.monotonic() + 3
            while termios.tcgetattr(slave)[3] & termios.ICANON and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertFalse(termios.tcgetattr(slave)[3] & termios.ICANON)
            proc.send_signal(signal.SIGTERM)
            proc.wait(timeout=3)
            self.assertEqual(proc.returncode, 143)
            self.assertEqual(termios.tcgetattr(slave), original)
            self.assertEqual(self.requests, [])
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=3)
            os.close(master)
            os.close(slave)

    def test_sigint_cancels_inflight_api_without_another_request(self):
        started, release = threading.Event(), threading.Event()
        def reply(body):
            started.set()
            release.wait(5)
            return text("late response")
        self.reply = reply
        proc = subprocess.Popen([str(BINARY), "wait for response"], cwd=self.cwd, env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertTrue(started.wait(3))
            proc.send_signal(signal.SIGINT)
            proc.communicate(timeout=3)
            self.assertEqual(proc.returncode, 130)
            self.assertEqual(len(self.requests), 1)
        finally:
            release.set()
            if proc.poll() is None:
                proc.kill()
                proc.communicate(timeout=3)

    def test_sigterm_cancels_idle_piped_input_without_api_request(self):
        proc = subprocess.Popen([str(BINARY)], cwd=self.cwd, env=self.env,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertTrue(select.select([proc.stdout], [], [], 3)[0])
            proc.send_signal(signal.SIGTERM)
            proc.communicate(timeout=3)  # Also close stdin: completion must not hide the signal.
            self.assertEqual(proc.returncode, 143)
            self.assertEqual(self.requests, [])
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate(timeout=3)

    def test_timed_out_shell_cannot_leave_a_child_writing_afterward(self):
        command = 'python3 -c \'import time; from pathlib import Path; time.sleep(0.4); Path("late-write").write_text("orphan")\' & wait'
        self.reply = lambda body: tools(call("bash", {"cmd": command, "timeout_ms": 50})) if len(self.requests) == 1 else text("finished")
        result = self.run_agent("run a bounded command")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Timeout", result.stdout)
        time.sleep(0.6)
        self.assertFalse((self.cwd / "late-write").exists())

    def test_command_timeout_kills_a_term_ignoring_leader(self):
        self.reply = lambda body: tools(call("bash", {"cmd": "trap '' TERM; exec sleep 10 >/dev/null 2>&1", "timeout_ms": 50})) if len(self.requests) == 1 else text("finished")
        started = time.monotonic()
        result = self.run_agent("run a bounded command")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Timeout", result.stdout)
        self.assertLess(time.monotonic() - started, 3)

    def test_successful_error_prefixed_output_keeps_success_status(self):
        def reply(body):
            if len(self.requests) == 1:
                return tools(call("bash", {"cmd": "printf 'error: example'"}, "one"),
                             call("bash", {"cmd": "printf 'error: example'"}, "two"),
                             call("bash", {"cmd": "printf normal; exit 7"}, "failed"))
            return text("finished")
        self.reply = reply
        result = self.run_agent("inspect diagnostic output")
        self.assertEqual(result.returncode, 0, result.stderr)
        results = {item["tool_use_id"]: item for item in self.requests[-1][0]["messages"][-1]["content"]}
        for name in ("one", "two"):
            self.assertFalse(results[name]["is_error"])
            self.assertEqual(results[name]["content"], "error: example")
        self.assertTrue(results["failed"]["is_error"])
        self.assertIn("normal", results["failed"]["content"])

    def test_subagent_preserves_successful_error_prefixed_output(self):
        def reply(body):
            if len(self.requests) == 1:
                return tools(call("task", {"prompt": "inspect diagnostics", "mode": "edit"}))
            if len(self.requests) == 2:
                return tools(call("bash", {"cmd": "printf 'error: example'"}))
            if len(self.requests) == 3:
                result = body["messages"][-1]["content"][0]
                self.assertFalse(result["is_error"])
                self.assertEqual(result["content"], "error: example")
                return text("child finished")
            return text("parent finished")
        self.reply = reply
        result = self.run_agent("inspect with a subagent")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 4)

    def test_bash_command_alias_has_consistent_display_execution_and_validation(self):
        def reply(body):
            if len(self.requests) == 1:
                return tools(call("bash", {"command": "printf alias-ok"}, "alias"),
                             call("bash", {"cmd": "printf both-ok", "command": "printf both-ok"}, "both"),
                             call("bash", {"cmd": "touch forbidden", "command": "printf other"}, "conflict"),
                             call("bash", {"cmd": False, "command": "touch forbidden"}, "invalid"),
                             call("bash", {"command": "touch forbidden\x00"}, "nul"))
            return text("finished")
        self.reply = reply
        result = self.run_agent("execute compatible commands")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("╭─ BASH  $ printf alias-ok", result.stdout)
        self.assertFalse((self.cwd / "forbidden").exists())
        results = {r["tool_use_id"]: r for r in self.requests[-1][0]["messages"][-1]["content"]}
        for key, output in [("alias", "alias-ok"), ("both", "both-ok")]:
            self.assertFalse(results[key]["is_error"])
            self.assertEqual(results[key]["content"], output)
        for key, error in [("conflict", "ConflictingArguments"), ("invalid", "ExpectedString"), ("nul", "InvalidCommandArgument")]:
            self.assertTrue(results[key]["is_error"])
            self.assertIn(error, results[key]["content"])

    def test_invalid_tool_arguments_return_schema_for_recovery(self):
        def reply(body):
            if len(self.requests) == 1:
                return tools(call("bash", {"script": "touch should-not-run"}, "bad"))
            if len(self.requests) == 2:
                error = body["messages"][-1]["content"][0]
                self.assertTrue(error["is_error"])
                self.assertIn("UnknownArgument", error["content"])
                self.assertIn('"required":["cmd"]', error["content"])
                self.assertNotIn("touch should-not-run", error["content"])
                return tools(call("bash", {"cmd": "printf recovered"}, "good"))
            return text("finished")
        self.reply = reply
        result = self.run_agent("execute a command")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.cwd / "should-not-run").exists())
        self.assertEqual(len(self.requests), 3)
        good = self.requests[-1][0]["messages"][-1]["content"][0]
        self.assertFalse(good["is_error"])
        self.assertEqual(good["content"], "recovered")

    def test_write_creates_parent_directories_and_read_only_creates_nothing(self):
        self.reply = lambda body: tools(call("write", {"path": "nested/tests/output.txt", "content": "created"})) if len(self.requests) == 1 else text("done")
        result = self.run_agent("create nested file")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.cwd / "nested/tests/output.txt").read_text(), "created")
        self.requests.clear()
        self.reply = lambda body: tools(call("write", {"path": "blocked/deep/file.txt", "content": "no"})) if len(self.requests) == 1 else text("denied")
        result = self.run_agent("--read-only", "inspect only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.cwd / "blocked").exists())
        self.assertIn("ReadOnlyMode", result.stdout)

    def test_read_only_mode_rejects_unadvertised_tools_and_survives_resets(self):
        (self.cwd / "input.txt").write_text("preserve this")
        calls = [call("write", {"path": "blocked.txt", "content": "bad"}, "write"),
                 call("edit", {"path": "input.txt", "old": "preserve", "new": "destroy"}, "edit"),
                 call("bash", {"cmd": "touch shell-ran"}, "bash"),
                 call("todo", {"items": [{"task": "blocked", "done": False}]}, "todo"),
                 call("task", {"prompt": "write a file", "mode": "edit"}, "task"),
                 call("review", {}, "review"),
                 call("future-tool", {}, "unknown"),
                 call("read", {"path": "input.txt"}, "read")]
        def reply(body):
            if "tools" not in body:
                return text("summary of read-only investigation")
            if isinstance(body["messages"][-1]["content"], list):
                return text("inspection complete")
            return tools(*calls)
        self.reply = reply
        result = self.run_agent("--read-only", stdin="inspect first\n/compact\ninspect second\n/c\ninspect third\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 7)
        self.assertEqual((self.cwd / "input.txt").read_text(), "preserve this")
        self.assertFalse((self.cwd / "blocked.txt").exists())
        self.assertFalse((self.cwd / "shell-ran").exists())
        result_sets = []
        for body, _ in self.requests:
            if "tools" not in body:
                continue
            self.assertEqual({tool["name"] for tool in body["tools"]}, {"read", "glob", "grep", "skill"})
            self.assertIn("Read-only mode", body["system"])
            last = body["messages"][-1]["content"]
            if isinstance(last, list):
                result_sets.append({item["tool_use_id"]: item for item in last})
        self.assertEqual(len(result_sets), 3)
        for results in result_sets:
            for name in ("write", "edit", "bash", "todo", "task", "review", "unknown"):
                self.assertTrue(results[name]["is_error"])
                self.assertIn("ReadOnlyMode", results[name]["content"])
            self.assertFalse(results["read"]["is_error"])
            self.assertIn("preserve this", results["read"]["content"])

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
        # Subagent saw ReadOnlyMode and NestedSubagent errors.
        child_results = {r["tool_use_id"]: r for r in self.requests[2][0]["messages"][-1]["content"]}
        self.assertIn("ReadOnlyMode", child_results["c2"]["content"])
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

    def test_model_comparison_shows_cost_in_throughput_order_before_selection(self):
        self.catalog = {"data": [model("fast/expensive", "0.000002", "0.000004"),
                                 model("slow/cheap", "0.0000001", "0.0000002")]}
        result = self.run_agent(stdin="/model compare\n/model 1\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("recent median throughput", result.stdout)
        self.assertLess(result.stdout.index("fast/expensive"), result.stdout.index("slow/cheap"))
        self.assertIn("$2.00/$4.00 per 1M in/out", result.stdout)
        self.assertIn("$0.10/$0.20 per 1M in/out", result.stdout)
        self.assertIn("[openrouter / fast/expensive]", result.stdout)
        self.assertIn("sort=throughput-high-to-low", self.catalog_requests[0][0])
        self.assertEqual(self.requests, [])

    def test_model_picker_uses_arrow_keys_and_escape_cancels(self):
        self.env.update(TERM="xterm-256color")
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
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
            output.clear()
            os.write(master, b"/model\r")
            until(b"Enter select")
            os.write(master, b"\x1b[B\x1b[A\x1b[B\r")
            until(b"[anthropic / fast-test-model]")
            until(b"\x1b[?2004h")
            output.clear()
            os.write(master, b"/model\r")
            until(b"Esc cancel: 2/")
            output.clear()
            os.write(master, b"\x1b")
            until(b"Model selection canceled.")
            until(b"\x1b[?2004h")
            os.write(master, b"/q\r")
            proc.wait(timeout=10)
            self.assertEqual(proc.returncode, 0, output.decode(errors="replace"))
            self.assertEqual(termios.tcgetattr(slave), original)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            os.close(master)
            os.close(slave)

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

    def test_compressed_model_responses_remain_supported(self):
        import gzip
        self.response_headers = [("Content-Encoding", "gzip")]
        self.reply = lambda _: gzip.compress(json.dumps(text("compressed response")).encode())
        result = self.run_agent("inspect")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("compressed response", result.stdout)
        self.assertEqual(len(self.requests), 1)

    def test_completion_reconciles_pending_checklist_once_and_checkpoints_result(self):
        def reply(body):
            if len(self.requests) == 1:
                return tools(call("todo", {"items": [{"task": "verify result", "done": False}]}))
            if len(self.requests) == 2:
                return text("work is complete")
            if len(self.requests) == 3:
                reminder = body["messages"][-1]["content"]
                self.assertIn("reconcile the session checklist", reminder)
                self.assertIn("Use todo to read the current list", reminder)
                self.assertIn("Do not claim checks", reminder)
                return tools(call("todo", {"items": [{"task": "verify result", "done": True}]}))
            return text("completion reviewed")
        self.reply = reply
        result = self.run_agent("--session", "verified", "complete task")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 4)
        self.assertEqual(result.stdout.count("reviewing completion once"), 1)
        saved = json.loads((self.cwd / ".omnicode/sessions/verified.json").read_text())
        self.assertEqual(saved["todo"], "1. [x] verify result\n")
        self.assertEqual(saved["messages"][-1]["role"], "assistant")

    def test_completion_review_redacts_private_checklist_text(self):
        secret = "private-checklist-review-token"
        def reply(body):
            if len(self.requests) == 1:
                return tools(call("todo", {"items": [{"task": secret, "done": False}]}))
            if len(self.requests) == 3:
                reminder = body["messages"][-1]["content"]
                self.assertNotIn(secret, reminder)
                self.assertIn("[REDACTED:TOKEN]", json.dumps(body))
            return text("blocked")
        self.reply = reply
        result = self.run_agent(stdin=f"/secrets set TOKEN {secret}\nattempt task\n/save private\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 3)
        saved = (self.cwd / ".omnicode/sessions/private.json").read_text()
        self.assertNotIn(secret, saved)
        self.assertIn("[REDACTED:TOKEN]", saved)

    def test_completion_review_is_bounded_and_preserves_blocked_steps(self):
        self.reply = lambda _: tools(call("todo", {"items": [{"task": "blocked work", "done": False}]})) if len(self.requests) == 1 else text("blocked; more input required")
        result = self.run_agent("--session", "blocked", "attempt task")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 3)
        self.assertIn("Checklist still has pending steps", result.stdout)
        saved = json.loads((self.cwd / ".omnicode/sessions/blocked.json").read_text())
        self.assertEqual(saved["todo"], "1. [ ] blocked work\n")
        self.requests.clear()
        self.reply = lambda _: text("current state reported")
        result = self.run_agent("--read-only", "--session", "blocked", "report current state")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 1)
        self.assertNotIn("reviewing completion once", result.stdout)

    def test_model_requests_are_paced_across_tool_continuations(self):
        self.env["MAX_REQUESTS_PER_MINUTE"] = "120"
        (self.cwd / "source.txt").write_text("ready\n")
        self.reply = lambda _: tools(call("read", {"path": "source.txt"})) if len(self.requests) == 1 else text("done")
        result = self.run_agent("inspect source")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.request_times), 2)
        self.assertGreaterEqual(self.request_times[1] - self.request_times[0], 0.45)
        self.env["MAX_REQUESTS_PER_MINUTE"] = "601"
        invalid = self.run_agent("inspect source")
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("InvalidRequestRate", invalid.stderr)
        self.assertEqual(len(self.requests), 2)

    def test_model_server_retries_preserve_requests_and_execute_tools_once(self):
        def reply(body):
            if len(self.requests) <= 2:
                return (503, {"error": "private-provider-body fake-anthropic"})
            if len(self.requests) == 3:
                return tools(call("bash", {"cmd": "printf once >> executions"}, "execute"))
            if len(self.requests) <= 5:
                return (500, {})
            return text("completed")
        self.reply = reply
        result = self.run_agent("complete the task")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 6)
        self.assertEqual(self.requests[3], self.requests[4])
        self.assertEqual(self.requests[4], self.requests[5])
        self.assertEqual(self.requests[0], self.requests[1])
        self.assertEqual(self.requests[1], self.requests[2])
        self.assertEqual((self.cwd / "executions").read_text(), "once")
        self.assertIn("Retrying model request (2/2)", result.stderr)
        self.assertNotIn("private-provider-body", result.stderr + result.stdout)
        self.assertNotIn("fake-anthropic", result.stderr + result.stdout)

    def test_corrupt_compressed_success_response_is_an_error_without_panic(self):
        self.response_headers = [("Content-Encoding", "gzip")]
        self.reply = lambda _: b"corrupt private-response-body fake-anthropic"
        result = self.run_agent(stdin="inspect\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 1)
        self.assertIn("InvalidResponseBody", result.stdout)
        self.assertIn("unreadable response body", result.stdout)
        self.assertNotIn("panic", result.stderr)
        self.assertNotIn("private-response-body", result.stdout + result.stderr)
        self.assertNotIn("fake-anthropic", result.stdout + result.stderr)

    def test_model_server_retry_does_not_require_a_readable_error_body(self):
        for oversized in (False, True):
            with self.subTest(oversized=oversized):
                self.requests.clear()
                def reply(_):
                    if len(self.requests) == 1:
                        self.response_headers = [] if oversized else [("Content-Encoding", "gzip")]
                        return (503, b"x" * (2 * 1024 * 1024 + 1) if oversized else b"unreadable error")
                    self.response_headers = []
                    return text("recovered without error body")
                self.reply = reply
                result = self.run_agent("inspect")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.requests), 2)
                self.assertIn("recovered without error body", result.stdout)

    def test_model_retries_stop_after_two_attempts_and_preserve_retry_after(self):
        self.reply = lambda _: (500, {})
        result = self.run_agent("inspect")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.requests), 3)
        for delay in ["31", "Wed, 21 Oct 2037 07:28:00 GMT", "invalid", "-1"]:
            with self.subTest(delay=delay):
                self.requests.clear()
                self.response_headers = [("Retry-After", delay)]
                result = self.run_agent("inspect")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(self.requests), 1)
        self.requests.clear()
        self.response_headers = [("Retry-After", "0"), ("Retry-After", "0")]
        result = self.run_agent("inspect")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.requests), 1)
        self.requests.clear()
        self.response_headers = [("Retry-After", "2")]
        self.reply = lambda _: (503, {}) if len(self.requests) == 1 else text()
        started = time.monotonic()
        result = self.run_agent("inspect")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 2)
        self.assertGreaterEqual(time.monotonic() - started, 2)

    def test_interrupt_cancels_model_retry_backoff(self):
        self.response_headers = [("Retry-After", "30")]
        self.reply = lambda _: (503, {})
        process = subprocess.Popen([str(BINARY), "inspect"], cwd=self.cwd, env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while not self.requests and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(self.requests)
            time.sleep(0.15)
            process.send_signal(signal.SIGINT)
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 130, stdout + stderr)
            self.assertEqual(len(self.requests), 1)
            self.assertIn("after 30000 ms", stderr)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_failed_repl_turn_resets_history(self):
        self.reply = lambda _: (400, {}) if len(self.requests) == 1 else text()
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
                return (400, {})
            return text("resumed")
        self.reply = partial
        result = self.run_agent(stdin="fix bug\ncontinue\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("completed work retained in summary", result.stdout)
        self.assertIn("<summary>", self.requests[-1][0]["messages"][0]["content"])
        self.assertIn("- tool write: kept.txt", self.requests[-1][0]["messages"][0]["content"])

    def test_tool_budget_stops_batches_checkpoints_and_resumes(self):
        self.env["MAX_TOOL_CALLS"] = "2"
        self.reply = lambda body: tools(*(call("write", {"path": name, "content": name}, name) for name in ("first", "second", "denied")))
        result = self.run_agent("--session", "limited", "build task")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ToolLimit", result.stdout + result.stderr)
        self.assertEqual(len(self.requests), 1)
        self.assertIn("budget remaining at task start: 2", self.requests[0][0]["system"])
        self.assertTrue((self.cwd / "first").exists())
        self.assertTrue((self.cwd / "second").exists())
        self.assertFalse((self.cwd / "denied").exists())
        path = self.cwd / ".omnicode/sessions/limited.json"
        saved = json.loads(path.read_text())
        outcomes = saved["messages"][-1]["content"]
        self.assertEqual([r["is_error"] for r in outcomes], [False, False, True])
        self.assertIn("ToolLimit", outcomes[-1]["content"])
        self.reply = lambda _: text("resumed completed work")
        result = self.run_agent("--session", "limited", "continue")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests[-1][0]["messages"][:len(saved["messages"])], saved["messages"])

    def test_tool_budget_is_shared_with_delegated_work(self):
        self.env["MAX_TOOL_CALLS"] = "3"
        def reply(body):
            if len(self.requests) == 1:
                return tools(call("task", {"prompt": "write fixtures", "mode": "edit"}, "child"))
            if len(self.requests) == 2:
                self.assertIn("budget remaining at task start: 2", body["system"])
                return tools({"type": "text", "text": "Preparing to create fixtures"},
                             call("write", {"path": "child-first", "content": "ok"}, "first"),
                             call("write", {"path": "child-second", "content": "ok"}, "second"))
            if len(self.requests) == 3:
                return tools(call("write", {"path": "child-denied", "content": "bad"}, "denied"))
            self.fail("No API request is allowed after tool-budget exhaustion")
        self.reply = reply
        result = self.run_agent("--session", "delegated", "implement task")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ToolLimit", result.stdout + result.stderr)
        self.assertEqual(len(self.requests), 3)
        self.assertTrue((self.cwd / "child-first").exists())
        self.assertTrue((self.cwd / "child-second").exists())
        self.assertFalse((self.cwd / "child-denied").exists())
        saved = json.loads((self.cwd / ".omnicode/sessions/delegated.json").read_text())
        self.assertIn("subagent reached tool budget", saved["messages"][-1]["content"][0]["content"])
        self.assertTrue(saved["messages"][-1]["content"][0]["is_error"])
        self.assertIn("child-first", saved["messages"][-1]["content"][0]["content"])

    def test_exact_shared_tool_budget_can_finish_and_reports_child_calls(self):
        self.env["MAX_TOOL_CALLS"] = "2"
        (self.cwd / "file").write_text("fixture")
        def reply(_):
            if len(self.requests) == 1:
                return tools(call("task", {"prompt": "inspect file", "mode": "explore"}, "child"))
            if len(self.requests) == 2:
                return tools(call("read", {"path": "file"}, "read"))
            if len(self.requests) == 3:
                return text("child inspected fixture")
            return text("inspection complete")
        self.reply = reply
        result = self.run_agent("inspect fixture")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 4)
        self.assertIn("2 tool calls", result.stdout)
        self.assertNotIn("ToolLimit", result.stdout + result.stderr)

    def test_review_tool_budget_skips_second_critic_after_exhaustion(self):
        self.env["MAX_TOOL_CALLS"] = "1"
        (self.cwd / "file").write_text("fixture")
        self.reply = lambda _: tools(call("read", {"path": "file"}, "first"), call("read", {"path": "file"}, "denied"))
        result = self.run_agent(stdin="/review inspect fixture\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ToolLimit", result.stdout)
        self.assertEqual(len(self.requests), 1)
        self.assertIn("Correctness & Security Critic", self.requests[0][0]["system"])
        self.assertNotIn("OVERALL VERDICT: PASS", result.stdout)

    def test_exact_tool_budget_resets_each_request_and_skips_futile_checklist_review(self):
        self.env["MAX_TOOL_CALLS"] = "1"
        self.reply = lambda body: tools(call("todo", {"items": [{"task": "blocked", "done": False}]})) if len(body["messages"]) in (1, 5) else text("needs more work")
        result = self.run_agent(stdin="first request\nsecond request\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 4)
        self.assertNotIn("ToolLimit", result.stdout + result.stderr)
        self.assertNotIn("reviewing completion once", result.stdout)
        self.assertEqual(result.stdout.count("Checklist still has pending steps"), 2)

    def test_tool_limit_changes_apply_to_next_repl_request_without_stacking_system_notes(self):
        def reply(body):
            count = len(body["messages"])
            if count == 1:
                return tools(call("write", {"path": "first", "content": "ok"}, "first"))
            if count == 5:
                return tools(call("write", {"path": "second", "content": "ok"}, "second"),
                             call("write", {"path": "third", "content": "ok"}, "third"))
            return text("completed")
        self.reply = reply
        result = self.run_agent(stdin="/setup set MAX_TOOL_CALLS 1\nfirst request\n/setup set MAX_TOOL_CALLS 2\nsecond request\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 4)
        for body, _ in self.requests:
            self.assertEqual(body["system"].count("Shared model-tool budget remaining"), 1)
        self.assertIn("task start: 1", self.requests[0][0]["system"])
        self.assertIn("task start: 2", self.requests[2][0]["system"])
        self.assertNotIn("ToolLimit", result.stdout + result.stderr)
        self.assertTrue(all((self.cwd / name).exists() for name in ("first", "second", "third")))

    def test_setup_repairs_only_the_targeted_invalid_saved_limit(self):
        config = self.cwd / "repair.env"
        self.env["OMNICODE_CONFIG"] = str(config)
        for key in ("MAX_TURNS", "MAX_TOOL_CALLS"):
            for command in (("set", key, "5"), ("unset", key), (key.lower(), "5")):
                with self.subTest(key=key, command=command):
                    config.write_text(f"{key}=0\nMODEL=preserve-model\n")
                    result = self.run_agent("--setup", *command)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    saved = config.read_text()
                    self.assertIn('MODEL="preserve-model"', saved)
                    if command[0] == "unset":
                        self.assertNotIn(key + "=", saved)
                    else:
                        self.assertIn(key + '="5"', saved)
        invalid = "MAX_TOOL_CALLS=0\nMODEL=preserve-model\n"
        for command in (("set", "MAX_TOOL_CALLS", "4097"),
                        ("set", "MODEL", "replacement"), ("unset", "MODEL")):
            config.write_text(invalid)
            result = self.run_agent("--setup", *command)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(config.read_text(), invalid)
        invalid = "MAX_TOOL_CALLS=0\nMAX_TURNS=0\n"
        config.write_text(invalid)
        result = self.run_agent("--setup", "set", "MAX_TOOL_CALLS", "5")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(config.read_text(), invalid)
        for invalid in ('# Omnicode configuration v2 (JSON values; managed by /setup)\nMAX_TOOL_CALLS=broken-json\n',
                        'MAX_TOOL_CALLS=bad\x00value\n'):
            config.write_text(invalid)
            result = self.run_agent("--setup", "unset", "MAX_TOOL_CALLS")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(config.read_text(), invalid)
        self.assertEqual(self.requests, [])
        self.assertEqual(self.catalog_requests, [])

    def test_invalid_tool_limits_fail_before_api_requests(self):
        for value in ("0", "4097", "-1", "invalid"):
            with self.subTest(value=value):
                self.env["MAX_TOOL_CALLS"] = value
                result = self.run_agent("inspect")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("InvalidToolLimit", result.stdout + result.stderr)
                self.assertEqual(self.requests, [])

    def test_turn_limit_can_resume_and_budget_changes_apply_next_request(self):
        calls = 0
        def reply(body):
            nonlocal calls
            if "tools" not in body:
                return text("summary of completed file updates")
            calls += 1
            if calls <= 4:
                return tools(call("write", {"path": "progress.txt", "content": str(calls)}, f"step-{calls}"))
            if calls == 5:
                self.assertIn("progress.txt", json.dumps(body["messages"]))
                self.assertIn("Completed before failure", json.dumps(body["messages"]))
                return tools(call("bash", {"cmd": "printf resumed"}, "resume"))
            return text("resumed successfully")
        self.reply = reply
        result = self.run_agent(stdin=(
            "/setup set MAX_TURNS 1\nfix task\n"
            "/setup set MAX_TURNS 2\ncontinue\n/q\n"
        ))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TurnLimit", result.stdout)
        self.assertIn("enter continue to resume", result.stdout)
        self.assertNotIn("Conversation limit reached", result.stdout)
        self.assertIn("resumed successfully", result.stdout)
        self.assertEqual((self.cwd / "progress.txt").read_text(), "4")
        self.assertEqual(calls, 6)
        self.assertEqual(len(self.requests), 9)  # Six model calls plus three compactions.
        result = self.run_agent("--setup")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MAX_TURNS   = 2", result.stdout)

    def test_invalid_turn_budget_blocks_requests_and_preserves_settings(self):
        self.env["PROVIDER"] = "openrouter"
        for value in ("0", "257", "-1", "invalid"):
            with self.subTest(value=value):
                self.env["MAX_TURNS"] = value
                result = self.run_agent(stdin="inspect project\n/q\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("InvalidTurnLimit", result.stdout)
                self.assertEqual(self.requests, [])
                self.assertEqual(self.catalog_requests, [])
        self.env.pop("MAX_TURNS")
        result = self.run_agent("--setup", "set", "MAX_TURNS", "64")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = self.cwd / ".config/omnicode/config.env"
        saved = config.read_bytes()
        result = self.run_agent("--setup", "set", "MAX_TURNS", "0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("InvalidTurnLimit", result.stderr)
        self.assertEqual(config.read_bytes(), saved)

    def test_loop_is_bounded(self):
        self.reply = lambda body: text("summary of progress") if "tools" not in body else tools(call("bash", {"cmd": "printf ok"}))
        result = self.run_agent("fix bug")
        self.assertNotEqual(result.returncode, 0)
        # 4 windows of 32 tool turns + 3 compactions = 131 requests before TurnLimit.
        self.assertEqual(len(self.requests), 32 * 4 + 3)
        self.assertIn("TurnLimit", result.stderr)
        self.assertIn("3 compaction(s)", result.stdout)

    def test_compaction_retries_truncated_summary_once(self):
        attempts = []
        def reply(body):
            if "tools" in body:
                return text("initial answer" if len(self.requests) == 1 else "continued")
            attempts.append(body)
            if len(attempts) == 1:
                return {"stop_reason": "max_tokens", "content": [{"type": "text", "text": "incomplete summary"}]}
            return text("complete summary")
        self.reply = reply
        result = self.run_agent(stdin="original goal\n/compact\ncontinue\n/usage\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r["max_tokens"] for r in attempts], [4096, 8192])
        self.assertEqual(attempts[0]["messages"], attempts[1]["messages"])
        self.assertIn("retrying once", result.stdout)
        self.assertIn("1 compaction(s)", result.stdout)
        saved = self.requests[-1][0]["messages"][0]["content"]
        self.assertIn("original goal", saved)
        self.assertIn("complete summary", saved)
        self.assertNotIn("incomplete summary", saved)

    def test_exhausted_summary_retry_preserves_history(self):
        self.reply = lambda body: text("initial answer") if "tools" in body else {"stop_reason": "max_tokens"}
        result = self.run_agent(stdin="original goal\n/save before\n/compact\n/save after\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 3)
        self.assertIn("IncompleteResponse", result.stdout)
        self.assertNotIn("Context compacted.", result.stdout)
        sessions = self.cwd / ".omnicode/sessions"
        self.assertEqual(json.loads((sessions / "before.json").read_text()),
                         json.loads((sessions / "after.json").read_text()))

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
        self.assertIn("Context · 14/128 messages", result.stdout)
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
        # Tool schema carries ephemeral cache_control breakpoint on the final tool.
        self.assertEqual(self.requests[0][0]["tools"][-1]["cache_control"], {"type": "ephemeral"})
        # Save, clear, and resume session (including todo checklist); reject traversal names.
        result = self.run_agent(stdin="first step\n/save work1\n/save ../escape\n/c\n/todo\n/resume work1\n/todo\ncontinue\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Session saved.", result.stdout)
        self.assertIn("InvalidSessionName", result.stdout)
        self.assertIn("Session resumed.", result.stdout)
        self.assertGreaterEqual(len(self.requests[-1][0]["messages"]), 3)

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
                return tools(call("bash", {"cmd": "printf '1\\n2\\n3\\n4\\n5\\n6\\n7\\n8\\n9\\n10\\n11\\n12\\n13\\n14\\n15\\n16\\n17\\n18\\n'"}))
            return text("finished")
        self.reply = reply
        compact = self.run_agent("list files")
        self.assertEqual(compact.returncode, 0, compact.stderr)
        self.assertIn("╭─ BASH  $ printf", compact.stdout)
        self.assertIn("✓ Done", compact.stdout)
        self.assertIn("6 lines hidden", compact.stdout)
        self.assertIn("18", compact.stdout)
        self.assertIn("1 tool call", compact.stdout)
        self.assertNotIn("\x1b", compact.stdout)
        verbose = self.run_agent("--verbose", "list files")
        self.assertEqual(verbose.returncode, 0, verbose.stderr)
        self.assertNotIn("lines hidden", verbose.stdout)
        self.assertIn("    │ 5\n", verbose.stdout)
        repl = self.run_agent(stdin="/help\n/model\n/verbose on\nlist files\n/verbose off\n/out list\n/out\n/out 1\n/q\n")
        self.assertEqual(repl.returncode, 0, repl.stderr)
        self.assertIn("Full tool output enabled", repl.stdout)
        self.assertGreaterEqual(repl.stdout.count("BASH output #1"), 2)
        self.assertIn("Recent Bash outputs", repl.stdout)
        self.assertIn("#1 · ✓ Done", repl.stdout)
        self.assertIn("BASH output #1 · ✓ Done", repl.stdout)
        self.assertIn("\n  $ printf", repl.stdout)
        self.assertIn("18", repl.stdout)
        self.assertNotIn("lines hidden", repl.stdout)
        self.assertIn("fast-test-model", repl.stdout)

    def test_recent_non_bash_tool_results_can_be_listed_and_replayed(self):
        (self.cwd / "first.txt").write_text("first-one\nfirst-two\nfirst-three\nfirst-four\nfirst-five\nfirst-six\n")
        (self.cwd / "second.txt").write_text("second-one\nsecond-two\n")

        def reply(body):
            if isinstance(body["messages"][-1]["content"], str):
                return tools(call("read", {"path": "first.txt"}, "first"),
                             call("read", {"path": "second.txt"}, "second"))
            return text("finished")

        self.reply = reply
        result = self.run_agent(stdin="read both files\n/details list\n/details 1\n/details #2\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Recent tool outputs", result.stdout)
        self.assertIn("#1 · read", result.stdout)
        self.assertIn("#2 · read", result.stdout)
        self.assertIn("TOOL #1 · read", result.stdout)
        self.assertIn("TOOL #2 · read", result.stdout)
        self.assertIn("first-six", result.stdout)
        self.assertIn("second-two", result.stdout)
        self.assertEqual(len(self.requests), 2)

    def test_recent_output_index_unifies_bash_and_other_tools(self):
        (self.cwd / "target.txt").write_text("tool-result-marker\n")

        def reply(body):
            if isinstance(body["messages"][-1]["content"], str):
                return tools(call("bash", {"cmd": "printf bash-result-marker"}, "bash"),
                             call("read", {"path": "target.txt"}, "read"))
            return text("finished")

        self.reply = reply
        result = self.run_agent(stdin="run both tools\n/details list\n/details 1\n/details #2\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        listing = result.stdout.split("Recent tool outputs", 1)[-1].split("Use /details", 1)[0]
        self.assertIn("#2 · read", listing, listing)
        self.assertIn("#1 · BASH", listing, listing)
        self.assertLess(listing.index("#2 · read"), listing.index("#1 · BASH"))
        self.assertIn("BASH output #1", result.stdout)
        self.assertIn("TOOL #2 · read", result.stdout)
        self.assertIn("bash-result-marker", result.stdout)
        self.assertIn("tool-result-marker", result.stdout)

    def test_new_secrets_scrub_already_retained_tool_results(self):
        secret = "late-retained-secret-773"
        (self.cwd / "secret.txt").write_text(secret + "\n")
        self.reply = lambda _: tools(call("read", {"path": "secret.txt"})) if len(self.requests) == 1 else text("read complete")
        result = self.run_agent(stdin=f"read secret file\n/secrets set TOKEN {secret}\n/details 1\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        replay = result.stdout.rsplit("TOOL #1", 1)[-1]
        self.assertIn("[REDACTED:TOKEN]", replay)
        self.assertNotIn(secret, replay)
        self.assertEqual(len(self.requests), 2)

    def test_help_search_filters_commands_case_insensitively(self):
        result = self.run_agent(stdin="/help tmux\n/help OuTpUt\n/help no-such-help-topic\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Help matches for "tmux":', result.stdout)
        self.assertIn("/tmux [status|on|off]", result.stdout)
        self.assertIn('Help matches for "OuTpUt":', result.stdout)
        self.assertIn("Ctrl+O", result.stdout)
        self.assertIn("No help entries match that topic.", result.stdout)
        self.assertEqual(self.requests, [])

    def test_slash_browses_only_repl_commands_without_a_model_request(self):
        result = self.run_agent(stdin="/\n/commands\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("Interactive commands"), 2)
        self.assertIn("/tmux [status|on|off]", result.stdout)
        self.assertIn("Ctrl+O", result.stdout)
        self.assertNotIn("--free", result.stdout)
        self.assertNotIn("Config:", result.stdout)
        self.assertEqual(self.requests, [])

    def test_slash_command_index_lists_local_skill_metadata(self):
        self.skill()
        result = self.run_agent(stdin="/\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Available skills (load with /skill NAME)", result.stdout)
        self.assertIn("- check: Check the project", result.stdout)
        self.assertEqual(self.requests, [])

    def test_retained_details_replace_and_sanitize(self):
        self.reply = lambda _: tools(call("bash", {"cmd": "printf 'first\\n2\\n3\\n4\\n5\\n6\\nlast\\033[2J'"})) if len(self.requests) == 1 else text()
        result = self.run_agent(stdin="/details\nlist files\n/details\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No retained tool output", result.stdout)
        self.assertIn("Last tool result", result.stdout)
        self.assertIn("    4\n", result.stdout)
        self.assertNotIn("\x1b", result.stdout)

    def test_invalid_environment_credentials_are_rejected_before_http(self):
        for provider, key_name in (("anthropic", "ANTHROPIC_API_KEY"), ("openai", "OPENAI_API_KEY")):
            for control in ("\r\nX-Injected: yes", "\r", "\n", "\x01", "\x7f"):
                with self.subTest(provider=provider, control=repr(control)):
                    marker = "private-invalid-credential"
                    self.env["PROVIDER"] = provider
                    self.env[key_name] = marker + control
                    result = self.run_agent(stdin="inspect project\n/q\n")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("InvalidHttpHeader", result.stdout)
                    self.assertIn("Check the selected provider key", result.stdout)
                    self.assertNotIn(marker, result.stdout + result.stderr)
                    self.assertNotIn("X-Injected", result.stdout + result.stderr)
                    self.assertEqual(self.requests, [])

    def test_http_failures_have_safe_actionable_diagnostics(self):
        marker = "provider-error-body-must-stay-private"
        for status, error, hint in (
            (401, "ApiAuthenticationFailed", "selected provider key"),
            (403, "ApiAccessDenied", "permissions"),
            (429, "ApiRateLimited", "Wait before retrying"),
            (503, "ApiServerError", "provider availability"),
            (529, "ApiServerError", "provider availability"),
            (400, "ApiError", "endpoint"),
        ):
            with self.subTest(status=status):
                self.requests.clear()
                self.reply = lambda _, status=status: (status, {"error": marker + " fake-anthropic"})
                result = self.run_agent(stdin="inspect project\n/q\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(error, result.stdout)
                self.assertIn(hint, result.stdout)
                self.assertIn(f"API HTTP {status}", result.stderr)
                self.assertNotIn(marker, result.stdout + result.stderr)
                self.assertNotIn("fake-anthropic", result.stdout + result.stderr)
                self.assertEqual(len(self.requests), 3 if status == 503 else 1)

    def test_invalid_json_response_is_reported_without_echoing_body(self):
        self.reply = lambda _: b"<html>private-response-body fake-anthropic</html>"
        result = self.run_agent(stdin="inspect project\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("InvalidJsonResponse", result.stdout)
        self.assertIn("Check the endpoint", result.stdout)
        self.assertNotIn("private-response-body", result.stdout + result.stderr)
        self.assertNotIn("fake-anthropic", result.stdout + result.stderr)
        self.assertEqual(len(self.requests), 1)

    def test_nul_voice_and_secret_import_paths_fail_without_io_side_effects(self):
        secret = "must-not-import-private-token"
        (self.cwd / "import.env").write_text(f"TOKEN={secret}\n")
        (self.cwd / "clip.wav").write_bytes(b"RIFFfixtureWAVE")
        result = self.run_agent(stdin=(
            "/voice clip.wav\x00suffix.wav\n"
            "/secrets load import.env\x00suffix\n"
            "/secrets\n/q\n"
        ))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("InvalidPath"), 2)
        self.assertIn("no custom secrets stored", result.stdout)
        self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertFalse((self.cwd / ".config/omnicode/secrets.env").exists())
        self.assertEqual(self.requests, [])
        self.assertEqual(self.catalog_requests, [])

    def test_nul_tool_arguments_fail_without_side_effects_and_recover(self):
        (self.cwd / "file").write_text("original")
        def reply(_):
            if len(self.requests) == 1:
                return tools(
                    call("write", {"path": "file\x00suffix", "content": "overwrite"}, "write"),
                    call("edit", {"path": "file\x00suffix", "old": "original", "new": "changed"}, "edit"),
                    call("read", {"path": "file\x00suffix"}, "read"),
                    call("bash", {"cmd": "touch forbidden\x00; false"}, "bash"),
                    call("glob", {"pat": "*\x00suffix"}, "glob"),
                    call("grep", {"pat": "original", "path": "file\x00suffix"}, "grep"),
                )
            errors = self.requests[-1][0]["messages"][-1]["content"]
            self.assertEqual(len(errors), 6)
            for block in errors:
                self.assertTrue(block["is_error"])
                self.assertIn("NUL", block["content"])
            return text("recovered after invalid arguments")
        self.reply = reply
        result = self.run_agent("inspect malformed arguments")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.cwd / "file").read_text(), "original")
        self.assertFalse((self.cwd / "forbidden").exists())
        self.assertIn("recovered after invalid arguments", result.stdout)
        self.assertEqual(len(self.requests), 2)

    def test_overlapping_edit_is_rejected_until_all_is_requested(self):
        (self.cwd / "overlap.txt").write_text("aaa")
        def reply(_):
            if len(self.requests) == 1:
                return tools(call("edit", {"path": "overlap.txt", "old": "aa", "new": "x"}, "ambiguous"))
            if len(self.requests) == 2:
                self.assertEqual((self.cwd / "overlap.txt").read_text(), "aaa")
                error = self.requests[-1][0]["messages"][-1]["content"][0]
                self.assertTrue(error["is_error"])
                self.assertIn("AmbiguousMatch", error["content"])
                return tools(call("edit", {"path": "overlap.txt", "old": "aa", "new": "x", "all": True}, "all"))
            return text("done")
        self.reply = reply
        result = self.run_agent("fix overlapping text")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.cwd / "overlap.txt").read_text(), "xa")
        self.assertEqual(len(self.requests), 3)

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
                    output.clear()
                    os.write(master, b"manual first\n")
                    until("  … ".encode())
                    self.assertEqual(len(self.requests), 1)
                    output.clear()
                    os.write(master, b"\x0f")
                    until(b"No retained Bash output.")
                    until(b"manual first")
                    until("  … ".encode())
                    os.write(master, b"manual second\r")
                    until(b"paste accepted")
                    until(b"\x1b[?2004h")
                    self.assertEqual(self.requests[-1][0]["messages"][-1]["content"], "manual first\nmanual second")
                    if finish == b"/q\r":
                        output.clear()
                        os.write(master, b"/to\x1bOP\x1bOQ\x1bOR\x1bOS\x1bOH\x1bOFdo\r")
                        until(b"(empty todo list)")
                        until(b"\x1b[?2004h")
                        output.clear()
                        os.write(master, b"\x1bOA\x1bOB\x1b[A\r")
                        until(b"(empty todo list)")
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
        output = self.run_pty(b"list files\n/model anthropic pinned-model\n/status inline\n/status title\n/status off\n/status bogus\n/exit\n", cols=100)
        lines = [l for l in output.replace("\r", "").split("\n") if " · " in l and "anthropic" in l and "~" in l]
        self.assertGreaterEqual(len(lines), 2, output)
        # Default mode is pinned at the bottom row (row 24 of 24) with DECSTBM 1..23.
        self.assertIn("\x1b[1;23r\x1b[24;1H", lines[0])
        self.assertRegex(lines[0], r"anthropic · auto · ~/nested · \d\d:\d\d")
        self.assertIn("auto → fast-test-model", lines[1])
        self.assertIn("anthropic · pinned-model · ~/nested", output)
        self.assertIn("\x1b[r", output)
        self.assertIn("\x1b]0;omnicode · anthropic · pinned-model", output)
        self.assertIn("\x1b[22;0t", output)
        self.assertIn("\x1b[23;0t", output)
        self.assertIn("usage: /status inline|pinned|title|off (current: off)", output)
        # Width comes from the terminal, not COLUMNS; the line never exceeds it.
        self.env["COLUMNS"] = "160"
        self.env["OMNICODE_STATUS"] = "inline"
        output = self.run_pty(b"/exit\n", cols=50)
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
        self.env.pop("OPENROUTER_API_KEY", None)
        for args in [("--help",), ("--version",), ("--skills",), ("--init",), ("--setup",), ("--secrets",)]:
            self.assertEqual(self.run_agent(*args).returncode, 0)
        self.assertIn("0.2.0", self.run_agent("--version").stdout)
        self.assertTrue((self.cwd / "OMNICODE.md").exists())
        self.assertTrue((self.cwd / ".omnicode/skills/verify/SKILL.md").exists())
        result = self.run_agent("list files")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MissingApiKey", result.stderr)
        self.assertEqual(self.requests, [])

    def test_setup_multi_provider_keys_and_voice_transcription(self):
        # 1. Configure DeepSeek via offline --setup; verify config.env permissions and masked display.
        self.env.pop("ANTHROPIC_API_KEY", None)
        self.env.pop("OPENROUTER_API_KEY", None)
        self.env.pop("PROVIDER", None)
        self.env.pop("MODEL", None)
        self.env.pop("FAST_MODEL", None)
        setup_res = self.run_agent("--setup", "deepseek", "sk-deepseek-secret-9876")
        self.assertEqual(setup_res.returncode, 0, setup_res.stderr)
        self.assertIn("configured (***)", setup_res.stdout)
        self.assertNotIn("sk-d", setup_res.stdout)
        self.assertNotIn("9876", setup_res.stdout)
        self.assertNotIn("secret", setup_res.stdout)
        cfg_file = Path(self.tmp.name) / ".config/omnicode/config.env"
        self.assertTrue(cfg_file.exists())
        self.assertEqual(cfg_file.stat().st_mode & 0o777, 0o600)
        # Subsequent run loads DEEPSEEK_API_KEY and PROVIDER=deepseek from config.env.
        self.reply = lambda _: text("deepseek reply")
        run_ds = self.run_agent("explain code")
        self.assertEqual(run_ds.returncode, 0, run_ds.stderr)
        self.assertEqual(self.requests[-1][0]["model"], "deepseek-flash")
        self.assertEqual(self.requests[-1][1]["authorization"], "Bearer sk-deepseek-secret-9876")

        # 2. In REPL: configure OpenRouter via /setup, transcribe a WAV file and a recorded voice clip via /voice.
        self.requests.clear()
        self.catalog_requests.clear()
        self.catalog["data"].extend([
            {"id": "expensive/audio-model", "pricing": {"prompt": "0.00001", "completion": "0.00002"},
             "context_length": 65536, "supported_parameters": ["tools"],
             "architecture": {"input_modalities": ["text", "audio"], "output_modalities": ["text"]}},
            {"id": "cheap/voice-flash", "pricing": {"prompt": "0.00000005", "completion": "0.0000001"},
             "context_length": 65536, "supported_parameters": ["tools"],
             "architecture": {"input_modalities": ["text", "audio"], "output_modalities": ["text"]}},
        ])
        (self.cwd / "sample.wav").write_bytes(b"RIFF\x24\x00\x00\x00WAVEfmt ")
        self.env["OMNICODE_VOICE_CMD"] = 'printf "RIFFrecorded" > "$OMNICODE_VOICE_OUT"'
        def voice_and_turn_reply(body):
            content = body["messages"][0]["content"]
            if isinstance(content, list) and any(b.get("type") == "input_audio" for b in content):
                return {"choices": [{"message": {"content": "list project files"}}],
                        "usage": {"input_tokens": 25, "output_tokens": 4, "cost": 0.00001}}
            return text("voice command executed")
        self.reply = voice_and_turn_reply
        repl = self.run_agent(stdin=(
            "/providers xai xai-key-9999\n"
            "/providers\n"
            "/setup openrouter sk-or-voice-key-1234\n"
            "/providers 2\n"
            "/setup\n"
            "/voice sample.wav\n"
            "/voice model custom/voice-model\n"
            "/providers xai\n"
            "/voice record 1\n"
            "/exit\n"
        ))
        self.assertEqual(repl.returncode, 0, repl.stderr)
        self.assertIn("Configured xai", repl.stdout)
        self.assertIn("Providers (* = active):", repl.stdout)
        self.assertIn("Active provider set to openrouter", repl.stdout)
        self.assertIn("configured (***)", repl.stdout)
        self.assertNotIn("sk-or-voice-key-1234", repl.stdout)
        self.assertEqual(repl.stdout.count("Voice: list project files"), 2)
        self.assertEqual(repl.stdout.count("voice command executed"), 2)
        # First /voice selected cheap/voice-flash from the OpenRouter catalog; second used pinned custom/voice-model.
        audio_reqs = [r[0] for r in self.requests if isinstance(r[0]["messages"][0]["content"], list)]
        self.assertEqual([r["model"] for r in audio_reqs], ["cheap/voice-flash", "custom/voice-model"])
        self.assertEqual(audio_reqs[0]["messages"][0]["content"][1]["input_audio"]["format"], "wav")

    def test_voice_prompt_survives_model_error_and_history_reset(self):
        self.env["PROVIDER"] = "openrouter"
        self.env["VOICE_MODEL"] = "custom/voice-model"
        self.catalog = {"data": []}
        (self.cwd / "sample.wav").write_bytes(b"RIFF" + bytes([36, 0, 0, 0]) + b"WAVEfmt ")
        self.reply = lambda _: text("list project files")

        result = self.run_agent(stdin="/voice sample.wav\n/q\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Voice: list project files", result.stdout)
        self.assertIn("No eligible model in the live catalog", result.stdout)
        self.assertEqual(len(self.requests), 1)

    def test_init_preserves_existing_instruction_entries_without_force(self):
        destination = self.cwd / "OMNICODE.md"
        target = self.cwd / "instruction-target"
        for kind in ("large file", "unreadable file", "dangling symlink", "symlink", "directory"):
            with self.subTest(kind=kind):
                if destination.is_symlink() or destination.is_file():
                    destination.unlink()
                elif destination.exists():
                    destination.rmdir()
                target.unlink(missing_ok=True)
                if kind == "directory":
                    destination.mkdir()
                elif "symlink" in kind:
                    if kind == "symlink": target.write_text("keep target")
                    destination.symlink_to(target)
                else:
                    destination.write_text("x" * 65537 if kind == "large file" else "keep instructions")
                    if kind == "unreadable file": destination.chmod(0)
                result = self.run_agent("--init")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("AlreadyInitialized", result.stderr)
                if "symlink" in kind:
                    self.assertTrue(destination.is_symlink())
                    if kind == "symlink": self.assertEqual(target.read_text(), "keep target")
                    else: self.assertFalse(target.exists())
                elif kind == "directory":
                    self.assertTrue(destination.is_dir())
                else:
                    destination.chmod(0o600)
                    self.assertEqual(destination.read_text(), "x" * 65537 if kind == "large file" else "keep instructions")
                self.assertEqual(self.requests, [])

    def test_init_preserves_existing_verify_skill_links_and_large_files(self):
        skill = self.cwd / ".omnicode/skills/verify/SKILL.md"
        skill.parent.mkdir(parents=True)
        target = self.cwd / "skill-target"
        for kind in ("large file", "dangling symlink", "symlink"):
            with self.subTest(kind=kind):
                (self.cwd / "OMNICODE.md").unlink(missing_ok=True)
                skill.unlink(missing_ok=True)
                target.unlink(missing_ok=True)
                if kind == "large file": skill.write_text("x" * 65537)
                else:
                    if kind == "symlink": target.write_text("keep skill")
                    skill.symlink_to(target)
                result = self.run_agent("--init")
                self.assertEqual(result.returncode, 0, result.stderr)
                if kind == "large file": self.assertEqual(skill.read_text(), "x" * 65537)
                else:
                    self.assertTrue(skill.is_symlink())
                    if kind == "symlink": self.assertEqual(target.read_text(), "keep skill")
                    else: self.assertFalse(target.exists())
                self.assertIn("preserved the existing verification skill", result.stdout)
                self.assertTrue((self.cwd / "OMNICODE.md").is_file())
                self.assertEqual(self.requests, [])

    @unittest.skipUnless(hasattr(os, "mkfifo"), "requires POSIX FIFOs")
    def test_read_only_tools_reject_special_files_and_continue(self):
        os.mkfifo(self.cwd / "pipe")
        (self.cwd / "pipe-link").symlink_to("pipe")
        (self.cwd / "regular").write_text("inspectable")
        (self.cwd / "regular-link").symlink_to("regular")
        def reply(body):
            if len(self.requests) == 1:
                return tools(call("read", {"path": "pipe"}, "pipe"),
                             call("read", {"path": "pipe-link", "byte_limit": 4}, "link"),
                             call("read", {"path": "."}, "directory"))
            if len(self.requests) == 2:
                for result in body["messages"][-1]["content"]:
                    self.assertTrue(result["is_error"])
                    self.assertIn("NotRegularFile", result["content"])
                    self.assertIn("regular file", result["content"])
                return tools(call("read", {"path": "regular-link"}, "regular"))
            self.assertIn("inspectable", body["messages"][-1]["content"][0]["content"])
            return text("continued after special-file errors")
        self.reply = reply
        result = self.run_agent("--read-only", "inspect project")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 3)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "requires POSIX FIFOs")
    def test_special_project_instructions_fail_before_api_requests(self):
        os.mkfifo(self.cwd / "OMNICODE.md")
        result = self.run_agent("inspect project")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NotRegularFile", result.stderr)
        self.assertEqual(self.requests, [])

    @unittest.skipUnless(hasattr(os, "mkfifo"), "requires POSIX FIFOs")
    def test_file_tools_reject_special_write_targets_and_continue(self):
        os.mkfifo(self.cwd / "pipe")
        (self.cwd / "pipe-link").symlink_to("pipe")
        def reply(body):
            if len(self.requests) == 1:
                return tools(call("write", {"path": "pipe", "content": "bad"}, "pipe"),
                             call("write", {"path": "pipe-link", "content": "bad"}, "link"),
                             call("edit", {"path": "pipe", "old": "bad", "new": "bad"}, "edit"))
            if len(self.requests) == 2:
                for result in body["messages"][-1]["content"]:
                    self.assertTrue(result["is_error"])
                    self.assertIn("NotRegularFile", result["content"])
                return tools(call("write", {"path": "nested/regular", "content": "recovered"}, "regular"))
            return text("continued after rejected writes")
        self.reply = reply
        result = self.run_agent("create project files")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 3)
        self.assertEqual((self.cwd / "nested/regular").read_text(), "recovered")
        self.assertTrue((self.cwd / "pipe").is_fifo())
        self.assertTrue((self.cwd / "pipe-link").is_symlink())
        (self.cwd / "regular-link").symlink_to("nested/regular")
        self.requests.clear()
        self.reply = lambda _: tools(call("write", {"path": "regular-link", "content": "updated"})) if len(self.requests) == 1 else text()
        result = self.run_agent("update regular file through its link")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.cwd / "nested/regular").read_text(), "updated")
        self.assertTrue((self.cwd / "regular-link").is_symlink())

    @unittest.skipUnless(hasattr(os, "mkfifo"), "requires POSIX FIFOs")
    def test_forced_init_checks_both_targets_before_overwriting_instructions(self):
        instructions = self.cwd / "OMNICODE.md"
        os.mkfifo(instructions)
        result = self.run_agent("--init", "force")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NotRegularFile", result.stderr)
        self.assertTrue(instructions.is_fifo())
        instructions.unlink()
        instructions.write_text("preserve original instructions")
        skill = self.cwd / ".omnicode/skills/verify/SKILL.md"
        skill.parent.mkdir(parents=True, exist_ok=True)
        os.mkfifo(skill)
        result = self.run_agent("--init", "force")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NotRegularFile", result.stderr)
        self.assertEqual(instructions.read_text(), "preserve original instructions")
        self.assertTrue(skill.is_fifo())
        self.assertEqual(self.requests, [])

    @unittest.skipUnless(hasattr(os, "mkfifo"), "requires POSIX FIFOs")
    def test_special_config_and_vault_fail_before_api_requests(self):
        pipe = self.cwd / "state-pipe"
        os.mkfifo(pipe)
        for variable in ("OMNICODE_CONFIG", "OMNICODE_SECRETS"):
            with self.subTest(variable=variable):
                self.env[variable] = str(pipe)
                try:
                    result = self.run_agent("inspect project")
                finally:
                    del self.env[variable]
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("NotRegularFile", result.stderr)
                self.assertTrue(pipe.is_fifo())
                self.assertEqual(self.requests, [])

    @unittest.skipUnless(hasattr(os, "mkfifo"), "requires POSIX FIFOs")
    def test_special_resume_preserves_live_conversation(self):
        sessions = self.cwd / ".omnicode/sessions"
        sessions.mkdir(parents=True)
        os.mkfifo(sessions / "blocked.json")
        result = self.run_agent("--session", "blocked", "inspect project")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NotRegularFile", result.stderr)
        self.assertEqual(self.requests, [])
        result = self.run_agent(stdin="original task\n/resume blocked\n/save retained\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("NotRegularFile", result.stdout)
        saved = json.loads((sessions / "retained.json").read_text())
        self.assertEqual(saved["messages"][0]["content"], "original task")
        self.assertEqual(len(self.requests), 1)
        self.assertTrue((sessions / "blocked.json").is_fifo())

    @unittest.skipUnless(hasattr(os, "mkfifo"), "requires POSIX FIFOs")
    def test_special_import_audio_and_timezone_inputs_do_not_block(self):
        pipe = self.cwd / "input-pipe"
        os.mkfifo(pipe)
        self.env["TZ"] = str(pipe)
        self.env["OMNICODE_SECRETS"] = str(self.cwd / "vault.env")
        result = self.run_agent(stdin="/secrets set TOKEN synthetic-value\n/secrets load input-pipe\n/secrets list\n/voice input-pipe\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("NotRegularFile"), 2)
        self.assertIn("TOKEN", result.stdout)
        self.assertNotIn("synthetic-value", result.stdout + result.stderr)
        self.assertTrue(pipe.is_fifo())
        self.assertEqual(self.requests, [])
        self.assertEqual(self.catalog_requests, [])

    @unittest.skipUnless(hasattr(os, "mkfifo"), "requires POSIX FIFOs")
    def test_init_detects_large_manifest_without_reading_special_files(self):
        os.mkfifo(self.cwd / "build.zig")
        (self.cwd / "Cargo.toml").mkdir()
        (self.cwd / "package.json").write_text(" " * (64 * 1024) + "{}")
        result = self.run_agent("--init")
        self.assertEqual(result.returncode, 0, result.stderr)
        instructions = (self.cwd / "OMNICODE.md").read_text()
        self.assertIn("npm run build", instructions)
        self.assertNotIn("zig build", instructions)
        self.assertNotIn("cargo build", instructions)
        self.assertEqual(self.requests, [])
        (self.cwd / "build.zig").unlink()
        (self.cwd / "marker").write_text("// zig build marker")
        (self.cwd / "build.zig").symlink_to("marker")
        result = self.run_agent("--init", "force")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("zig build test", (self.cwd / "OMNICODE.md").read_text())

    def test_init_project_instructions_and_adversarial_multi_agent_review(self):
        (self.cwd / "build.zig").write_text("// zig build")
        (self.cwd / "target.zig").write_text("pub fn add(a: i32, b: i32) i32 { return a + b; }\n")
        def reply(body):
            sys_prompt = body["system"]
            if "Correctness & Security Critic" in sys_prompt:
                # Critic 1 inspects target.zig first, then passes.
                if len(body["messages"]) == 1:
                    return tools(call("read", {"path": "target.zig"}, "rc1"))
                return text("target.zig:1 checked arithmetic bounds.\nVERDICT: PASS")
            if "Anti-Slop & Simplicity Critic" in sys_prompt:
                # Critic 2 flags slop on the first review call, then passes on /review.
                if "focus: strict" in body["messages"][0]["content"]:
                    return text("target.zig:1 unused helper wrapper.\nVERDICT: FAIL")
                return text("Minimal implementation.\nVERDICT: PASS")
            # Parent agent calls review tool on first turn, then finishes.
            if isinstance(body["messages"][-1]["content"], str):
                return tools(call("review", {"focus": "focus: strict"}, "rev1"))
            return text("addressed review findings")
        self.reply = reply
        result = self.run_agent(stdin="/init\n/init\n/init force\nimplement feature\n/review final check\n/details\n/exit\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Initialized OMNICODE.md", result.stdout)
        self.assertIn("AlreadyInitialized", result.stdout)
        # OMNICODE.md is injected into the system prompt after /init.
        self.assertIn("Project instructions (OMNICODE.md):", self.requests[0][0]["system"])
        self.assertIn("zig build test", self.requests[0][0]["system"])
        # First review (via tool): Correctness Critic used read tool and passed; Anti-Slop Critic failed -> OVERALL VERDICT: FAIL.
        tool_reply = self.requests[4][0]["messages"][-1]["content"][0]["content"]
        self.assertIn("=== Correctness & Security Critic ===", tool_reply)
        self.assertIn("=== Anti-Slop & Simplicity Critic ===", tool_reply)
        self.assertIn("OVERALL VERDICT: FAIL", tool_reply)
        # Second review (via /review REPL command): both critics pass -> OVERALL VERDICT: PASS.
        self.assertIn("OVERALL VERDICT: PASS", result.stdout)
        # Critic models: strong-test-model for correctness critic (2 turns each), fast-test-model for anti-slop critic (1 turn each).
        critic_models = [r[0]["model"] for r in self.requests if "Critic" in r[0]["system"]]
        self.assertEqual(critic_models, [
            "strong-test-model", "strong-test-model", "fast-test-model",
            "strong-test-model", "strong-test-model", "fast-test-model",
        ])

    def test_secrets_vault_scrubbing_and_model_browser_switching(self):
        (self.cwd / ".env.secret").write_text("export LOGIN_TOKEN='tok_live_ultra_secret_777'\n")
        self.env["DEEPSEEK_API_KEY"] = "sk-deepseek-key-1111"
        def reply(body):
            if isinstance(body["messages"][-1]["content"], str) and len(self.requests) == 1:
                return tools(
                    call("bash", {"cmd": 'printf "db=%s tok=%s" "$DB_PASS" "$LOGIN_TOKEN"'}, "sb1"),
                    call("read", {"path": ".env.secret"}, "sr1"),
                )
            return text("completed securely")
        self.reply = reply
        result = self.run_agent(stdin=(
            "/secrets set DB_PASS hunter2_super_secret\n"
            "/secrets load .env.secret\n"
            "/secrets\n"
            "check login using hunter2_super_secret\n"
            "/details\n"
            "/model list\n"
            "/model 2\n"
            "second turn on model #2\n"
            "/model deepseek-reasoner\n"
            "third turn on inferred deepseek\n"
            "/exit\n"
        ))
        self.assertEqual(result.returncode, 0, result.stderr)
        secrets_file = Path(self.tmp.name) / ".config/omnicode/secrets.env"
        self.assertTrue(secrets_file.exists())
        self.assertEqual(secrets_file.stat().st_mode & 0o777, 0o600)
        # Raw secrets must never appear anywhere in stdout or outbound LLM messages/tool_results.
        self.assertNotIn("hunter2_super_secret", result.stdout)
        self.assertNotIn("tok_live_ultra_secret_777", result.stdout)
        all_requests_json = json.dumps([r[0] for r in self.requests])
        self.assertNotIn("hunter2_super_secret", all_requests_json)
        self.assertNotIn("tok_live_ultra_secret_777", all_requests_json)
        # System prompt advertises secret names only.
        self.assertIn("Available secret env vars (values hidden; reference as $NAME in bash): DB_PASS, LOGIN_TOKEN", self.requests[0][0]["system"])
        # User prompt and tool results have secrets scrubbed to [REDACTED:<NAME>].
        self.assertIn("[REDACTED:DB_PASS]", self.requests[0][0]["messages"][0]["content"])
        tool_outputs = {r["tool_use_id"]: r["content"] for r in self.requests[1][0]["messages"][-1]["content"]}
        self.assertEqual(tool_outputs["sb1"], "db=[REDACTED:DB_PASS] tok=[REDACTED:LOGIN_TOKEN]")
        self.assertIn("[REDACTED:LOGIN_TOKEN]", tool_outputs["sr1"])
        # /model list showed numbered models and switching by #2 and by model ID preserved conversation history!
        self.assertIn("Available models:", result.stdout)
        self.assertEqual([r[0]["model"] for r in self.requests], [
            "fast-test-model", "fast-test-model", "fast-test-model", "deepseek-reasoner"
        ])
        self.assertGreaterEqual(len(self.requests[-1][0]["messages"]), 5)

    def test_agentic_workflow_max_tokens_recovery_and_error_guidance(self):
        (self.cwd / "box.py").write_text("width = 10\n")
        def reply(body):
            n = len(self.requests)
            if n == 1:
                # Response 1 hits max_tokens mid-generation with thinking + partial text + truncated write tool_use.
                return {
                    "stop_reason": "max_tokens",
                    "content": [
                        {"type": "thinking", "thinking": "long design calculation"},
                        {"type": "text", "text": "Designing parametric food carton..."},
                        call("write", {"path": "truncated.py", "content": "should_not_run"}, "bad_w"),
                    ],
                }
            if n == 2:
                # After automatic continuation prompt, model calls edit twice with a missing string to trigger guidance + repeat guard.
                return tools(
                    call("edit", {"path": "box.py", "old": "nonexistent", "new": "20"}, "e1"),
                    call("edit", {"path": "box.py", "old": "nonexistent", "new": "20"}, "e2"),
                )
            if n == 3:
                # Model now writes/edits cleanly.
                return tools(call("edit", {"path": "box.py", "old": "width = 10", "new": "width = 20"}, "e3"))
            return text("Food box design complete.")
        self.reply = reply
        result = self.run_agent("design a to-go carton foodbox")
        self.assertEqual(result.returncode, 0, result.stderr)
        # Truncated tool call from max_tokens response must never execute.
        self.assertFalse((self.cwd / "truncated.py").exists())
        # Partial text from the truncated response was shown, followed by automatic recovery.
        self.assertIn("Designing parametric food carton...", result.stdout)
        self.assertIn("Response hit output token limit; continuing automatically in smaller steps...", result.stdout)
        self.assertIn("Food box design complete.", result.stdout)
        self.assertEqual((self.cwd / "box.py").read_text(), "width = 20\n")
        # Request 3 received actionable MatchNotFound hint and repeated-failure loop-breaker note.
        err_results = {r["tool_use_id"]: r["content"] for r in self.requests[2][0]["messages"][-1]["content"]}
        self.assertIn("use read", err_results["e1"])
        self.assertIn("Identical tool call failed again", err_results["e2"])


if __name__ == "__main__":
    unittest.main()
