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

    def test_oversized_piped_input_recovers_at_next_line(self):
        result = self.run_agent(stdin="x" * 16385 + "\n/help\n/q\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("InputTooLong", result.stdout)
        self.assertIn("omnicode [--free", result.stdout)
        self.assertEqual(self.requests, [])

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
                self.assertEqual(len(self.requests), 1)

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
        self.assertIn("sk-d...9876", setup_res.stdout)
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
            "/voice record 1\n"
            "/exit\n"
        ))
        self.assertEqual(repl.returncode, 0, repl.stderr)
        self.assertIn("Configured xai", repl.stdout)
        self.assertIn("Providers (* = active):", repl.stdout)
        self.assertIn("Active provider set to openrouter", repl.stdout)
        self.assertIn("sk-o...1234", repl.stdout)
        self.assertEqual(repl.stdout.count("Voice: list project files"), 2)
        self.assertEqual(repl.stdout.count("voice command executed"), 2)
        # First /voice selected cheap/voice-flash from the OpenRouter catalog; second used pinned custom/voice-model.
        audio_reqs = [r[0] for r in self.requests if isinstance(r[0]["messages"][0]["content"], list)]
        self.assertEqual([r["model"] for r in audio_reqs], ["cheap/voice-flash", "custom/voice-model"])
        self.assertEqual(audio_reqs[0]["messages"][0]["content"][1]["input_audio"]["format"], "wav")

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
