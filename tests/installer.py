#!/usr/bin/env python3
"""Run the real installer against offline release fixtures in an isolated PATH."""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"
ASSET = "omnicode-linux-x86_64.tar.gz"


class Installer(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("mktemp", "rm", "mkdir", "tar", "gzip", "install", "awk", "cp", "sha256sum"):
            (self.bin / name).symlink_to(shutil.which(name))
        self.script("uname", 'case "$1" in -s) echo Linux;; -m) echo x86_64;; esac\n')
        self.script("curl", '''url="$2"
out="$4"
case "$url" in
    */SHA256SUMS) cp "$FIXTURES/SHA256SUMS" "$out" ;;
    *) cp "$FIXTURES/archive" "$out" ;;
esac
''')
        body = b"#!/bin/sh\necho fixture-version\n"
        with tarfile.open(self.root / "archive", "w:gz") as archive:
            info = tarfile.TarInfo("omnicode")
            info.size = len(body)
            info.mode = 0o755
            archive.addfile(info, io.BytesIO(body))
        self.digest = hashlib.sha256((self.root / "archive").read_bytes()).hexdigest()
        self.manifest(f"{self.digest}  {ASSET}\n")
        self.dest = self.root / "install with spaces"
        self.dest.mkdir()
        self.existing = self.dest / "omnicode"
        self.existing.write_text("existing binary")

    def script(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\nset -eu\n" + body)
        path.chmod(0o755)

    def manifest(self, text):
        (self.root / "SHA256SUMS").write_text(text)

    def run_installer(self):
        return subprocess.run(["/bin/sh", str(INSTALLER)], text=True, capture_output=True,
                              env={"PATH": str(self.bin), "HOME": str(self.root),
                                   "INSTALL_DIR": str(self.dest), "FIXTURES": str(self.root)},
                              timeout=10)

    def assert_rejected(self):
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.existing.read_text(), "existing binary")

    def test_verified_install_with_spaces(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("fixture-version", result.stdout)
        self.assertTrue(os.access(self.existing, os.X_OK))

    def test_checksum_download_failure(self):
        (self.root / "SHA256SUMS").unlink()
        self.assert_rejected()

    def test_missing_checksum_tool(self):
        (self.bin / "sha256sum").unlink()
        self.assert_rejected()

    def test_bad_manifests(self):
        for manifest in ("", f"{'0' * 64}  {ASSET}\n", f"invalid  {ASSET}\n",
                         f"{self.digest}  {ASSET}\n" * 2,
                         f"{self.digest}  other.tar.gz\n",
                         f"{self.digest}  {ASSET} extra\n"):
            with self.subTest(manifest=manifest):
                self.manifest(manifest)
                self.assert_rejected()

    def test_corrupted_archive(self):
        with (self.root / "archive").open("ab") as archive:
            archive.write(b"tampered")
        self.assert_rejected()


if __name__ == "__main__":
    unittest.main()
